# nixstorage-layout-verify -- see modules/layout.nix's own header for the
# full design story and modules/reconciler.nix's own reconcile.sh for the
# sibling this file's shape is deliberately copied from: one plain,
# readable script (open it, diff it, `bash -n` it in one sitting), no
# shebang (supplied by `pkgs.writeShellScriptBin`), and `set -u` only --
# see below for why `-e` would be actively wrong here too.
#
# WHAT THIS DOES, IN ONE SENTENCE: reads a live device's ACTUAL GPT
# partition table (`sfdisk --json`, a listing command, never a write one)
# and compares it against what `nixstorage.layout` declared. It never
# writes anything, ever -- not to the device this checks, not to the image
# this repo can separately build. A mismatch is reported, never corrected;
# correcting it means re-running the image-write path BY HAND, outside
# this module entirely, the same boundary modules/layout.nix's own header
# draws around every acting piece of this file.
#
# Deliberately `set -u` only, NOT `set -e`/`pipefail` -- same reasoning as
# reconcile.sh's own header: one declared target with an unplugged device,
# or one partition that has genuinely drifted, must cost this run one
# logged FAIL/SKIP line, not abort the whole pass before every OTHER
# declared target gets checked in the same invocation.
set -u

CFG="${NIXSTORAGE_LAYOUT_VERIFY_CONFIG:-/etc/nixstorage/layout-verify.json}"

LOG() { echo "nixstorage-layout-verify: $*" >&2; }

[ -r "$CFG" ] || { LOG "FATAL: $CFG missing or unreadable -- nothing to verify against"; exit 1; }
jq -e . "$CFG" >/dev/null 2>&1 || { LOG "FATAL: $CFG is not valid JSON"; exit 1; }
J() { jq -r "$@" "$CFG"; }

# Alignment rounding tolerance, in MiB -- `nixstorage.layout`'s own image
# builder reserves ~1 MiB for the mandatory leading alignment gap before
# the first partition (measured, not guessed -- see studies/) plus a
# negligible trailing GPT-footer reservation; comparing sizes with a
# little slack is what makes this check about DRIFT, not about re-deriving
# sgdisk's own internal alignment arithmetic here a second time.
TOLERANCE_MIB=1

fail=0

target_count="$(J '.targets | length')"
if [ "$target_count" = "0" ]; then
  echo "SKIP  no nixstorage.layout.verify.targets declared"
  exit 0
fi

while IFS= read -r tname; do
  device="$(J --arg n "$tname" '.targets[$n].device')"

  # Defense in depth, not decoration: the Nix-level assertion on
  # nixstorage.layout.verify.targets.<name>.device already refuses
  # anything that is not a stable /dev/disk/by-* identity before this ever
  # reaches a rendered config file. This is the SAME check again, at
  # runtime, against whatever actually landed on disk -- reconciler.nix's
  # own ancestorTraversalAssertions duplicates shape.nix's own check for
  # the identical reason: never trust a config file to still say what the
  # Nix eval that produced it said.
  case "$device" in
    /dev/disk/by-*) : ;;
    *)
      echo "FAIL  ${tname}: device '$device' is not a /dev/disk/by-* path -- refusing to resolve it at all"
      fail=1
      continue
      ;;
  esac

  resolved="$(readlink -f "$device" 2>/dev/null)"
  if [ -z "$resolved" ] || [ ! -e "$resolved" ]; then
    echo "SKIP  ${tname}: $device does not currently resolve to anything -- device not attached right now"
    continue
  fi
  if [ ! -b "$resolved" ] && [ ! -f "$resolved" ]; then
    echo "FAIL  ${tname}: $device resolves to $resolved, which is neither a block device nor a plain file"
    fail=1
    continue
  fi

  table_json="$(sfdisk --json "$resolved" 2>/dev/null)"
  if [ -z "$table_json" ]; then
    echo "FAIL  ${tname}: sfdisk could not read a GPT partition table from $device ($resolved)"
    fail=1
    continue
  fi

  actual_count="$(echo "$table_json" | jq '.partitiontable.partitions | length')"
  expected_count="$(J --arg n "$tname" '.targets[$n].partitions | length')"
  if [ "$actual_count" != "$expected_count" ]; then
    echo "FAIL  ${tname}: declared ${expected_count} partition(s), $device ($resolved) actually has ${actual_count}"
    fail=1
    continue
  fi
  echo "PASS  ${tname}: partition count matches (${actual_count})"

  i=0
  while [ "$i" -lt "$expected_count" ]; do
    idx1=$((i + 1))

    exp_name="$(J --arg n "$tname" --argjson i "$i" '.targets[$n].partitions[$i].name')"
    exp_guid="$(J --arg n "$tname" --argjson i "$i" '.targets[$n].partitions[$i].typeGuid')"
    exp_size="$(J --arg n "$tname" --argjson i "$i" '.targets[$n].partitions[$i].sizeMiB')"

    act_name="$(echo "$table_json" | jq -r ".partitiontable.partitions[$i].name // empty")"
    act_guid="$(echo "$table_json" | jq -r ".partitiontable.partitions[$i].type")"
    act_sectors="$(echo "$table_json" | jq -r ".partitiontable.partitions[$i].size")"
    act_size_mib=$(( act_sectors * 512 / 1024 / 1024 ))

    if [ "$act_name" = "$exp_name" ]; then
      echo "PASS  ${tname}[${idx1}]: name '${exp_name}'"
    else
      echo "FAIL  ${tname}[${idx1}]: declared name '${exp_name}', device has '${act_name}'"
      fail=1
    fi

    exp_guid_lc="$(printf '%s' "$exp_guid" | tr 'A-Z' 'a-z')"
    act_guid_lc="$(printf '%s' "$act_guid" | tr 'A-Z' 'a-z')"
    if [ "$act_guid_lc" = "$exp_guid_lc" ]; then
      echo "PASS  ${tname}[${idx1}]: type GUID ${exp_guid}"
    else
      echo "FAIL  ${tname}[${idx1}]: declared type GUID ${exp_guid}, device has ${act_guid}"
      fail=1
    fi

    if [ "$exp_size" = "null" ]; then
      echo "SKIP  ${tname}[${idx1}]: sizeMiB not asserted (declared to consume the remainder of the image)"
    else
      if [ "$act_size_mib" -ge "$exp_size" ]; then
        diff=$((act_size_mib - exp_size))
      else
        diff=$((exp_size - act_size_mib))
      fi
      if [ "$diff" -le "$TOLERANCE_MIB" ]; then
        echo "PASS  ${tname}[${idx1}]: size ~${act_size_mib} MiB (declared ${exp_size} MiB)"
      else
        echo "FAIL  ${tname}[${idx1}]: declared ${exp_size} MiB, device reports ~${act_size_mib} MiB (diff ${diff} MiB, over the ${TOLERANCE_MIB} MiB alignment tolerance)"
        fail=1
      fi
    fi

    i=$((i + 1))
  done
done < <(J '.targets | keys[]')

if [ "$fail" -ne 0 ]; then
  LOG "at least one declared layout did not match live media (see FAIL lines above). This tool never writes anything back -- fixing drift means re-running the image-write path by hand, outside this module entirely."
  exit 1
fi

LOG "every declared target matches live media."
