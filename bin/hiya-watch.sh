#!/usr/bin/env bash
# hiya-watch.sh — watcher election + wake routing.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-watch.sh <sid> [--once] [--help]

Watcher election: try to acquire the singleton watcher lock (non-blocking).
The holder drains the wake queue and routes each record to the inbox/ of the
live session leasing its task (one file per record, named by zero-padded
seq). Records for unleased tasks, or tasks whose owner is dead, are parked in
the home-level state/unrouted/, where the task's next claimant adopts them
(hiya-inbox.sh --unrouted lists them). Non-holders print
"watcher held by <sid>" and exit 0.

With --once, run a single drain pass and exit (for tests and demos).
By default, loop with a short sleep (HIYA_WATCH_INTERVAL, default 2s). Every
pass refreshes <sid>'s heartbeat, so a session that is only watching stays
alive. If <sid> is gone (reaped) the watcher exits non-zero, freeing the
lock so a live session can take over.

The queue itself is append-only; the watcher tracks progress with a cursor
(state/.wake-cursor holding the last routed seq). The cursor moves past a
record only once it has been written, so a record is never dropped: if it
cannot be written anywhere the pass fails and the next pass retries it.
Delivery is therefore at-least-once — a watcher that dies between writing a
record and saving the cursor routes that record again — and the seq is the
idempotency key.

exit status:
  0  drained (or another session is the watcher)
  1  <sid> is gone, or (--once) a record could not be written

environment:
  HIYA_HOME            home directory (default ./home)
  HIYA_WATCH_INTERVAL  seconds between drain passes (default 2)
EOF
}

sid=
once=0
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --once) once=1 ;;
    -*) usage >&2; exit 1 ;;
    *)
      if [ -z "$sid" ]; then sid=$1; else usage >&2; exit 1; fi
      ;;
  esac
  shift
done
if [ -z "$sid" ]; then
  usage >&2
  exit 1
fi

hiya_require_home
session_alive "$sid" || hiya_die "unknown or dead session '$sid' (did you join?)"

if ! lock_acquire watcher 0; then
  holder=$(cat "$(hiya_watcher_sid)" 2>/dev/null || true)
  printf 'watcher held by %s\n' "${holder:-unknown}"
  exit 0
fi
printf '%s\n' "$sid" > "$(hiya_watcher_sid)"
trap 'lock_release watcher' EXIT
printf '%s is the watcher\n' "$sid"

routed_to=
# shellcheck disable=SC2329  # invoked indirectly via with_lock
route_record() {
  # route_record <seq> <task> <record> — write the record where its task
  # lives; sets routed_to. Fails only if it could be written nowhere.
  local owner unrouted name
  owner=$(wake_live_owner "$2")
  if [ -n "$owner" ] && wake_put "$(hiya_session_dir "$owner")/inbox" "$1" "$3"; then
    routed_to=$owner
    return 0
  fi
  # no live owner — or it vanished between the liveness check and the write
  unrouted=$(hiya_unrouted_dir)
  mkdir -p "$unrouted" 2> /dev/null
  wake_put "$unrouted" "$1" "$3" || return 1
  routed_to=unrouted
  # A claim may have landed while the record was on its way here. A claimant
  # adopts unrouted records once, right after it wins, so re-check the owner:
  # either we see the new lease and hand the record over ourselves, or the
  # lease is written later and the claimant's adoption finds the record.
  owner=$(wake_live_owner "$2")
  if [ -n "$owner" ]; then
    printf -v name '%08d' "$1"
    if mv -f "$unrouted/$name" "$(hiya_session_dir "$owner")/inbox/$name" 2> /dev/null \
      || [ ! -e "$unrouted/$name" ]; then
      routed_to=$owner
    fi
  fi
  return 0
}

# shellcheck disable=SC2329  # invoked indirectly via with_lock
drain_impl() {
  local queue cursor_file cur epoch seq task payload rc
  queue="$HIYA_HOME/state/wake-queue"
  cursor_file="$HIYA_HOME/state/.wake-cursor"
  cur=$(cat "$cursor_file" 2>/dev/null || true)
  case $cur in
    ''|*[!0-9]*) cur=0 ;;
  esac
  [ -f "$queue" ] || return 0
  rc=0
  # the queue is read on fd 3 so nothing run inside the loop can eat records
  while IFS=$'\t' read -r epoch seq task payload <&3; do
    case $seq in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$seq" -gt "$cur" ] || continue
    if ! route_record "$seq" "$task" \
      "$(printf '%s\t%s\t%s\t%s' "$epoch" "$seq" "$task" "$payload")"; then
      printf 'hiya-watch: cannot write wake %s (%s) anywhere; will retry\n' \
        "$seq" "$task" >&2
      rc=1
      break
    fi
    printf 'routed wake %s (%s) -> %s\n' "$seq" "$task" "$routed_to"
    # the record is durable: only now may the cursor move past it
    cur=$seq
    printf '%s\n' "$cur" | atomic_write "$cursor_file" || { rc=1; break; }
  done 3< "$queue"
  return "$rc"
}

interval=${HIYA_WATCH_INTERVAL:-2}
while :; do
  # heartbeat every pass: watching IS being alive. A watcher whose session is
  # gone must not linger — it would hold the lock while routing for nobody.
  if ! session_touch "$sid"; then
    printf 'hiya-watch: session %s is gone (reaped?); stepping down\n' "$sid" >&2
    exit 1
  fi
  # drain under the wake lock so a half-appended record is never read
  rc=0
  with_lock wake drain_impl || rc=$?
  if [ "$once" -eq 1 ]; then
    exit "$rc"
  fi
  # the sleep must not inherit the watcher lock: killed mid-sleep, this
  # process would otherwise leave the lock held by its orphaned child
  hiya_unlocked sleep "$interval"
done
