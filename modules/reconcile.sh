# nixstorage-reconcile — see modules/reconciler.nix's header for the full
# design story and the cross-module contract this file is the runtime half
# of. Deliberately kept as one plain, readable script (open it, diff it,
# `bash -n` it in one sitting) rather than generated Nix -- same choice this
# family's own private ancestor reconciler made, for the same reason: this
# is the one place in nixstorage where "can a human read the actual
# chown/chmod calls" matters more than everything being Nix-native.
#
# No shebang line here on purpose: this file is concatenated into a real
# script by reconciler.nix's `pkgs.writeShellScriptBin`, which supplies its
# own `#!${stdenv.shell}` as line 1 -- a second `#!` line here would just be
# a confusing no-op comment.
#
# Deliberately `set -u` only, NOT `set -e`/`pipefail`. This is the one place
# that departs from "always fail loudly": a `find` walk over a live,
# multi-terabyte, concurrently-mutated tree WILL occasionally hit a single
# file that vanished mid-walk or briefly returns EACCES against one
# path -- that must cost this run ONE logged line, not abort convergence
# for every OTHER declared root/leaf still queued behind it in the same
# invocation. `-u` alone still catches the actual class of bug this script
# needs caught: a typo'd/renamed shell variable silently expanding to
# nothing and turning a scoped `chown` into an unscoped one.
set -u

CFG="${NIXSTORAGE_RECONCILE_CONFIG:-/etc/nixstorage/reconcile.json}"
DRYRUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRYRUN=1 ;;
    *)
      echo "nixstorage-reconcile: unknown argument '$arg' (only --dry-run is recognized)" >&2
      exit 2
      ;;
  esac
done
# Environment override wins alongside the flag -- lets the SAME systemd
# unit definition be flipped into observe-only mode via a drop-in
# (Environment=NIXSTORAGE_RECONCILE_DRYRUN=1) without touching the CLI
# invocation nixstorage.reconciler.nix renders.
[ "${NIXSTORAGE_RECONCILE_DRYRUN:-0}" = "1" ] && DRYRUN=1

LOG() { echo "nixstorage-reconcile: $*" >&2; }

[ -r "$CFG" ] || { LOG "FATAL: $CFG missing or unreadable -- nothing to reconcile against"; exit 1; }
jq -e . "$CFG" >/dev/null 2>&1 || { LOG "FATAL: $CFG is not valid JSON"; exit 1; }
J() { jq -r "$1" "$CFG"; }

[ "$DRYRUN" = "1" ] && LOG "DRY RUN -- printing the plan, changing nothing on disk"

# ── the shared prune predicate, built ONCE ──────────────────────────────
# Every recursive `find` below (root AND leaf passes alike) is handed the
# SAME prune list -- paths that came from nixstorage.reconciler.prune
# directly, from nixstorage.shape.datasets.*.prune (a dataset flagged as
# unsafe to bulk-walk, e.g. drive-managed SMR media), and from every OTHER
# declared root/leaf whose OWN reconcile flag is false (see
# reconciler.nix's `allPrune` for why: a carve-out nested under a
# recursing root has to be excluded from that root's own walk, or the
# root's recursive chown would silently "fix" the carve-out's ownership
# right back out from under whatever legitimately owns it, on every
# single run -- the two mechanisms would otherwise fight forever).
#
# Kept as an array of `-path X -prune -o` triples so it can be spliced
# directly in front of any `find` predicate below -- an EMPTY array
# splices in as nothing at all (`"${PRUNE_ARGS[@]}"` with zero elements
# expands to zero words under `set -u`, not an error), so the common case
# of no prune entries costs nothing extra.
PRUNE_ARGS=()
while IFS= read -r p; do
  [ -n "$p" ] && PRUNE_ARGS+=( -path "$p" -prune -o )
done < <(J '.prune[]?')

# ── chown: RECURSIVE, mis-owned-only, never dereferencing a symlink ─────
# Three rules bundled into one function because getting any one of them
# wrong reintroduces a real incident:
#
#   1. RECURSES. Unlike chmod below, ownership genuinely needs to reach
#      every file underneath a tree root -- the live uid-that-must-change
#      is in the CONTENT, not just the top directory.
#   2. MIS-OWNED ONLY (`find … ! -uid U -o ! -gid G … | xargs chown`,
#      never a blanket `chown -R`). This is what makes the whole pass
#      idempotent AND near-free in steady state: a tree that already
#      matches the model touches nothing, so running this on a schedule
#      against unchanged data costs one `find` stat-walk, not one `chown`
#      syscall per file every single time.
#   3. `-h`, ALWAYS. A plain `chown` follows a symlink and chowns its
#      TARGET, not the link itself. Field data, anonymized: a symlink left
#      inside a reconciled tree pointed at the filesystem root; the very
#      next ownership pass walked into it, `chown`'d "/" to the tree's
#      uid/gid, and `sshd`'s own `StrictModes` check (which refuses to
#      authenticate against a world/group-writable path anywhere in a
#      user's home ownership chain, and effectively checks upward from
#      "/") then locked every account on that host out simultaneously.
#      `-h` acts on the link itself and never follows it -- the single
#      most load-bearing flag in this entire script.
do_chown_recursive() {
  local path="$1" uid="$2" gid="$3" n
  if [ "$DRYRUN" = "1" ]; then
    n=$(find "$path" "${PRUNE_ARGS[@]}" \( ! -uid "$uid" -o ! -gid "$gid" \) -print0 2>/dev/null \
        | tr -cd '\0' | wc -c)
    LOG "PLAN chown -h -R $uid:$gid $path ($n mis-owned path(s), prune- and mis-owned-only)"
  else
    find "$path" "${PRUNE_ARGS[@]}" \( ! -uid "$uid" -o ! -gid "$gid" \) -print0 2>/dev/null \
      | xargs -0r chown -h "$uid:$gid"
    LOG "chown -h -R $uid:$gid $path (prune- and mis-owned-only)"
  fi
}

