# modules/shape.nix
#
# The SHAPE half of nixstorage: `options.nixstorage.shape` declares, for a
# handful of dataset CLASSES, what ZFS properties every dataset of that
# class should converge to, and then assigns real datasets to those
# classes. THIS FILE is schema and validation only -- there is no service
# here, no systemd unit, nothing "enabled" in modules/shape.nix itself.
#
# That claim is deliberately scoped to this one file, and the scope is
# worth stating in so many words rather than leaving it to be inferred:
# nixstorage AS A REPO is not entirely inert. modules/reconciler.nix ships
# a real systemd oneshot (+ optional timer) that runs actual `chown`/
# `chmod` against live paths, and modules/layout.nix ships a real, if
# strictly read-only, verify pass that reads a live block device. Neither
# fact contradicts what this file says about ITSELF -- both live in their
# OWN file, behind their OWN `enable`, and neither one folds "is this in
# the model" (schema -- what THIS file is) together with "does something
# act on it" (a service -- what a DIFFERENT file is) inside one option
# surface. See the repo root README's "The modules" section for the full
# split.
#
# A reconciler consuming THIS module's own data (recordsize/compression) --
# running the actual `zfs set` calls -- would be a separate module again,
# following the identical pattern, and it does not exist yet: see the
# README's own Status section for the honest gap. modules/reconciler.nix's
# shipped reconciler converges ownership and top-directory mode only, never
# `zfs set`. This file exists so that a future shape-reconciler, whenever
# it lands, and every human reading the config in the meantime, has exactly
# one place to look up what a dataset is supposed to look like.
#
# INVARIANT, load-bearing for anything that consumes `nixstorage.shape.*`,
# and already upheld by every acting module this repo ships today -- not
# merely promised here for one that doesn't exist yet: convergence may set
# properties on an EXISTING dataset. It must NEVER destroy or (re)create
# one. A dataset that should exist but doesn't is a provisioning problem
# for a human or a different tool to solve; treating an absent dataset as
# "just create it" from inside a property-convergence pass is how a typo in
# this file turns into data loss instead of a loud, obvious eval-time or
# run-time error. modules/reconciler.nix's own reconcile.sh already honours
# this today, in code, not just in theory -- it refuses to act on a
# declared root or leaf that is absent on disk (`[ ! -d "$path" ]` -> skip,
# logged, never created) rather than provisioning one on the spot.
#
# If your reconciler needs to create datasets -- or, one layer further
# down, needs to partition and format the media a dataset will eventually
# live on at all -- that is a SECOND, explicitly separate, explicitly gated
# operation, never a side effect of running the same pass that also sets
# recordsize/compression. `modules/layout.nix` (how media are CARVED --
# partition tables, sizes, roles) is exactly that second operation for the
# provisioning half of this story, and it keeps its own, sharper safety
# model on top of the same principle: see that file's own header for why
# it never touches a block device at all, only ever a plain file.
#
# Why classes exist at all, and why getting one wrong is expensive:
# `recordsize` is the single biggest ZFS tuning knob for anything that
# isn't the 128K default, and it has a property most people don't expect
# on first contact: IT APPLIES TO NEWLY WRITTEN BLOCKS ONLY. Changing
# `recordsize` on a dataset that already holds data does not resize
# anything already on disk -- every existing file keeps whatever block
# size it was written with, forever, until that file is rewritten (a
# fresh write, or a full copy / `zfs send | zfs recv` into a new dataset).
# There is no in-place "reformat" for this. So the class map isn't a nice-
# to-have default -- it's the only lever that's cheap to pull BEFORE data
# lands, and one of the most expensive things to fix AFTER: a 2 TiB media
# tree written at the wrong recordsize is only fixable by rewriting 2 TiB.
#
# Matching recordsize to the workload, not to a single house default:
#   - Large, mostly-whole-file media (video, disk images, VM/container
#     layer blobs, ML model weights): a LARGE recordsize (1M-16M). These
#     files are read back sequentially and close to in full; a large
#     record means one big contiguous read request and one entry in the
#     block-pointer tree per many megabytes of data, instead of thousands
#     of small ones. Getting this wrong the "safe-sounding" way (leaving
#     the small default) doesn't corrupt anything -- it just quietly
#     multiplies metadata overhead and seek count on every read, forever.
#   - Database engines (an embedded KV store, a relational engine's own
#     data files): a SMALL recordsize matching the engine's own page size
#     (commonly 8K-32K; check your engine's docs, don't guess). A
#     database issues small, randomly-located reads and writes at its own
#     page granularity. A recordsize larger than that page forces ZFS's
#     copy-on-write to read-modify-write the WHOLE oversized record for
#     every small write the database makes -- write amplification that
#     scales with how wrong the mismatch is, not a rounding error.
#   - A general-purpose / mixed-content source tree (source code,
#     configuration, a home directory, anything without one dominant
#     access pattern): ZFS's own 128K default. Not a placeholder for "we
#     didn't think about this one" -- 128K is a genuinely reasonable,
#     measured default for mixed workloads, and a class that just restates
#     it exists so that "yes, this was a deliberate choice" is visible
#     next to the classes that deviate from it for a documented reason.
#
# `compression` is comparatively low-stakes by comparison (algorithm
# choice does not have recordsize's write-once-forever property -- ZFS
# quietly compresses new writes with whatever the CURRENT property says
# and nothing more dramatic than "old blocks compressed with the old
# algorithm/level" happens if you change it), but it lives in the same
# class map because it's the other property every dataset needs an
# opinion on, and the two are usually decided together per workload (e.g.
# already-compressed media wants a cheap algorithm since further gains
# are unlikely and CPU is the only thing spent chasing them; WAN-bound
# writes can afford an expensive algorithm because the CPU cost is free
# next to the network cost it avoids).

