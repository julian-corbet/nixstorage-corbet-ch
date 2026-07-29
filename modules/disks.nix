# modules/disks.nix
#
# THE DISK TABLE: `options.nixstorage.disks` names the physical block devices a host
# actually has, once, so every other module reads a NAME instead of re-typing a path.
#
# WHY THIS EXISTS, AND WHAT IT COST NOT TO HAVE IT. Three repos independently declared
# `/dev/disk/by-id/...` strings for what is, on a real host, the same handful of disks:
# this repo's own `layout.verify.targets.<name>.device`, `nixluks.volumes.<name>.device`,
# and `nixvault.device` + `nixvault.luksVolumes[].device`. None referenced the others and
# nothing asserted they agreed. `layout` is the one module in this family that WRITES
# PARTITION TABLES, so a string that drifts out of step with the crypto layer's copy is
# precisely the failure where a layout run and an unlock run disagree about which disk is
# which. This repo's own README already warns about exactly this anti-pattern ("two numbers
# someone has to remember to keep in sync by hand") -- for uid/gid, where it delegates to
# nixid's table. The same discipline, applied to device paths, is this file.
#
# IT IS A TABLE, NOT A MECHANISM. Nothing here partitions, formats, mounts, opens, or
# touches a device in any way. It declares that a name means a path, and refuses paths that
# cannot survive a reboot. Consumers read it defensively (`config.nixstorage.disks or { }`)
# exactly as this repo reads `config.nixid.posix.identities or { }`, so a module that reads
# it keeps working on a host that has never imported this one.
#
# WHY IN nixstorage AND NOT A REGISTRY. A host's disks ARE its mass storage, and this repo
# owns mass storage. A separate machine registry would have to know what a disk is to hold
# one, which puts hardware knowledge in a table whose whole virtue is having none. The
# division that does hold: this file says WHICH DEVICES EXIST; a machine registry says which
# machine we are talking about at all.
#
# ⚠ BY-ID OR BY-UUID ONLY, ENFORCED. /dev/sdX is refused by the type, not by convention.
# On 2026-07-29 a reboot moved a rescue stick from sdr to sdq while a blank 239 GiB drive
# took over sdr; a partition table written to the remembered letter would have gone to the
# wrong disk entirely. Letters are not identity.
{ config, lib, ... }:

let
  inherit (lib) mkOption types mkIf;

  cfg = config.nixstorage.disks;

  # Same restriction lib/device-path.nix draws in nixluks, for the same reason -- kept
  # inline rather than shared so this module depends on nothing.
  stableDevicePath = types.strMatching "/dev/disk/by-(id|uuid|partlabel|partuuid|label)/.+";

  diskModule = { name, ... }: {
    options = {
      device = mkOption {
        type = stableDevicePath;
        example = "/dev/disk/by-id/ata-EXAMPLE_MODEL_SERIAL";
        description = ''
          The stable path to this disk. `/dev/sdX` is REFUSED by the type: device letters
          are assigned in discovery order and change across reboots, so a letter is not an
          identity and must never reach a partition table or an unlock declaration.
        '';
      };

      role = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "pool-member";
        description = ''
          What this disk is FOR, in the operator's own words. Never branched on by this
          module -- it exists so `nixstorage-disks` output and any consumer's diagnostics
          can say something more useful than a by-id string, and so a human reading the
          declaration can tell a pool member from an archive drive without cross-checking.
        '';
      };

      model = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "ST14000DM001-2JC101";
        description = ''
          Model designation, for human legibility only. Deliberately NOT used to match or
          select a device -- the `device` path is the only identity. Recorded because
          "which of these five identical archive drives is failing" is a question the
          by-id string alone answers badly.
        '';
      };

      smr = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this is a drive-managed SMR disk. Declared here because it is a property
          of the DISK, and because getting it wrong is destructive in a way no other field
          is: shingled drives are write-once/append-only in practice, and random-writing,
          defragmenting or TRIMming one degrades it badly. Consumers that choose write
          patterns can read this; this module only records it.
        '';
      };
    };
  };
in
{
  options.nixstorage.disks = mkOption {
    type = types.attrsOf (types.submodule diskModule);
    default = { };
    example = lib.literalExpression ''
      {
        pool0 = { device = "/dev/disk/by-id/ata-EXAMPLE_A"; role = "pool-member"; };
        archive0 = { device = "/dev/disk/by-id/ata-EXAMPLE_B"; role = "archive"; smr = true; };
      }
    '';
    description = ''
      The physical disks this host has, keyed by a short stable name.

      The name is the point: `nixluks`, `nixvault` and this repo's own `layout` module all
      need to say WHICH DISK, and before this table each said it with its own copy of a
      by-id path. A name resolved from one table cannot drift; three transcriptions of one
      path can, and the module that writes partition tables is one of the three.

      Declaring a disk here does nothing on its own. It neither partitions, formats,
      mounts, nor opens anything -- it makes a fact available to be read by name.
    '';
  };

  config = mkIf (cfg != { }) {
    assertions = [
      {
        # Two names for one device is almost always a copy-paste, and it defeats the entire
        # purpose: the table exists so there is ONE answer to "which disk is pool0".
        assertion =
          let paths = lib.mapAttrsToList (_: d: d.device) cfg;
          in lib.length (lib.unique paths) == lib.length paths;
        message =
          let
            dup = lib.filter
              (p: lib.count (q: q == p) (lib.mapAttrsToList (_: d: d.device) cfg) > 1)
              (lib.unique (lib.mapAttrsToList (_: d: d.device) cfg));
          in ''
            nixstorage.disks: the same device path is declared under more than one name:
            ${lib.concatStringsSep "\n" (map (p: "  ${p}") dup)}

            One disk, one name. Two names for one device means two consumers can believe
            they own it, which is the drift this table exists to remove.
          '';
      }
    ];
  };
}
