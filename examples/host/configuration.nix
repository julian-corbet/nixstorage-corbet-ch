# The smallest NixOS configuration that composes nixstorage's own four
# implemented modules together with nixiam's posix identity module, used by the
# `modules-evaluate` check.
#
# This is not a machine anyone would run: the pool is called "tank", the
# domain is example.org, and the root filesystem is tmpfs. Every real,
# already-implemented option in modules/shape.nix, modules/delivery.nix,
# modules/reconciler.nix, and modules/layout.nix gets exercised at least
# once here, including the ones that are easy to get backwards --
# `subtreeMountable`'s ancestor-chain requirement (checked TWICE,
# independently, by shape.nix's own boolean-consistency assertion and
# reconciler.nix's mode-VALUE assertion — see reconciler.nix's own comment
# for why one does not make the other redundant), `prune` excluding one
# child from every bulk walk (shape's own recordsize/compression sweep AND
# the ownership reconciler's chown walk, both), the `reconcile = false`
# carve-out, and layout's own "only the last partition may consume the
# remainder" rule.
#
# `nixiam.posix.*` below is VERIFIED against the shipped module, not
# anticipated: this example composes with nixiam's posix module through
# `lib.nixosSystem`, `system.build.toplevel` resolves, and every assertion
# the composed config produces evaluates true. The contract
# `modules/reconciler.nix` depends on -- `nixiam.posix.identities.<name> =
# { uid; gid; variant; reconcile; }` plus the derived, read-only
# `nixiam.posix.podSecurity.<name>` -- matches what nixiam actually declares,
# including the native-vs-puid branch.
{ ... }:
{
  # ── SHAPE: dataset classes -------------------------------------------
  # Reconciler-tunable properties only (recordsize/compression, plus any
  # other ZFS property via `properties`) -- see modules/shape.nix's header
  # for why recordsize specifically is the one worth a deliberate class
  # rather than a per-dataset ad hoc value: it applies to newly written
  # blocks only, so getting it wrong is cheap to prevent and expensive
  # (a full rewrite) to fix after the fact.
  nixstorage.shape.classes = {
    media = {
      # Large, mostly-whole-file, already-compressed content: one big
      # contiguous read per file instead of thousands of small ones.
      recordsize = "16M";
      compression = "zstd";
    };

    appdata = {
      # General-purpose application state with no one dominant access
      # pattern -- a deliberate restatement of ZFS's own 128K-class
      # instinct at a slightly larger size for mixed blob/config content.
      recordsize = "32K";
      compression = "zstd";
    };

    weights = {
      # Incompressible ML model weights: a large recordsize for the same
      # sequential-whole-file reason as `media`, but `lz4` instead of
      # `zstd` -- spending more CPU chasing compression on data that does
      # not compress buys nothing.
      recordsize = "16M";
      compression = "lz4";
    };

    database = {
      # Small recordsize matching a typical embedded/relational engine's
      # own page size -- a larger record would force ZFS's copy-on-write
      # to read-modify-write the whole oversized record on every small
      # write the engine makes. `properties` demonstrates the free-form
      # escape hatch for anything beyond recordsize/compression.
      recordsize = "16K";
      compression = "zstd";
      properties = {
        atime = "off"; # a database never needs its own read timestamped
      };
    };
  };

  # ── SHAPE: dataset declarations ---------------------------------------
  nixstorage.shape.datasets = {
    # World-traversable so an NFS root_squash client's walk survives past
    # this root, AND a subtree one level down declares the same bit --
    # proving the ancestor-chain assertion rather than only the leaf.
    # `children = "reconcile"` re-applies this class recursively; without
    # it, an undeclared grandchild dataset would just inherit ZFS's
    # native property inheritance instead (see `children`'s own
    # description in modules/shape.nix for the third option, "ignore").
    "tank/media" = {
      class = "media";
      children = "reconcile";
      subtreeMountable = true;
    };
    "tank/media/movies" = {
      class = "media";
      # Dropping `subtreeMountable` here, even though the parent sets it,
      # would make the PARENT's promise a lie for exactly this subtree: an
      # NFS client's walk reaches "tank/media" fine, then dies here. That
      # is precisely what the ancestor-chain assertion (checked here at
      # the boolean level by shape.nix, and again at the actual MODE-VALUE
      # level by reconciler.nix below, since this path is ALSO declared as
      # its own `nixstorage.reconciler.ownership` root) exists to catch.
      subtreeMountable = true;
    };

    # A general application tree that legitimately holds many child
    # datasets which should all agree with its own shape.
    "tank/library" = {
      class = "appdata";
      children = "reconcile";
    };

    # PRUNED: excluded from EVERY bulk, tree-walking operation any
    # reconciler in this repo runs beneath "tank/library" -- not just a
    # future recordsize/compression sweep, but (see
    # `nixstorage.reconciler.prune` below, which folds this flag in
    # automatically) TODAY's real ownership `chown -R` walk too. This is
    # the generalised form of a real incident: a large, already-correctly-
    # blocked tree nested under an otherwise-recursive parent must never
    # be reachable by that parent's bulk pass, whether the pass in
    # question tunes ZFS properties or fixes ownership -- both are exactly
    # the access pattern this flag exists to make structurally impossible.
    # A pruned dataset may NOT also be separately declared as its own
    # active reconciler root/leaf (asserted by reconciler.nix's own
    # `pruneOverlapAssertions`) -- prune means genuinely hands-off, not
    # "reconciled independently instead of inherited".
    "tank/library/models" = {
      class = "weights";
      prune = true;
    };

    # The "documented, not converged" carve-out on the SHAPE side: a
    # database tree whose own recordsize/compression is tuned by an
    # out-of-band database-normalization process, never by this
    # reconciler. `class = null` is exactly modules/shape.nix's own answer
    # for this -- NOT omitting the dataset from the map entirely, which
    # would make it invisible to every OTHER dataset's ancestor-chain /
    # prune checks. Its RIGHTS-side counterpart is
    # `nixiam.posix.identities.example-db.reconcile = false` below --
    # deliberately the same carve-out concept, one layer over.
    "tank/apps/dbs" = {
      class = null;
      children = "ignore";
    };

    "tank/apps/data" = {
      class = "appdata";
      children = "reconcile";
    };
  };

  # ── DELIVERY: where a dataset surfaces under $HOME ---------------------
  # Deliberately decoupled from `nixstorage.shape.datasets` above -- a
  # category names a host PATH, not a dataset key (see modules/delivery.nix's
  # header for why: nothing here stops `source` from pointing at a declared
  # dataset's own mountpoint, but nothing requires it either).
  nixstorage.delivery.categories = {
    # mount = "zfs": a host that already has the pool imported delivers
    # this by mounting/binding the dataset at `source` directly, locally
    # -- SHAPE's own convergence is the whole story for this one.
    media = {
      source = "/tank/media";
      home = "media";
      xdg = "VIDEOS";
      scope = [ "common" ];
      mount = "zfs";
    };

    # mount = "nfs": this host reaches `source` over the network instead
    # -- exporting it, if this host IS the storage host, or mounting it
    # (e.g. via nixshare) if it isn't. Which side a given host plays is
    # not encoded here; it follows from whether that host owns the pool.
    exchange = {
      source = "/tank/transfer";
      home = "transfer";
      xdg = "DOWNLOAD";
      # The download role is fulfilled by a SUBDIRECTORY of this shared
      # exchange tree, not by the category's own root -- see
      # modules/delivery.nix's `xdgSubdirectory` for why this exists
      # instead of giving downloads its own top-level category.
      xdgSubdirectory = "downloads";
      scope = [ "common" ];
      mount = "nfs";
    };

    # mount = "none": declared (a reserved home/xdg role, visible to the
    # model) but not actually delivered on THIS host today -- distinct
    # from leaving "workstation" out of `scope` entirely, which would say
    # this category isn't even meant for that class of consumer at all.
    archive = {
      source = "/tank/archive";
      home = "archive";
      scope = [ "workstation" ];
      mount = "none";
    };
  };

  # ── RECONCILER: ownership + top-directory mode -------------------------
  # `owner`/`group` (roots) and `identity` (leaves) are all NAME
  # references resolved against `nixiam.posix.identities`/`.groups` below,
  # never a raw uid/gid restated here -- see this repo's README, "Why
  # nixstorage depends on nixiam, and never the reverse".
  nixstorage.reconciler = {
    enable = true;
    onCalendar = "hourly";

    ownership = {
      # recurse = true: content underneath is swept to this owner too.
      "/tank/media" = {
        owner = "shared-media";
        group = "shared-media";
        mode = "2770"; # no bit for others -- subtreeMountable below forces o+x into the EFFECTIVE mode only, this declared value never changes
        recurse = true;
      };

      # Declared as its OWN root (not a leaf) specifically because
      # `subtreeMountable`'s mode-forcing only ever applies to
      # `nixstorage.reconciler.ownership` entries, never to `leaves` --
      # see reconciler.nix's own `effectiveModes`, computed over
      # `cfg.ownership` only. `recurse = false`: "tank/media"'s own
      # recurse=true sweep already reaches every file under this path;
      # this entry exists purely to force ITS OWN top-directory mode
      # (the o+x bit), not to re-walk content a sibling pass already
      # covers twice.
      "/tank/media/movies" = {
        owner = "shared-media";
        group = "shared-media";
        mode = "2770";
        recurse = false;
      };

      "/tank/library" = {
        owner = "agents-owner";
        group = "agents-owner";
        mode = "2750"; # no subtreeMountable dataset here -- stays fully closed
        recurse = true;
      };
    };

    leaves = {
      # No `owner`/`group`/`mode`-vs-`uid`/`gid` split to get wrong here --
      # a leaf's on-disk numbers ALWAYS come from `identity`, which is
      # exactly what makes the on-disk-uid vs k8s-securityContext
      # assertion below checkable at all.
      "/tank/apps/data" = { identity = "example-app"; mode = "0750"; };

      # The reconcile = false carve-out itself: declared so this identity
      # is visible end to end (a real uid, a real mode, checked by every
      # structural assertion), but never chowned or chmodded, because
      # `nixiam.posix.identities.example-db.reconcile = false` below is the
      # identity's OWN opinion that an external database-normalization
      # process already owns its lifecycle -- there is no separate
      # per-leaf override for this; the identity's flag is the only one
      # that governs a leaf.
      "/tank/apps/dbs" = { identity = "example-db"; mode = "0750"; };
    };
  };

  # nixiam's posix registry must be ENABLED, not merely populated. Its
  # assertions -- uid/gid collision detection, and the non-empty `domain`
  # check -- all sit behind `mkIf cfg.enable`, so an example that declares
  # identities without enabling the module gets the data and none of the
  # safety, which is precisely the wrong thing for an example to teach.
  nixiam.posix.enable = true;

  # The identity domain, shared by everything that maps names across a
  # boundary. Its first consumer is NFSv4 idmapd's `Domain=`: a client
  # whose domain does not match the server's falls back to its DNS domain,
  # and every ACL-touching syscall then pays a failed kernel upcall while
  # plain ownership keeps working -- which is exactly why it goes unnoticed.
  nixiam.posix.domain = "example.org";

  # ── LAYOUT: how media is CARVED -- partition tables, sizes, roles ------
  # A single small image with all three sanctioned roles: an ESP (the
  # only role that gets real filesystem content -- vfat, empty), a raw
  # slot (reserved, untouched -- would eventually hold, say, a ZFS pool
  # member this repo's own shape.nix has no opinion on because it isn't a
  # mountable dataset yet), and a trailing encrypted region consuming
  # whatever is left (reserved, never `cryptsetup luksFormat`-ed by this
  # repo -- see modules/layout.nix's own header for exactly why).
  nixstorage.layout.images.example-host-disk = {
    sizeMiB = 512;
    partitions = [
      {
        name = "ESP";
        role = "esp";
        sizeMiB = 256;
        espLabel = "EXAMPLEESP";
      }
      {
        name = "pool-member";
        role = "raw";
        sizeMiB = 128;
      }
      # The LAST partition in the list, and the only one allowed to leave
      # sizeMiB unset -- consumes whatever remains of the 512 MiB image
      # after the ESP and the raw slot above, minus GPT's own overhead.
      {
        name = "vault";
        role = "luks";
      }
    ];
  };

  # `nixstorage-layout-verify` never writes anything -- see this option's
  # own description and modules/layout.nix's header for the full safety
  # model. `device` is a placeholder /dev/disk/by-id path precisely
  # because a real one here would be exactly the kind of host-specific detail a
  # public repo must never carry; `nix flake check`'s own checks/
  # directory proves the verify SCRIPT itself actually works, against a
  # real built image, without ever touching a real device.
  nixstorage.layout.verify.enable = true;
  nixstorage.layout.verify.onCalendar = "daily";
  nixstorage.layout.verify.targets.example-host-disk = {
    device = "/dev/disk/by-id/example-host-disk-uuid";
    image = "example-host-disk";
  };

  # ── SCRUB: idle-/RAM-/temperature-gated integrity verification ---------
  # One job with a group (proving the group-declaration assertion passes)
  # and one ungrouped job (proving `group = null` never needs a
  # `nixstorage.scrub.groups` entry at all).
  nixstorage.scrub = {
    enable = true;
    idle.effectiveCores = 0.25; # a small/burstable example host
    groups.shared-controller = { };

    jobs = {
      archive = {
        fsType = "xfs";
        target = "/tank/archive";
        group = "shared-controller";
        priority = 10;
        minCycleDays = 30;
        tempDevices = [ "/dev/disk/by-id/example-archive-0" ];
      };

      root = {
        fsType = "btrfs";
        target = "/";
        priority = 20;
        minCycleDays = 30;
      };
    };
  };

  nixiam.posix.identities = {
    # Referenced only as a ROOT owner/group above (no leaf uses it) --
    # `gid` is left unset, defaulting to a User Private Group (== uid).
    shared-media = { uid = 3000; variant = "native"; reconcile = true; };
    agents-owner = { uid = 3001; variant = "native"; reconcile = true; };

    # variant = "puid": an s6-overlay/linuxserver.io-style image that
    # starts as root and drops privilege itself via PUID/PGID -- this
    # leaf's on-disk uid still comes from THIS identity, but the
    # Kubernetes side is checked against `podSecurity.example-app.env.PUID`
    # instead of `.pod.runAsUser` (see reconciler.nix's own
    # `leafInvariantAssertions` for exactly which pair applies to which
    # variant).
    example-app = { uid = 3002; variant = "puid"; reconcile = true; };

    # uid 26 mirrors a real, common convention (a database engine image's
    # own baked-in uid), which is exactly why it carries `encountered`:
    # nixiam's `identityRange` band (3000-3999) governs numbers WE hand
    # out, and one an upstream image baked in is not ours to move. Naming
    # the single identity as encountered is the route nixiam documents for
    # this; widening the band down to 26 would make it assert nothing about
    # the three identities above, which is the whole point of having it.
    #
    # variant = "native" here: this identity's own consistency is still
    # checked (see reconciler.nix's own comment: the invariant assertion
    # runs regardless of `reconcile`), even though `reconcile = false`
    # means none of it is ever actually chowned.
    example-db = {
      uid = 26;
      encountered = "the database engine's own image runs as 26 and chowns nothing at startup";
      variant = "native";
      reconcile = false;
    };
  };

  # ── Stubs NixOS demands of any bootable system ───────────────────────────
  # tmpfs on / could never boot a real machine, which is the point: this
  # config exists to type-check modules, not to describe hardware.
  fileSystems."/" = {
    device = "nodev";
    fsType = "tmpfs";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  networking.hostName = "example-node";
  system.stateVersion = "25.05";
}
