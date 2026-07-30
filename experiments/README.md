# experiments

Throwaway trials: quick spikes, one-off scripts, half-finished attempts at
proving or disproving an idea before it's worth writing up properly.
Nothing in here is expected to be maintained, documented for others, or
kept working across commits — it can be deleted at any time.

This is also the open-questions ledger for nixstorage's own judgment
calls — every entry below corresponds to a default or design choice that's
reasoned, not yet measured against a second, independent real pool.

When an experiment produces a real finding worth keeping, promote the
write-up to [`../studies/`](../studies/README.md) and either delete the
experiment or leave it as supporting evidence linked from the study.

## 001 — is the `subtreeMountable` ancestor-chain check sufficient on its own?

**Question:** `modules/shape.nix`'s ancestor-chain assertion for
`subtreeMountable` only ever sees ancestors that are THEMSELVES declared in
`nixstorage.shape.datasets` (see that option's own description). A pool's
bare mountpoint, or any directory above a declared tree that this repo was
never told about, is outside what the assertion can verify. Is that gap
worth closing with something stronger than a documentation caveat — for
instance, a runtime check (a boot-time oneshot that walks `stat()` up from
each `subtreeMountable` dataset to the pool root and warns on the first
non-traversable directory it finds, the same "advisory, never fatal"
pattern nixiam's own `exposeOnInterfaces` check uses)?

**Hypothesis:** probably yes, eventually — the failure mode (an
undeclared grandparent silently breaking the traversal guarantee) is
exactly the kind of thing that reads as "this should have been caught" in
hindsight. Not done for the initial scaffold because it needs a real ZFS
pool with a real mount hierarchy to validate against, not just module
evaluation.

**Method sketch:** on a real pool, declare a `subtreeMountable` dataset
several levels deep, deliberately leave one intermediate directory (not
itself a `nixstorage.shape.datasets` entry — e.g. the bind-mount point of a
foreign filesystem) non-traversable, and confirm the eval-time assertion
stays silent while an actual `mount` attempt from a `root_squash` NFS
client fails. If that reproduces cleanly, the runtime check earns its
keep.

**Status:** open. No real pool has run this repo yet.

## 002 — should `children = "reconcile"` compute a deterministic sweep order?

**Question:** `modules/shape.nix`'s own `children` option description flags
that Nix attribute sets carry no guaranteed key order, and that a
reconciler needing deterministic sweep order (e.g. letting a more specific
descendant's own `"reconcile"` intentionally re-win a subtree after a
broader ancestor's sweep already touched it) has to compute that itself.
Is alphabetical-by-dataset-name sufficient, or does a real deployment need
something depth-aware (shallowest first, so a descendant always applies
last and wins)?

**Hypothesis:** depth-aware, not alphabetical — a name sort is only
correct by accident (it happens to put `"tank/agents"` before
`"tank/agents/models"` because of the string, not because of the
hierarchy), and a future dataset naming scheme that broke that accident
would silently invert the intended precedence with no eval-time signal at
all.

**Status:** open — this belongs to `modules/reconciler.nix`, not yet
written.

## 003 — is a fixed 2 MiB `reservedOverheadMiB` the right constant forever?

**Question:** `modules/layout.nix`'s `reservedOverheadMiB` (currently a
hardcoded `2`) exists so an obviously-too-tight `images.<name>` declaration
fails at eval time instead of only at image-build time. It was set from one
real measurement (see `studies/sandboxed-image-building.md`): a ~1 MiB
leading alignment gap plus a negligible trailing GPT-footer reservation, on
`sgdisk`'s own DEFAULT 2048-sector alignment. Is `2` still correct if a
future version of this module ever exposes `sgdisk`'s own `-a`/
`--set-alignment` override (coarser alignment on some flash media wants a
bigger unit), or on a sector size other than 512 bytes (4Kn drives)?

**Hypothesis:** probably not without revisiting it -- the constant is
measured against ONE alignment/sector-size combination, not derived
symbolically from whatever `lib/image.nix` actually asks `sgdisk` for. If
alignment or sector size ever become configurable, this constant needs to
become a function of those, not stay a bare number.

**Status:** open. No real 4Kn device, and no alignment override, has been
exercised against this repo yet.

## 004 — should `nixstorage.layout.verify`'s size tolerance be configurable?

**Question:** `modules/layout-verify.sh` accepts a live partition's size
within ±1 MiB of its declared `sizeMiB` before calling it drift (see that
file's own `TOLERANCE_MIB`). That number absorbs the SAME alignment
rounding `reservedOverheadMiB` above is about, from the other direction --
generous enough that a device written by this repo's own image builder
should never spuriously fail, but was never measured against a device
whose image was built by something OTHER than `lib/image.nix` (a
hand-`sgdisk`'d disk, or an image built with a different alignment). Is a
single hardcoded tolerance right for every declared target, or does a
target sometimes need its own, especially once experiment 003's alignment
question is resolved?

**Status:** open. No real drift case from a foreign image-building tool has
been reproduced against this check yet.

## Renumbering history

001/002 above are original to this file. 003/004 above were briefly
renumbered 001/002 in a standalone `nixlayout` repo's own
`experiments/README.md` when `modules/layout.nix` was extracted out of
this one; that split has been reversed (see the main
[README](../README.md)'s "Why layout is not a separate repo" for the
argument), and 003/004 are restored to their original numbers here.
