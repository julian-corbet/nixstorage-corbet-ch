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
      # Three independently toggleable modules under one `nixstorage.*`
      # namespace -- same shape as nixbackup's three (destinations/
      # autobootstrap/monitor). `shape` and `delivery` are pure schema +
      # assertion, no systemd unit, nothing to "enable" -- import either
      # on its own to get validated, machine-readable declarations with
      # zero runtime footprint. `reconciler` is the one module that
      # actually acts -- today, on ownership and top-directory mode only
      # (see README's Status for the one open gap: nothing yet runs the
      # `zfs set` half `shape.nix`'s own model describes) -- hence
      # `default` for the common case of wanting all three.
      # ---------------------------------------------------------------
      nixosModules.shape = ./modules/shape.nix;
      nixosModules.delivery = ./modules/delivery.nix;
      nixosModules.reconciler = ./modules/reconciler.nix;
      nixosModules.default = {
        imports = [
          self.nixosModules.shape
          self.nixosModules.delivery
          self.nixosModules.reconciler
        ];
      };

      # Same three files, same schema, on system-manager's smaller option
      # surface. None of the three touches a NixOS-only primitive as
      # designed -- shape/delivery are pure option declarations + eval-time
      # assertions, and the reconciler is `chown`/`chmod` in a systemd
      # oneshot + optional timer -- the same portability argument
      # nixshare's own client-side core makes for its watchdog.
      # UNCONFIRMED against a real system-manager-applied host (see
      # README's Non-goals); flagged rather than silently assumed, same
      # convention nixshare uses for its own equivalent caveat.
      systemManagerModules.shape = ./modules/shape.nix;
      systemManagerModules.delivery = ./modules/delivery.nix;
      systemManagerModules.reconciler = ./modules/reconciler.nix;
      systemManagerModules.default = {
        imports = [
          self.systemManagerModules.shape
          self.systemManagerModules.delivery
          self.systemManagerModules.reconciler
        ];
      };

      # All three of this repo's modules, PLUS nixid's posix identity
      # module -- the one thing nixstorage can name an owner/identity
      # reference to but must never define itself -- composed into one
      # system from examples/host. This is the only place a collision
      # between the two flakes' namespaces, a dangling `owner`/`identity`
      # reference, or a `subtreeMountable` ancestor gap would actually
      # surface, the same reason nixid's own flake composes lldap.nix +
      # pocket-id.nix together rather than checking either alone.
      #
      # ⚠ At the time this scaffold was written, nixid's own posix/identity
      # module (`nixid.posix.identities`/`.groups`/`.podSecurity` --
      # `modules/reconciler.nix`'s own declared cross-repo contract, see
      # that file's header) had not been published in
      # https://github.com/julian-corbet/nixid-corbet-ch yet. This check
      # is written against that contract, not against code that has run
      # from the nixid side -- it will not evaluate until it lands. See
      # README's Status section.
      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          host = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.shape
              self.nixosModules.delivery
              self.nixosModules.reconciler
              nixid.nixosModules.posix
              ./examples/host/configuration.nix
            ];
          };
        in
        {
          # String context around a derivation path MUST be discarded --
          # same reasoning as nixid's and nixbackup's own equivalent
          # checks: keeping it BUILDS a whole NixOS system rather than
          # evaluating one, minutes and a multi-gigabyte download versus
          # seconds.
          modules-evaluate =
            pkgs.writeText "nixstorage-host-drvpath"
              (builtins.unsafeDiscardStringContext host.config.system.build.toplevel.drvPath);
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
