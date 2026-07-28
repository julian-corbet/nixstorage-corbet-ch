# modules/delivery.nix
#
# The DELIVERY half of nixstorage: `options.nixstorage.delivery` declares
# CATEGORIES -- the model of what a human sitting at a home directory, or
# a container looking at its mount table, actually sees. A category names
# a host path, the leaf name it surfaces as under `$HOME`, which XDG
# user-directory role (if any) it fills, which classes of consumer are
# even meant to see it, and which delivery MECHANISM applies to it on a
# given host. That is the whole of what this module does.
#
# ⚠ THE BOUNDARY THAT IS EASY TO GET WRONG: this module defines the
# category. It does not mount, export, bind, or symlink anything itself --
# there is no `systemd.mounts` entry, no `fileSystems.<path>`, no
# `services.nfs.server` export anywhere in this file, on purpose. A
# category with `mount = "nfs"` describes a fact ("this is delivered over
# NFS on hosts that aren't the storage host itself") for a companion
# project (a client-side NFS-mount module, e.g. nixshare) to act on; a
# category with `mount = "zfs"` describes a different fact ("a host that
# already has the underlying pool imported delivers this by mounting/
# binding the dataset directly, locally") for whatever local-host module
# does THAT. This module's own job stops at describing which case applies
# -- reading this file looking for the actual mount call will not find
# one, and that absence is deliberate, not a missing feature.
#
# Why source/home/xdg/scope/mount are kept as separate, independently
# readable fields instead of one combined "delivery spec" string: each
# answers a genuinely different question a consumer might ask without
# caring about the others -- "where does the data live" (source), "what
# does a human call it" (home), "does some XDG-aware application expect
# to find this automatically" (xdg), "should THIS host even see it"
# (scope), "how does it get here" (mount) -- and collapsing them loses the
# ability to answer one without parsing all of them back out again.

{ lib, config, ... }:

with lib;

