# modules/reconciler.nix
#
# THE RECONCILER: the one idempotent pass that converges real on-disk
# ownership (uid/gid) and the TOP-DIRECTORY mode of every declared storage
# tree to the model, forever. This is the third leg of nixstorage's own
# thesis (see repo README): shape.nix converges what a dataset IS
# (recordsize/compression), delivery.nix converges where it SURFACES
# (source -> $HOME -> XDG -> scope), this file converges WHO owns it and
# HOW FAR it can be walked into.
#
# Extracted, with its exact semantics preserved on purpose, from a real,
# already-running private reconciler that has been chowning/chmodding a
# multi-pool, multi-hundred-terabyte deployment on an unattended schedule for
# months. The actual chown/chmod rules this buys you -- recursive chown vs
# top-dir-only chmod, mis-owned-only, never dereferencing a symlink, roots
# before leaves, shallow leaves before deep ones, prune honoured on every
# walk -- live in reconcile.sh, one rule per function, each with its own
# "why" comment; every one of them reads as counter-intuitive on first
# sight, and every one is there because someone tried the obvious
# alternative first, on real data, and it broke something real. This file
# is the Nix half: the schema, the cross-module wiring, and the
# assertions that make a bad declaration fail loudly instead of quietly
# reconciling the wrong thing.
#
# ── Cross-repo contract: nixstorage CONSUMES nixid, never the reverse ────
# `ownership.<path>.owner`/`.group` and `leaves.<path>.identity` are NAMES
# resolved against `config.nixid.posix.identities.<name> = { uid; gid; ...
# }` and, for `group` only, optionally also `config.nixid.posix.groups.
# <name> -> gid` (a plain shared-group table, independent of any one app
# identity). `config.nixid.posix.podSecurity.<name>` is nixid's own
# Kubernetes-securityContext-shaped twin of the SAME identity -- see the
# per-leaf assertions below for what cross-checking it actually buys you.
# All three option paths are read defensively (`config.nixid.posix.… or
# {}`), so importing this module WITHOUT nixid's posix module works fine
# as long as `ownership.*.owner`/`.group` are given as literal numeric
# uid/gid strings and no `leaves` are declared at all -- the moment a
# `leaves` entry is declared, its `identity` MUST resolve, and that
# failure is reported as a real assertion, not a cryptic missing-attribute
# trace. Dependency direction is enforced by convention, not by any
# mechanism in this file: nixid must never gain any notion of a dataset, a
# path, or a pool. If that boundary is ever crossed in either direction,
# the entire reason these are two separate repos is gone.
#
# ── Why a standalone reconcile.sh, wrapped, not pkgs.writeShellApplication ──
# reconcile.sh is deliberately readable as one plain script -- open it,
# diff it, `bash -n` it, in one sitting -- the same choice this family's
# private ancestor made, for the same reason: this is the one file in
# nixstorage where "can a human read every chown/chmod call this thing can
# possibly make" matters more than everything else being Nix-native.
#
# It is wrapped with `pkgs.writeShellScriptBin`, deliberately NOT
# `pkgs.writeShellApplication`: that helper hard-codes `set -euo pipefail`
# onto whatever text it's given, and `errexit` is actively wrong for this
# script's job. A `find` walk over a live, multi-terabyte, concurrently
# mutated tree WILL occasionally meet one file that vanished mid-walk or
# briefly denies a stat -- that has to cost this run one logged line, not
# abort convergence for every OTHER declared root/leaf still queued behind
# it in the same invocation. See reconcile.sh's own header for the same
# note from the script's side of this boundary.
{ lib, config, pkgs, options, ... }:

with lib;

