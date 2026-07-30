# checks/purity.nix
#
# Generalises nixposix/modules/posix.nix's own `posix-purity` check group (see that repo's
# checks/default.nix, group 1) into a reusable function any registry-shaped module in this
# family can call against its own module file, instead of re-deriving the same proofs by hand
# per repo. Never a flake input on nixposix for this -- the house rule ("no flake inputs on
# other nix* repos, read siblings defensively") applies in its strongest form here: this is not
# even a cross-repo DATA read, it is a test HELPER, and the fix for "don't want to retype this"
# is the one nixluks already took for lib/device-path.nix ("kept inline rather than shared so
# this module depends on nothing") -- copy the file, never the dependency. Applied here ONLY to
# `modules/disks.nix`: `shape.nix`/`delivery.nix` are pure schema too but out of this pass's
# scope, and `reconciler.nix` ships a real systemd oneshot on purpose -- this check would be
# wrong there, not merely unnecessary.
#
# ── The definition of "pure" this mechanically enforces, stated precisely ───────────────────
#
# A module is PURE DATA for this check's purposes iff ALL THREE hold:
#
#   1. Its own top-level module function never binds a `pkgs` formal argument -- checked via
#      `builtins.functionArgs`, not a text search, because a module can reference something
#      called `pkgs` under a different bound name or smuggle it in through `...`, but it
#      cannot LEGALLY use it as `pkgs` inside its own body without that name appearing as a
#      formal argument first.
#   2. Composing it ALONE (plus a bare, non-bootable stub system) against a realistic,
#      non-default USE of its own options produces IDENTICAL values on every watched surface
#      (by default: `systemd.services`, `environment.systemPackages`; see `extraSurfaces`
#      below for a caller-supplied fourth) to the same bare stub system with the module absent
#      entirely. THIS IS THE LOAD-BEARING HALF, the one every watched surface gets regardless
#      of source: it is not enough that the module's own text never writes a watched option
#      path directly (see 3 below) -- an INDIRECT path (some other option that happens to
#      expand into a systemd unit or a package) dodges a text scan but cannot dodge this,
#      because it diffs what the module system actually PRODUCES.
#   3. For the two BASE surfaces only (`systemd.services`, `environment.systemPackages`): its
#      source text (comments stripped) never contains the literal option-path string. A cheap,
#      fast-failing companion to (2) that gives a violator's own diff a readable reason without
#      waiting for a full NixOS eval -- deliberately NOT extended to `extraSurfaces`, see below.
#
# Declaring `options` and `config.assertions` is explicitly NOT a violation of any of the three
# -- a table that only ever validates itself and hands back facts is exactly what "pure data"
# means here. `modules/disks.nix`'s own device-collision assertion (and the `deepSeq` it uses
# to force every declared device's type, even a lone entry `lib.unique` would otherwise never
# force) branches on `config.assertions` freely and stays pure by this definition.
#
# ── What this does NOT prove, stated as honestly as what it does ────────────────────────────
#
# `systemd.services` and `environment.systemPackages` are the two surfaces nixposix's own
# module header names by name, and the two `baseSurfaces` below watches unconditionally --
# they are not the only way a module could stop being pure data (a stray `users.users.*` entry
# with no `pkgs` involved at all would dodge both). `extraSurfaces` exists for exactly that gap
# -- see nixmachines' own copy of this file, which hands it `networking.hostName` because that
# module's own header promises it by name, via the load-bearing eval-diff (2) and its
# meta-test only, deliberately NOT the text scan (3): a registry's own option `description` is
# exactly the place a caller legitimately needs to name a guarded option in PROSE, and a
# literal scan cannot tell that string apart from an actual write -- confirmed the first time
# nixmachines' own copy tried it, against a real, correct `description` string, not a
# violation. `modules/disks.nix`'s own header makes no such named promise beyond "nothing here
# partitions, formats, mounts, opens, or touches a device" -- prose actions with no single
# clean option-path to watch -- so `extraSurfaces` is left at its empty default here. A module
# that adds some fourth, still-unwatched NixOS-only primitive is this generalisation's own
# remaining honest gap -- watch for it explicitly the day it becomes a real risk, rather than
# claiming a coverage this mechanism does not actually have.
#
# ── The meta-tests, and why they exist ───────────────────────────────────────────────────────
#
# A comparison that has never been shown capable of failing is not a proof, it is an
# assumption wearing a proof's clothes. `decoyModule` below DOES bind `pkgs`, DOES add a
# systemd unit and a package, and DOES touch every `extraSurfaces` entry a caller supplies --
# composed only against the bare stub, never alongside the real module under test -- so every
# check above gets a companion meta-test proving it actually notices a real violation, not
# just that the real module happens not to have one today.
{ lib, nixpkgs, system, label, modulePath, bareStubs, populatedConfig, extraSurfaces ? [ ] }:

