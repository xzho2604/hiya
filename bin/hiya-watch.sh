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
The holder drains the wake queue and routes each record to the lease
owner's inbox/ (one file per record, named by zero-padded seq). Records for
unleased tasks, or tasks whose owner is dead, land in the watcher's own
inbox. Non-holders print "watcher held by <sid>" and exit 0.

With --once, run a single drain pass and exit (for tests and demos).
By default, loop with a short sleep (HIYA_WATCH_INTERVAL, default 2s).

The queue itself is append-only; the watcher tracks progress with a cursor
(state/.wake-cursor holding the last routed seq).

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
  holder=$(cat "$(hiya_lockdir watcher)/sid" 2>/dev/null || true)
  printf 'watcher held by %s\n' "${holder:-unknown}"
  exit 0
fi
printf '%s\n' "$sid" > "$(hiya_lockdir watcher)/sid"
trap 'lock_release watcher' EXIT
printf '%s is the watcher\n' "$sid"

# shellcheck disable=SC2329  # invoked indirectly via with_lock
drain_impl() {
  local queue cursor_file cur epoch seq task payload owner dest fname
  queue="$HIYA_HOME/state/wake-queue"
  cursor_file="$HIYA_HOME/state/.wake-cursor"
  cur=$(cat "$cursor_file" 2>/dev/null || printf '0')
  [ -f "$queue" ] || return 0
  while IFS=$'\t' read -r epoch seq task payload; do
    [ -n "$seq" ] || continue
    [ "$seq" -gt "$cur" ] || continue
    owner=$(lease_owner "$task")
    dest=$sid
    if [ -n "$owner" ] && session_alive "$owner"; then
      dest=$owner
    fi
    fname=$(printf '%08d' "$seq")
    printf '%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$task" "$payload" \
      > "$(hiya_session_dir "$dest")/inbox/$fname"
    printf 'routed wake %s (%s) -> %s\n' "$seq" "$task" "$dest"
    cur=$seq
  done < "$queue"
  printf '%s\n' "$cur" > "$cursor_file"
  return 0
}

interval=${HIYA_WATCH_INTERVAL:-2}
while :; do
  # drain under the wake lock so a half-appended record is never read
  with_lock wake drain_impl
  if [ "$once" -eq 1 ]; then
    break
  fi
  sleep "$interval"
done
exit 0
