#
# The partition ROLE catalogue: what `nixstorage.layout` actually knows how
# to carve, kept as pure data -- the same "data separate from the module"
# split nixfs's own lib/catalogue.nix draws between what a host declares
# and what a fixed, reviewable table says that declaration MEANS. A role
# answers "what is this slot for", never "what GPT type-GUID do I type" --
# see modules/layout.nix's own `role` option for why that question belongs
# here and not on the option surface a host actually writes.
#
# Three roles, matching exactly the three this repo's own design record
# sanctions (modules/shape.nix's header: "an ESP, raw slots, an encrypted
# region") -- deliberately not a wider, more "complete" partition-type
# table. A role this catalogue does not name is a role `nixstorage.layout`
# has no opinion on; add one here, with a reason, rather than smuggling a
# type-GUID in some other way.
#
# `formatted` says what lib/image.nix actually writes into that
# slot when it builds an image: `"vfat"` for the one role this repo puts
# real filesystem content into, `null` for the two it deliberately leaves
# empty. Both empty cases are empty for the SAME underlying reason stated
# once here rather than twice: this module carves capacity, it does not
# provision what eventually lives in it. See modules/layout.nix's own
# header for exactly where that boundary sits for `luks` in particular --
# the one place getting this wrong would mean embedding real key material
# in a world-readable Nix store path, which this repo will never do.
{}:
{
  esp = {
    typeGuid = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
    summary = "the EFI System Partition";
    detail = ''
      What a host's `nixboot.esp.mountPoint` expects mounted, and what that
      same project's own header already states as its boundary: "ESP
      (declared, never created -- nixboot does not partition)". This role
      is the other half of that sentence -- nixstorage.layout carves an
      ESP-typed, vfat-FORMATTED slot of the declared size, but it is empty
      the moment this module is done with it. Populating it (the actual
      EFI binaries, boot entries) is nixboot's own live-system job, done by
      mounting the real device after this image has already been written
      to it -- never this module's, and never at image-build time.
    '';
    formatted = "vfat";
  };

  raw = {
    typeGuid = "0FC63DAF-8483-4772-8E79-3D69D8477DE4";
    summary = "reserved, unformatted capacity";
    detail = ''
      A correctly-sized, correctly-typed slot for a filesystem the
      CONSUMING system creates later -- a ZFS pool member, a swap device,
      anything this repo's own shape.nix/reconciler.nix have no opinion on
      because it does not exist as a mountable dataset yet. Carved here and
      left completely empty; nothing in lib/image.nix ever writes a
      single byte into a "raw" partition's own data region.
    '';
    formatted = null;
  };

  luks = {
    typeGuid = "CA7D7CCB-63ED-4C53-861C-1742536059CC";
    summary = "reserved capacity for an encrypted region";
    detail = ''
      Sized and typed so cryptsetup recognizes the slot as intended for
      LUKS, but NEVER formatted by this repo. Running `cryptsetup
      luksFormat` needs a key, and the only place that key may ever be
      generated is on the real, already-written-to-media host, by a human,
      at the console -- exactly nixvault's own `nixvault-create` lifecycle
      (see that project's README for why create/update are deliberately
      absent from systemd entirely). Baking a key of any kind, real or
      disposable-and-supposedly-thrown-away, into a Nix derivation would
      put it in a WORLD-READABLE store path forever; this repo will never
      do that, so this role stops at "reserved capacity", full stop.
    '';
    formatted = null;
  };
}