let
  check = name: ok: detail: { inherit name ok detail; };

  isCommentLine = line: builtins.match "[ \t]*#.*" line != null;
  stripComments = src:
    lib.concatStringsSep "\n"
      (lib.filter (l: !(isCommentLine l)) (lib.splitString "\n" src));

  moduleSrc = stripComments (builtins.readFile modulePath);

  evalNixosModules = modules:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system modules;
    }).config;

  sorted = lib.sort (a: b: a < b);

  # The two surfaces nixposix's own module header names by name -- see this file's own header
  # for why these two are the unconditional default rather than an exhaustive list.
  baseSurfaces = [
    {
      path = "systemd.services";
      value = cfg: sorted (lib.attrNames cfg.systemd.services);
    }
    {
      path = "environment.systemPackages";
      value = cfg: sorted (map (p: p.name) cfg.environment.systemPackages);
    }
  ];

  allSurfaces = baseSurfaces ++ extraSurfaces;

  cfg-bare = evalNixosModules [ bareStubs ];
  cfg-module-alone = evalNixosModules [ modulePath bareStubs populatedConfig ];

  # A deliberately broken stand-in, used ONLY to prove the checks below actually have teeth --
  # never composed alongside the real module under test, and never exported by any flake in
  # this family. Its own namespace (`purityCheckDecoy`) can never collide with a real option.
  decoyModule = { config, lib, pkgs, ... }: {
    options.purityCheckDecoy.enable =
      lib.mkEnableOption "decoy, for this purity check's own meta-tests -- never a real module";
    config = lib.mkIf config.purityCheckDecoy.enable (lib.mkMerge (
      [
        { systemd.services.purity-check-decoy-unit.script = "exit 0"; }
        { environment.systemPackages = [ pkgs.hello ]; }
      ]
      ++ map (s: s.decoy) extraSurfaces
    ));
  };

  cfg-decoy-alone = evalNixosModules [ bareStubs decoyModule { purityCheckDecoy.enable = true; } ];

  # The load-bearing pair, run for EVERY surface (base and extra alike): the eval-diff proof
  # itself, and the meta-test proving that proof has teeth. Neither reads the module's source
  # text, so neither can be fooled by a legitimate PROSE mention of the watched option path
  # inside the module's own `description` strings -- unlike the text scan below.
  evalDiffChecks = s: [
    (check "${label}-purity/alone-never-changes-${s.path}"
      (s.value cfg-module-alone == s.value cfg-bare)
      "composing this module alone (with a realistic, non-default use of its own options) changed ${s.path} vs. the identical system without it -- got: ${builtins.toJSON (s.value cfg-module-alone)}, expected: ${builtins.toJSON (s.value cfg-bare)}")

    (check "${label}-purity/mechanism-catches-a-${s.path}-change (meta-test)"
      (s.value cfg-decoy-alone != s.value cfg-bare)
      "a decoy module that DOES change ${s.path} was not caught by this comparison -- the comparison itself is what's broken, not the module under test")
  ];

  # The cheap, fast-failing companion -- BASE SURFACES ONLY. Deliberately not run against
  # `extraSurfaces`: a caller's own module is free to (and, for a registry, often should)
  # mention a guarded option's dotted path in an option's own `description` prose ("this is
  # `networking.hostName` on NixOS, or the equivalent on..."), which is a real Nix string in
  # the module's CODE, not a `#` comment `stripComments` would remove -- a literal scan cannot
  # tell that apart from an actual write, and a caller-supplied surface has no guarantee its
  # own module avoids the vocabulary the way `systemd.services`/`environment.systemPackages`
  # mentions happen to here (both currently occur only inside `#` header comments -- see the
  # eval-diff pair above for the check that holds regardless either way). Concretely: this
  # fired a false positive in nixmachines' own copy of this file, against `networking.hostName`
  # mentioned correctly inside a real `description` string, not a violation -- exactly the
  # failure mode this scoping exists to avoid.
  sourceScanChecks = s: [
    (check "${label}-purity/source-never-mentions-${s.path}"
      (!(lib.hasInfix s.path moduleSrc))
      "${modulePath}'s source text now contains the literal string \"${s.path}\"")
  ];
in
[
  (check "${label}-purity/no-pkgs-argument"
    (!(lib.functionArgs (import modulePath) ? pkgs))
    "${modulePath}'s own module function now binds a `pkgs` argument -- pure-data registries in this family never take one")
]
++ lib.concatMap sourceScanChecks baseSurfaces
++ lib.concatMap evalDiffChecks allSurfaces
++ [
  (check "${label}-purity/functionArgs-mechanism-catches-a-pkgs-argument (meta-test)"
    (lib.functionArgs decoyModule ? pkgs)
    "the decoy module (which binds `pkgs` itself) was not detected by functionArgs -- the mechanism itself is broken")
]
