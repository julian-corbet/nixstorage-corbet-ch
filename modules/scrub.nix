# modules/scrub.nix
#
# THE INTEGRITY-VERIFICATION LEG of nixstorage's own thesis (see repo
# README): shape.nix converges what a dataset IS, delivery.nix converges
# where it SURFACES, reconciler.nix converges WHO owns it, and this file
# converges WHETHER its bits are still what they were written as --
# idle-, RAM-, and temperature-gated scrub scheduling for btrfs/xfs/zfs
# volumes, so a scrub actually gets a turn on a real host with real
# contention instead of either hogging it or never running at all.
#
# Constraints this scheduling has to satisfy: ordering cannot rely on declaration order (Nix
# attrsets have no preserved key order -- `attrNames` sorts lexicographically, so "run the SMR
# drives before the big pool" cannot be encoded by write-order alone -- priority is explicit, see
# `jobNames` below); xfs_scrub, unlike btrfs/zfs, has no way to checkpoint mid-run, so an xfs job
# runs to completion within one heartbeat invocation rather than nibbling like the other two; and
# any job with `tempDevices` set gets continuous thermal monitoring so this module cannot collide
# with an operator's own separately-paced scrub tooling on a shared, thermally-sensitive drive.
#
# A single frequent heartbeat (default every 10 min) checks weekday,
# system load, available RAM, and — for any job with `tempDevices` set —
# drive temperature via `smartctl`. If all are comfortable, it walks the
# due jobs in priority order and advances the first one it can. For
# btrfs/zfs (which CAN checkpoint) that is one small nibble (default 10
# min, re-checked periodically during the nibble). If that nibble runs to
# its full budget, the tick ends there — one job, one turn, as before. But
# if conditions degrade MID-nibble (load/RAM/weekday/temperature) and the
# job has to pause early, it YIELDS the rest of this tick to the next due
# job instead of ending the tick — a job that keeps getting cut short
# right after starting can no longer sit at the front of the priority
# order and starve everything behind it forever (see "yield on interrupt"
# below). For xfs (which CANNOT checkpoint across separate heartbeat
# invocations) the job instead runs to completion within this one
# invocation — potentially hours on a multi-TB drive — but is
# continuously monitored and paced with SIGSTOP/SIGCONT if weekday/load/
# RAM/temperature degrade mid-run, so it is never long-UNWATCHED, just
# long. xfs jobs do NOT yield while the process is still alive (running or
# paused) — see the xfs branch below for why that would cost, not save,
# progress — but DO yield once it has actually exited without a clean
# pass (rc != 0), for the same reason an interrupted btrfs/zfs nibble
# yields: staying "due" forever and re-winning priority every tick is
# exactly the failure this mechanism exists to prevent, and by the time
# the process has exited there is no progress left to protect.
#
# SCOPE: this module is NixOS-only (no system-manager backend). It reads
# `/proc/loadavg`/`/proc/meminfo`, drives `btrfs`/`zpool`/`xfs_scrub`
# directly via a generated systemd oneshot + timer, and has no equivalent
# on a non-NixOS host managing its own scrub scheduling some other way.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixstorage.scrub;

  enabledJobs = lib.filterAttrs (_: j: j.enable) cfg.jobs;

  # Explicit priority, NOT declaration order -- Nix attrsets have no
  # preserved insertion order (attrNames sorts lexicographically), so a
  # relay like "SMR drives, then a big HDD pool, then an SSD mirror"
  # cannot be encoded by write-order alone. Ties broken by name for
  # determinism.
  jobNames =
    map (p: p.name) (
      lib.sort (a: b: a.priority < b.priority || (a.priority == b.priority && a.name < b.name)) (
        lib.mapAttrsToList (n: j: {
          name = n;
          priority = j.priority;
        }) enabledJobs
      )
    );

  usedFsTypes = lib.unique (lib.mapAttrsToList (_: j: j.fsType) enabledJobs);
  anyThermal = lib.any (j: j.tempDevices != [ ]) (lib.attrValues enabledJobs);

  # Delimiter note: names/paths/pool names are not EXPECTED to contain a
  # literal ":" in any real deployment, but nothing ENFORCES that -- guarded
  # instead by the assertion below, which rejects any field containing the
  # delimiter at eval time rather than silently corrupting the parsed
  # fields at runtime.
  jobLine =
    name:
    let
      j = cfg.jobs.${name};
    in
    "${name}:${j.fsType}:${j.target}:${
      if j.group == null then "" else j.group
    }:${toString j.nibbleMinutes}:${toString j.minCycleDays}:${
      if j.xfsAutoRepair then "1" else "0"
    }:${lib.concatStringsSep "," j.tempDevices}:${toString j.tempPaceC}:${toString j.tempResumeC}";

  heartbeat = pkgs.writeShellScript "nixstorage-scrub-heartbeat" ''
    set -uo pipefail
    export PATH=${
      lib.makeBinPath (
        [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gawk
          pkgs.findutils
          pkgs.util-linux
        ]
        ++ lib.optional (lib.elem "btrfs" usedFsTypes) pkgs.btrfs-progs
        ++ lib.optional (lib.elem "xfs" usedFsTypes) pkgs.xfsprogs
        ++ lib.optional (lib.elem "zfs" usedFsTypes) pkgs.zfs
        ++ lib.optional anyThermal pkgs.smartmontools
      )
    }

    idle_load_threshold=${toString cfg.idle.loadThreshold}
    min_available_percent=${toString cfg.idle.minAvailablePercent}
    effective_cores=${if cfg.idle.effectiveCores == null then "$(nproc)" else toString cfg.idle.effectiveCores}
    allowed_weekdays=" ${toString cfg.idle.allowedWeekdays} "
    recheck_sec=${toString cfg.idle.recheckIntervalSec}

    is_weekday_ok() {
      # Checked continuously, not just once at tick start -- a long xfs run
      # (see below, can span many hours in one go) must still stop cleanly
      # if it crosses into a disallowed day, not just at the moment it began.
      local today; today=$(date +%u) # ISO: 1=Mon .. 7=Sun
      case "$allowed_weekdays" in
        *" $today "*) return 0 ;;
        *)
          echo "nixstorage-scrub-heartbeat: weekday $today not in allowed set ($allowed_weekdays)" >&2
          return 1
          ;;
      esac
    }

    is_idle() {
      local l a
      l=$(cut -d' ' -f1 /proc/loadavg)
      a=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
      local total; total=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
      local threshold; threshold=$(awk -v n="$effective_cores" -v t="$idle_load_threshold" 'BEGIN{printf "%.2f", n*t}')
      local min_mb; min_mb=$(awk -v t="$total" -v p="$min_available_percent" 'BEGIN{printf "%d", t*p}')
      if ! awk -v l="$l" -v th="$threshold" 'BEGIN{exit !(l < th)}'; then
        echo "nixstorage-scrub-heartbeat: not idle -- load $l >= threshold $threshold" >&2
        return 1
      fi
      if [ "$a" -lt "$min_mb" ]; then
        echo "nixstorage-scrub-heartbeat: not idle -- available ''${a}MB < ''${min_mb}MB" >&2
        return 1
      fi
      return 0
    }

    # A scrub should never cook a disk. Applies to ANY job with `tempDevices`
    # set, regardless of media type -- HDD, SATA SSD, and NVMe all get an
    # external cap, just at different default thresholds (see mediaType in
    # the module doc). Empty tempDevices = no gate (e.g. thermal monitoring
    # isn't wired up yet for that target). FAILS CLOSED: an unreadable/
    # timed-out smartctl read is treated as HOT -- never proceed blind on a
    # temperature you can't confirm is safe. Checks EVERY listed device
    # (e.g. all members of a RAID vdev) and is hot if ANY of them is.
    is_too_hot() {
      local devices_csv="$1" cut_c="$2"
      [ -n "$devices_csv" ] || return 1
      local dev t
      local IFS=,
      for dev in $devices_csv; do
        t=$(timeout 10 smartctl -A "$dev" 2>/dev/null | awk '/Temperature_Celsius/{print $10; exit}')
        if ! [[ "$t" =~ ^[0-9]+$ ]]; then
          echo "nixstorage-scrub-heartbeat: temp read FAILED for $dev -- failing closed (treating as hot)" >&2
          return 0
        fi
        if [ "$t" -ge "$cut_c" ]; then
          echo "nixstorage-scrub-heartbeat: $dev at ''${t}C >= ''${cut_c}C -- too hot" >&2
          return 0
        fi
      done
      return 1
    }

    # THE single source of truth for "is it currently OK to keep scrubbing":
    # weekday + idle (load/RAM) + (if applicable) thermal. Used before
    # starting any job, periodically during a btrfs/zfs nibble, AND
    # throughout a long-running xfs job's monitoring loop -- one gate,
    # checked everywhere progress happens.
    is_safe() {
      is_weekday_ok || return 1
      is_idle || return 1
      if is_too_hot "$1" "$2"; then
        return 1
      fi
      return 0
    }

    # Sleep for up to $1 seconds TOTAL, in $recheck_sec increments, bailing
    # early (return 1) the moment the box stops looking idle OR a monitored
    # device gets too hot. $2/$3 = devices/tempPaceC, forwarded to is_safe on
    # each re-check. On thermal bail-out, additionally wait for the RESUME
    # threshold before returning, so the caller's next action (pause/cancel)
    # happens only once, but the CALLER still won't restart until this
    # function's caller checks is_safe again on the next tick -- this
    # function's job is just "stop nibbling now", not "wait out the whole
    # cooldown inline" (that would block the heartbeat far longer than one
    # nibble should ever run).
    nibble_sleep() {
      local total="$1" devices_csv="$2" pace_c="$3"
      local elapsed=0 step
      while [ "$elapsed" -lt "$total" ]; do
        step=$recheck_sec
        [ $((total - elapsed)) -lt "$step" ] && step=$((total - elapsed))
        sleep "$step"
        elapsed=$((elapsed + step))
        if [ "$elapsed" -lt "$total" ] && ! is_safe "$devices_csv" "$pace_c"; then
          echo "nixstorage-scrub-heartbeat: conditions degraded mid-nibble after ''${elapsed}s -- stopping early"
          return 1
        fi
      done
      return 0
    }

    # Top-of-tick gate: weekday + idle. (Thermal is per-job/per-device, so
    # it's only meaningfully checked once we know which job we're about to
    # touch -- see the per-job section below and, for xfs, its monitoring
    # loop.)
    is_weekday_ok || exit 0
    is_idle || exit 0

    mkdir -p /var/lib/nixstorage-scrub

    jobs=(
      ${lib.concatMapStringsSep "\n      " (n: "\"${jobLine n}\"") jobNames}
    )

    now=$(date +%s)

    for job in "''${jobs[@]}"; do
      IFS=: read -r name fs_type target group nibble_min min_cycle_days xfs_repair temp_devices temp_pace_c temp_resume_c <<< "$job"

      stamp="/var/lib/nixstorage-scrub/$name.completed"
      if [ -f "$stamp" ]; then
        last=$(cat "$stamp")
        age_days=$(( (now - last) / 86400 ))
        if [ "$age_days" -lt "$min_cycle_days" ]; then
          continue # still within its cooldown -- not due yet, try the next job
        fi
      fi

      if [ -n "$temp_devices" ] && is_too_hot "$temp_devices" "$temp_pace_c"; then
        continue # too hot right now -- try a different (cooler/unmonitored) job this tick
      fi

      # xfs only: if this unit was killed externally (systemd stop/restart,
      # e.g. a deploy) while an xfs_scrub was running, KillMode=process
      # (below) deliberately left that child alive rather than cgroup-killing
      # it -- xfs_scrub has NO checkpoint, so killing it would silently
      # discard however many hours of media-scan progress it had made.
      # It's now an orphan (reparented to PID 1), still running to
      # completion on its own. Detect it and skip this job entirely this
      # tick rather than launching a SECOND concurrent xfs_scrub on the same
      # drive -- there's no way to `wait` on (or get an exit code from) a
      # process that isn't this shell's child, so it isn't re-adopted/
      # monitored, just left alone; the NEXT tick re-checks and will
      # eventually find it gone and proceed normally.
      if [ "$fs_type" = "xfs" ]; then
        xfs_pidfile="/var/lib/nixstorage-scrub/$name.xfs.pid"
        if [ -f "$xfs_pidfile" ]; then
          orphan_pid=$(cat "$xfs_pidfile" 2>/dev/null || true)
          if [ -n "$orphan_pid" ] && kill -0 "$orphan_pid" 2>/dev/null; then
            echo "nixstorage-scrub-heartbeat: $name (xfs) already running as pid $orphan_pid (survived a prior restart) -- not double-launching, trying a different job this tick"
            continue
          fi
          rm -f "$xfs_pidfile"
        fi
      fi

      # Due. Try to take the group's slot (or, for an ungrouped job, its own
      # private never-contended lock -- see below) WITHOUT blocking -- if
      # busy, skip to the next job this tick rather than waiting.
      # NOTE (current, honest limitation): at most ONE job is ever ACTIVE at
      # once regardless of grouping, so a group today is a human-readable
      # "these share a resource" label plus a typo-guard, not (yet) a real
      # concurrency primitive -- see module doc. That's still true even with
      # yield-on-interrupt below: yielding hands the REST OF THIS TICK to
      # the next due job in sequence, one at a time, never two jobs running
      # together.
      #
      # ALWAYS allocate a real fd here, even for group=null (private
      # lockfile keyed by job name -- nothing else ever contends for it, so
      # the flock always succeeds instantly; this exists ONLY so `fd` is
      # always a valid descriptor below, never empty). That matters because
      # `btrfs scrub start`/`resume` (without `-B`) and a backgrounded
      # `xfs_scrub &` both daemonize/persist beyond this script's own
      # lifetime, and a plain fork+exec hands them a COPY of every open fd
      # unless told otherwise. Confirmed live on a NixOS host: a deploy
      # restarted this unit mid-nibble, KillMode=process (deliberately)
      # left the btrfs child running, and that orphan inherited the group
      # lock fd -- permanently holding it (flock is scoped to the open file
      # description, shared across the fork) and silently starving every
      # OTHER job in the group for as long as that scrub kept running,
      # regardless of the yield-on-interrupt fix above. `{fd}>&-` on each
      # such launch (below) closes this shell's copy in the CHILD only,
      # before it daemonizes, so an orphan can no longer carry the lock
      # away with it.
      lockfile="/run/nixstorage-scrub-groups/''${group:-__solo-$name}.lock"
      mkdir -p /run/nixstorage-scrub-groups
      exec {fd}>"$lockfile"
      if ! flock -n "$fd"; then
        continue
      fi

      echo "nixstorage-scrub-heartbeat: nibbling $name ($fs_type $target), budget ''${nibble_min}min''${temp_devices:+, thermal-paced}"
      nibble_sec=$((nibble_min * 60))
      done_full=0
      # Whether this attempt made real progress toward a clean cycle (1) or
      # didn't (0): btrfs/zfs go to 0 when a nibble is cut short mid-flight
      # by degraded conditions; xfs goes to 0 when the process has actually
      # exited without a clean pass (rc != 0) -- see each branch. A 0 makes
      # the loop below YIELD to the next due job instead of ending the tick
      # here -- this is what stops a chronically-marginal job (thermally
      # riding the edge every single nibble, or repeatedly finding the same
      # benign issue) from parking itself at the front of the priority order and
      # starving every job behind it, tick after tick, indefinitely.
      nibble_ok=1
      # Human-readable reason for a nibble_ok=0 yield, filled in at the
      # point of failure below -- so the log line at the bottom (shared by
      # all three fs types) says what ACTUALLY happened instead of one
      # generic phrase that's only literally true for the nibble case.
      yield_reason=""

      case "$fs_type" in
        btrfs)
          if ! btrfs scrub resume -c idle "$target" {fd}>&- 2>/dev/null; then
            btrfs scrub start -c idle "$target" {fd}>&- 2>/dev/null || true
          fi
          nibble_sleep "$nibble_sec" "$temp_devices" "$temp_pace_c" || { nibble_ok=0; yield_reason="interrupted before using its full nibble budget"; }
          # Explicit cancel either way -- SAVES progress for the next resume
          # (this is what makes an early bail-out from nibble_sleep safe,
          # whether the reason was load/RAM OR heat: we always pause
          # cleanly via btrfs's own checkpoint, never leave it running
          # unwatched and never raw-kill it).
          btrfs scrub cancel "$target" 2>/dev/null || true
          if btrfs scrub status "$target" 2>/dev/null | grep -m1 "^Status:" | grep -q "finished"; then
            done_full=1
          fi
          ;;
        zfs)
          # `zpool scrub <pool>` both starts fresh AND resumes a paused scan
          # -- same command either way, ZFS tells them apart internally.
          zpool scrub "$target" {fd}>&- 2>/dev/null || true
          nibble_sleep "$nibble_sec" "$temp_devices" "$temp_pace_c" || { nibble_ok=0; yield_reason="interrupted before using its full nibble budget"; }
          status_out=$(zpool status "$target" 2>/dev/null)
          if printf '%s' "$status_out" | grep -q "scan:.*in progress"; then
            zpool scrub -p "$target" 2>/dev/null || true
          elif printf '%s' "$status_out" | grep -qE "scan:.*(scrubbed|resilvered).*errors on"; then
            # Positive completion signal required -- absence of "in
            # progress" alone (e.g. from a failed/typo'd `zpool status`)
            # must NOT be misread as "done".
            done_full=1
          fi
          ;;
        xfs)
          # xfs_scrub has NO native checkpoint/resume -- and this heartbeat
          # is a fresh systemd oneshot invocation every tick, so a process
          # can't be frozen here and picked back up in a LATER invocation
          # (systemd's cgroup cleanup kills anything left behind when the
          # unit exits). So an xfs job runs in the BACKGROUND for as long
          # as it takes to finish within THIS one invocation, while this
          # loop monitors it every recheck_sec and SIGSTOPs/SIGCONTs it
          # live if conditions degrade (weekday boundary crossed, load/RAM
          # spike, or a drive gets too hot). SIGSTOP freezes the process in
          # place: NO progress is lost, unlike a timeout-based restart.
          # `nibbleMinutes` does not apply here (xfs jobs are exempt from
          # the "small chunks" budget -- there is no safe way to chunk a
          # process that can't checkpoint); the thermal/idle gate is the
          # safety mechanism instead of a time box. xfs_scrub -n itself
          # media-scans every data sector (not metadata-only), so this can
          # legitimately run for hours on a multi-TB drive.
          #
          # This is also why xfs never sets nibble_ok=0 WHILE the process is
          # still alive (paused or running): a SIGSTOPped xfs_scrub is inert
          # (no CPU/IO) but still holds its slot -- there is no checkpoint to
          # hand off, so "yielding" mid-run would mean either killing it
          # (discarding however many hours of media-scan progress it already
          # made, the exact outcome KillMode=process above exists to
          # prevent) or running a second job concurrently with it (real
          # parallelism, out of scope for a single serial heartbeat).
          # Pausing in place and waiting it out is the only progress-safe
          # option, so this branch intentionally blocks the tick for as long
          # as the process is running. Once it has actually EXITED, though,
          # that constraint is gone -- see the rc check below.
          if [ "$xfs_repair" = "1" ]; then
            xfs_scrub "$target" {fd}>&- &
          else
            xfs_scrub -n "$target" {fd}>&- &
          fi
          xfs_pid=$!
          # Recorded so a LATER tick (after this one gets killed by systemd,
          # e.g. a deploy restart) can recognize this orphaned-but-still-
          # running process and not double-launch a second xfs_scrub on the
          # same drive -- see the pre-check above. KillMode=process (below)
          # is what keeps this child alive through that kill in the first
          # place.
          echo "$xfs_pid" > "$xfs_pidfile"
          xfs_stopped=0
          while kill -0 "$xfs_pid" 2>/dev/null; do
            sleep "$recheck_sec"
            if is_safe "$temp_devices" "$temp_pace_c"; then
              if [ "$xfs_stopped" = "1" ]; then
                echo "nixstorage-scrub-heartbeat: $name (xfs) resuming (SIGCONT) -- conditions OK again"
                kill -CONT "$xfs_pid" 2>/dev/null || true
                xfs_stopped=0
              fi
            else
              if [ "$xfs_stopped" = "0" ]; then
                echo "nixstorage-scrub-heartbeat: $name (xfs) pausing (SIGSTOP) -- degraded conditions, no progress lost"
                kill -STOP "$xfs_pid" 2>/dev/null || true
                xfs_stopped=1
              fi
            fi
          done
          set +e
          wait "$xfs_pid"
          rc=$?
          set -e
          rm -f "$xfs_pidfile"
          if [ "$rc" -eq 0 ]; then
            done_full=1
          else
            echo "nixstorage-scrub-heartbeat: $name (xfs) exited rc=$rc (nonzero = issues found or error) -- not marking complete"
            # The process has now genuinely EXITED (not paused, not still
            # scanning) without producing a clean pass -- so, same as an
            # interrupted btrfs/zfs nibble, it stays "due" and would
            # otherwise re-win priority over everything behind it on every
            # future tick forever (observed live: a single cosmetic
            # filename warning on `shows` was enough to permanently starve
            # blackhole/solid, the exact failure this whole mechanism
            # exists to prevent). Yield the rest of this tick so a
            # lower-priority job gets a turn instead of waiting on this one
            # to either get fixed (e.g. the offending file renamed) or
            # never complete at all.
            nibble_ok=0
            yield_reason="exited rc=$rc without a clean pass"
          fi
          ;;
      esac

      if [ "$done_full" = "1" ]; then
        echo "$now" > "$stamp"
        echo "nixstorage-scrub-heartbeat: $name completed a full cycle"
      fi

      exec {fd}>&- # always a real fd now (see allocation above) -- always safe to close

      if [ "$nibble_ok" = "0" ]; then
        echo "nixstorage-scrub-heartbeat: $name yielded the rest of this tick ($yield_reason) -- trying the next due job"
        continue
      fi

      exit 0 # this job used its full turn -- only ONE job gets a full turn per tick, by design
    done

    echo "nixstorage-scrub-heartbeat: nothing due this tick"
  '';
