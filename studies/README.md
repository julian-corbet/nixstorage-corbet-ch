# studies

Written-up findings: results worth keeping, with enough context that
someone other than the author can understand what was tried, what was
measured, and what was concluded. This is where a promising result from
[`../experiments/`](../experiments/README.md) lands once it's been turned
into something durable.

- [`subtree-traversability.md`](subtree-traversability.md) — the
  measurement behind `subtreeMountable`: why a `root_squash` NFS export
  dies at a non-traversable tree root, why that makes independent subtree
  mounts (and therefore per-subtree mount options) impossible, and why the
  fix costs exactly one bit.
- [`sandboxed-image-building.md`](sandboxed-image-building.md) — the
  measurement behind `nixstorage.layout`: why `sgdisk`/`sfdisk`/`mkfs.vfat
  -C` need no loop device and no root to build a real, formatted GPT image
  as a pure Nix derivation, and why a partition's byte offset is queried
  back from `sgdisk` rather than recomputed by hand.

See the main [README](../README.md) for the project itself.