{ lib, config, ... }:

with lib;

let
  cfg = config.nixstorage.shape;

  classNames = attrNames cfg.classes;
  datasetNames = attrNames cfg.datasets;

  # A dataset's declared ancestors: every OTHER dataset name in THIS SAME
  # map that is a path-prefix of it. Deliberately does not (and cannot)
  # reason about a pool root or any intermediate directory this module
  # was never told about -- shape.nix only knows what is declared here,
  # and asserting about a level it has no visibility into would be a
  # check that LOOKS load-bearing but silently isn't (see
  # `subtreeMountable`'s own description for why an undeclared ancestor
  # is a real, separate risk this cannot close).
  ancestorsOf = name: filter (a: a != name && hasPrefix "${a}/" name) datasetNames;

  classAssertions = concatMap
    (name:
      let d = cfg.datasets.${name};
      in optional (d.class != null && !(elem d.class classNames)) {
        assertion = false;
        message = ''
          nixstorage.shape.datasets."${name}".class is set to "${d.class}",
          but nixstorage.shape.classes has no such class declared.
          Declared classes: ${
            if classNames == [ ] then "(none)" else concatStringsSep ", " classNames
          }.
          Either add a `classes."${d.class}"` entry, or fix the typo -- an
          unrecognized class name here is a silent no-op for whatever
          reconciler reads this data unless something checks it, which is
          exactly what this assertion is for.
        '';
      })
    datasetNames;

  # See `subtreeMountable` below for the full traversability story this
  # closes. Only fires for a dataset THIS MODULE can see is missing
  # coverage -- an ancestor outside the declared map (a bare pool
  # mountpoint above every dataset this file knows about, for instance)
  # is out of scope by construction and stays a documented caveat, not a
  # false sense of completeness.
  subtreeAssertions = concatMap
    (name:
      let d = cfg.datasets.${name};
      in optionals d.subtreeMountable
        (map
          (a: {
            assertion = cfg.datasets.${a}.subtreeMountable;
            message = ''
              nixstorage.shape.datasets."${name}".subtreeMountable = true,
              but its declared ancestor "${a}" does not also set
              subtreeMountable = true. A non-traversable ancestor makes the
              child's own o+x bit meaningless -- an NFS client (or anything
              else walking the path component by component) never reaches
              "${name}" at all, because it dies at "${a}" first. Set
              subtreeMountable = true on every declared ancestor in this
              chain, or set it to false here and accept that "${name}"
              cannot be mounted/traversed independently of its parent.
            '';
          })
          (ancestorsOf name))
    )
    datasetNames;

  classModule = { ... }: {
    options = {
      recordsize = mkOption {
        type = types.str;
        example = "128K";
        description = ''
          ZFS `recordsize` for every dataset assigned this class. See this
          module's header for why this is the single highest-stakes
          property here: it applies to newly written blocks only, so
          picking it AFTER a dataset already holds data means living with
          the wrong choice until every existing file is rewritten. Pick it
          from the workload the dataset actually holds, not from habit --
          large for big sequentially-read files, small (matching the
          engine's own page size) for a database, the ZFS default (128K)
          for anything mixed or undecided.
        '';
      };

      compression = mkOption {
        type = types.str;
        example = "zstd";
        description = ''
          ZFS `compression` for every dataset assigned this class. Lower
          stakes than `recordsize` (changing it later only affects blocks
          written from that point on -- nothing needs a rewrite to become
          "correct"), but decided per-class for the same reason:
          already-compressed media gains little from more CPU spent
          trying, while a WAN-bound write path can spend CPU it has for
          free to buy pool space it doesn't.
        '';
      };

      properties = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = { acltype = "posixacl"; atime = "off"; };
        description = ''
          Any other ZFS-settable property for this class, applied the same
          way `recordsize`/`compression` are: as a plain `zfs set
          <property>=<value>` per property, per dataset. Free-form on
          purpose -- ZFS's property surface is large (`acltype`, `exec`,
          `sync`, `atime`, `xattr`, ...) and growing a typed option for
          each one here would just be re-deriving `zfs set`'s own argument
          list one field at a time. Values are plain strings regardless of
          the property's own underlying type, because that's what `zfs
          set` itself takes on the command line -- this option performs no
          type coercion or validation beyond that.
        '';
      };
    };
  };

  datasetModule = { ... }: {
    options = {
      class = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Which `classes.<name>` this dataset converges to. Must name an
          already-declared class (asserted below) -- a typo here is a
          silent no-op for anything that isn't checking, not a loud
          failure, which is exactly the failure mode the assertion exists
          to close.

          `null` is legitimate, not just "not filled in yet": it marks a
          dataset that this module still needs to know ABOUT (so
          `children`/`prune`/`subtreeMountable` below can apply to it) but
          whose own recordsize/compression convergence is intentionally
          out of scope here -- either because its properties are owned by
          a different, out-of-band process (a specialized tuning pass this
          reconciler must never fight with), or because it exists purely
          as a structural node whose only job is carrying `children`
          semantics down to the real classed datasets beneath it.
        '';
      };

      children = mkOption {
        type = types.enum [ "reconcile" "inherit" "ignore" ];
        default = "ignore";
        description = ''
          What convergence does below this dataset:

          - `"reconcile"`: descend recursively and re-apply this dataset's
            own class properties to every child dataset underneath, every
            run. Use this for a tree that legitimately holds many child
            datasets that should all agree with the parent's shape.
          - `"inherit"`: set this dataset's own properties once, but do
            not descend -- children are left to ZFS's own native property
            inheritance (a child with no `local` override picks up
            whatever its nearest ancestor sets; a child that DOES have its
            own local override keeps it). Use this when a class boundary
            genuinely doesn't need per-child chasing.
          - `"ignore"`: never descend from this dataset at all, not even
            to check inheritance. Use this for a subtree that is either
            fully unmanaged from this module's point of view, or deep and
            large enough that walking it on every run would be pure cost
            for no benefit.

          ⚠ Nix attribute sets carry no guaranteed key order, and this
          option does not impose one. If a reconciler needs deterministic
          sweep order (for instance, to let a more specific descendant's
          own `"reconcile"` pass intentionally re-win a subtree after a
          broader ancestor's sweep already touched it), that ordering has
          to be computed by the reconciler itself -- typically by sorting
          declared dataset names -- never assumed from how they happen to
          be written in this file.
        '';
      };

      prune = mkOption {
        type = types.bool;
        default = false;
        description = ''
          When true: no recursive pass -- not `children = "reconcile"`'s
          per-child convergence, not any other bulk, tree-walking
          operation a reconciler might run -- may ever descend beneath
          this dataset. Default false.

          This is a SAFETY mechanism, not a performance optimization, and
          the distinction matters for when to reach for it. A plain `zfs
          set` is metadata-only and safe to run against live data on
          ordinary storage. It stops being safe the moment a dataset sits
          on backing media that is damaged by rewrite-in-place or
          random-write patterns in the first place -- some archival media
          (a drive-managed SMR disk pressed into service as a single
          write-once, mostly-append filesystem, rather than genuine
          random-access storage) measurably wears down under exactly the
          access pattern a recursive convergence or bulk-ownership pass
          produces. `prune` exists so that kind of tree can be declared
          here at all (visible to the rest of the model, holding a class
          for documentation purposes) while making it structurally
          impossible for an automated sweep to ever walk into it -- the
          decision of when and how deep to touch it stays a deliberate,
          human one.
        '';
      };

      subtreeMountable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Forces the "others may traverse" bit (o+x) into the effective
          mode this dataset's ownership/rights declaration ends up with,
          and asserts (below) that every declared ancestor of this dataset
          in `nixstorage.shape.datasets` sets this to true as well.
          Ownership itself -- uid/gid/the rest of the mode bits -- is
          deliberately out of this module's scope (see the repo README
          for the dependency direction: this half of nixstorage never
          computes a mode value on its own); this flag only reaches into
          whatever mode a dataset ends up with and guarantees one specific
          bit survives.

          Why this specific bit, and why it needs its own option instead
          of just "pick a more open mode": measured directly against a
          real NFS export. NFS exports are commonly configured
          `root_squash`, which means an NFS client mount walks the
          server-side path AS `nobody`, not as whatever uid owns the
          share. A tree root with no o+x for others (mode `2750`, i.e.
          `drwxr-s---`) makes that walk fail at the root -- `mount
          server:/tree/child` returns "access denied by server" for EVERY
          child, regardless of that child's own mode, because the walk
          never gets past the parent. This was reproduced directly: the
          same failure occurred with and without an unrelated mount
          option under test, proving the option was never the cause, the
          traversal was; the same mount against a sibling tree at mode
          `2775` (already world-traversable) succeeded immediately, and
          went on to prove the actual goal -- two children of the SAME
          parent mounted independently, at the same time, carrying
          DIFFERENT mount options from each other. That independence is
          only possible because each child gets its own mount at all: a
          `crossmnt`-synthesized child mount inherits its parent
          superblock's options wholesale, so giving a subtree its own
          cache policy, its own timeout tuning, anything -- requires
          mounting it separately, which requires the walk to it surviving
          in the first place.

          The fix costs exactly one bit: `2750` -> `2751`. Setting o+x
          grants TRAVERSE only, not LIST -- others can walk THROUGH a
          directory whose name they already know, they still cannot
          enumerate its contents with a plain directory listing, and
          every child underneath still enforces its own mode independent
          of this one. That is also why the ancestor-chain assertion below
          is not optional decoration: a non-traversable grandparent breaks
          the guarantee exactly as completely as a non-traversable direct
          parent does, just less obviously, since the mistake can sit two
          or three levels above the dataset someone is actually trying to
          mount.

          ⚠ This assertion only sees ancestors that are THEMSELVES declared
          in `nixstorage.shape.datasets`. A pool's own bare mountpoint, or
          any other directory above your declared tree that this module
          was never told about, is outside what this check can verify --
          confirm those stay traversable by hand.
        '';
      };
    };
  };

in
{
  options.nixstorage.shape = {
    classes = mkOption {
      type = types.attrsOf (types.submodule classModule);
      default = { };
      description = ''
        Named dataset classes: the recordsize/compression/extra-property
        bundle a dataset converges to by naming this class from
        `datasets.<name>.class`. See this module's header comment for the
        full reasoning behind why recordsize in particular is worth a
        deliberate class rather than a per-dataset ad hoc value.
      '';
    };

    datasets = mkOption {
      type = types.attrsOf (types.submodule datasetModule);
      default = { };
      description = ''
        Real ZFS datasets, keyed by their full dataset path (e.g.
        `"tank/media"`, `"tank/apps/data"`) exactly as `zfs list` would
        show it -- this is also how ancestor relationships are computed
        for `subtreeMountable`'s assertion (`"tank/apps"` is an ancestor
        of `"tank/apps/data"` because the latter's path is prefixed by the
        former's, nothing fancier). Each entry says which class it
        belongs to and how convergence should treat it; see `class`,
        `children`, `prune`, and `subtreeMountable` above.
      '';
    };
  };

  config = {
    assertions = classAssertions ++ subtreeAssertions;
  };
}
