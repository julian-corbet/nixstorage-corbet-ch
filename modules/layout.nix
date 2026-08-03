# modules/layout.nix
#
# The LAYOUT half of nixstorage: `options.nixstorage.layout` declares how
# a piece of media is CARVED -- a partition table, sizes, roles (an ESP, a
# raw slot, an encrypted region) -- the third leg alongside shape.nix
# (what a dataset IS) and delivery.nix (where it SURFACES). This is the
# provisioning question those two files each explicitly refuse to answer:
# shape.nix's own header states its invariant applies to an EXISTING
# dataset and that creating one is "a second, explicitly separate,
# explicitly gated operation"; this file is that operation, one layer
# further down, at the media level rather than the ZFS-pool level.
#
# `layout` lives in this same repo, not a standalone one, because PRE-POOL vs POST-POOL is a
# ZFS-SHAPED boundary, not an implementation-neutral one -- a real line, drawn in a place only
# ZFS has. Under LVM there is no pool for a partition table to precede: a PV is carved, grouped
# into a VG, and carved again into LVs, and "before the pool exists" names no single point in
# that lifecycle. The same holds for every other storage architecture a PUBLIC module family
# cannot enumerate in advance -- a hardware RAID controller presenting one opaque LUN, plain
# partitions with plain filesystems, btrfs's own multi-device volumes, bcachefs, an iSCSI target
# somebody else already carved before this host ever saw it. A repo boundary drawn from ONE
# implementation's lifecycle stages would bake that implementation into the option namespace,
# which is exactly what a namespace this generic must not do.
#
# What IS true independent of implementation is the LAYER, and the layer is what this repo is:
# storage sits between hosts and the consumers of data, and "which physical device is this"
# (disks.nix), "how is it carved" (this file), "what shape is the dataset that lands on it"
# (shape.nix), "who owns it" (reconciler.nix) and "where does it surface" (delivery.nix) are all
# facts about that ONE layer, however the layer happens to be built underneath.
#
# ⚠ `nixstorage.layout.*` MUST NEVER MOVE AGAIN WITHOUT SWEEPING EVERY CONSUMER IN THE SAME
# CHANGE. Consumers in this family read layout by NAME, defensively, the way every cross-module
# read here works: `config.nixstorage.layout.images or { }`. `nixboot`'s own `esp.fromLayout` and
# `nixvault`'s own `deviceFromLayout` both do exactly that -- and a defensive read across a
# renamed option path cannot fail loudly, by construction: `or { }` cannot tell "option absent"
# from "declared, empty", so a rename here would silently kill every consumer, on every host,
# with no error and no warning. Any future move of this option root has to update every reader
# in the same change, or repeat that exact failure.
#
# THE SAFETY MODEL, stated once here because every option and every script
# below exists to uphold it: **nixstorage never touches a block device.**
#
#   `nixstorage.layout.images.<name>` renders a declaration and EMITS AN
#   IMAGE -- a plain, ordinary FILE, built by `lib/image.nix` as a pure
#   Nix derivation. `sgdisk`/`sfdisk` and `mkfs.vfat -C` all operate on
#   that file directly; none of them are ever pointed at a device node
#   anywhere in this repo, and none of them need to be -- GPT tools do
#   their own file I/O at whatever byte offset the table says, and
#   `mkfs.vfat -C` CREATES a correctly-sized file from nothing. A bug in
#   this file, or in lib/image.nix, produces a bad FILE. It cannot produce
#   a lost pool, because there is no pool, and no device, anywhere in its
#   reach. See lib/image.nix's own header for exactly how (measured on a
#   real build, not assumed -- see studies/) and studies/ for the
#   write-up of the one non-obvious step (querying sgdisk's own alignment
#   decision back, rather than recomputing it by hand).
#
#   Writing that finished image to real media -- `dd`, `sgdisk --load-backup`
#   against a real disk, whatever a human's own tooling looks like -- is a
#   human act OUTSIDE this module, on purpose, the same boundary
#   nixvault's own SCOPE note draws around its own `nixvault.device`
#   ("provisioning that device is a disk-layout tool's job") and nixboot's
#   own ESP section draws around itself ("declared, never created --
#   nixboot does not partition"). This repo is that disk-layout tool, and
#   the one thing it will never do, in either direction, is perform that
#   write itself. There is no `nixstorage-layout-write` tool in this file.
#   Go looking for one; it does not exist, and that absence is the point.
#
#   `nixstorage.layout.verify` is the one acting surface this file DOES
#   ship, and it stays inside the safety model by construction: it only
#   ever READS a live device (`sfdisk --json`, a listing command) and
#   reports drift against the declaration -- PASS/FAIL/SKIP, the same
#   convention nixboot-verify and nixstorage's own reconciler.nix use, and
#   the same "declared, checked, never side-effected" split shape.nix's
#   own header draws for property convergence. It never writes, and it is
#   never wired to run as a side effect of `nixos-rebuild switch` or any
#   other activation path -- see `verify.enable`/`verify.onCalendar` below
#   for exactly how it is (and is not) reachable, mirroring
#   `nixstorage.reconciler`'s own enable/onCalendar shape in this same
#   repo. Device identity is asserted to be a `/dev/disk/by-*` path, never
#   a raw `/dev/sdX`/`/dev/nvmeXnY` -- checked twice, once by an
#   `assertions` entry here at eval time and again, defensively, by
#   modules/layout-verify.sh itself at run time (see that file's own
#   comment for why: never trust a rendered config file to still say what
#   the Nix eval that produced it said).
#
#   `verify.targets.<name>.device` MAY ALSO be left unset and resolved
#   instead via `fromDisk`, a name into `nixstorage.disks` (modules/
#   disks.nix, this same repo). That table exists precisely because three
#   repos once each retyped the same by-id string for the same physical
#   disk with nothing asserting they agreed -- see disks.nix's own header
#   for the incident. Before `fromDisk`, this file's `device` was a FOURTH
#   independent transcription of that same fact, inside the one repo whose
#   declared images are what eventually get written to real media -- so a
#   verify target checking the wrong disk because its own copy of the
#   by-id string had quietly drifted from `nixstorage.disks`' copy was
#   exactly as possible here as the cross-repo version disks.nix was built
#   to close. Read as `config.nixstorage.disks or { }`, never imported:
#   `nixosModules.layout` is exported STANDALONE (see flake.nix) precisely
#   so a consumer can use verify without ever hearing about `disks.nix`,
#   and that must keep working -- `fromDisk` left `null` (its default)
#   simply has nothing to resolve against, and `device` falls back to
#   being the same required, hand-typed field it always was.
#
# ROLES ARE A FIXED, REVIEWABLE CATALOGUE, NOT A FREE-FORM GUID FIELD --
# see lib/partition-roles.nix. A role answers "what is this slot for"
# (`esp`, `raw`, `luks`), never "what GPT type-GUID do I type" -- the same
# "options describe the question they answer" principle this repo's whole
# design system holds to elsewhere. Only `esp` ever gets real filesystem
# content (vfat, empty); `raw` and `luks` are carved and left completely
# untouched -- see lib/partition-roles.nix's own header for exactly why
# `luks` in particular is never `cryptsetup luksFormat`-ed here: that needs
# a key, and the only place a key may ever be generated is on the real,
# already-written-to-media host, by a human, at the console (nixvault's
# own `nixvault-create` lifecycle). Baking one into a world-readable Nix
# store path is not a shortcut this repo will ever take.
{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.nixstorage.layout;

  roleCatalogue = import ../lib/partition-roles.nix { };
  roleNames = attrNames roleCatalogue;

  buildImage = import ../lib/image.nix { inherit pkgs; };

  imageNames = attrNames cfg.images;

  # ── per-image partition resolution: role -> {typeGuid, formatted} ──────
  resolvePartition = p: p // {
    typeGuid = roleCatalogue.${p.role}.typeGuid;
    formatted = roleCatalogue.${p.role}.formatted;
  };

  resolvedPartitionsOf = imageName: map resolvePartition cfg.images.${imageName}.partitions;

  # ── assertions: per image ───────────────────────────────────────────────
  # Reserved for the mandatory leading alignment gap before the first
  # partition plus the negligible trailing GPT-footer reservation -- both
  # measured directly against a real `sgdisk` build (see studies/), not
  # guessed. This is a soft, EARLY sanity check: `sgdisk` itself is the
  # ultimate ground truth at BUILD time regardless (a config that still
  # doesn't fit fails the derivation loudly), the same "assertion catches
  # it early, the acting tool catches it again for real" doubling this
  # repo already uses for `subtreeMountable`.
  reservedOverheadMiB = 2;

  imageAssertions = concatMap
    (imageName:
      let
        image = cfg.images.${imageName};
        partitions = image.partitions;
        n = length partitions;

        names = map (p: p.name) partitions;
        nameCounts = foldl' (acc: nm: acc // { ${nm} = (acc.${nm} or 0) + 1; }) { } names;
        duplicateNames = filter (nm: nameCounts.${nm} > 1) (unique names);

        # Every partition strictly BEFORE the last with sizeMiB = null --
        # only the LAST entry may ever leave it unset (meaning "consume
        # the remainder of the image").
        nonLastNullIndices =
          filter (i: i < n - 1 && (elemAt partitions i).sizeMiB == null) (range 0 (n - 1));

        misplacedEspLabels =
          filter (p: p.espLabel != null && p.role != "esp") partitions;

        explicitSizes = map (p: p.sizeMiB) (filter (p: p.sizeMiB != null) partitions);
        explicitSum = foldl' (a: b: a + b) 0 explicitSizes;
        lastIsRemainder = n > 0 && (elemAt partitions (n - 1)).sizeMiB == null;
        # With a remainder partition the fit-check must be a STRICT
        # inequality: a remainder partition consuming exactly zero bytes
        # is not a partition, it's a declaration that describes nothing.
        fits =
          if lastIsRemainder
          then explicitSum + reservedOverheadMiB < image.sizeMiB
          else explicitSum + reservedOverheadMiB <= image.sizeMiB;
      in
      (optional (image.sizeMiB == null) {
        assertion = false;
        message = ''
          nixstorage.layout.images."${imageName}".sizeMiB is unset. No
          default: how big a piece of media this image is meant to land on
          is exactly as host/device-specific a fact as nixboot's
          `loader.efiVariables` or nixvault's `device` -- guessing it here
          is how an image quietly stops fitting the media it was meant for.
        '';
      })
      ++ (optional (duplicateNames != [ ]) {
        assertion = false;
        message = ''
          nixstorage.layout.images."${imageName}".partitions has duplicate
          name(s): ${concatStringsSep ", " duplicateNames}. Each
          partition name becomes its GPT partition name -- two partitions
          answering to the same name on the same image is not expressible
          on real media and is almost certainly a copy-paste mistake here.
        '';
      })
      ++ (optional (nonLastNullIndices != [ ]) {
        assertion = false;
        message = ''
          nixstorage.layout.images."${imageName}".partitions has sizeMiB
          left unset (null, meaning "consume the remainder of the image")
          on partition index(es) ${concatStringsSep ", " (map toString nonLastNullIndices)},
          not just the final entry. Only the LAST partition in the list may
          ever leave sizeMiB unset -- every earlier one needs its own
          explicit size, or "the remainder" is ambiguous about which of
          several partitions it belongs to.
        '';
      })
      ++ (optional (misplacedEspLabels != [ ]) {
        assertion = false;
        message = ''
          nixstorage.layout.images."${imageName}" sets espLabel on
          partition(s) ${concatStringsSep ", " (map (p: p.name) misplacedEspLabels)}
          whose role is NOT "esp". espLabel narrows the FAT volume label of
          an esp-role partition specifically -- it has nothing to label on
          a role that is never formatted vfat at all. Drop espLabel, or set
          role = "esp".
        '';
      })
      ++ (optional (image.sizeMiB != null && n > 0 && !fits) {
        assertion = false;
        message = ''
          nixstorage.layout.images."${imageName}"'s declared partitions
          (explicit sizes summing to ${toString explicitSum} MiB${
            optionalString lastIsRemainder " plus a final remainder partition that would then get 0 MiB or less"
          }) do not fit within sizeMiB = ${toString image.sizeMiB}
          once the ${toString reservedOverheadMiB} MiB reserved for GPT's
          own leading-alignment and trailing-footer overhead is accounted
          for. Either raise images."${imageName}".sizeMiB, or shrink one of
          its partitions.
        '';
      }))
    imageNames;

  # ── assertions: verify targets ──────────────────────────────────────────
  verifyTargetNames = attrNames cfg.verify.targets;

  # `config.nixstorage.disks`, not imported: `nixstorage.disks` (modules/
  # disks.nix) lives in THIS repo, so unlike the nixiam cross-repo contract
  # reconciler.nix reads (see that file's own header), there is no reason
  # to go through a separate module boundary to reach it. Still read as
  # `or { }`, not assumed present, because `nixosModules.layout` is
  # exported STANDALONE and `systemManagerModules.layout` in this repo's
  # own flake.nix is a real, live example of exactly that: layout imported
  # without disks. On such a host `nsDisks` is `{ }`, no `fromDisk` below
  # ever resolves, and every `device` reverts to being required and
  # hand-typed, unchanged from before this option existed.
  nsDisks = config.nixstorage.disks or { };

  deviceIdentityAssertions = concatMap
    (name:
      let t = cfg.verify.targets.${name}; in
      optional (t.device != null && !(hasPrefix "/dev/disk/by-" t.device)) {
        assertion = false;
        message = ''
          nixstorage.layout.verify.targets."${name}".device = "${t.device}"
          is not a /dev/disk/by-* path. Device identity here is ALWAYS a
          stable symlink (by-id, by-uuid, by-partuuid, by-partlabel) --
          never a raw /dev/sdX or /dev/nvmeXnY, which can silently point at
          a different physical disk after a reboot or a drive swap. See
          this module's own header for the full safety model.
        '';
      })
    verifyTargetNames;

  # `device == null` only ever happens here when BOTH the hand-typed field
  # and `fromDisk`'s resolution came up empty -- see `verifyTargetModule`'s
  # own `device` option below for exactly which of those two this is.
  # Caught here, deliberately, rather than left as a bare "used but not
  # defined" trace on `device` itself -- the same choice `imageModule`'s
  # own `sizeMiB` makes above, for the same reason: which live device a
  # verify target means is exactly as host-specific a fact, and a plain
  # module-system trace can't say WHY it's missing (typo'd `fromDisk`?
  # `nixstorage.disks` never imported? never set at all?) the way this
  # message can.
  deviceUnresolvedAssertions = concatMap
    (name:
      let t = cfg.verify.targets.${name}; in
      optional (t.device == null) {
        assertion = false;
        message = ''
          nixstorage.layout.verify.targets."${name}" has no device: neither
          `device` nor a resolving `fromDisk` is set.${
            optionalString (t.fromDisk != null) ''

              fromDisk = "${t.fromDisk}" was set but does not name an entry
              in nixstorage.disks. Declared disks: ${
                if nsDisks == { } then "(none -- is modules/disks.nix imported on this host at all?)"
                else concatStringsSep ", " (attrNames nsDisks)
              }.''
          }
          Either set device directly to a /dev/disk/by-* path, or set
          fromDisk to the name of an already-declared nixstorage.disks.<name>
          entry. Which live device nixstorage-layout-verify checks is exactly
          as host-specific a fact as nixstorage.layout.images."<name>".sizeMiB
          above -- guessing it here is how a verify run quietly checks the
          wrong disk, or none at all.
        '';
      })
    verifyTargetNames;

  imageReferenceAssertions = concatMap
    (name:
      let t = cfg.verify.targets.${name}; in
      optional (!(elem t.image imageNames)) {
        assertion = false;
        message = ''
          nixstorage.layout.verify.targets."${name}".image = "${t.image}",
          but nixstorage.layout.images has no such image declared. Declared
          images: ${if imageNames == [ ] then "(none)" else concatStringsSep ", " imageNames}.
        '';
      })
    verifyTargetNames;

  # Only targets actually reachable from BOTH assertion sets above are safe
  # to render below -- imageReferenceAssertions is what keeps a dangling
  # verify.targets.<name>.image from ever reaching here, and
  # deviceUnresolvedAssertions is the same guarantee for a `device` that
  # came up null (unset, with a `fromDisk` that didn't resolve either).
  # Without this second half, an unresolved target would still fail the
  # eval via the assertion above, but `renderedVerifyModel` below would
  # ALSO have already embedded a literal JSON `null` as that target's
  # device in the process of getting there -- harmless today only because
  # the assertion fires first, but not a rendering this file should ever
  # produce even transiently.
  safeVerifyTargetNames = filter
    (name: elem cfg.verify.targets.${name}.image imageNames && cfg.verify.targets.${name}.device != null)
    verifyTargetNames;

  renderedVerifyModel = {
    targets = listToAttrs (map
      (name:
        let t = cfg.verify.targets.${name}; in
        nameValuePair name {
          device = t.device;
          partitions = map
            (p: { inherit (p) name typeGuid sizeMiB; })
            (resolvedPartitionsOf t.image);
        })
      safeVerifyTargetNames);
  };

  verifyConfigFile = pkgs.writeText "nixstorage-layout-verify.json" (builtins.toJSON renderedVerifyModel);

  verifyPackage = pkgs.writeShellScriptBin "nixstorage-layout-verify" (builtins.readFile ./layout-verify.sh);

  partitionModule = { ... }: {
    options = {
      name = mkOption {
        type = types.strMatching "^[A-Za-z0-9_.-]{1,36}$";
        example = "ESP";
        description = ''
          This partition's GPT partition name (`sgdisk -c`), and the value
          `nixstorage.layout.verify` compares a live device's own partition
          name against. Must be unique within its image (asserted). 36
          characters is GPT's own limit for a partition name.
        '';
      };

      role = mkOption {
        type = types.enum roleNames;
        example = "esp";
        description = ''
          Which entry in the fixed role catalogue (lib/partition-roles.nix)
          this slot is for -- answers "what is this for", never "what
          GPT type-GUID do I type"; the type-GUID is resolved from this
          name, never restated here. Available roles: ${concatStringsSep ", " roleNames}.
          See lib/partition-roles.nix for what each one actually means and,
          for "esp" specifically, exactly what does and does not get
          written into it.
        '';
      };

      sizeMiB = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 256;
        description = ''
          This partition's size, in MiB. `null` (the default) means
          "consume every remaining usable sector of the image" -- legitimate
          ONLY for the LAST partition in the list (asserted); every earlier
          partition needs an explicit size, or "the remainder" would be
          ambiguous about which one it belongs to.
        '';
      };

      espLabel = mkOption {
        type = types.nullOr (types.strMatching "^[A-Z0-9_-]{1,11}$");
        default = null;
        example = "ESP";
        description = ''
          The FAT volume label this partition is formatted with. Only
          meaningful when `role = "esp"` (asserted) -- every other role is
          never formatted with any filesystem at all, so there is nothing
          here to label. 11 characters is FAT's own volume-label limit;
          left `null`, `mkfs.vfat` picks no label at all.
        '';
      };
    };
  };

  # `{ config, name, ... }`, not `{ ... }`: `result` is computed from THIS
  # submodule instance's own `sizeMiB`/`partitions` only, via its own
  # `config`, and `name` is the attribute key `attrsOf` supplies for free.
  # Deliberately NOT computed in the outer `let` from `cfg.images` (which
  # was tried first): reading `cfg.images` to decide what `nixstorage.
  # layout.images` itself should contain is a genuine cycle in the module
  # system's KEY resolution, not just a value-level one -- `attrsOf` must
  # know every config source's contributed keys before any one key's
  # submodule can be finalized, so a contribution whose own key set comes
  # from reading that same merged attrset can never resolve. Computing
  # `result` from this submodule's OWN fields sidesteps that entirely: it
  # depends only on `sizeMiB`/`partitions`, never on `result` or on the
  # sibling images this instance knows nothing about.
  imageModule = { config, name, ... }: {
    options = {
      sizeMiB = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 1024;
        description = ''
          The total size of this image, in MiB. No default (asserted
          below, not left to a bare "used but not defined" trace): how big
          a piece of media this image is meant to land on is exactly as
          host/device-specific a fact as nixboot's `loader.efiVariables` or
          nixvault's `device` -- guessing it here is how an image quietly
          stops fitting the media it was meant for.
        '';
      };

      sectorSize = mkOption {
        type = types.enum [ 512 4096 ];
        default = 4096;
        example = 512;
        description = ''
          The LOGICAL sector size of the medium this image is written to.

          THE POLICY: 4Kn is the default and the preferred shape. Use 512 only
          where the drive is natively 512e/512n, or where something downstream
          mandates it. Check the target before declaring:
          `cat /sys/block/<dev>/queue/logical_block_size`.

          THIS IS NOT COSMETIC. A GPT stores every partition boundary as a
          SECTOR NUMBER, so an identical table describes a byte layout eight
          times larger at 4096 than at 512. An image built for the wrong sector
          size does not degrade gracefully -- the header LBAs, the partition
          entries and the backup-header location all land at the wrong offsets,
          and the medium is not readable as partitioned at all.

          Real example from these hosts: the nixnas rescue stick is 512/512, and
          a laptop's NVMe is 4096/4096. The SAME declared layout therefore
          cannot produce one image serving both -- it needs two, differing only
          in this value.

          Mechanically, 4096 also changes which tool builds the table: `sgdisk`
          has no sector-size override when operating on a plain file (it assumes
          512, because normally it asks the kernel and a file has nobody to ask),
          so the 4Kn path uses `sfdisk --sector-size 4096` instead. See
          ../lib/image.nix for why the 512 path deliberately stays on sgdisk.
        '';
      };

      partitions = mkOption {
        type = types.listOf (types.submodule partitionModule);
        default = [ ];
        description = ''
          This image's partition table, in on-disk order. Empty is a
          legitimate, if unusual, answer -- a declared-but-not-yet-designed
          image, the same "documented, not decided" placeholder shape
          `nixstorage.shape.datasets.<name>.class = null` uses on the
          SHAPE side of this repo.
        '';
      };

      result = mkOption {
        type = types.package;
        readOnly = true;
        description = ''
          The built image: a single, plain, ordinary FILE (never a block
          device, never mounted, never touched by anything in this repo
          beyond the build that produced it) -- a pure derivation from
          `lib/image.nix`. Writing it to real media is a human act outside
          this module; see this file's own header for exactly why that
          write will never live here. This is a lazy attribute: nothing in
          this module ever forces it, so declaring `nixstorage.layout.images.*`
          costs nothing at eval time beyond the assertions above -- the
          image is only actually built the moment something (a human's own
          `nix build`, or a consumer's own `packages.<system>` output)
          asks for it by name.
        '';
      };
    };

    # Local to THIS submodule instance only -- see this module's own
    # comment above for why that locality is exactly what keeps it
    # non-circular. `resolvePartition` and `buildImage` close over the
    # outer `let` normally (a submodule's module function is still just a
    # function value, defined in, and lexically scoped to, this file).
    config.result = buildImage {
      inherit name;
      inherit (config) sectorSize;
      sizeMiB = if config.sizeMiB == null then 1 else config.sizeMiB;
      partitions = map resolvePartition config.partitions;
    };
  };

  verifyTargetModule = { config, ... }: {
    options = {
      fromDisk = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "pool0";
        description = ''
          Which `nixstorage.disks.<name>` entry (modules/disks.nix, this
          same repo) names this target's physical device, so `device`
          below can default from it instead of being retyped a fourth
          time -- see this file's own header for why a verify target is
          exactly the transcription disks.nix exists to remove.

          Left `null` (the default), `device` must be set directly --
          legitimate whenever this host has no `nixstorage.disks` table at
          all (e.g. `nixosModules.layout` imported standalone), or this
          target's medium genuinely isn't one of the physical disks named
          there (a loopback image under test, say).
        '';
      };

      device = mkOption {
        type = types.nullOr types.str;
        default =
          if config.fromDisk != null && nsDisks ? "${config.fromDisk}"
          then nsDisks."${config.fromDisk}".device
          else null;
        defaultText = lib.literalExpression ''
          the `device` of `nixstorage.disks.<fromDisk>`, when `fromDisk` is
          set and names a declared entry; otherwise `null` -- a `null`
          reaching activation is a hard eval failure (see
          deviceUnresolvedAssertions above), never a silently-accepted
          missing device
        '';
        example = "/dev/disk/by-id/example-target-uuid";
        description = ''
          The live device this target's declared image is expected to
          already have been written to. ALWAYS a stable `/dev/disk/by-*`
          symlink (by-id, by-uuid, by-partuuid, by-partlabel) -- never a
          raw `/dev/sdX`/`/dev/nvmeXnY`, which can silently point at a
          different physical disk after a reboot or a drive swap (asserted
          below, and checked again at runtime by
          modules/layout-verify.sh itself). `nixstorage-layout-verify`
          only ever READS this device -- see this file's own header for the
          full safety model.

          Set this directly to override `fromDisk`'s resolution, or to
          declare a target with no corresponding `nixstorage.disks` entry
          at all -- an explicit value here always wins over `fromDisk`,
          never the reverse.
        '';
      };

      image = mkOption {
        type = types.str;
        example = "example-host-esp";
        description = ''
          Which `nixstorage.layout.images.<name>` this device is expected
          to match. Must name an already-declared image (asserted) -- this
          is what lets `nixstorage-layout-verify` know what "correct" means
          for this device without restating the whole partition table a
          second time here.
        '';
      };
    };
  };
