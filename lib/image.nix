#
# The builder: turn a resolved partition list into ONE raw disk image --
# a plain, ordinary FILE, and nothing this repo ever writes to a block
# device. See modules/layout.nix's own header for the full safety model
# this function is the mechanism half of; this file is deliberately kept
# free of any notion of "roles" (esp/raw/luks) -- it only ever sees
# already-resolved records (a GPT type-GUID, a name, an optional vfat
# label, a size), the same "data separate from the module" split nixfs's
# lib/catalogue.nix draws between a fixed table and the module that reads
# it. modules/layout.nix is the one place role names get resolved into the
# fields this function actually consumes (lib/partition-roles.nix).
#
# HOW THIS AVOIDS EVERY PRIVILEGE A NIX BUILD SANDBOX DOES NOT HAVE: no
# loop device, no `mount`, no root. `sgdisk`/`sfdisk` operate on a plain
# regular file exactly as they would on a block device -- GPT tools do
# their own file I/O at whatever byte offset the table says, they do not
# require the target to BE a device node. The one partition role that
# needs real filesystem content (`esp`, formatted vfat) uses the same
# trick a second time: `mkfs.vfat -C <file> <size-in-KiB>` CREATES a
# fresh, correctly-sized plain file and formats it, again with no loop
# device involved, and the result is then `dd`'d into the main image at
# the exact byte offset `sgdisk`'s own `-i` (info) readback reports for
# that partition -- queried back from sgdisk itself rather than computed
# by hand here, so this never has to assume or re-derive sgdisk's own
# alignment behaviour (measured, not guessed: see studies/ for the write-up).
# The two other roles (`raw`, `luks`) get a correctly-sized, correctly-typed
# slot and nothing else -- this function never writes a single byte into
# either one's data region.
#
# PARTITION IDENTITY IS PINNABLE HERE, AND THAT IS NOT A COSMETIC KNOB. A
# GPT entry carries a UNIQUE partition GUID (what udev exposes as
# `/dev/disk/by-partuuid/*` and blkid prints as `PARTUUID=`) that is an
# entirely separate field from its TYPE GUID, and neither `sgdisk -n` nor
# an `sfdisk` script line lacking a `uuid=` field reproduces it: both mint
# a fresh random one on every run. So an image rebuilt from a completely
# unchanged declaration comes back identical in size, position, type and
# name -- and DIFFERENT in identity. Anything that recorded the old value
# then names a partition that no longer exists while the medium is still
# physically present: no blkid row, no by-partuuid symlink, and boot
# tooling that refuses to reconcile a boot tree it can no longer resolve.
# An optional `partUuid` on a partition record closes that -- `-u
# <n>:<guid>` on the sgdisk path, a `uuid=` field on the 4Kn sfdisk path,
# and nothing at all when it is unset, which is exactly the behaviour
# every declaration predating the field already had. See
# modules/layout.nix's own `partUuid` option for the full failure story.
{ pkgs }:

{ name, sizeMiB, partitions, sectorSize ? 512 }:

let
  lib = pkgs.lib;

  sizeBytes = sizeMiB * 1024 * 1024;

  # SECTOR SIZE IS NOT COSMETIC AND CANNOT BE LEFT TO THE TOOL'S DEFAULT.
  #
  # A GPT stores every start/end as a SECTOR NUMBER, so the same table means a
  # different byte layout at 512 than at 4096 -- by a factor of eight. An image
  # built at 512 and written to a 4Kn device does not "mostly work": the header
  # LBAs, the partition entries and the backup-header location all land wrong.
  #
  # `sgdisk` has NO sector-size override when operating on a plain FILE -- it
  # assumes 512 unconditionally, because it normally asks the kernel and a file
  # has nobody to ask. That is why 4Kn takes a different tool rather than a
  # different flag: `sfdisk --sector-size` is the one that can be told.
  #
  # The 512 path is deliberately left on sgdisk rather than unified onto sfdisk:
  # this builder's alignment behaviour was MEASURED against sgdisk (see the file
  # header and studies/), and the readback below re-queries sgdisk rather than
  # re-deriving its arithmetic. Rewriting the proven path to gain symmetry would
  # trade a measured basis for a tidier-looking one.
  is4k = sectorSize == 4096;

  indexed = lib.imap1 (i: p: p // { index = i; }) partitions;

  # sgdisk's own `-n partnum:start:end` syntax: `0` for `start` means "the
  # next available (aligned) sector" -- always what we want, there is no
  # per-partition start gap to express in this model. `end` is either an
  # explicit `+<N>MiB` or bare `0`, sgdisk's own syntax for "consume every
  # remaining usable sector" -- the ONE partition in the list allowed to
  # leave `sizeMiB` unset (asserted in modules/layout.nix, not here).
  endArgFor = p: if p.sizeMiB == null then "0" else "+${toString p.sizeMiB}MiB";

  # `p.partUuid or null`, not `p.partUuid`: this builder is ALSO exported
  # standalone as `lib.buildLayoutImage` (see flake.nix), so its partition
  # record is a public interface that outside callers hand-write. A field
  # added later must therefore be optional in the RECORD as well as in the
  # option -- a caller who has never heard of `partUuid` keeps building
  # exactly the image they built before. modules/layout.nix always passes
  # it (its submodule defaults it to `null`).
  partUuidOf = p: p.partUuid or null;

  sgdiskCreateArgs = lib.concatMap
    (p:
      [
        "-n"
        "${toString p.index}:0:${endArgFor p}"
        "-t"
        "${toString p.index}:${p.typeGuid}"
      ]
      # `-u` is sgdisk's flag for the partition's UNIQUE GUID -- its
      # identity, not its type (`-t`, just above, and a different field
      # entirely). Emitted ONLY when declared: without it sgdisk generates
      # a fresh random one per run, which stays the default.
      ++ lib.optionals (partUuidOf p != null) [
        "-u"
        "${toString p.index}:${partUuidOf p}"
      ]
      ++ [
        "-c"
        "${toString p.index}:${p.name}"
      ])
    indexed;

  espPartitions = lib.filter (p: p.formatted == "vfat") indexed;

  formatEspPartition = p: ''
    echo "nixstorage-layout: formatting partition ${toString p.index} (\"${p.name}\") as vfat..."
    ${if is4k then ''
    start_sector="$(sfdisk --sector-size 4096 --json "$out" | jq -r '.partitiontable.partitions[${toString (p.index - 1)}].start')"
    size_sectors="$(sfdisk --sector-size 4096 --json "$out" | jq -r '.partitiontable.partitions[${toString (p.index - 1)}].size')"
    '' else ''
    start_sector="$(sgdisk -i ${toString p.index} "$out" | awk '/^First sector/ {print $3}')"
    size_sectors="$(sgdisk -i ${toString p.index} "$out" | awk '/^Partition size/ {print $3}')"
    ''}
    size_kib=$(( size_sectors * ${toString sectorSize} / 1024 ))
    # `-u`: a unique PATH only, never the file itself -- `mkfs.vfat -C`
    # creates the file from nothing and refuses if it already exists, so
    # a plain `mktemp` (which pre-creates an empty file) would collide
    # with it (measured: "mkfs.vfat: file ... already exists").
    esp_tmp="$(mktemp -u)"
    mkfs.vfat ${lib.optionalString (p.espLabel != null) "-n ${lib.escapeShellArg p.espLabel}"} -C "$esp_tmp" "$size_kib" >&2
    # bs MUST be the medium's sector size: `seek` counts BLOCKS OF bs, and
    # start_sector is expressed in sectors. Mixing the two writes the ESP to
    # one eighth of its intended offset on a 4Kn image.
    dd if="$esp_tmp" of="$out" bs=${toString sectorSize} seek="$start_sector" conv=notrunc,fsync status=none
    rm -f "$esp_tmp"
  '';
in
pkgs.runCommand "nixstorage-layout-${name}.img"
{
  nativeBuildInputs = [ pkgs.gptfdisk pkgs.dosfstools ]
    ++ lib.optionals is4k [ pkgs.util-linux pkgs.jq ];
}
  ''
    set -euo pipefail

    # A plain, sparse FILE -- this is the entirety of what this derivation
    # ever touches. There is no device node anywhere in this build.
    truncate -s ${toString sizeBytes} "$out"

    ${lib.optionalString (sgdiskCreateArgs != [ ]) (
      if is4k then ''
        sfdisk --sector-size 4096 --label gpt "$out" >&2 <<'SFDISK_EOF'
${lib.concatMapStringsSep "\n" (p:
  "${if p.sizeMiB == null then "" else "size=${toString (p.sizeMiB * 1024 * 1024 / 4096)}, "}type=${p.typeGuid}, ${lib.optionalString (partUuidOf p != null) "uuid=${partUuidOf p}, "}name=\"${p.name}\"")
  indexed}
SFDISK_EOF
      '' else ''
        sgdisk ${lib.concatMapStringsSep " " lib.escapeShellArg sgdiskCreateArgs} "$out" >&2
      ''
    )}

    ${lib.concatMapStringsSep "\n" formatEspPartition espPartitions}

    echo "nixstorage-layout: built ${name} (${toString sizeMiB} MiB declared, ${toString (builtins.length partitions)} partition(s), ${toString (builtins.length espPartitions)} formatted vfat)"
  ''