let
  cfg = config.nixstorage.reconciler;

  # ── nixid.posix: read defensively, see header for why ───────────────
  posixDeclared = options ? nixid && (options.nixid ? posix) && (options.nixid.posix ? identities);
  identities = config.nixid.posix.identities or { };
  groups = config.nixid.posix.groups or { };
  podSecurity = config.nixid.posix.podSecurity or { };

  # Mirrors nixid.posix's own private `resolvedGid` (modules/posix.nix):
  # an unset `gid` is a User Private Group, numerically equal to `uid`.
  # Duplicated here rather than imported because it's three lines of pure
  # arithmetic on a value this module already has in hand -- not worth a
  # cross-repo function-sharing mechanism neither repo otherwise needs.
  identGid = ident: if ident.gid == null then ident.uid else ident.gid;

  isNumericStr = s: builtins.match "[0-9]+" s != null;

  availableIdentities =
    if identities == { } then "(none declared)" else concatStringsSep ", " (attrNames identities);

  notImportedHint = ''

    nixid's posix module does not appear to be imported into this
    configuration at all (checked via `options.nixid.posix.identities`).
    Either import it alongside nixstorage, or use a literal numeric
    uid/gid string here instead of a name.'';

  resolveOwnerUid = path: spec:
    if isNumericStr spec.owner then lib.toInt spec.owner
    else if identities ? ${spec.owner} then identities.${spec.owner}.uid
    else throw ''
      nixstorage.reconciler.ownership."${path}".owner = "${spec.owner}" is
      neither a literal numeric uid nor a name in nixid.posix.identities.
      Declared identities: ${availableIdentities}.${optionalString (!posixDeclared) notImportedHint}
    '';

  # ⚠ A group NAME is resolved against two independent tables -- the cross-host
  # group registry first, then an identity's own UPG gid. If the same name
  # exists in BOTH with different numbers, silently preferring one is how a
  # tree ends up chowned to a gid nobody declared and nobody can find. NFS
  # AUTH_SYS passes gids numerically, so the wrong number does not fail
  # loudly at the mount -- it just grants or denies the wrong access on
  # another machine. Refuse the ambiguity instead of resolving it.
  ambiguousGroup = name:
    groups ? ${name} && identities ? ${name}
    && groups.${name} != identGid identities.${name};

  resolveOwnerGid = path: spec:
    if isNumericStr spec.group then lib.toInt spec.group
    else if ambiguousGroup spec.group then throw ''
      nixstorage.reconciler.ownership."${path}".group = "${spec.group}" is
      ambiguous: it names BOTH nixid.posix.groups."${spec.group}"
      (gid ${toString (groups.${spec.group} or 0)}) AND
      nixid.posix.identities."${spec.group}"
      (resolved gid ${toString (identGid (identities.${spec.group} or { uid = 0; gid = null; }))}),
      and the two disagree.

      Resolving this silently would chown the tree to a gid that appears in
      neither table by intent. Either rename one of them, make the two
      numbers agree, or write the literal numeric gid here.
    ''
    else if groups ? ${spec.group} then groups.${spec.group}
    else if identities ? ${spec.group} then identGid identities.${spec.group}
    else throw ''
      nixstorage.reconciler.ownership."${path}".group = "${spec.group}" is
      neither a literal numeric gid, a name in nixid.posix.groups, nor a
      name in nixid.posix.identities (an identity's own resolved gid).
      Declared identities: ${availableIdentities}.${optionalString (!posixDeclared) notImportedHint}
    '';

  resolveLeafUid = path: spec:
    if identities ? ${spec.identity} then identities.${spec.identity}.uid
    else throw ''
      nixstorage.reconciler.leaves."${path}".identity = "${spec.identity}"
      was not found in nixid.posix.identities. A leaf's uid/gid are ALWAYS
      looked up from the identity registry, never restated here -- that is
      what makes the on-disk-uid vs k8s-runAsUser/PUID invariant checkable
      at all (see this module's own per-leaf assertions).
      Declared identities: ${availableIdentities}.${optionalString (!posixDeclared) notImportedHint}
    '';

  resolveLeafGid = path: spec:
    if identities ? ${spec.identity} then identGid identities.${spec.identity}
    else throw "nixstorage.reconciler.leaves.\"${path}\".identity = \"${spec.identity}\" not found in nixid.posix.identities (see the uid resolution error above for the full message).";

  # `reconcile=false` is ONE honest concept, generalizing what used to be
  # several separately-named per-leaf carve-out flags (a database owning
  # its own data directory's lifecycle, a path genuinely owned by a
  # different system entirely): "declared, visible, asserted against --
  # but this pass must never chown/chmod it." For a root, that flag lives
  # locally (`ownership.<path>.reconcile`) because a root's owner can be a
  # bare literal uid with no identity behind it at all. For a LEAF, the
  # flag is never restated here: it is read straight from
  # `nixid.posix.identities.<name>.reconcile` -- the identity's OWN
  # opinion on whether anything is allowed to touch its data's ownership,
  # which is the one and only place that opinion should live (see that
  # option's own description in nixid for the two real shapes this
  # covers). A root whose `owner` happens to BE an identity name is
  # additionally gated by that identity's own flag too, on top of its
  # local one -- the more restrictive of the two always wins.
  rootReconcile = path: spec:
    spec.reconcile && (isNumericStr spec.owner || (identities.${spec.owner}.reconcile or true));

  leafReconcile = path: spec: identities.${spec.identity}.reconcile;

  # ── shape.nix cross-reference ────────────────────────────────────────
  # nixstorage.shape.datasets is keyed by the dataset's full ZFS path
  # exactly as `zfs list` shows it (e.g. "tank/media", no leading "/") --
  # see shape.nix's own `datasets` option description. This module's own
  # ownership/leaves keys are real filesystem paths (chown/chmod/find need
  # paths, not dataset names; a leaf in particular is very often just a
  # directory inside a LARGER dataset's tree, not a dataset of its own, so
  # dataset-name keying would not even be expressible for every leaf).
  # The translation between the two key spaces assumes plain ZFS
  # mountpoint inheritance -- dataset "tank/media" mounts at "/tank/media"
  # -- which is ZFS's own default behavior whenever nobody has set a
  # custom `mountpoint=` override anywhere in that dataset's ancestry.
  # ⚠ If a consumer's pool uses custom mountpoints that break this
  # assumption, this cross-reference silently finds no matching shape.nix
  # entry and `subtreeMountable`/dataset-level `prune` are simply never
  # picked up here -- there is no way for this module to detect that
  # mismatch on its own, the same honest limit shape.nix's own
  # ancestor-chain assertion documents for itself.
  shapeDatasets = config.nixstorage.shape.datasets or { };
  datasetKeyFor = path: lib.removePrefix "/" path;
  shapeEntryFor = path: shapeDatasets.${datasetKeyFor path} or { prune = false; subtreeMountable = false; };

  # ── subtreeMountable: force o+x into the EFFECTIVE mode, never stored ──
  # See nixstorage.shape.datasets.*.subtreeMountable's own description for
  # the measured NFS root_squash traversal chain this whole mechanism
  # fixes (mode 2750 → 2751 is the fix; o+x grants traverse, never list).
  # Applied here, not in shape.nix, because shape.nix is explicit that
  # mode computation is entirely out of its own scope -- ownership is
  # this module's job end to end.
  hasOtherExec = mode: elem (lib.substring (lib.stringLength mode - 1) 1 mode) [ "1" "3" "5" "7" ];

  forceOtherExecDigit = d: {
    "0" = "1"; "1" = "1"; "2" = "3"; "3" = "3";
    "4" = "5"; "5" = "5"; "6" = "7"; "7" = "7";
  }.${d};

  forceOtherExec = mode:
    let
      len = lib.stringLength mode;
      lastDigit = lib.substring (len - 1) 1 mode;
      rest = lib.substring 0 (len - 1) mode;
    in
    rest + forceOtherExecDigit lastDigit;

  effectiveModeOf = path: spec:
    if (shapeEntryFor path).subtreeMountable then forceOtherExec spec.mode else spec.mode;

  effectiveModes = mapAttrs effectiveModeOf cfg.ownership;

  isProperAncestor = a: b: a != b && lib.hasPrefix (a + "/") (b + "/");

  subtreeMountablePaths = filter (p: (shapeEntryFor p).subtreeMountable) (attrNames cfg.ownership);

  # ⚠ Only sees ancestors that are THEMSELVES declared in
  # nixstorage.reconciler.ownership -- an undeclared directory above a
  # declared tree (a bare pool mountpoint, say) is outside what this
  # module can verify, the same honest limit shape.nix's own equivalent
  # assertion documents. Complements, rather than duplicates, shape.nix's
  # own ancestor check: shape.nix verifies the `subtreeMountable` BOOLEAN
  # stays consistent across ITS declared dataset chain; this verifies the
  # actual MODE VALUE this module is about to write carries the bit that
  # boolean promises, across the (possibly larger, possibly differently
  # shaped) ownership-root ancestor chain.
  ancestorTraversalAssertions = flatten (map
    (p: map
      (a: {
        assertion = hasOtherExec effectiveModes.${a};
        message = ''
          nixstorage.reconciler.ownership."${p}" is subtreeMountable (per
          nixstorage.shape.datasets."${datasetKeyFor p}"), which forces o+x
          into its own effective mode (now "${effectiveModes.${p}}") -- but
          its declared ancestor "${a}" (effective mode
          "${effectiveModes.${a}}", from ownership."${a}".mode) does NOT
          grant "others" traverse. An NFS root_squash client (or anything
          else walking this path component by component, as `nobody`) dies
          at "${a}" and never reaches "${p}" at all, regardless of what
          "${p}"'s own mode says. Set subtreeMountable = true on the
          shape.nix dataset for "${a}" too -- shape.nix's own assertion
          already requires this among its OWN declared datasets; this
          checks the identical requirement against every reconciler
          ownership root shape.nix has no visibility into on its own.
        '';
      })
      (filter (a: isProperAncestor a p) (attrNames cfg.ownership)))
    subtreeMountablePaths);

  # ── structural sanity: machine-detectable mistakes, not documentation ──
  absolutePathAssertions =
    (map
      (path: {
        assertion = hasPrefix "/" path;
        message = ''nixstorage.reconciler.ownership."${path}" is not an absolute path -- every declared tree root must start with "/".'';
      })
      (attrNames cfg.ownership))
    ++ (map
      (path: {
        assertion = hasPrefix "/" path;
        message = ''nixstorage.reconciler.leaves."${path}" is not an absolute path -- every declared app leaf must start with "/".'';
      })
      (attrNames cfg.leaves))
    ++ (imap0
      (i: p: {
        assertion = hasPrefix "/" p;
        message = "nixstorage.reconciler.prune[${toString i}] (\"${p}\") is not an absolute path.";
      })
      cfg.prune);

  identityExistenceAssertions =
    (concatMap
      (path:
        let spec = cfg.ownership.${path}; in
        optional (!(isNumericStr spec.owner) && !(identities ? ${spec.owner})) {
          assertion = false;
          message = ''
            nixstorage.reconciler.ownership."${path}".owner = "${spec.owner}"
            is neither a literal numeric uid nor a name in
            nixid.posix.identities. Declared identities: ${availableIdentities}.${optionalString (!posixDeclared) notImportedHint}
          '';
        })
      (attrNames cfg.ownership))
    ++ (concatMap
      (path:
        let spec = cfg.ownership.${path}; in
        optional (!(isNumericStr spec.group) && !(groups ? ${spec.group}) && !(identities ? ${spec.group})) {
          assertion = false;
          message = ''
            nixstorage.reconciler.ownership."${path}".group = "${spec.group}"
            is neither a literal numeric gid, a name in nixid.posix.groups,
            nor a name in nixid.posix.identities. Declared identities:
            ${availableIdentities}.${optionalString (!posixDeclared) notImportedHint}
          '';
        })
      (attrNames cfg.ownership))
    ++ (concatMap
      (path:
        let spec = cfg.leaves.${path}; in
        optional (!(identities ? ${spec.identity})) {
          assertion = false;
          message = ''
            nixstorage.reconciler.leaves."${path}".identity = "${spec.identity}"
            was not found in nixid.posix.identities. Declared identities:
            ${availableIdentities}.${optionalString (!posixDeclared) notImportedHint}
          '';
        })
      (attrNames cfg.leaves));

  # THE invariant this module exists to make machine-checkable rather than
  # a comment: a leaf's on-disk uid/gid (what this reconciler actually
  # chowns it to) must equal the runAsUser/runAsGroup (native identities)
  # or PUID/PGID (puid identities) that nixid generated for the SAME
  # identity's Kubernetes securityContext. Get this wrong and a pod starts
  # as a uid that cannot open its own already-chowned data -- EACCES on
  # every read/write, discovered only once the container actually runs,
  # nowhere near build/deploy time. Both values are, today, pure functions
  # of the exact same `nixid.posix.identities.<name>` entry
  # (`nixid.posix.podSecurity` is `readOnly = true` and entirely derived --
  # see that option's own description), so this assertion is structurally
  # guaranteed to hold as long as this module and nixid's posix module
  # both resolve a leaf through `identity` the way they're documented to.
  # It stays here anyway, as a real assertion rather than a comment
  # claiming the guarantee, because a guarantee that is never actually
  # checked is indistinguishable from one that silently stopped holding --
  # this is the trip-wire for the day nixid's own derivation, or this
  # module's own resolution path, changes underneath that guarantee.
  leafInvariantAssertions = flatten (map
    (path:
      let
        spec = cfg.leaves.${path};
        n = spec.identity;
      in
      optionals (identities ? ${n}) (
        let
          ident = identities.${n};
          gid = identGid ident;
          ps = podSecurity.${n};
        in
        if ident.variant == "native" then [
          {
            assertion = ps.pod.runAsUser == ident.uid;
            message = ''
              nixstorage.reconciler.leaves."${path}" uses identity "${n}"
              (variant "native"): its on-disk uid
              (nixid.posix.identities.${n}.uid = ${toString ident.uid}, what
              this leaf is actually chowned to) does not match
              nixid.posix.podSecurity.${n}.pod.runAsUser
              (${toString ps.pod.runAsUser}). This should be structurally
              impossible -- both are derived from the same identity entry --
              so if this fires, whatever broke that derivation is the real
              bug, not this leaf's declaration.
            '';
          }
          {
            assertion = ps.pod.runAsGroup == gid;
            message = ''
              nixstorage.reconciler.leaves."${path}" uses identity "${n}":
              its on-disk gid (${toString gid}) does not match
              nixid.posix.podSecurity.${n}.pod.runAsGroup
              (${toString ps.pod.runAsGroup}). Same failure class as the
              runAsUser check above, one field over.
            '';
          }
        ] else [
          {
            assertion = ps.env.PUID == toString ident.uid;
            message = ''
              nixstorage.reconciler.leaves."${path}" uses identity "${n}"
              (variant "puid" -- an s6-overlay/linuxserver.io-style image:
              starts as root, drops privilege itself via PUID/PGID). Its
              on-disk uid (${toString ident.uid}) does not match
              nixid.posix.podSecurity.${n}.env.PUID (${ps.env.PUID}). If
              this ever drifts, the container's own entrypoint chowns its
              data to a DIFFERENT uid than this reconciler applies, and the
              two fight each other's ownership forever, once per restart
              and once per timer tick.
            '';
          }
          {
            assertion = ps.env.PGID == toString gid;
            message = ''
              nixstorage.reconciler.leaves."${path}" uses identity "${n}":
              its on-disk gid (${toString gid}) does not match
              nixid.posix.podSecurity.${n}.env.PGID (${ps.env.PGID}).
            '';
          }
        ]
      ))
    (attrNames cfg.leaves));

  duplicatePathAssertions =
    let shared = filter (p: elem p (attrNames cfg.leaves)) (attrNames cfg.ownership); in
    map
      (p: {
        assertion = false;
        message = ''
          "${p}" is declared as BOTH nixstorage.reconciler.ownership and
          .leaves. A tree root (swept to one tree-wide owner) and an app
          leaf (swept to one identity, re-won AFTER every root pass) are
          mutually exclusive roles for the same path -- pick one.
        '';
      })
      shared;

  # A self-pruned active path is a silent no-op, not a loud one: its own
  # `find "$path" -path "$path" -prune` stops at the top directory and
  # descends nowhere, which looks IDENTICAL in the log to "everything
  # already matched" -- this assertion is the only thing standing between
  # that and a tree that quietly never converges again.
  pruneOverlapAssertions =
    let
      activeRoots = attrNames (filterAttrs (p: s: rootReconcile p s) cfg.ownership);
      activeLeaves = attrNames (filterAttrs (p: s: leafReconcile p s) cfg.leaves);
      # `unique`: a path declared as BOTH a root and a leaf (already its own
      # separate assertion above) would otherwise appear in both lists and
      # report this exact same overlap twice.
      overlapping = unique (filter (p: elem p allPrune) (activeRoots ++ activeLeaves));
    in
    map
      (p: {
        assertion = false;
        message = ''
          "${p}" is declared as an ACTIVELY reconciled root/leaf, but also
          appears in the effective prune set (nixstorage.reconciler.prune,
          or a nixstorage.shape.datasets."${datasetKeyFor p}".prune = true
          dataset at the same path). Either drop it from prune, or mark it
          reconcile = false here instead of pruning it.
        '';
      })
      overlapping;

  # ── the aggregate prune list, fed to every `find` in reconcile.sh ─────
  # Three sources, all folded into ONE list so the script only ever has to
  # reason about a single prune predicate: explicit extras declared right
  # here, every nixstorage.shape.datasets.*.prune = true dataset (media
  # this family's own field data flags as unsafe to bulk-walk -- see
  # shape.nix's own `prune` description), and every declared root/leaf
  # whose EFFECTIVE reconcile is false. That last source is the
  # non-obvious one: a carve-out nested under a recursing root has to be
  # excluded from that root's own recursive walk, or the root's own
  # ownership sweep would silently "fix" the carve-out's ownership right
  # back out from under whatever legitimately owns it, every single run --
  # `reconcile = false` and `prune` would otherwise fight each other
  # forever instead of composing.
  shapePrunePaths = mapAttrsToList (dsName: _: "/" + dsName) (filterAttrs (_: d: d.prune) shapeDatasets);
  carveOutRootPaths = attrNames (filterAttrs (p: s: !(rootReconcile p s)) cfg.ownership);
  carveOutLeafPaths = attrNames (filterAttrs (p: s: !(leafReconcile p s)) cfg.leaves);
  allPrune = unique (cfg.prune ++ shapePrunePaths ++ carveOutRootPaths ++ carveOutLeafPaths);

  # ── render the one JSON interface between Nix and reconcile.sh ────────
  # Same pattern this whole nix* family uses throughout (nixnet's
  # config.json, nixshare's watchdog.json): Nix computes and validates
  # everything at eval time, the script consumes one flat, already-
  # resolved JSON document at run time and contains no Nix-shaped logic of
  # its own at all.
  renderedModel = {
    roots = mapAttrs
      (path: spec: {
        uid = resolveOwnerUid path spec;
        gid = resolveOwnerGid path spec;
        mode = effectiveModes.${path};
        recurse = spec.recurse;
        reconcile = rootReconcile path spec;
      })
      cfg.ownership;
    leaves = mapAttrs
      (path: spec: {
        uid = resolveLeafUid path spec;
        gid = resolveLeafGid path spec;
        mode = spec.mode;
        reconcile = leafReconcile path spec;
      })
      cfg.leaves;
    prune = allPrune;
  };

  configFile = pkgs.writeText "nixstorage-reconcile.json" (builtins.toJSON renderedModel);

  reconcilePackage = pkgs.writeShellScriptBin "nixstorage-reconcile" (builtins.readFile ./reconcile.sh);

in
{
  options.nixstorage.reconciler = {
    enable = mkEnableOption ''
      the nixstorage ownership/mode reconciler: a systemd oneshot (+
      optional timer) that converges real on-disk uid/gid and top-
      directory mode to this module's declared model
    '';

    package = mkOption {
      type = types.package;
      default = reconcilePackage;
      description = ''
        The `nixstorage-reconcile` package (wraps reconcile.sh). Override
        only to pin/patch a build -- the wrapper deliberately carries no
        `set -e`/`pipefail` (see this module's own header), so replacing
        it with something built via `pkgs.writeShellApplication` would
        silently reintroduce the exact abort-on-first-EACCES failure mode
        this module exists to avoid.
      '';
    };

    dryRun = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Pass `--dry-run` to every scheduled run of `nixstorage-reconcile`:
        print the full chown/chmod plan (including a count of mis-owned
        paths under every recursively-swept root/leaf) and change nothing
        on disk. Independent of the timer/manual-invocation split below --
        a manual `nixstorage-reconcile --dry-run` always works regardless
        of this setting, which only controls the SCHEDULED run's default.

        Recommended: after any change to `ownership`/`leaves`/`prune`, or
        after touching `nixstorage.shape.datasets.*.subtreeMountable`, run
        `nixstorage-reconcile --dry-run` by hand once and read the plan
        before trusting the next scheduled run to apply it for real. A
        `chown` is only reversible from a snapshot taken before it ran --
        there is no built-in undo.
      '';
    };

    ownership = mkOption {
      default = { };
      description = ''
        Tree ROOTS, keyed by absolute filesystem path (asserted). Each
        root is swept to ONE owner, and swept BEFORE every declared leaf
        (see `leaves` below for why the order is load-bearing, not
        arbitrary). `owner`/`group` may each independently be a literal
        numeric uid/gid string, OR a name resolved against
        `nixid.posix.identities`/`nixid.posix.groups` -- see those two
        options' own descriptions for exactly how each is looked up
        (checked by assertion, not left to fail as a raw missing-attribute
        trace).
      '';
      type = types.attrsOf (types.submodule {
        options = {
          owner = mkOption {
            type = types.str;
            example = "3000";
            description = ''
              A literal numeric uid (as a string, e.g. `"3000"`), or a name
              found in `nixid.posix.identities.<name>.uid`. No default --
              every declared root needs an explicit, deliberate owner;
              silently defaulting one is exactly how a fresh tree ends up
              owned by whatever happened to be running when it was first
              created.
            '';
          };

          group = mkOption {
            type = types.str;
            example = "3000";
            description = ''
              A literal numeric gid (as a string), a name found in
              `nixid.posix.groups.<name>` (a shared group, independent of
              any one identity), or a name found in
              `nixid.posix.identities.<name>` (that identity's own resolved
              gid -- a User Private Group unless it overrides `gid`). No
              default, same reasoning as `owner`.
            '';
          };

          mode = mkOption {
            type = types.strMatching "^[0-7]{4}$";
            example = "2750";
            description = ''
              The tree root's mode, always as the full 4-digit octal form
              (setuid/setgid/sticky digit included even when it's `0`, e.g.
              `"0755"`) -- written out explicitly rather than a 3-digit
              form so every declared root visibly states whether it carries
              a special bit, instead of a reader having to know that a
              missing 4th digit means zero. Applied to the TOP DIRECTORY
              ONLY, never recursively -- see reconcile.sh's own
              `do_chmod_topdir` for why a recursive chmod would be actively
              wrong here (it would make every plain file underneath setgid
              and group-executable too), not just expensive.

              If `nixstorage.shape.datasets."<dataset-name-for-this-path>"`
              (see that module for the exact key translation) sets
              `subtreeMountable = true`, the o+x ("others" traverse) bit is
              forced into the EFFECTIVE mode actually written, regardless
              of what is typed here -- this field always reflects your
              intent, the reconciler is the one that adds the one bit a
              traversable subtree structurally requires.
            '';
          };

          recurse = mkOption {
            type = types.bool;
            example = true;
            description = ''
              `true`: this is a genuine content tree (a human's home
              directory, a media library) -- the owner's uid/gid must reach
              every file underneath it, because the uid that actually needs
              fixing lives in the CONTENT, not just the top directory.
              `false`: this is a container/parent directory whose own
              children are entirely owned by `leaves` below (e.g. an
              `/appdata` parent holding many independently-owned app
              directories) -- only the top directory itself is chowned/
              chmodded, never descended into. No default: every root needs
              an explicit, considered answer, because getting this backwards
              either recursively chowns thousands of files that belong to
              other identities (true when it should be false) or leaves an
              entire content tree's real files mis-owned forever (false
              when it should be true).
            '';
          };

          reconcile = mkOption {
            type = types.bool;
            default = true;
            description = ''
              `false`: this root is declared -- visible to the model, still
              checked by every structural assertion above -- but this pass
              must never chown or chmod it, because something else already
              owns its data's ownership lifecycle (a different, already-
              running system sharing this registry's numbering scheme; a
              human-managed exception). Automatically added to the
              aggregate prune set (see `prune` below) so that an ANCESTOR
              root's own recursive sweep does not silently "fix" this
              carve-out's ownership right back out from under whatever
              legitimately owns it.

              If `owner` names an identity, that identity's own
              `nixid.posix.identities.<name>.reconcile` flag is ALSO
              consulted, and the more restrictive of the two always wins --
              you cannot force-enable reconciliation here against an
              identity that has declared itself off limits.
            '';
          };
        };
      });
    };

    leaves = mkOption {
      default = { };
      description = ''
        App leaves, keyed by absolute filesystem path (asserted). Each
        leaf is swept to ONE identity, AFTER every declared root (so a
        leaf nested inside a recursing root's tree is re-won back to its
        own owner instead of being left at the tree owner from the roots
        pass), and, among leaves, SHALLOW paths before DEEP ones -- so a
        leaf nested inside ANOTHER declared leaf ends up owned by the
        more specific, innermost declaration, not the outer one.

        Deliberately no `owner`/`group`/`uid`/`gid` fields at all: a
        leaf's numbers are ALWAYS looked up from `identity`, never
        restated here. That is what makes the on-disk-uid vs
        k8s-runAsUser/PUID invariant this module asserts for every leaf
        checkable in the first place -- a leaf that could restate its own
        uid independent of the identity registry could restate a WRONG
        one, silently, with nothing left to check it against.
      '';
      type = types.attrsOf (types.submodule {
        options = {
          identity = mkOption {
            type = types.str;
            example = "myapp";
            description = ''
              Name in `nixid.posix.identities`. This leaf's on-disk uid/gid
              ARE that identity's `uid`/resolved `gid`, full stop -- see
              this option group's own header for why there is no
              literal-number escape hatch here (there is one on
              `ownership.<path>.owner`/`.group`, deliberately, because a
              tree root's owner is often a human account with no
              Kubernetes workload behind it at all; an app leaf, by
              definition, always has exactly the identity that owns it).

              Whether this pass is actually allowed to touch this leaf's
              ownership is controlled entirely by
              `nixid.posix.identities.<name>.reconcile` -- there is no
              separate per-leaf override; see that option's own
              description in nixid for the two real shapes it covers.
            '';
          };

          mode = mkOption {
            type = types.strMatching "^[0-7]{4}$";
            example = "2770";
            description = ''
              Same 4-digit, top-directory-only mode as
              `ownership.<path>.mode` above -- see that option's own
              description for the full reasoning, all of which applies
              identically here.
            '';
          };
        };
      });
    };

    prune = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/tank/media/archive-drive-a" ];
      description = ''
        Extra absolute paths (asserted) that no recursive pass -- neither
        `ownership`'s root sweep nor `leaves`' own sweep -- may ever
        descend beneath, merged with two other sources this module
        computes automatically: every
        `nixstorage.shape.datasets.<name>.prune = true` dataset (see that
        option's own description for the write-once/drive-managed-media
        safety story it exists for), and every declared root/leaf whose
        EFFECTIVE `reconcile` resolves to false (see `ownership.<path>.
        reconcile` and `leaves.<path>.identity`'s own descriptions for
        why that composition is load-bearing, not optional). Set this
        directly only for a path that needs pruning for a reason neither
        of those two sources already covers.
      '';
    };

    onCalendar = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "hourly";
      description = ''
        systemd `OnCalendar=` for a recurring `nixstorage-reconcile.timer`.
        `null` (default): no timer at all -- reconciliation only ever runs
        when invoked by hand (`nixstorage-reconcile`, installed into
        `environment.systemPackages` whenever `enable` is true) or via
        `systemctl start nixstorage-reconcile.service`. Deliberately no
        guessed default cadence: how often real `chown`/`chmod` calls are
        allowed to run unattended against real data is an operational
        decision for whoever owns that data, not a value this module
        should silently pick for you.
      '';
    };
  };

  # `mkMerge`, NOT `//`, to combine the unconditional part with the
  # `mkIf cfg.enable` part. `//` is a plain Nix attrset union: it merges
  # `mkIf`'s own internal representation (`{ _type = "if"; condition; content;
  # }`) as flat SIBLING keys alongside `assertions` instead of leaving it as
  # a single recognizable marker value. Verified the hard way, against this
  # exact module, with `lib.evalModules`: a `config = { assertions = …; } //
  # mkIf cfg.enable { … };` shape evaluates WITHOUT ERROR (nothing in the
  # module system rejects it) and even applies the `mkIf`-wrapped
  # `environment`/`systemd` values correctly -- but silently discards this
  # module's ENTIRE `assertions` list in the process, because the merge
  # machinery sees the resulting attrset's `_type = "if"` field, decides the
  # WHOLE returned value is one `mkIf` marker, and keeps only its
  # `condition`/`content` -- the `assertions` key sitting next to them is not
  # part of that shape and is dropped without a trace, no error, no warning.
  # This is exactly the class of failure this family's own house rule
  # ("assertions over documentation wherever a mistake is machine-detectable")
  # exists to prevent, so getting the ONE THING that makes assertions
  # actually reach the evaluator silently wrong would be the least excusable
  # bug this file could ship with. `mkMerge` walks a LIST of config
  # fragments and knows how to combine `mkIf`-wrapped entries against plain
  # ones correctly, which is what every other module in this family already
  # relies on it for.
  config = mkMerge [
    {
      # Unconditional -- NOT gated behind `cfg.enable`, matching shape.nix's
      # and delivery.nix's own always-on assertions. A bad declaration (a
      # typo'd identity name, a self-pruned active leaf, two roles claiming
      # the same path) is exactly as real a mistake whether or not the timer
      # that would eventually act on it is currently enabled -- catching it
      # should never depend on that flag.
      assertions =
        absolutePathAssertions
        ++ identityExistenceAssertions
        ++ leafInvariantAssertions
        ++ ancestorTraversalAssertions
        ++ duplicatePathAssertions
        ++ pruneOverlapAssertions;
    }
    (mkIf cfg.enable {
      environment.etc."nixstorage/reconcile.json".source = configFile;

      # The manual-invocation entry point: `nixstorage-reconcile` (optionally
      # `--dry-run`) from any interactive shell, independent of the timer.
      environment.systemPackages = [ cfg.package ];

      systemd.services.nixstorage-reconcile = {
        description = "Converge on-disk ownership/mode to nixstorage's declared model";
        # No sandboxing directives (ProtectSystem, ProtectHome, DynamicUser,
        # ...) -- deliberately, same reasoning nixshare's own watchdog.service
        # documents for itself: this unit's entire job is `chown`/`chmod`
        # against real, arbitrary filesystem trees the operator declared,
        # which is exactly the access any hardening profile here would exist
        # to take away. Runs as root (systemd's default with no `User=` set).
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${cfg.package}/bin/nixstorage-reconcile" + optionalString cfg.dryRun " --dry-run";
        };
        # jq is the one binary this script needs that a bare NixOS host does
        # not already guarantee in a systemd unit's PATH (unlike chown/chmod/
        # find/xargs/stat, which come from coreutils/findutils and are part
        # of `environment.systemPackages`'s own closure on essentially every
        # real system already) -- `path` is the idiomatic NixOS way to widen
        # a single unit's PATH without touching the host's own.
        path = [ pkgs.jq pkgs.coreutils pkgs.findutils ];
      };

      systemd.timers.nixstorage-reconcile = mkIf (cfg.onCalendar != null) {
        description = "Periodic trigger for nixstorage-reconcile.service";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.onCalendar;
          Persistent = true;
          # Spreads out an identical OnCalendar value shared across many
          # hosts -- avoids every host's chown/chmod pass
          # landing on the same wall-clock tick against a shared backing pool.
          RandomizedDelaySec = "5m";
        };
      };
    })
  ];
}
