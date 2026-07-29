{
  description = "Declarative ZFS dataset shape (recordsize/compression convergence) and category-based delivery (source -> $HOME -> XDG -> scope), reconciled by one idempotent pass. Ownership -- uid/gid and its Kubernetes securityContext twin -- is deliberately NOT here; a dataset names its owner by a string key into nixid instead.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixstorage answers "where and what shape"; nixid answers "who". A
    # root's owner/group may be a literal numeric uid/gid, but an app
    # leaf's identity is ALWAYS a STRING KEY into
    # `nixid.posix.identities.<name>`, never a raw uid/gid copied into
    # this repo -- so the on-disk owner and a workload's securityContext
    # can never independently drift (see README's "Why nixstorage depends
    # on nixid, and never the reverse"). This dependency is permanently
    # one-way: nixid must never learn a dataset name or a pool path. The
    # day it does, the layering this split exists to enforce has already
    # inverted.
    nixid = {
      url = "github:julian-corbet/nixid-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixid }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # ---------------------------------------------------------------
      # Four independently toggleable modules under one `nixstorage.*`
      # namespace -- same shape as nixbackup's three (destinations/
      # autobootstrap/monitor). `shape` and `delivery` are pure schema +
      # assertion, no systemd unit, nothing to "enable" -- import either
      # on its own to get validated, machine-readable declarations with
      # zero runtime footprint. `reconciler` and `layout` are the two
      # modules that actually act -- `reconciler` on ownership and
      # top-directory mode only (see README's Status for the one open gap:
      # nothing yet runs the `zfs set` half `shape.nix`'s own model
      # describes), `layout` on nothing but READING a live device back
      # (see modules/layout.nix's own header for the full safety model --
      # it never writes to a block device, only ever to a plain file it
      # builds itself) -- hence `default` for the common case of wanting
      # all four.
      # ---------------------------------------------------------------
      nixosModules.shape = ./modules/shape.nix;
      nixosModules.delivery = ./modules/delivery.nix;
      nixosModules.reconciler = ./modules/reconciler.nix;
      nixosModules.disks = ./modules/disks.nix;
      nixosModules.layout = ./modules/layout.nix;
      nixosModules.default = {
        imports = [
          self.nixosModules.shape
          self.nixosModules.delivery
          self.nixosModules.reconciler
          self.nixosModules.disks
          self.nixosModules.layout
        ];
      };

      # Same four files, same schema, on system-manager's smaller option
      # surface. None of the four touches a NixOS-only primitive as
      # designed -- shape/delivery are pure option declarations + eval-time
      # assertions, and both reconciler and layout.verify are `systemd`
      # oneshots + optional timers -- the same portability argument
      # nixshare's own client-side core makes for its watchdog.
      # UNCONFIRMED against a real system-manager-applied host (see
      # README's Non-goals); flagged rather than silently assumed, same
      # convention nixshare uses for its own equivalent caveat.
      systemManagerModules.shape = ./modules/shape.nix;
      systemManagerModules.delivery = ./modules/delivery.nix;
      systemManagerModules.reconciler = ./modules/reconciler.nix;
      systemManagerModules.layout = ./modules/layout.nix;
      systemManagerModules.default = {
        imports = [
          self.systemManagerModules.shape
          self.systemManagerModules.delivery
          self.systemManagerModules.reconciler
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

      # All four of this repo's modules, PLUS nixid's posix identity
      # module -- the one thing nixstorage can name an owner/identity
      # reference to but must never define itself -- composed into one
      # system from examples/host, PLUS a handful of standalone eval-tests
      # for the parts a single composed-host check cannot exercise (the
      # image builder actually building, the verify script actually
      # detecting drift). See checks/default.nix for all of it, the same
      # split nixfs/nixvault/nixboot already use in this family.
      #
      # ⚠ At the time this scaffold was written, nixid's own posix/identity
      # module (`nixid.posix.identities`/`.groups`/`.podSecurity` --
      # `modules/reconciler.nix`'s own declared cross-repo contract, see
      # that file's header) had not been published in
      # https://github.com/julian-corbet/nixid-corbet-ch yet. The composed-
      # host check is written against that contract, not against code that
      # has run from the nixid side -- it will not evaluate until it
      # lands. See README's Status section.
      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system nixid;
          shapeModule = self.nixosModules.shape;
          deliveryModule = self.nixosModules.delivery;
          reconcilerModule = self.nixosModules.reconciler;
          layoutModule = self.nixosModules.layout;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
