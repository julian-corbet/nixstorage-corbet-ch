# checks/default.nix
#
# Two kinds of test, the same split nixboot's own checks/default.nix draws:
#
#   EVAL-TIME tests (`eval-tests`, `modules-evaluate`): each evaluates a real
#   configuration through NixOS's own eval-config.nix and inspects what the
#   module RENDERS, or whether forcing `system.build.toplevel` fails. Nothing
#   here boots anything -- these are entirely about selection and
#   validation, which are eval-time properties.
#
# A third kind, BUILD-level proofs against a real produced artifact
# (`layout-image-build-proof`, `layout-verify-detects-drift`, in `./layout.nix`) --
# `nixstorage.layout` is the one module in this repo that produces a real disk image and
# reads real (if fake, for testing) media back. This module spent a while extracted into a
# standalone `nixlayout` repo, on the grounds that layout runs BEFORE any ZFS pool exists
# while shape/delivery/reconciler all presuppose one that already does. THAT SPLIT IS
# REVERSED: "pre-pool vs post-pool" is a ZFS-SHAPED boundary, and under LVM -- or any of the
# many other storage architectures a public module family cannot enumerate in advance --
# there is no equivalent line in the same place. See modules/layout.nix's own header for the
# full argument. `shape`/`delivery` remain pure schema, `reconciler` acts on ownership/mode
# via a real script (proving THAT script's own idempotence needs a real filesystem tree, not
# a build sandbox -- see `modules/reconcile.sh`'s own header), and `disks` is a pure table
# with no acting surface at all -- so every check in THIS file outside of `./layout.nix`'s own
# two build proofs remains eval-only.
#
# `disks-purity` (below, via `./purity.nix`) is a fourth kind, specific to `modules/disks.nix`
# only -- a generalisation of nixposix/modules/posix.nix's own `posix-purity` check group,
# mechanically proving the "pure table, no acting surface" claim two paragraphs up rather than
# leaving it as prose. Deliberately NOT applied to `shape`/`delivery` (in scope, but not asked
# for in this pass) or `reconciler` (a real systemd oneshot -- this check would be WRONG there).
{ pkgs, lib, nixpkgs, system, nixiam, shapeModule, deliveryModule, reconcilerModule, disksModule, layoutModule, scrubModule }:

let
  # Shared by every NixOS-eval fixture in this file, including `purity.nix`'s own bare/alone
  # comparison -- one definition, so the purity check's "bare" baseline is never allowed to
  # silently drift from the baseline every other eval-test in this file already uses.
  bareStubs = {
    boot.loader.grub.enable = false;
    fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
    system.stateVersion = "25.05";
  };

  # ── NixOS eval fixtures ──────────────────────────────────────────────────
  # `evalShapeDeliveryReconciler`: shape+delivery+reconciler, WITHOUT nixiam --
  # every fixture below leaves nixstorage.reconciler untouched (default
  # disabled, no ownership/leaves declared), which reconciler.nix's own
  # header states is the one case that needs no nixiam import at all.
  evalShapeDeliveryReconciler = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        shapeModule
        deliveryModule
        reconcilerModule
        extraConfig
        bareStubs
      ];
    }).config;

  # NixOS enforces assertions when `system.build.toplevel` is forced, not on
  # a bare read of `config.assertions` (a passive list) -- same reasoning as
  # every sibling project's own `nixosBuildFails` in this family. `seq`
  # reaches the wrapping throw without deep-forcing the whole system
  # closure.
  buildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalShapeDeliveryReconciler extraConfig).system.build.toplevel true)).success;

  # `evalDisksOnly`: `nixstorage.disks` on its own -- this table has no
  # dependency on shape/delivery/reconciler (see modules/disks.nix's own
  # header: "nothing here partitions, formats, mounts, opens, or touches a
  # device in any way"), so its own assertions are exercised against the
  # smallest fixture that can force them, not the full composition.
  evalDisksOnly = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        disksModule
        extraConfig
        bareStubs
      ];
    }).config;

  disksBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalDisksOnly extraConfig).system.build.toplevel true)).success;

  # `evalScrubOnly`: `nixstorage.scrub` on its own -- no dependency on
  # shape/delivery/reconciler/disks, same reasoning as `evalDisksOnly`
  # above.
  evalScrubOnly = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        scrubModule
        extraConfig
        bareStubs
      ];
    }).config;

  scrubBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalScrubOnly extraConfig).system.build.toplevel true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # ── Mechanical purity: modules/disks.nix stays pure data, provably ────────────────────────────
  # See this file's own header and purity.nix's own header for what this proves and why it is
  # scoped to `disks.nix` alone. `populatedConfig` is a realistic, non-default use of the table
  # (one real-shaped disk) -- not the composed-host example, which never declares
  # `nixstorage.disks` at all (see examples/host/configuration.nix).
  purityResults = import ./purity.nix {
    inherit lib nixpkgs system bareStubs;
    label = "disks";
    modulePath = disksModule;
    populatedConfig = {
      nixstorage.disks.pool0 = {
        device = "/dev/disk/by-id/example-pool0";
        role = "pool-member";
      };
    };
  };

  # ── nixstorage.layout: eval-time checks + the two build-level proofs ────────────────────
  # See ./layout.nix's own header for the full story -- this module's repo-split history,
  # and why its eval-time checks now feed the SAME combined `results`/`eval-tests` every
  # other module in this file already contributes to, rather than a standalone derivation of
  # their own.
  layoutChecks = import ./layout.nix {
    inherit pkgs lib nixpkgs system disksModule bareStubs layoutModule;
  };

  results = purityResults ++ layoutChecks.results ++ [
    # --- nixstorage.disks: /dev/sdX is refused, /dev/disk/by-* is fine ------
    (check "disks/raw-devnode-fails-the-build"
      (disksBuildFails { nixstorage.disks.pool0.device = "/dev/sdb"; })
      "expected a raw /dev/sdb device path in nixstorage.disks to fail the build, but it succeeded")

    (check "disks/by-id-device-builds-fine"
      (!(disksBuildFails { nixstorage.disks.pool0.device = "/dev/disk/by-id/example-pool0"; }))
      "a /dev/disk/by-id/* nixstorage.disks entry should never fail the build on its own")

    # --- nixstorage.disks: one device, two names is refused -----------------
    # The exact anti-pattern this table exists to remove (see
    # modules/disks.nix's own header) -- two names resolving to the same
    # physical disk means two consumers can each believe they own it.
    (check "disks/duplicate-device-fails-the-build"
      (disksBuildFails {
        nixstorage.disks.pool0.device = "/dev/disk/by-id/example-same-disk";
        nixstorage.disks.pool1.device = "/dev/disk/by-id/example-same-disk";
      })
      "expected two nixstorage.disks names sharing one device path to fail the build, but it succeeded")

    (check "disks/distinct-devices-build-fine"
      (
        !(disksBuildFails {
          nixstorage.disks.pool0.device = "/dev/disk/by-id/example-pool0";
          nixstorage.disks.pool1.device = "/dev/disk/by-id/example-pool1";
        })
      )
      "two nixstorage.disks entries naming two different devices should never fail the build")

    # --- nixstorage.scrub: a job's `group` must be declared in `groups` -----
    (check "scrub/undeclared-group-fails-the-build"
      (scrubBuildFails {
        nixstorage.scrub.enable = true;
        nixstorage.scrub.jobs.root = {
          fsType = "btrfs";
          target = "/";
          minCycleDays = 7;
          group = "missing";
        };
      })
      "expected a job referencing an undeclared nixstorage.scrub.groups name to fail the build, but it succeeded")

    (check "scrub/declared-group-builds-fine"
      (
        !(scrubBuildFails {
          nixstorage.scrub.enable = true;
          nixstorage.scrub.groups.shared = { };
          nixstorage.scrub.jobs.root = {
            fsType = "btrfs";
            target = "/";
            minCycleDays = 7;
            group = "shared";
          };
        })
      )
      "a job whose group IS declared in nixstorage.scrub.groups should never fail the build on its own")

    # --- nixstorage.scrub: no field may carry the internal ':'/',' job-line delimiter ---
    (check "scrub/delimiter-in-target-fails-the-build"
      (scrubBuildFails {
        nixstorage.scrub.enable = true;
        nixstorage.scrub.jobs.root = {
          fsType = "btrfs";
          target = "/tank:evil";
          minCycleDays = 7;
        };
      })
      "expected a nixstorage.scrub target containing ':' to fail the build (it would corrupt the internal job-line encoding), but it succeeded")

    (check "scrub/plain-target-builds-fine"
      (
        !(scrubBuildFails {
          nixstorage.scrub.enable = true;
          nixstorage.scrub.jobs.root = {
            fsType = "btrfs";
            target = "/tank/archive";
            minCycleDays = 7;
          };
        })
      )
      "a plain nixstorage.scrub target with no delimiter characters should never fail the build on its own")
  ];

  failed = builtins.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  eval-tests =
    if failed != [ ]
    then
      throw ''
        nixstorage eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
        ${report}
      ''
    else
    # Depending on `passedCount` forces `results`, so the tests genuinely
    # run under `nix flake check` rather than merely being defined.
      pkgs.runCommand "nixstorage-eval-tests"
        { passedCount = toString (builtins.length results); }
        ''
          echo "all $passedCount nixstorage eval tests passed"
          touch $out
        '';

  # ── the composed-host check: every real, implemented option, once ───────
  # Unchanged in spirit from this repo's original scaffold check -- still a
  # `lib.nixosSystem` composing all four modules plus nixiam's posix module
  # against examples/host/configuration.nix, still discarding the drvPath's
  # string context so this evaluates a system rather than building one.
  # nixiam.nixosModules.posix is a real, shipped module as of this check
  # (see README's Status) -- if that ever regresses, this is the one check
  # that will say so by refusing to evaluate.
  composedHost = lib.nixosSystem {
    inherit system;
    modules = [
      shapeModule
      deliveryModule
      reconcilerModule
      layoutModule
      scrubModule
      nixiam.nixosModules.posix
      ../examples/host/configuration.nix
    ];
  };

  modules-evaluate =
    pkgs.writeText "nixstorage-host-drvpath"
      (builtins.unsafeDiscardStringContext composedHost.config.system.build.toplevel.drvPath);
in
{
  inherit eval-tests modules-evaluate;
  layout-image-build-proof = layoutChecks.layoutImageBuildProof;
  layout-verify-detects-drift = layoutChecks.layoutVerifyDriftProof;
}
