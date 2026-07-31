{
  description = "Declarative storage, as ONE layer between hosts and the consumers of data: the physical disk table every other module reads by name, pre-pool media layout (a GPT partition table -- sizes, sector size, roles -- built as a pure derivation emitting a plain FILE, plus a read-only drift check against live media), ZFS dataset shape (recordsize/compression convergence), and category-based delivery (source -> $HOME -> XDG -> scope), reconciled by one idempotent pass. Ownership -- uid/gid and its Kubernetes securityContext twin -- is deliberately NOT here; a dataset names its owner by a string key into nixiam instead.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixstorage answers "where and what shape"; nixiam answers "who". A
    # root's owner/group may be a literal numeric uid/gid, but an app
    # leaf's identity is ALWAYS a STRING KEY into
    # `nixiam.posix.identities.<name>`, never a raw uid/gid copied into
    # this repo -- so the on-disk owner and a workload's securityContext
    # can never independently drift (see README's "Why nixstorage depends
    # on nixiam, and never the reverse"). This dependency is permanently
    # one-way: nixiam must never learn a dataset name or a pool path. The
    # day it does, the layering this split exists to enforce has already
    # inverted.
    nixiam = {
      url = "github:julian-corbet/nixiam-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # A different CATEGORY of input from nixiam above, and the distinction matters because this
    # family's rule is "no flake input on a sibling". nixtest is a lib-only TEST FIXTURE -- no
    # NixOS module, no `enable`, nothing that acts on a host -- and is never composed into
    # anything this flake exports; it is reached only from `checks`.
    #
    # It is an input rather than a copy because the copy failed. checks/purity.nix used to carry a
    # hand-kept version of nixtest.lib.mkPurityChecks, and it quietly stopped matching: it never
    # gained the `factPaths` plain-data proof the original grew, so a derivation sitting in
    # nixstorage.disks would have passed silently while the check still reported success. One
    # recipe taken as a dependency cannot drift from itself the way three hand-kept copies did.
    nixtest = {
      url = "github:julian-corbet/nixtest-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # A third category again, distinct from both of the above: nixhost is a lib-only dependency
    # like nixtest (no NixOS module of ITS shape composed here either), but unlike nixtest it IS
    # reached from a real exported module, not only from `checks`. `reconciler.nix`'s own
    # `config.nixiam.posix.identities`/`.groups`/`.podSecurity` reads are exactly the cross-
    # namespace defensive-read defect class nixhost's `lib.probeFact`/`lib.collectProbes`
    # (`lib/facts.nix`) exists to fix -- a bare `config.nixfoo.bar or fallback` cannot tell
    # "nixfoo not composed here" from "nixfoo composed but `bar` moved/renamed/rejected", and the
    # second one is a real defect this exact shape already cost this family real weeks over
    # (`nixstorage.layout`, this repo's own README/Status records it). `probeFact`/`collectProbes`
    # are closed over as plain function arguments when `reconciler.nix` is exported below, never
    # `_module.args` -- the same partially-applied-before-the-module-system-sees-it pattern this
    # family already uses for `nixfsCatalogue` (see infra's own flake.nix comment on `mkNixnas` for
    # that precedent) -- so a consumer importing `nixosModules.reconciler` sees an ordinary module
    # function and never needs to know `probeFact` exists.
    nixhost = {
      url = "github:julian-corbet/nixhost-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixiam, nixtest, nixhost }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # ---------------------------------------------------------------
      # SIX independently toggleable modules under one `nixstorage.*`
      # namespace -- same shape as nixbackup's three (destinations/
      # autobootstrap/monitor). `shape`, `delivery` and `disks` are pure
      # schema + assertion, no systemd unit, nothing to "enable" -- import
      # any one on its own to get validated, machine-readable declarations
      # with zero runtime footprint. `reconciler`, `layout`, and `scrub`
      # are the three modules that actually act -- `reconciler` on
      # ownership and top-directory mode only (see README's Status for the
      # one open gap: nothing yet runs the `zfs set` half `shape.nix`'s
      # own model describes), `layout` on nothing but READING a live
      # device back (see modules/layout.nix's own header for the full
      # safety model -- it never writes to a block device, only ever to a
      # plain file it builds itself), and `scrub` on an idle-/RAM-/
      # temperature-gated btrfs/xfs/zfs scrub heartbeat (see
      # modules/scrub.nix's own header) -- hence `default` for the common
      # case of wanting all six.
      #
      # `layout` spent a while extracted out of here into a standalone
      # `nixlayout` repo, on the grounds that shape/delivery/reconciler all
      # presuppose an EXISTING dataset while `layout` runs BEFORE any pool
      # exists. THAT SPLIT IS REVERSED, and the merge is the current
      # design: "pre-pool vs post-pool" is a ZFS-SHAPED boundary, and under
      # LVM -- or hardware RAID presenting one opaque LUN, or plain
      # partitions, or any of the storage architectures a public module
      # family cannot enumerate in advance -- there is no equivalent line
      # in the same place. What survives every implementation is the LAYER,
      # which is what this repo is. See modules/layout.nix's own header for
      # the full argument, and for what the split cost while it lasted:
      # consumers reading `config.nixstorage.layout.images or { }` resolved
      # to `{ }` forever, silently, because a defensive read across an
      # option-path rename cannot fail loudly.
      # ---------------------------------------------------------------
      nixosModules.shape = ./modules/shape.nix;
      nixosModules.delivery = ./modules/delivery.nix;
      # `probeFact`/`collectProbes` closed over here, before the module system ever sees the
      # result -- see the nixhost input comment above. The exported value is a plain module
      # function taking the usual `{ lib, config, pkgs, options, ... }`; nothing about consuming
      # it changes.
      nixosModules.reconciler = import ./modules/reconciler.nix { inherit (nixhost.lib) probeFact collectProbes; };
      nixosModules.disks = ./modules/disks.nix;
      nixosModules.layout = ./modules/layout.nix;
      # nixstorage.scrub -- idle-/RAM-/temperature-gated btrfs/xfs/zfs scrub
      # scheduling (modules/scrub.nix). NixOS-only (see that module's own
      # SCOPE note) -- deliberately absent from systemManagerModules below,
      # unlike its five siblings.
      nixosModules.scrub = ./modules/scrub.nix;
      nixosModules.default = {
        imports = [
          self.nixosModules.shape
          self.nixosModules.delivery
          self.nixosModules.reconciler
          self.nixosModules.disks
          self.nixosModules.layout
          self.nixosModules.scrub
        ];
      };

      # Same five files, same schema, on system-manager's smaller option
      # surface. None of the five touches a NixOS-only primitive as
      # designed -- shape/delivery/disks are pure option declarations +
      # eval-time assertions, and both reconciler and layout.verify are
      # `systemd` oneshots + optional timers -- the same portability
      # argument nixshare's own client-side core makes for its watchdog.
      # UNCONFIRMED against a real system-manager-applied host (see
      # README's Non-goals); flagged rather than silently assumed, same
      # convention nixshare uses for its own equivalent caveat. `scrub` is
      # deliberately NOT among these five -- it drives systemd.timers plus a
      # generated heartbeat script against `/proc/loadavg`/`/proc/meminfo`
      # directly, with no system-manager equivalent attempted.
      #
      # `disks` was missing from this list entirely from the commit that
      # introduced modules/disks.nix (it reached nixosModules above, never
      # here) until this comment was written -- the exact kind of drift a
      # naming table is supposed to prevent elsewhere, caught here by
      # nothing more than rereading this file end to end.
      systemManagerModules.shape = ./modules/shape.nix;
      systemManagerModules.delivery = ./modules/delivery.nix;
      # Same closed-over `probeFact`/`collectProbes` as nixosModules.reconciler above -- one
      # `import`, reused on both backends (the module body itself is backend-agnostic).
      systemManagerModules.reconciler = self.nixosModules.reconciler;
      systemManagerModules.disks = ./modules/disks.nix;
      systemManagerModules.layout = ./modules/layout.nix;
      systemManagerModules.default = {
        imports = [
          self.systemManagerModules.shape
          self.systemManagerModules.delivery
          self.systemManagerModules.reconciler
          self.systemManagerModules.disks
          self.systemManagerModules.layout
        ];
      };

      # The partition-role catalogue, exposed so a consumer can inspect or
      # validate it without re-reading the file -- same reason nixfs
      # exposes `lib.catalogue`.
      lib.partitionRoles = import ./lib/partition-roles.nix { };

      # The image builder itself, exposed standalone for anyone who wants a
      # `nixstorage.layout.images.<name>`-shaped derivation without going
      # through the NixOS/system-manager module system at all -- e.g. a
      # plain `packages.<system>.<name>` output built straight from this
      # function. modules/layout.nix is the only consumer that matters
      # inside this repo; this export is for everyone else:
      #
      #   inputs.nixstorage.lib.buildLayoutImage { pkgs = ...; } {
      #     name = "example"; sizeMiB = 256; partitions = [ ... ];
      #   }
      lib.buildLayoutImage = { pkgs }: import ./lib/image.nix { inherit pkgs; };

      # All six of this repo's modules, PLUS nixiam's posix identity
      # module -- the one thing nixstorage can name an owner/identity
      # reference to but must never define itself -- composed into one
      # system from examples/host, PLUS a handful of standalone eval-tests
      # for the parts a single composed-host check cannot exercise (the
      # image builder actually building, the verify script actually
      # detecting drift). See checks/default.nix for all of it, the same
      # split nixfs/nixvault/nixboot already use in this family.
      #
      # ⚠ nixiam's own posix/identity module (`nixiam.posix.identities`/
      # `.groups`/`.podSecurity` -- `modules/reconciler.nix`'s own declared
      # cross-repo contract, see that file's header) is real and shipped --
      # this repo's own read path was repointed at it (from an intervening
      # standalone nixposix repo, itself moved out of and back into nixid,
      # since renamed nixiam) precisely because nixiam.posix was found NOT
      # actually declared under the OLD path this file's own `nixid` input
      # once pointed at, silently resolving `identities`/`groups` to the
      # empty set. See README's "Why nixstorage depends on nixiam" and
      # Status section. `github:julian-corbet/nixiam-corbet-ch` above is
      # now published and resolves normally -- see flake.lock.
      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system nixiam nixtest;
          shapeModule = self.nixosModules.shape;
          deliveryModule = self.nixosModules.delivery;
          reconcilerModule = self.nixosModules.reconciler;
          disksModule = self.nixosModules.disks;
          layoutModule = self.nixosModules.layout;
          scrubModule = self.nixosModules.scrub;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