let
  cfg = config.nixstorage.delivery;

  categoryNames = attrNames cfg.categories;

  homeAssertions = concatMap
    (name:
      let c = cfg.categories.${name};
      in optional (hasInfix "/" c.home) {
        assertion = false;
        message = ''
          nixstorage.delivery.categories."${name}".home = "${c.home}"
          contains a "/". `home` names a single leaf directly under
          `$HOME` (the thing a real `$HOME/<leaf>` entry is named), not a
          path -- a value with a slash in it does not describe a deeper
          location, it silently produces whatever your delivery mechanism
          does with a slash in a single path component (on most of them:
          nothing sensible). If you mean a role living INSIDE another
          category, that is exactly what `xdgSubdirectory` below is for.
        '';
      })
    categoryNames;

  xdgSubdirAssertions = concatMap
    (name:
      let c = cfg.categories.${name};
      in optional (c.xdgSubdirectory != null && c.xdg == null) {
        assertion = false;
        message = ''
          nixstorage.delivery.categories."${name}".xdgSubdirectory is set
          ("${c.xdgSubdirectory}"), but `xdg` is null on the same category.
          `xdgSubdirectory` narrows WHICH ROLE inside this category's
          `home` is fulfilled by a subdirectory instead of the category
          root -- it has nothing to narrow if no XDG role is declared at
          all. Set `xdg` to the role this subdirectory fulfills, or drop
          `xdgSubdirectory` if this category fills no XDG role.
        '';
      })
    categoryNames;

  categoryModule = { ... }: {
    options = {
      source = mkOption {
        type = types.str;
        example = "/tank/media";
        description = ''
          The host path this category's data actually lives at -- a plain
          filesystem path, not a dataset name (a category and a
          `nixstorage.shape.datasets` entry are not the same map, and this
          module deliberately keeps no hard link between the two; nothing
          here stops `source` from pointing at a path that also happens to
          be a declared dataset's mountpoint, but nothing requires it
          either). This is where a `mount = "zfs"` consumer binds/mounts
          FROM, and where a `mount = "nfs"` server-side export is rooted.
        '';
      };

      home = mkOption {
        type = types.str;
        example = "media";
        description = ''
          The leaf name this category surfaces as under `$HOME` --
          `"media"` here means a consumer is expected to expose it at
          `$HOME/media`. A single path component, not a path (asserted
          below): a category with a nested home location is exactly the
          `xdgSubdirectory` case, not a slash typed into this field.
        '';
      };

      xdg = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "DOWNLOAD";
        description = ''
          The `XDG_*_DIR` role (from the `xdg-user-dirs` convention --
          `DOWNLOAD`, `MUSIC`, `PICTURES`, `VIDEOS`, `DOCUMENTS`,
          `DESKTOP`, etc.) this category fulfills for an XDG-aware
          application, or `null` if it fills none. Free-form string
          rather than a fixed enum on purpose -- the set of roles an
          application might look for is not closed, and this module has
          no business being the thing that goes stale when a new one
          shows up.

          By default the role is fulfilled by this category's OWN root
          (`source`/`home` above) -- see `xdgSubdirectory` for the other
          real case, where the role instead belongs to a subdirectory of
          a category that is about something broader than that one role.
        '';
      };

      xdgSubdirectory = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "downloads";
        description = ''
          When set, the XDG role named by `xdg` is fulfilled by
          `$HOME/<home>/<xdgSubdirectory>`, NOT by the category's own root
          -- and requires `xdg` to also be set (asserted below; a
          subdirectory role with no role to narrow is a contradiction,
          not a smaller version of the same thing).

          The real pattern this exists for: a downloads directory that
          lives INSIDE a broader shared exchange/inbox tree, rather than
          getting its own top-level category. Modeling it as its own
          category would be a lie about what it actually is -- a landing
          spot inside one shared tree, not an independent piece of
          storage with its own lifecycle -- so instead the exchange-style
          category declares `xdg = "DOWNLOAD"` and `xdgSubdirectory =
          "downloads"`, and a consumer is expected to deliver
          `$XDG_DOWNLOAD_DIR` as a symlink pointing at
          `$HOME/<exchange-home>/downloads` rather than as a directory of
          its own. This module only declares that the relationship
          exists; creating the symlink (or whatever a given consumer's
          equivalent is) is, like every other piece of actual delivery
          mechanism, out of scope here -- see this file's header.
        '';
      };

      scope = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "common" ];
        description = ''
          Which classes of consumer this category is meant for, as a
          free-form list of tags -- this module never defines what a tag
          MEANS, only carries the list through so that whatever decides
          "does THIS particular host/container/user get this category"
          can filter on it. Left as opaque strings rather than a fixed
          enum for the same reason `xdg` is a free-form string: the set of
          consumer classes a given deployment cares about (a shared
          workstation profile vs. a single-purpose container image vs.
          anything else a consumer invents) is that consumer's business,
          not this module's.
        '';
      };

      mount = mkOption {
        type = types.enum [ "zfs" "nfs" "none" ];
        example = "zfs";
        description = ''
          How this category is delivered, on whichever host is currently
          asking. This module does not act on the value -- see the header
          for the full boundary statement -- it only records which case
          applies, for a delivery-mechanism module (a local-host ZFS
          mount/bind for `"zfs"`, an NFS client/server module such as
          nixshare for `"nfs"`) to branch on:

          - `"zfs"`: the consumer already has the underlying pool
            imported, and delivers this category by mounting or binding
            the dataset at `source` directly, locally.
          - `"nfs"`: the consumer reaches `source` over NFS -- either
            exporting it (the storage host itself) or mounting it (every
            other consumer). Which side a given host plays is not encoded
            here; it follows from whether that host IS the storage host.
          - `"none"`: this category is declared (visible to the model,
            has a `home`/`xdg` role reserved) but not actually delivered
            on the host asking right now -- staged for later, or
            deliberately absent there. Distinct from omitting the
            category from `scope` entirely: `scope` says who this is FOR
            in general, `mount = "none"` says a particular consumer that
            IS in scope still doesn't get it delivered today.
        '';
      };
    };
  };

in
{
  options.nixstorage.delivery = {
    categories = mkOption {
      type = types.attrsOf (types.submodule categoryModule);
      default = { };
      description = ''
        The `~/<home>` delivery model: what a human or container actually
        sees, upstream of how any of it is mounted. See each field's own
        description (`source`, `home`, `xdg`, `xdgSubdirectory`, `scope`,
        `mount`) and this file's header for the mechanism boundary every
        one of them stops short of.
      '';
    };
  };

  config = {
    assertions = homeAssertions ++ xdgSubdirAssertions;
  };
}
