# Why one bit decides whether a subtree can be mounted independently

## The problem

NFS exports are commonly configured `root_squash`: a client mount walks the
server-side path as the unprivileged `nobody` account, not as whatever uid
actually owns the tree. That single fact has a consequence that is easy to
miss until it actually bites: if a tree ROOT is mode `2750`
(`drwxr-s---` — owner and group only, no bits for others at all), the
`nobody` walk dies at that root. Every mount of every path beneath it fails
identically, regardless of what that deeper path's own mode says, because
the walk never gets that far.

That would just be an access-control inconvenience if mounting the whole
tree at once were always an option. It isn't, for a reason that has nothing
to do with permissions: a `crossmnt`-synthesized child mount inherits its
parent superblock's mount options wholesale. There is no way to give one
subtree of an already-mounted tree a different cache policy, a different
timeout, anything — the only way to hand a subtree its own options is to
mount it as its own, separate, independent mount. And that independent
mount is exactly what a non-traversable root makes impossible.

## What was measured

On a real deployment, with a tree root at mode `2750`:

```
$ mount server:/tree/child /mnt/child
mount.nfs4: access denied by server while mounting server:/tree/child
```

The same failure occurred with an unrelated mount option present and
absent — ruling out the option as the cause, and confirming the failure
was the directory walk itself, not anything about what was being asked
for on top of it.

The same mount, against a sibling tree already at mode `2775`
(world-traversable, world-listable), succeeded immediately — and went on
to prove the actual goal: two children of the SAME parent, mounted
independently, at the same time, carrying DIFFERENT mount options from
each other (one with a persistent local cache enabled, one without). That
independence is only possible because each got its own real mount at all.

## The fix, and why it is exactly one bit

`2750` → `2751`. Adding `o+x` (execute/search for "others") grants
TRAVERSE only — the ability to walk THROUGH a directory whose name you
already know — and grants nothing else:

- It does **not** grant LIST. `ls` against the directory from an
  unprivileged walker still shows nothing; only a path component that is
  already known can be traversed, not discovered.
- It does **not** weaken any child's own mode. Every directory beneath the
  one bit that changed still enforces exactly what its own permissions say;
  a `2751` parent with a `2750` child still stops the walk at that child.
- It is reversible with zero data risk: `chmod` on a directory's mode bits
  touches metadata only, nothing about the data underneath changes shape,
  and it can be flipped back the instant it turns out to be wrong for a
  particular tree.

## Why the check has to be recursive, not just "is the leaf's own mode right"

A non-traversable ancestor breaks the guarantee exactly as completely as a
non-traversable direct parent — it is just less obvious, because the
mistake can sit two or three levels above the dataset someone is actually
trying to mount, nowhere near the config a person is looking at when the
mount fails. `subtreeMountable = true` on a leaf while some ancestor above
it is still `2750` produces the identical "access denied by server"
failure, and nothing about the leaf's own declaration looks wrong in
isolation. This is why `modules/shape.nix`'s assertion walks the entire
declared ancestor chain of every `subtreeMountable` dataset, not just the
dataset itself — see that option's own description for the exact
assertion text a broken chain produces.

## What the check cannot see

The ancestor-chain assertion only has visibility into datasets that are
THEMSELVES declared in `nixstorage.shape.datasets`. A bare pool mountpoint,
or any other directory above a declared tree that this repo was never told
about, is structurally outside what an eval-time check can verify —
promoting that gap into `experiments/README.md` #001 rather than either
ignoring it or overclaiming a guarantee this module cannot actually make.

## Trade-offs

- **The bit is permanent exposure of the path's existence to anyone who
  already knows it**, not a temporary or revocable grant in the way a
  token or a signed URL would be. Anyone who can name the child path can
  traverse to it, forever, until the bit is removed. This is the intended
  trade — enumeration stays blocked, naming does not — but it is worth
  stating plainly rather than leaving implicit.
- **It buys nothing on its own without the independent mount it enables.**
  Setting the bit and continuing to access everything through the parent's
  single crossmnt-synthesized mount changes nothing observable; the payoff
  only exists once something actually mounts the subtree on its own.

## See also

- [`../modules/shape.nix`](../modules/shape.nix) — `subtreeMountable`'s
  full option description and the assertion implementation
- [`../README.md`](../README.md) — the traversability finding as this
  repo's headline feature, and how it fits alongside `class`/`children`/
  `prune`
