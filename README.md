# nixstorage

**A dataset is declared once — its shape, its owner, and where it
surfaces — and one idempotent reconciler converges all three, forever.**

`nixstorage` is the declarative model of a ZFS storage substrate: what
shape a dataset's blocks should take (`recordsize`/`compression`,
converged forever, never a one-time `zfs create` flag left to drift), and
where its contents actually surface for a human or a container to use
(a `$HOME` leaf, an XDG role, which class of consumer even gets it). It
does not decide who owns a dataset on disk — see
[Why nixstorage depends on nixid, and never the reverse](#why-nixstorage-depends-on-nixid-and-never-the-reverse)
for why that third concern lives one repo over, consumed here by name
only.

This repo, and the design it implements, exists because a real,
already-running storage host's model of itself was one file wearing three
unrelated hats — dataset shape, on-disk ownership, and delivery — and the
day someone needed "who owns this" answered from Kubernetes instead of
from a shell script, there was nowhere for that to live without either
duplicating the uid/gid or reaching into a file that had no business
knowing about pods. Splitting it was not a refactor for its own sake; it
was the fix for a coupling that had already started to bite.

## The three modules

- **`modules/shape.nix`** (`nixstorage.shape`) — named dataset **classes**
  (`recordsize`, `compression`, and any other ZFS property via the
  free-form `properties` field) and the real **datasets** assigned to
  them. Pure schema and eval-time assertion — there is no systemd unit
  here, nothing to "enable". A typo'd class name, a `subtreeMountable`
  dataset whose declared ancestor isn't also traversable — both fail
  `nix flake check` by name, not silently at 3am when a reconciler run
  does the wrong thing.
- **`modules/delivery.nix`** (`nixstorage.delivery`) — named **categories**:
  what a human sitting at `$HOME`, or a container reading its own mount
  table, actually sees. A category names a host path, the `$HOME/<leaf>`
  it surfaces as, which `XDG_*_DIR` role it fills (if any), which classes
  of consumer it's even meant for, and which delivery *mechanism* applies
  (`"zfs"`, `"nfs"`, or `"none"` — declared but not delivered here, yet).
  Also pure schema and assertion, same as `shape.nix`. It does not mount,
  export, bind, or symlink anything — see
  [Non-goals](#non-goals).
- **`modules/reconciler.nix`** (`nixstorage.reconciler`) — the module that
  actually acts, today scoped to **ownership and top-directory mode**:
  declares tree `ownership` roots and per-app `leaves`, resolves each
  one's `owner`/`group`/`identity` name against `nixid.posix.identities`/
  `.groups`, and idempotently `chown -h`/`chmod`s real, live paths to
  match — via `modules/reconcile.sh`, a real, already-running shell
  script, not a stub. Nothing here creates or destroys a dataset, and
  nothing here runs `zfs set` — recordsize/compression convergence is
  `shape.nix`'s own declared model, and (see [Status](#status)) does not
  yet have a reconciler of its own actually applying it; this module's
  job stops at ownership and mode.

Each is independently toggleable: import `shape` alone to get a validated,
machine-readable dataset model with zero runtime footprint (useful as
documentation, or as an input to a completely different reconciler you
already run); import `delivery` alone for the same on the `$HOME`/XDG
side; import all three (`nixosModules.default`) for the common case of
wanting the whole thing to actually converge. Nothing here is a lumped
`nixstorage.enable` — see `modules/shape.nix` and `modules/delivery.nix`
for why neither even has an `enable` option: there is nothing running to
turn on, only a schema to validate, so the act of importing the file *is*
the toggle.

## Why nixstorage depends on nixid, and never the reverse

A leaf's identity — uid, gid, which of the two real ownership-drop
patterns it uses (`"native"`: runs as its own non-root uid directly; or
`"puid"`: an s6-overlay/linuxserver.io-style image that starts root and
drops privilege itself via `PUID`/`PGID`), and the Kubernetes
`securityContext` a workload touching the same data needs to agree
with — is declared exactly once, in
[nixid](https://github.com/julian-corbet/nixid-corbet-ch), under a name
(`nixid.posix.identities.<name>`, in the design this repo implements).
`nixstorage.reconciler` consumes that name; it never holds a raw uid/gid
of its own — a tree ROOT's `owner`/`group` may still be a literal numeric
string (a human account with no Kubernetes workload behind it at all has
no identity to name), but an app LEAF's `identity` has no such escape
hatch, on purpose: it is *always* a name, because that is what makes the
on-disk uid and the k8s `runAsUser`/`PUID` checkable against each other at
all, rather than two numbers someone has to remember to keep in sync by
hand. This is the whole point of the split, not an implementation detail
of it: **nixid answers "who", nixstorage answers "where and what
shape."** If nixid ever learned a dataset name or a pool path, the
layering would have inverted — the identity module would now depend on
the storage module's own vocabulary, and the one thing this split exists
to prevent (an on-disk chown and a pod's `runAsUser` silently drifting
apart because they're maintained in two unrelated places) would be
exactly as possible as it was before the split, just with the duplication
moved one file over instead of removed.

Concretely: `nixstorage.reconciler.leaves."/tank/apps/data" = { identity =
"example-app"; mode = "0750"; }` names an identity; `nixid.posix.
identities.example-app = { uid = 3002; variant = "native"; }` defines it
once, and `nixid.posix.podSecurity.example-app` (derived, read-only) is
the SAME identity reshaped into a pod/container `securityContext`. Change
the uid in one place and both the on-disk chown and the securityContext
your Kubernetes manifest builds from it move together, because there is
only one place a uid was ever actually written down — and
`nixstorage.reconciler`'s own per-leaf assertion checks exactly this
consistency (`nixid.posix.podSecurity.<name>.pod.runAsUser ==
nixid.posix.identities.<name>.uid`, or the `PUID`-string equivalent for a
`"puid"` identity) on every eval, not just at the moment someone wrote it
correctly.

## Non-goals

- **It does not mount anything.** A `delivery.nix` category with
  `mount = "nfs"` describes a fact for a client-side mount module (a
  role [nixshare](https://github.com/julian-corbet/nixshare-corbet-ch)
  fills) to act on. There is no `systemd.mounts`/`fileSystems.<path>`
  entry anywhere in this repo.
- **It does not back anything up.** ZFS send/receive discipline,
  replication-destination invariants, and freshness monitoring are
  [nixbackup](https://github.com/julian-corbet/nixbackup-corbet-ch)'s
  entire reason to exist. `nixstorage` has no opinion on retention or
  replication targets.
- **It does not install filesystem tooling.** Whatever ships `zfs(8)`
  itself, kernel module loading, pool import at boot — that's `nixfs`'s
  domain, not this repo's. `nixstorage` assumes a working, imported pool
  and only ever runs `zfs set`/`zfs get` against datasets that already
  exist.
- **It does not boot anything.** Appliance boot chains, impermanence,
  USB-image builds — [nixnas](https://github.com/julian-corbet/nixnas)'s
  job. `nixstorage` is a set of NixOS/system-manager modules any host can
  import; it has no opinion on how that host got to a running kernel.

## The traversability finding

This is the headline feature, and the reason `nixstorage.shape.datasets`
carries a `subtreeMountable` option at all rather than leaving mode bits
to be worked out by hand per host.

NFS exports are commonly `root_squash`: an NFS client's mount walks the
server-side path as `nobody`, not as whatever uid actually owns the
share. If a tree root is mode `2750` (`drwxr-s---` — no bits for others,
not even traverse), that walk dies at the root. That failure applies
identically to **every** subtree beneath it, regardless of what that
deeper path's own mode says, because the walk never reaches it. And
because a `crossmnt`-synthesized child mount inherits its parent
superblock's mount options wholesale, mounting a subtree *independently*
— the only way to give it its own cache policy, its own timeout tuning,
anything different from its siblings — requires the walk to survive far
enough to mount it separately in the first place.

Measured directly against a real deployment:

- `mount server:/tree/child` failed **"access denied by server"** — with
  and without an unrelated mount option under test, proving the option
  was never the cause; the traversal always was.
- The identical mount against a sibling tree already at mode `2775`
  (world-traversable) **succeeded**, and went on to prove the actual
  goal: two children of the *same* parent mounted independently, at the
  same time, carrying *different* cache policy from each other — one with
  a persistent local cache, one without.

The fix costs exactly one bit: `2750` → `2751`. Setting `o+x` grants
TRAVERSE only, never LIST — others can walk *through* a directory whose
name they already know; they still cannot enumerate its contents, and
every child underneath still enforces its own mode independently. See
[`studies/subtree-traversability.md`](studies/subtree-traversability.md)
for the full write-up.

`nixstorage.shape.datasets.<name>.subtreeMountable = true` is this fix,
made declarative and self-checking:

- it forces `o+x` into the effective mode `nixstorage.reconciler`'s own
  `ownership.<path>.mode` ends up writing for this dataset (mode lives in
  `nixstorage.reconciler`, never in `nixid` — only uid/gid are looked up
  by identity name), and
- it **asserts** that every declared ancestor of that dataset in
  `nixstorage.shape.datasets` also sets `subtreeMountable = true` — a
  non-traversable grandparent breaks the guarantee exactly as completely
  as a non-traversable direct parent, just less obviously, since the
  mistake can sit two or three levels above the dataset someone is
  actually trying to mount.

That ancestor-chain assertion only sees ancestors this module was told
about — a bare pool mountpoint above every declared dataset is out of its
reach by construction, tracked honestly as an open question rather than
silently assumed safe (see `experiments/README.md` #001).

## Quickstart

```nix
# flake.nix (consumer side)
{
  inputs.nixstorage.url = "github:julian-corbet/nixstorage-corbet-ch";
  inputs.nixid.url = "github:julian-corbet/nixid-corbet-ch";

  outputs = { self, nixpkgs, nixstorage, nixid, ... }: {
    nixosConfigurations.example-host = nixpkgs.lib.nixosSystem {
      modules = [
        nixstorage.nixosModules.shape
        nixstorage.nixosModules.delivery
        nixstorage.nixosModules.reconciler
        nixid.nixosModules.posix # the "who" this repo consumes by name
        ./configuration.nix
      ];
    };
  };
}
```

```nix
# configuration.nix
nixstorage.shape.classes.appdata = {
  recordsize = "32K";
  compression = "zstd";
};

nixstorage.shape.datasets."tank/apps/data" = {
  class = "appdata";
  children = "reconcile";
};

nixstorage.delivery.categories.media = {
  source = "/tank/media";
  home = "media";
  xdg = "VIDEOS";
  scope = [ "common" ];
  mount = "zfs";
};

nixstorage.reconciler.enable = true;
nixstorage.reconciler.leaves."/tank/apps/data" = {
  identity = "example-app";
  mode = "0750";
};

nixid.posix.identities.example-app = { uid = 3002; variant = "native"; };
```

## Options reference

`nixstorage.shape.*` (`modules/shape.nix` — pure schema + assertion, no
`enable`):

- `classes.<name>.recordsize`, `.compression` — required per class; see
  the module header for how to pick each from a workload, not from habit.
- `classes.<name>.properties` — free-form `attrsOf str`, any other
  `zfs set`-able property.
- `datasets.<name>.class` — which class this dataset converges to, or
  `null` for a dataset this module needs to know ABOUT (so
  `subtreeMountable`'s ancestor check and `prune` can reason about it)
  but whose own recordsize/compression are intentionally out of scope —
  owned by a different, out-of-band process, or purely a structural node.
- `datasets.<name>.children` — `"reconcile"` (descend and re-apply this
  class recursively, every run), `"inherit"` (set once, let ZFS's own
  property inheritance handle descendants), or `"ignore"` (default: never
  descend at all).
- `datasets.<name>.prune` — when `true`, no recursive, tree-walking
  operation may ever descend beneath this dataset. A safety mechanism for
  content this repo's own convergence must never touch — most concretely,
  a subtree whose backing media measurably wears down under exactly the
  access pattern a bulk sweep produces — not a performance knob.
- `datasets.<name>.subtreeMountable` — see
  [The traversability finding](#the-traversability-finding) above.

`nixstorage.delivery.*` (`modules/delivery.nix` — pure schema + assertion,
no `enable`):

- `categories.<name>.source` — the host path this category's data lives
  at. A plain path, not a dataset name; nothing links a category back to a
  `nixstorage.shape.datasets` entry, on purpose (see the module header).
- `categories.<name>.home` — the single leaf name under `$HOME` (no `/`;
  asserted).
- `categories.<name>.xdg` — an `XDG_*_DIR` role, free-form string, or
  `null`.
- `categories.<name>.xdgSubdirectory` — when the XDG role belongs to a
  subdirectory of this category rather than its own root (requires `xdg`
  set; asserted).
- `categories.<name>.scope` — free-form list of consumer-class tags; this
  module assigns no meaning to any tag, only carries the list through.
- `categories.<name>.mount` — `"zfs"` (already-imported pool, mount/bind
  locally), `"nfs"` (reach `source` over the network — export or client
  side depending on which host is asking), or `"none"` (declared, not
  delivered here today).

`nixstorage.reconciler.*` (`modules/reconciler.nix` — real; converges
ownership + top-directory mode only, via `modules/reconcile.sh`):

- `enable` — install `nixstorage-reconcile` and render its config; with no
  `onCalendar` set, it only ever runs on manual invocation.
- `onCalendar` (default `null`) — a systemd `OnCalendar=` for a recurring
  timer. No guessed default cadence — how often unattended `chown`/`chmod`
  is allowed to run against real data is an operational decision, not a
  value this module picks for you.
- `dryRun` (default `false`) — pass `--dry-run` to every *scheduled* run
  (a manual invocation can always add the flag itself regardless).
- `ownership.<path>` — a tree ROOT, keyed by absolute filesystem path.
  `owner`/`group` are each either a literal numeric uid/gid **string**, or
  a name resolved against `nixid.posix.identities`/`.groups` (checked by
  assertion, not left to fail as a raw missing-attribute trace). `mode` —
  full 4-digit octal string (e.g. `"2750"`), applied to the top directory
  only, ever; if the matching `nixstorage.shape.datasets` entry sets
  `subtreeMountable = true`, the o+x bit is forced into the *effective*
  mode actually written, regardless of what's typed here. `recurse` (no
  default — every root needs a considered answer) — `true` sweeps
  ownership through every file underneath too; `false` chowns/chmods the
  top directory only, leaving descendants entirely to `leaves`.
  `reconcile` (default `true`) — `false` keeps this root fully declared
  and asserted-against but never touched; if `owner` names an identity,
  that identity's *own* `reconcile` flag is also consulted, and the more
  restrictive of the two wins.
- `leaves.<path>` — an app LEAF, keyed by absolute filesystem path, always
  swept recursively, after every root, shallowest-path-first (so a leaf
  nested inside a root — or inside a broader leaf — always re-wins its
  own content last). `identity` — a name in `nixid.posix.identities`,
  **no numeric escape hatch** (see [Why nixstorage depends on
  nixid](#why-nixstorage-depends-on-nixid-and-never-the-reverse) for why
  leaves specifically have none). `mode` — same 4-digit form as
  `ownership.<path>.mode`. Whether this pass may touch the leaf at all is
  controlled *entirely* by that identity's own `reconcile` flag — there is
  no separate per-leaf override.
- `prune` — extra absolute paths no recursive pass may descend beneath,
  merged automatically with every `nixstorage.shape.datasets.<name>.prune
  = true` dataset and every root/leaf whose *effective* `reconcile` is
  `false` (so a carve-out nested under a recursing root is never silently
  re-clobbered by that root's own sweep). A path that is both actively
  reconciled *and* in the effective prune set is an assertion failure —
  `prune` means genuinely hands-off, not "reconciled independently".

`nixid.posix.identities.<name>` (a different repo — not yet shipped; the
shape below is `modules/reconciler.nix`'s own declared cross-repo contract,
not this scaffold's invention):

- `uid`, `gid` (`null` default — a User Private Group, numerically equal
  to `uid`) — the on-disk ownership a `nixstorage.reconciler` leaf (or a
  root naming this identity) resolves to.
- `variant` — `"native"` (runs directly as its own non-root uid) or
  `"puid"` (an s6-overlay/linuxserver.io-style image: starts root, drops
  privilege itself via `PUID`/`PGID`). Decides which half of
  `nixid.posix.podSecurity.<name>` a leaf's invariant is checked against —
  `.pod.runAsUser`/`.runAsGroup` for `"native"`, `.env.PUID`/`.PGID` (as
  strings) for `"puid"`.
- `reconcile` (default `true`) — `false` marks an identity that is fully
  declared and still consistency-checked (its own uid/podSecurity
  invariant is asserted regardless) but never applied by
  `nixstorage.reconciler`, because something else already owns that
  identity's data lifecycle end to end — a database engine's own
  normalization process is the canonical example. The same "declared, not
  converged" carve-out concept as `nixstorage.shape.datasets.<name>.class
  = null`, one layer over, on the RIGHTS side instead of SHAPE.
- `nixid.posix.groups.<name> -> gid` — a plain shared-group table,
  independent of any one identity; `nixstorage.reconciler.ownership.
  <path>.group` may reference either this table or an identity's own
  resolved gid.
- `nixid.posix.podSecurity.<name>` — read-only, entirely derived from the
  matching `identities.<name>` entry; not something a consumer sets.

## Repository layout

| Path | What |
|---|---|
| `flake.nix` | `nixosModules.{shape,delivery,reconciler}` + `.default`; same trio under `systemManagerModules.*` |
| `modules/shape.nix` | dataset classes + datasets: `recordsize`/`compression` convergence, `subtreeMountable`, `prune` |
| `modules/delivery.nix` | categories: `source`/`home`/`xdg`/`scope`/`mount` |
| `modules/reconciler.nix` | Nix side: `nixstorage.reconciler` options, renders the JSON `reconcile.sh` reads |
| `modules/reconcile.sh` | runtime side: the actual idempotent `chown -h`/`chmod` pass, roots-then-leaves, mis-owned-only |
| `examples/host/` | a minimal composed system exercising every implemented option, used by `nix flake check` |
| `experiments/` | open questions and unmeasured defaults |
| `studies/` | write-ups, including the traversability measurement above |
| `LICENSE` | MIT |

## Status

**Pre-alpha, split still landing.** `modules/shape.nix`, `modules/delivery.nix`,
and `modules/reconciler.nix` (+ `modules/reconcile.sh`, its runtime half)
are all real, checked-in — pure schema and eval-time assertion for the
first two, an actual idempotent `chown -h`/`chmod` pass for the third:
roots swept before leaves, leaves sorted shallowest-path-first so nesting
resolves correctly, mis-owned-only comparisons so a converged tree costs
one `find` walk and zero syscalls in steady state, `-h` always (never
following a symlink — see `reconcile.sh`'s own header for the real
incident this specific flag traces back to), and a `reconcile = false`
carve-out reported, never acted on. All three were extracted and
generalized from a working deployment's own dataset-class, category, and
ownership maps, every site-specific value replaced with a generic one.

**Known gap, stated plainly rather than glossed over:** `reconciler.nix`,
as it stands, converges **ownership and top-directory mode only** — it
does not itself run `zfs set recordsize=…`/`compression=…` against
anything in `nixstorage.shape.classes`/`.datasets`. `shape.nix`'s own
header describes that convergence as "a reconciler consuming this data"'s
job; whether that becomes a fourth piece of this repo or folds into
`reconciler.nix` itself is genuinely open, not decided by this scaffold.

The RIGHTS half of the design — `nixid.posix.identities.<name>` (uid/gid/
variant/reconcile) plus its derived `nixid.posix.podSecurity.<name>`
twin — has not shipped in
[nixid](https://github.com/julian-corbet/nixid-corbet-ch) yet.
`examples/host/configuration.nix` and this README's Quickstart show the
intended shape of it, written directly against the cross-repo contract
`modules/reconciler.nix` itself already declares in its own header (not
invented independently of it) — but until `nixid.posix` actually ships,
`nix flake check` will not pass; `modules-evaluate`'s job once it does is
exactly what it is in every sibling repo here: catch a type error, a
failed assertion, or an option rename across the whole composed system at
once.

- [x] `nixosModules.shape` (`modules/shape.nix`)
- [x] `nixosModules.delivery` (`modules/delivery.nix`)
- [x] `nixosModules.reconciler` (`modules/reconciler.nix` + `modules/reconcile.sh`) — ownership/mode only, see the gap noted above
- [ ] a reconciler for `nixstorage.shape`'s own `recordsize`/`compression` model
- [ ] `nixid.posix` (a different repo — the RIGHTS half of this same design)

## Related projects

`nixstorage` is one of several small, independently-usable open-source
projects sharing a common design system:
[nixid](https://github.com/julian-corbet/nixid-corbet-ch) (the identity
half of this exact split — RIGHTS, exposed as `nixid.posix.identities` and
consumed here by name, never the reverse),
[nixshare](https://github.com/julian-corbet/nixshare-corbet-ch)
(actually mounts what a `delivery.nix` category with `mount = "nfs"`
describes), [nixbackup](https://github.com/julian-corbet/nixbackup-corbet-ch)
(ZFS backup-destination discipline — a sibling in spirit, same "hard-won
rules as enforced modules, not documentation to remember" shape), and
[nixnas](https://github.com/julian-corbet/nixnas) (the appliance this
model was extracted out of). Use any of them together or standalone.

## License

MIT.