# ── chmod: TOP DIRECTORY ONLY, never -R ─────────────────────────────────
# This is the other half of what makes flipping ONE bit on a tree root
# (the exact thing nixstorage.shape.datasets.*.subtreeMountable does --
# see reconciler.nix) a single, instant, one-directory operation instead
# of a recursive rewrite of every mode bit on every file underneath a
# tree that can hold millions of them. A recursive chmod would also be
# actively WRONG here regardless of cost: forcing a directory's own mode
# (2750, 2751, whatever) onto ordinary DATA FILES underneath it would make
# every plain file in the tree setgid and group-executable too, which is
# never what "make this tree traversable" was asking for.
do_chmod_topdir() {
  local path="$1" mode="$2" cur
  cur=$(stat -c '%a' "$path" 2>/dev/null) || { LOG "chmod: $path unreadable via stat -- skip"; return 0; }
  [ "$cur" = "$mode" ] && return 0
  if [ "$DRYRUN" = "1" ]; then
    LOG "PLAN chmod $mode $path (top directory only; currently $cur)"
  else
    chmod "$mode" "$path" && LOG "chmod $mode $path (top directory only; was $cur)"
  fi
}

do_chown_topdir() {
  local path="$1" uid="$2" gid="$3" cur
  cur=$(stat -c '%u:%g' "$path" 2>/dev/null) || { LOG "chown: $path unreadable via stat -- skip"; return 0; }
  [ "$cur" = "$uid:$gid" ] && return 0
  if [ "$DRYRUN" = "1" ]; then
    LOG "PLAN chown -h $uid:$gid $path (top directory only; currently $cur)"
  else
    chown -h "$uid:$gid" "$path" && LOG "chown -h $uid:$gid $path (top directory only; was $cur)"
  fi
}

# ── PASS 1: roots, BEFORE owners ─────────────────────────────────────────
# A human/general tree can legitimately contain app leaves nested inside
# it (an app's data directory living inside a broader shared tree). Roots
# run FIRST and sweep the ENTIRE tree (content included, when `recurse` is
# true) to the tree's own owner -- INCLUDING any nested app leaf, which
# this pass does not and cannot know is special. Pass 2 runs after and
# re-wins every nested leaf back to its own app identity. Reversing this
# order would let a root's sweep run LAST and silently reclaim every app
# leaf underneath it on every single run.
#
# `recurse=false` roots (a container/app PARENT directory whose own
# children are entirely owned by the leaves pass, never by the parent
# itself) get chown applied to the top directory ONLY, via the exact same
# do_chown_topdir/do_chmod_topdir the leaves pass uses for its own top
# directory -- there is no separate "shallow root" code path, just the
# same two primitives used without the recursive one.
J '.roots | to_entries[] | select(.value.reconcile != false) | [.key, .value.uid, .value.gid, .value.mode, .value.recurse] | @tsv' |
while IFS=$'\t' read -r path uid gid mode recurse; do
  if [ ! -d "$path" ]; then
    LOG "root $path declared but absent on disk -- skip (not this script's job to create it)"
    continue
  fi
  if [ "$recurse" = "true" ]; then
    do_chown_recursive "$path" "$uid" "$gid"
  else
    do_chown_topdir "$path" "$uid" "$gid"
  fi
  do_chmod_topdir "$path" "$mode"
done

# ── PASS 2: leaves, AFTER roots, SHALLOW → DEEP ──────────────────────────
# Sorted by path length ascending (mirrors `sort_by(.key|length)` on the
# private ancestor this was extracted from) so that if one declared leaf
# is nested inside another declared leaf (a sub-app's own data directory
# living inside a broader app's tree), the OUTER one is chowned first and
# the INNER one is chowned second and therefore WINS -- last write to any
# given file's ownership is always the most specific, most-nested
# declaration that claims it, never the broadest one.
J '.leaves | to_entries | map(select(.value.reconcile != false)) | sort_by(.key | length) | .[] | [.key, .value.uid, .value.gid, .value.mode] | @tsv' |
while IFS=$'\t' read -r path uid gid mode; do
  if [ ! -d "$path" ]; then
    LOG "leaf $path declared but absent on disk -- skip"
    continue
  fi
  do_chown_recursive "$path" "$uid" "$gid"
  do_chmod_topdir "$path" "$mode"
done

# ── carve-outs: reported, never touched ──────────────────────────────────
# reconcile=false entries were already excluded from both passes above by
# the `select(.value.reconcile != false)` filters -- this is purely
# observability, so `status`-style output (and a dry run) shows what's
# DELIBERATELY not being managed, not just silence that looks identical
# to "nothing needed fixing".
J '.roots | to_entries[] | select(.value.reconcile == false) | .key' | while IFS= read -r path; do
  LOG "carve-out: root $path declared but reconcile=false -- never chowned/chmodded by this pass"
done
J '.leaves | to_entries[] | select(.value.reconcile == false) | .key' | while IFS= read -r path; do
  LOG "carve-out: leaf $path declared but reconcile=false -- never chowned/chmodded by this pass"
done

LOG "done"
