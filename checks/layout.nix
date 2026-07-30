# checks/layout.nix
#
# The `nixstorage.layout` check group -- eval-time selection/validation checks for
# modules/layout.nix, PLUS the two BUILD-level proofs `shape`/`delivery`/`disks` have no
# equivalent of (a real produced artifact: a disk image, and a real, if fake-for-testing,
# media read-back -- see modules/layout.nix's own header for why `layout` alone among this
# repo's five modules needs that). Wired into checks/default.nix as one entry point, the same
# `results`-list-returning shape checks/purity.nix already uses for its own per-module check
# group: this file exports `results` (plain eval-time check records, folded into
# default.nix's own combined `nixstorage-eval-tests`) plus the two standalone build-proof
# derivations, which default.nix re-exports by name.
#
# THIS FILE, AND THE MODULE IT PROVES, SPENT A WHILE IN A REPO OF ITS OWN. That split (into a
# standalone `nixlayout` repo, argued from "layout runs pre-pool, while shape/delivery/
# reconciler all presuppose a pool that already exists") has been REVERSED: "pre-pool vs
# post-pool" is a ZFS-SHAPED boundary, and under LVM -- or hardware RAID presenting one opaque
# LUN, or plain partitions, or any of the other storage architectures a public module family
# cannot enumerate in advance -- there is no equivalent line in the same place. See
# modules/layout.nix's own header for the full argument. This file is the test-side half of
# that reversal: it now shares the SAME combined eval-tests run every other module in this
# repo already contributes to, rather than the standalone eval-config fixtures a separate
# flake needed when this was `nixlayout`'s own `checks/default.nix`.
#
# EVAL-TIME checks (returned as `results`): each evaluates a real configuration through
# NixOS's own eval-config.nix and inspects what the module RENDERS, or whether forcing
# `system.build.toplevel` fails. Nothing here boots anything, and nothing here builds a real
# image -- these are entirely about selection and validation, which are eval-time properties.
#
# BUILD-level proofs (`layoutImageBuildProof`, `layoutVerifyDriftProof` below, re-exported by
# checks/default.nix as `layout-image-build-proof`/`layout-verify-detects-drift`):
# `nixstorage.layout` is the one module in this repo that produces a real artifact (a disk
# image) and reads real (if fake, for testing) media back, so eval-only tests cannot prove it
# actually works -- only that it is WIRED to try. These two checks actually run
# `lib/image.nix`'s builder and `modules/layout-verify.sh`'s script, entirely inside the Nix
# build sandbox, and touch no block device: the "device" under test is a plain file the image
# builder itself produced, resolved to via a FAKE `readlink` placed ahead of the real one on
# PATH -- the identical technique nixboot's own checks/default.nix uses for its fake
# efibootmgr/findmnt/lsblk, and for the identical reason (a real block device here, which a
# build sandbox neither has nor should ever be given).
{ pkgs, lib, nixpkgs, system, layoutModule, disksModule, bareStubs }:

let
  roleCatalogue = import ../lib/partition-roles.nix { };
  buildImage = import ../lib/image.nix { inherit pkgs; };

  # ── NixOS eval fixtures ──────────────────────────────────────────────────
  # `evalLayoutOnly`: nixstorage.layout, alone -- every fixture below that does NOT
  # specifically exercise `fromDisk` uses this one, proving `nixstorage.layout`
  # works with no `nixstorage.disks` table anywhere in the composed system
  # at all (the exact claim modules/layout.nix's own header makes about
  # a host that imports `nixosModules.layout` standalone, without `disks`).
  evalLayoutOnly = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        layoutModule
        extraConfig
        bareStubs
      ];
    }).config;

  # NixOS enforces assertions when `system.build.toplevel` is forced, not on
  # a bare read of `config.assertions` (a passive list) -- same reasoning as
  # every sibling project's own `nixosBuildFails` in this family. `seq`
  # reaches the wrapping throw without deep-forcing the whole system
  # closure (in particular, never forces any `images.*.result` derivation).
  layoutBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalLayoutOnly extraConfig).system.build.toplevel true)).success;

  # `evalLayoutWithDisks`: layout PLUS the real `nixstorage.disks` table (modules/disks.nix,
  # this same repo) -- used only by the fixtures below that specifically exercise
  # `nixstorage.layout.verify.targets.<n>.fromDisk` resolving against a sibling disks table.
  #
  # Before the split was reversed, this fixture had to fake `nixstorage.disks`'s option
  # surface by hand: `nixlayout` was a standalone repo/flake, and pulling in the real
  # nixstorage flake as a `checks`-only input would have made a test-only dependency look
  # like a real one -- this family's own house rule (read a sibling defensively, never as a
  # flake input) applies in its strongest form to test code. Now that `layout` lives in THIS
  # repo, `disksModule` is not a foreign table to imitate -- it is the exact same module the
  # `disks/*` checks above already compose for their own fixtures, so this one just imports
  # it directly, same as they do.
  evalLayoutWithDisks = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        layoutModule
        disksModule
        extraConfig
        bareStubs
      ];
    }).config;

  layoutWithDisksBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalLayoutWithDisks extraConfig).system.build.toplevel true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # A small, complete, VALID layout -- the base every "and one thing about
  # it is wrong" fixture below starts from and mutates exactly one field of.
  validImages = {
    fixture = {
      sizeMiB = 8;
      partitions = [
        { name = "ESP"; role = "esp"; sizeMiB = 2; espLabel = "FIXESP"; }
        { name = "raw-a"; role = "raw"; sizeMiB = null; }
      ];
    };
  };

  cfg-valid = evalLayoutOnly { nixstorage.layout.images = validImages; };

  cfg-verify-enabled = evalLayoutOnly {
    nixstorage.layout.images = validImages;
    nixstorage.layout.verify.enable = true;
    nixstorage.layout.verify.targets.fixture = {
      device = "/dev/disk/by-id/example-fixture";
      image = "fixture";
    };
  };

  results = [
    # --- images: no default on sizeMiB (host-specific, same shape as
    #     nixboot's loader.efiVariables / nixvault's device) --------------
    (check "images/sizeMiB-unset-fails-the-build"
      (layoutBuildFails { nixstorage.layout.images.fixture.partitions = [ ]; })
      "expected an image with no sizeMiB to fail the build, but it succeeded")

    (check "images/valid-fixture-builds-fine"
      (!(layoutBuildFails { nixstorage.layout.images = validImages; }))
      "the base valid fixture should never fail the build on its own")

    # --- partitions: duplicate names ----------------------------------------
    (check "partitions/duplicate-names-fail-the-build"
      (layoutBuildFails {
        nixstorage.layout.images.fixture = {
          sizeMiB = 8;
          partitions = [
            { name = "dup"; role = "raw"; sizeMiB = 2; }
            { name = "dup"; role = "raw"; sizeMiB = null; }
          ];
        };
      })
      "expected two partitions sharing a name to fail the build, but it succeeded")

    # --- partitions: only the LAST entry may leave sizeMiB null -------------
    (check "partitions/non-last-null-sizeMiB-fails-the-build"
      (layoutBuildFails {
        nixstorage.layout.images.fixture = {
          sizeMiB = 8;
          partitions = [
            { name = "a"; role = "raw"; sizeMiB = null; }
            { name = "b"; role = "raw"; sizeMiB = 2; }
          ];
        };
      })
      "expected a non-final null sizeMiB to fail the build, but it succeeded")

    (check "partitions/last-null-sizeMiB-builds-fine"
      (!(layoutBuildFails { nixstorage.layout.images = validImages; }))
      "the base fixture's own trailing null sizeMiB (raw-a) must be legal")

    # --- espLabel is meaningless (and rejected) off the esp role -----------
    (check "partitions/espLabel-on-non-esp-role-fails-the-build"
      (layoutBuildFails {
        nixstorage.layout.images.fixture = {
          sizeMiB = 8;
          partitions = [{ name = "a"; role = "raw"; sizeMiB = null; espLabel = "NOPE"; }];
        };
      })
      "expected espLabel on a non-esp-role partition to fail the build, but it succeeded")

    # --- declared partitions must actually fit the declared image ----------
    (check "partitions/oversized-partitions-fail-the-build"
      (layoutBuildFails {
        nixstorage.layout.images.fixture = {
          sizeMiB = 4;
          partitions = [
            { name = "a"; role = "raw"; sizeMiB = 3; }
            { name = "b"; role = "raw"; sizeMiB = 3; }
          ];
        };
      })
      "expected partitions summing to more than sizeMiB (plus GPT overhead) to fail the build, but it succeeded")

    (check "partitions/exactly-fitting-partitions-build-fine"
      (
        !(layoutBuildFails {
          nixstorage.layout.images.fixture = {
            sizeMiB = 8;
            partitions = [{ name = "a"; role = "raw"; sizeMiB = 6; }];
          };
        })
      )
      "6 MiB of partitions plus the 2 MiB reserved overhead should just fit an 8 MiB image")

    # --- images.*.result is a real, lazily-built derivation, never forced --
    (check "images/result-is-a-derivation-without-forcing-a-build"
      (cfg-valid.nixstorage.layout.images.fixture.result.type or null == "derivation")
      "images.fixture.result did not evaluate to a derivation")

    # --- verify.targets: device identity must be a stable symlink -----------
    (check "verify/raw-devnode-fails-the-build"
      (layoutBuildFails {
        nixstorage.layout.images = validImages;
        nixstorage.layout.verify.targets.fixture = { device = "/dev/sda1"; image = "fixture"; };
      })
      "expected a raw /dev/sda1 device path to fail the build, but it succeeded")

    (check "verify/by-id-device-builds-fine"
      (
        !(layoutBuildFails {
          nixstorage.layout.images = validImages;
          nixstorage.layout.verify.targets.fixture = {
            device = "/dev/disk/by-id/example-fixture";
            image = "fixture";
          };
        })
      )
      "a /dev/disk/by-id/* device path should never fail the build on its own")

    # --- verify.targets: image must reference a declared image --------------
    (check "verify/dangling-image-reference-fails-the-build"
      (layoutBuildFails {
        nixstorage.layout.images = validImages;
        nixstorage.layout.verify.targets.fixture = {
          device = "/dev/disk/by-id/example-fixture";
          image = "does-not-exist";
        };
      })
      "expected a verify target naming an undeclared image to fail the build, but it succeeded")

    # --- verify.enable wiring: package installed, timer only when asked -----
    (check "verify/enable-installs-the-package"
      (lib.any (p: lib.hasInfix "nixstorage-layout-verify" (p.name or "")) cfg-verify-enabled.environment.systemPackages)
      "nixstorage-layout-verify was not found in environment.systemPackages with verify.enable = true")

    (check "verify/disabled-installs-nothing"
      (!(lib.any (p: lib.hasInfix "nixstorage-layout-verify" (p.name or "")) cfg-valid.environment.systemPackages))
      "nixstorage-layout-verify was installed even though verify.enable defaults to false")

    (check "verify/no-timer-without-onCalendar"
      (!(cfg-verify-enabled.systemd.timers ? "nixstorage-layout-verify"))
      "a timer was rendered even though verify.onCalendar was left at its null default")

    (check "verify/onCalendar-renders-a-timer"
      (
        let
          cfg = evalLayoutOnly {
            nixstorage.layout.images = validImages;
            nixstorage.layout.verify.enable = true;
            nixstorage.layout.verify.onCalendar = "daily";
            nixstorage.layout.verify.targets.fixture = {
              device = "/dev/disk/by-id/example-fixture";
              image = "fixture";
            };
          };
        in
        cfg.systemd.timers ? "nixstorage-layout-verify"
        && cfg.systemd.timers.nixstorage-layout-verify.timerConfig.OnCalendar == "daily"
      )
      "verify.onCalendar = \"daily\" did not render a matching systemd timer")

    # --- verify service is never wanted by activation/boot targets ----------
    (check "verify/service-never-wanted-by-multi-user-target"
      (!(lib.elem "multi-user.target" (cfg-verify-enabled.systemd.services.nixstorage-layout-verify.wantedBy or [ ])))
      "nixstorage-layout-verify.service must never run as a side effect of activation/boot")

    # --- verify.targets.<name>.fromDisk: resolves device by name ------------
    # The whole point of this option (see modules/layout.nix's own header): a verify target
    # can name a nixstorage.disks entry instead of retyping its by-id path a second time, for
    # the SAME physical disk -- formerly a DIFFERENT repo's own copy of that path, back when
    # this module was split out as `nixlayout`; now the same repo, disks.nix sitting two
    # directories away, but the transcription risk `fromDisk` closes is identical either way.
    (check "verify/fromDisk-resolves-device-from-nixstorage-disks"
      (
        let
          cfg = evalLayoutWithDisks {
            nixstorage.layout.images = validImages;
            nixstorage.disks.pool0.device = "/dev/disk/by-id/example-pool0";
            nixstorage.layout.verify.targets.fixture = {
              fromDisk = "pool0";
              image = "fixture";
            };
          };
        in
        cfg.nixstorage.layout.verify.targets.fixture.device == "/dev/disk/by-id/example-pool0"
      )
      "verify.targets.fixture.fromDisk = \"pool0\" did not resolve device from nixstorage.disks.pool0")

    # --- an explicit device always wins over fromDisk's resolution ----------
    # Non-negotiable per this design: changing a DEFAULT must never remove
    # the ability to state the value directly.
    (check "verify/explicit-device-overrides-fromDisk"
      (
        let
          cfg = evalLayoutWithDisks {
            nixstorage.layout.images = validImages;
            nixstorage.disks.pool0.device = "/dev/disk/by-id/example-pool0";
            nixstorage.layout.verify.targets.fixture = {
              fromDisk = "pool0";
              device = "/dev/disk/by-id/example-explicit-override";
              image = "fixture";
            };
          };
        in
        cfg.nixstorage.layout.verify.targets.fixture.device == "/dev/disk/by-id/example-explicit-override"
      )
      "an explicit verify.targets.fixture.device did not override fromDisk's resolved default")

    # --- fromDisk naming a non-existent nixstorage.disks entry fails --------
    (check "verify/fromDisk-unresolved-fails-the-build"
      (layoutWithDisksBuildFails {
        nixstorage.layout.images = validImages;
        nixstorage.disks.pool0.device = "/dev/disk/by-id/example-pool0";
        nixstorage.layout.verify.targets.fixture = {
          fromDisk = "does-not-exist";
          image = "fixture";
        };
      })
      "expected fromDisk naming an undeclared nixstorage.disks entry to fail the build, but it succeeded")

    # --- neither device nor fromDisk set still fails, disks module absent --
    # Proves nixstorage.layout's own standalone-import claim (modules/layout.nix's own
    # header): on a host that imports `nixosModules.layout` without `nixosModules.disks` at
    # all (evalLayoutOnly, not evalLayoutWithDisks), device stays exactly as required as it
    # was before fromDisk existed.
    (check "verify/no-device-no-fromDisk-fails-the-build-without-nixstorage"
      (layoutBuildFails {
        nixstorage.layout.images = validImages;
        nixstorage.layout.verify.targets.fixture = { image = "fixture"; };
      })
      "expected a verify target with neither device nor fromDisk set to fail the build, but it succeeded")
  ];

  # ── BUILD-level proof #1: the image builder actually builds a correct,
  #    real disk image -- a plain file, never a device. ───────────────────
  # Deliberately built straight from lib/image.nix, not through a NixOS
  # eval -- this is the one place this repo actually needs a real `sgdisk`/
  # `mkfs.vfat` run to happen, and going through a full NixOS toplevel to
  # get there would cost minutes for no extra coverage.
  testImage = buildImage {
    name = "check-fixture";
    sizeMiB = 8;
    partitions = [
      { name = "ESP"; sizeMiB = 2; typeGuid = roleCatalogue.esp.typeGuid; formatted = "vfat"; espLabel = "FIXESP"; }
      { name = "raw-a"; sizeMiB = null; typeGuid = roleCatalogue.raw.typeGuid; formatted = null; espLabel = null; }
    ];
  };

  layoutImageBuildProof = pkgs.runCommand "nixstorage-layout-image-build-proof"
    {
      nativeBuildInputs = [ pkgs.util-linux pkgs.dosfstools pkgs.jq pkgs.coreutils ];
    }
    ''
      set -euo pipefail
      img=${testImage}

      actual_bytes=$(stat -c %s "$img")
      expected_bytes=$((8 * 1024 * 1024))
      [ "$actual_bytes" -eq "$expected_bytes" ] || { echo "FAIL: image is $actual_bytes bytes, expected $expected_bytes"; exit 1; }

      table="$(sfdisk --json "$img")"
      count=$(echo "$table" | jq '.partitiontable.partitions | length')
      [ "$count" -eq 2 ] || { echo "FAIL: expected 2 partitions, sfdisk reports $count"; exit 1; }

      esp_name=$(echo "$table" | jq -r '.partitiontable.partitions[0].name')
      esp_type=$(echo "$table" | jq -r '.partitiontable.partitions[0].type')
      [ "$esp_name" = "ESP" ] || { echo "FAIL: partition 0 name is '$esp_name', expected ESP"; exit 1; }
      [ "$(printf '%s' "$esp_type" | tr 'A-Z' 'a-z')" = "$(printf '%s' "${roleCatalogue.esp.typeGuid}" | tr 'A-Z' 'a-z')" ] \
        || { echo "FAIL: partition 0 type-GUID is $esp_type, expected ${roleCatalogue.esp.typeGuid}"; exit 1; }

      esp_start=$(echo "$table" | jq -r '.partitiontable.partitions[0].start')
      esp_size=$(echo "$table" | jq -r '.partitiontable.partitions[0].size')
      dd if="$img" of=esp.img bs=512 skip="$esp_start" count="$esp_size" status=none
      fsck.vfat -n esp.img >/dev/null || { echo "FAIL: the built ESP partition is not a valid FAT filesystem"; exit 1; }

      raw_name=$(echo "$table" | jq -r '.partitiontable.partitions[1].name')
      raw_start=$(echo "$table" | jq -r '.partitiontable.partitions[1].start')
      raw_size=$(echo "$table" | jq -r '.partitiontable.partitions[1].size')
      [ "$raw_name" = "raw-a" ] || { echo "FAIL: partition 1 name is '$raw_name', expected raw-a"; exit 1; }

      # The "raw" role must be left completely untouched -- every byte in
      # its data region still zero, proving lib/image.nix never writes into
      # a slot it has no business formatting.
      nonzero=$(dd if="$img" bs=512 skip="$raw_start" count="$raw_size" status=none | tr -d '\000' | wc -c)
      [ "$nonzero" -eq 0 ] || { echo "FAIL: raw-a is not all-zero ($nonzero non-zero byte(s))"; exit 1; }

      echo "nixstorage-layout: image-build proof PASSED (size, partition count, names, type-GUIDs, ESP filesystem validity, raw-slot emptiness)"
      touch $out
    '';

  # ── BUILD-level proof #2: nixstorage-layout-verify actually detects a match AND
  #    a mismatch -- entirely inside the sandbox, no real device.
  # `readlink` is the one syscall-adjacent boundary that would otherwise
  # need a real /dev/disk/by-* entry (which a build sandbox cannot create);
  # faking exactly that one tool, and nothing else (sfdisk/jq run for
  # real, against the real testImage file), is the identical technique
  # nixboot's own checks/default.nix uses for its fake efibootmgr.
  testDevice = "/dev/disk/by-id/nixstorage-layout-test-fixture";

  fakeReadlink = pkgs.runCommand "nixstorage-layout-test-fake-readlink" { } ''
    mkdir -p $out/bin
    cat > $out/bin/readlink <<'SCRIPT'
    #!/bin/sh
    # Only ever called as: readlink -f <device>
    if [ "$2" = "@device@" ]; then
      echo "@image@"
    else
      exec @realReadlink@ "$@"
    fi
    SCRIPT
    substituteInPlace $out/bin/readlink \
      --replace '@device@' '${testDevice}' \
      --replace '@image@' '${testImage}' \
      --replace '@realReadlink@' '${pkgs.coreutils}/bin/readlink'
    chmod +x $out/bin/readlink
  '';

  # The real script, wrapped exactly the way modules/layout.nix wraps it -- obtained via a
  # real eval fixture (verify.enable = true), not rebuilt ad hoc here, so this proves the
  # MODULE's own default actually works, not just that layout-verify.sh in isolation can be
  # made to.
  verifyPkg = (evalLayoutOnly {
    nixstorage.layout.images.fixture = {
      sizeMiB = 8;
      partitions = [
        { name = "ESP"; role = "esp"; sizeMiB = 2; espLabel = "FIXESP"; }
        { name = "raw-a"; role = "raw"; sizeMiB = null; }
      ];
    };
    nixstorage.layout.verify.enable = true;
    nixstorage.layout.verify.targets.fixture = { device = testDevice; image = "fixture"; };
  }).nixstorage.layout.verify.package;

  matchingConfig = pkgs.writeText "nixstorage-layout-verify-match.json" (builtins.toJSON {
    targets.fixture = {
      device = testDevice;
      partitions = [
        { name = "ESP"; typeGuid = roleCatalogue.esp.typeGuid; sizeMiB = 2; }
        { name = "raw-a"; typeGuid = roleCatalogue.raw.typeGuid; sizeMiB = null; }
      ];
    };
  });

  driftingConfig = pkgs.writeText "nixstorage-layout-verify-drift.json" (builtins.toJSON {
    targets.fixture = {
      device = testDevice;
      partitions = [
        # Wrong declared size (64 MiB instead of the real image's 2 MiB) --
        # everything else matches, isolating exactly one drifted field.
        { name = "ESP"; typeGuid = roleCatalogue.esp.typeGuid; sizeMiB = 64; }
        { name = "raw-a"; typeGuid = roleCatalogue.raw.typeGuid; sizeMiB = null; }
      ];
    };
  });

  layoutVerifyDriftProof = pkgs.runCommand "nixstorage-layout-verify-detects-drift"
    {
      nativeBuildInputs = [ pkgs.util-linux pkgs.jq pkgs.coreutils ];
    }
    ''
      set -uo pipefail

      export PATH="${fakeReadlink}/bin:$PATH"

      # `stdenv`'s own builder already runs with `-e` active around this
      # whole buildCommand -- the drift scenario is SUPPOSED to exit
      # non-zero, so its invocation is deliberately written as the
      # left-hand side of `||`, the one shell context `-e` exempts, or a
      # genuine drift detection would abort this very check instead of
      # being captured and asserted on.
      match_exit=0
      NIXSTORAGE_LAYOUT_VERIFY_CONFIG=${matchingConfig} ${verifyPkg}/bin/nixstorage-layout-verify > match.log 2>&1 || match_exit=$?
      cat match.log

      drift_exit=0
      NIXSTORAGE_LAYOUT_VERIFY_CONFIG=${driftingConfig} ${verifyPkg}/bin/nixstorage-layout-verify > drift.log 2>&1 || drift_exit=$?
      cat drift.log

      fail=0

      [ "$match_exit" -eq 0 ] || { echo "FAIL: matching config should exit 0, got $match_exit"; fail=1; }
      grep -q '^FAIL' match.log && { echo "FAIL: matching config produced a FAIL line"; fail=1; }

      [ "$drift_exit" -ne 0 ] || { echo "FAIL: drifting config should exit non-zero, got 0"; fail=1; }
      grep -q '^FAIL' drift.log || { echo "FAIL: drifting config produced no FAIL line at all"; fail=1; }

      [ "$fail" -eq 0 ] || exit 1

      echo "nixstorage-layout-verify: drift-detection proof PASSED (clean match exits 0 with no FAIL lines; a drifted size exits non-zero with a FAIL line)"
      touch $out
    '';
in
{
  inherit results;
  inherit layoutImageBuildProof layoutVerifyDriftProof;
}