in
{
  options.nixstorage.layout = {
    images = mkOption {
      type = types.attrsOf (types.submodule imageModule);
      default = { };
      description = ''
        Named disk images: how a piece of media is CARVED -- a partition
        table, sizes, roles. Pure declaration plus a computed, lazy
        `result` package; see this file's own header for the full safety
        model (a pure derivation emitting a plain file, never a device).
      '';
    };

    verify = {
      enable = mkEnableOption ''
        installing nixstorage-layout-verify: a read-only pass that compares
        a live device's actual GPT partition table against a declared
        nixstorage.layout image and reports PASS/FAIL/SKIP per partition.
        It never writes to the device it checks, and it is never wired to
        run as a side effect of activation -- see this file's own header
      '';

      package = mkOption {
        type = types.package;
        default = verifyPackage;
        description = ''
          The `nixstorage-layout-verify` package (wraps layout-verify.sh).
          Override only to pin/patch a build -- the wrapper deliberately
          carries no `set -e`/`pipefail` (see layout-verify.sh's own
          header), so replacing it with something built via
          `pkgs.writeShellApplication` would silently reintroduce
          abort-on-first-mismatch instead of checking every declared
          target in one run.
        '';
      };

      onCalendar = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "daily";
        description = ''
          systemd `OnCalendar=` for a recurring `nixstorage-layout-verify.timer`.
          `null` (default): no timer at all -- verification only ever runs
          on manual invocation (`nixstorage-layout-verify`, installed to
          `environment.systemPackages` whenever `enable` is true) or via
          `systemctl start nixstorage-layout-verify.service`. No guessed
          default cadence, the same reasoning as
          `nixstorage.reconciler.onCalendar`: even a read-only pass against
          real block devices is an operational decision for the operator,
          not a value this module should silently pick.
        '';
      };

      targets = mkOption {
        type = types.attrsOf (types.submodule verifyTargetModule);
        default = { };
        description = ''
          Which live devices should match which declared image, keyed by a
          short, descriptive name (becomes this device's own label in
          nixstorage-layout-verify's output). See `device` and `image`
          above for the two things each entry says.
        '';
      };
    };
  };

  config = mkMerge [
    {
      # Unconditional -- NOT gated behind `verify.enable`, matching
      # shape.nix's, delivery.nix's, and reconciler.nix's own always-on
      # assertions. A bad declaration (a raw /dev/sdX, a dangling image
      # reference, a size that doesn't fit) is exactly as real a mistake
      # whether or not the tool that would eventually read it is installed.
      assertions =
        imageAssertions
        ++ deviceUnresolvedAssertions
        ++ deviceIdentityAssertions
        ++ imageReferenceAssertions;
    }
    (mkIf cfg.verify.enable {
      environment.etc."nixstorage/layout-verify.json".source = verifyConfigFile;

      # The manual-invocation entry point, independent of the timer --
      # mirrors nixstorage.reconciler's own package/environment.systemPackages
      # wiring exactly.
      environment.systemPackages = [ cfg.verify.package ];

      systemd.services.nixstorage-layout-verify = {
        description = "Compare live media against nixstorage's declared layout (read-only; never writes)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${cfg.verify.package}/bin/nixstorage-layout-verify";
        };
        path = [ pkgs.jq pkgs.util-linux pkgs.coreutils ];
      };

      systemd.timers.nixstorage-layout-verify = mkIf (cfg.verify.onCalendar != null) {
        description = "Periodic trigger for nixstorage-layout-verify.service";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.verify.onCalendar;
          Persistent = true;
          RandomizedDelaySec = "5m";
        };
      };
    })
  ];
}