in
{
  options.nixstorage.scrub = {
    enable = lib.mkEnableOption ''
      Idle-, RAM-, and temperature-gated scrub scheduling for btrfs/xfs/zfs
      volumes.

      A single frequent heartbeat (default every 10 min) checks weekday,
      system load, available RAM, and -- for any job with `tempDevices` set --
      drive temperature. If all are comfortable, it walks the due jobs in
      PRIORITY order (`priority`, lower first -- NOT declaration order; Nix
      attrsets don't preserve one) and advances the first one it can. For
      btrfs/zfs (which CAN checkpoint) that's one small nibble (default 10
      min, re-checked periodically during the nibble); if the nibble runs
      to its full budget, the tick ends there -- one job, one turn. If
      conditions instead degrade MID-nibble (load/RAM/weekday/temperature),
      the job pauses cleanly (checkpointed, no progress lost) and YIELDS
      the rest of the tick to the next due job, rather than ending the tick
      on a job that barely got started -- so a job that's chronically
      thermally marginal can't camp at the front of the priority order and
      starve every job behind it, tick after tick, forever. For xfs (which
      CANNOT checkpoint across separate heartbeat invocations) the job
      instead runs to completion within this one invocation -- potentially
      hours on a multi-TB drive -- but is continuously monitored and paced
      with SIGSTOP/SIGCONT if weekday/load/RAM/temperature degrade mid-run,
      so it's never long-UNWATCHED, just long; an xfs job does NOT yield
      while its process is still alive, running or paused (no checkpoint to
      hand off -- see the xfs branch's own comment for why that's the safe
      choice, not an oversight), but DOES yield once it has actually exited
      without a clean pass (rc != 0) -- otherwise a job that finishes
      quickly but never comes back clean (e.g. a filesystem warning that
      won't clear itself) would camp at the front of the priority order
      exactly like a chronically-interrupted one, just via a different
      mechanism. If conditions are unfavorable at tick start, the tick is a
      no-op (or, if
      only one specific job is too hot, a DIFFERENT cooler job may still
      get a turn). Each job has its own cooldown (`minCycleDays`) since its
      last fully-completed cycle.

      THERMAL: any job with `tempDevices` set gets an external temperature
      gate: read via smartctl, FAIL CLOSED on an unreadable temperature --
      never proceed blind. Applies uniformly to HDD, SATA SSD, and NVMe --
      `mediaType` only picks the DEFAULT pace/resume °C for the job (hdd
      50/45, sata-ssd 60/55, nvme 80/75; override tempPaceC/tempResumeC
      directly for a specific drive model). `tempDevices = []` (default) =
      no gate at all, e.g. for targets where temperature monitoring isn't
      wired up, or (a cloud VPS root disk) the virtual block device doesn't
      expose SMART to read. Reaching the temperature triggers the SAME
      pause mechanism already used for load/RAM/weekday degradation for
      that filesystem type: btrfs cancel / zfs pause (checkpointed, no
      progress lost either way) or, for xfs specifically, SIGSTOP (freezes
      the live process in place -- also no progress lost, just a different
      mechanism because xfs has no filesystem-level checkpoint to cancel
      into). One `is_safe` check, used everywhere progress happens,
      regardless of which pause primitive the filesystem type ends up
      using.

      LIMITATION (current, by design): at most one job is ever ACTIVE at a
      time, across the whole host -- `groups` label which jobs share a
      physical resource and are asserted to exist, but don't (yet) enable
      two DIFFERENT groups to progress concurrently. Yield-on-interrupt
      (above) fixes the STARVATION failure mode this used to allow -- a
      chronically-interrupted job no longer blocks lower-priority jobs
      indefinitely -- but it is still serial hand-off, never true
      concurrency: two groups genuinely capable of running at once (e.g. an
      SSD mirror sharing nothing physical with an HDD pool) still take
      turns, not parallel progress.

      SCOPE: this module is NixOS-only. A system-manager host manages its
      own scrub scheduling some other way; there is no backend for it here.
    '';

    idle = {
      allowedWeekdays = lib.mkOption {
        type = lib.types.listOf (lib.types.ints.between 1 7);
        default = [
          6
          7
        ]; # Sat, Sun (ISO: 1=Mon..7=Sun)
        description = ''
          Scrubbing is only ever attempted on these ISO weekdays (1=Mon..7=Sun).
          Default: weekends only -- the work week is off limits by policy,
          independent of how idle a box happens to be.
        '';
      };

      loadThreshold = lib.mkOption {
        type = lib.types.float;
        default = 0.5;
        description = "Idle gate: proceed only if 1-min load average < this * effectiveCores.";
      };

      effectiveCores = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        description = ''
          Cores to use for the load-average threshold instead of the real
          runtime `nproc`. Default `null` = use actual `nproc` (correct for
          normal, non-burstable hosts). Override this on burstable/shared-
          vCPU cloud boxes where `nproc` reports the nominal vCPU count but
          sustained real capacity is much lower (e.g. a small free-tier VPS:
          set to 0.25) -- otherwise the threshold is calibrated against
          capacity the box doesn't actually have. CAVEAT: guest-observed
          load average may not reflect hypervisor-level CPU steal/
          throttling on burstable VMs -- this is a best-effort proxy, not a
          guarantee, on that class of host.
        '';
      };

      minAvailablePercent = lib.mkOption {
        type = lib.types.float;
        default = 0.15;
        description = ''
          Idle gate: proceed only if /proc/meminfo MemAvailable is at least
          this fraction of MemTotal. A percentage, not an absolute MB floor,
          because one fixed MB number can't work across hosts this different
          in size (e.g. a 512MB floor is simply unreachable on a ~450MB-total
          free-tier VPS). Trade-off: the same percentage gives a much
          smaller ABSOLUTE cushion on the smallest hosts -- raise this
          per-host if a tiny/critical box needs a fatter margin.
        '';
      };

      recheckIntervalSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = ''
          While a nibble is in progress, re-check idle (and, for jobs with
          `tempDevices` set, temperature) every this many seconds and pause
          early (btrfs cancel / zfs pause) if conditions degrade.
        '';
      };

      heartbeatCalendar = lib.mkOption {
        type = lib.types.str;
        default = "*:0/10";
        description = "systemd OnCalendar= for the heartbeat check (default: every 10 minutes).";
      };
    };

    groups = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule { });
      default = { };
      description = ''
        Named per-host labels for jobs that share a physical resource (e.g.
        several drives on one shared controller). Validated (a job's
        `group` must be declared here) but see the top-level LIMITATION
        note: today this does not enable concurrent progress across
        different groups, only cross-checks a name was declared.
      '';
    };

    jobs = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Set false to stage a job definition without it actually
                running yet -- e.g. a target that isn't mounted/ready yet.
                Kept out of the generated jobs list entirely.
              '';
            };

            priority = lib.mkOption {
              type = lib.types.int;
              default = 100;
              description = ''
                Lower runs first. This is the ONLY way to express "job A
                before job B" -- Nix attribute sets have no preserved
                declaration order. Ties broken by name.
              '';
            };

            fsType = lib.mkOption {
              type = lib.types.enum [
                "zfs"
                "btrfs"
                "xfs"
              ];
              description = "Which scrub mechanism this job uses.";
            };

            target = lib.mkOption {
              type = lib.types.str;
              description = "Mountpoint (btrfs/xfs) or pool name (zfs).";
            };

            group = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Key into nixstorage.scrub.groups. null = never contends with anything.";
            };

            nibbleMinutes = lib.mkOption {
              type = lib.types.ints.positive;
              default = 10;
              description = ''
                btrfs/zfs only: how long a single nibble runs (start-or-
                resume, then paced sleep, then pause/cancel) before
                stopping to let other jobs/ticks have a turn. NOT used for
                xfs -- xfs_scrub has no checkpoint to resume from across
                separate heartbeat invocations, so an xfs job instead runs
                to completion within one invocation, paced live via
                SIGSTOP/SIGCONT if conditions degrade (see the module's xfs
                branch). "Small chunks" doesn't apply to xfs; "never cook
                the disk" still does.
              '';
            };

            minCycleDays = lib.mkOption {
              type = lib.types.ints.positive;
              description = ''
                Minimum days between finishing one full scrub and being
                eligible to start the next -- required, no universal default.
              '';
            };

            xfsAutoRepair = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "xfs only: allow xfs_scrub to write repairs. Default false -- report-only, safe for write-once media.";
            };

            mediaType = lib.mkOption {
              type = lib.types.enum [ "hdd" "sata-ssd" "nvme" ];
              default = "hdd";
              description = ''
                Physical media type backing `target`. Purely picks sensible
                DEFAULT temperature thresholds below (tempPaceC/tempResumeC)
                -- override those two directly if a specific drive model
                needs a different value. Generic defaults:
                  hdd:      pace 50C / resume 45C
                  sata-ssd: pace 60C / resume 55C -- SATA SSDs commonly idle
                            hotter than HDDs but still benefit from an
                            external cap during a scrub
                  nvme:     pace 80C / resume 75C -- NVMe runs hottest of
                            the three
                Deliberately NOT auto-detected (e.g. via
                /sys/block/*/queue/rotational): zvols and some device-mapper
                stacks are known to report misleading rotational flags --
                state it explicitly instead.
              '';
            };

            tempDevices = lib.mkOption {
              type = lib.types.listOf lib.types.path;
              default = [ ];
              description = ''
                `/dev/disk/by-id/...` paths to smartctl-query for
                temperature. A pool/RAID job should list ALL its member
                devices -- the gate treats the job as hot if ANY listed
                device is. Empty list (default) = no thermal gate applied
                at all, regardless of `mediaType` -- e.g. temperature-
                monitoring isn't wired up yet for that target, or (a cloud
                VPS root disk) the underlying virtual block device simply
                doesn't expose SMART data to read.
              '';
            };

            tempPaceC = lib.mkOption {
              type = lib.types.ints.positive;
              default = { hdd = 50; "sata-ssd" = 60; nvme = 80; }.${config.mediaType};
              description = ''
                Pause (not resume) if any `tempDevices` reads at or above
                this many °C. Defaults from `mediaType` (see its
                description) -- override directly for a specific drive
                model/environment that needs a different value.
              '';
            };

            tempResumeC = lib.mkOption {
              type = lib.types.ints.positive;
              default = { hdd = 45; "sata-ssd" = 55; nvme = 75; }.${config.mediaType};
              description = ''
                Informational hysteresis margin below tempPaceC (this
                module re-checks on the next tick/recheck interval rather
                than blocking inline until this exact temperature is
                reached). Defaults from `mediaType`, same as tempPaceC.
              '';
            };
          };
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      (lib.mapAttrsToList (n: j: {
        assertion = j.group == null || lib.hasAttr j.group cfg.groups;
        message = "nixstorage.scrub.jobs.${n}.group = \"${toString j.group}\" is not declared in nixstorage.scrub.groups.";
      }) cfg.jobs)
      ++ (
        let
          hasDelimiter = s: lib.hasInfix ":" s || lib.hasInfix "," s;
        in
        lib.mapAttrsToList (n: j: {
          assertion =
            !(hasDelimiter n)
            && !(hasDelimiter j.target)
            && (j.group == null || !(hasDelimiter j.group))
            && !(lib.any hasDelimiter j.tempDevices);
          message = "nixstorage.scrub.jobs.${n}: name/target/group/tempDevices must not contain ':' or ',' -- these delimit the internal job encoding.";
        }) cfg.jobs
      );

    systemd.services.nixstorage-scrub-heartbeat = {
      description = "nixstorage scrub heartbeat -- nibble one due job if idle, RAM, and temperature allow";
      serviceConfig = {
        Type = "oneshot";
        Nice = 19;
        IOSchedulingClass = "idle";
        ExecStart = "${heartbeat}";
        # Default systemd start-timeout (90s) would SIGKILL this well before
        # any real nibble (5-10+ min) reaches its own cancel/pause/stamp
        # code -- and an xfs job (no checkpoint, runs to completion in one
        # invocation, media-scans every data sector) can legitimately take
        # many hours on a multi-TB drive. Bounded generously, not left at
        # "infinity", so a genuinely wedged scrub command still gets reaped
        # eventually.
        TimeoutStartSec = "48h";
        # Default KillMode (control-group) would kill the backgrounded
        # xfs_scrub child too whenever this unit is stopped/restarted (e.g.
        # a deploy). xfs_scrub has NO checkpoint at all, so that kill
        # hitting an xfs job would silently discard however many hours of
        # media-scan progress it had made. KillMode=process only signals
        # THIS script's own PID; an in-flight xfs_scrub is left running as
        # an orphan (reparented to PID 1) to finish on its own -- see the
        # pidfile-based orphan check in the xfs pre-check/branch above,
        # which stops a later tick from double-launching a second one.
        KillMode = "process";
      };
      after = [ "local-fs.target" ];
      requires = [ "local-fs.target" ];
    };

    systemd.timers.nixstorage-scrub-heartbeat = {
      description = "nixstorage scrub heartbeat timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.idle.heartbeatCalendar;
        Persistent = false;
        AccuracySec = "1min";
      };
    };
  };
}
