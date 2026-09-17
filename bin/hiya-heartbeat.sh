#!/usr/bin/env bash
# hiya-heartbeat.sh — refresh own liveness, then reap expired sessions.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-heartbeat.sh <sid> [--help]

Touch <sid>'s heartbeat file (mtime = liveness), then reap: any session whose
heartbeat is older than HIYA_SESSION_TTL seconds is expired. An expired
session's leases are released back to "queued", its session dir is archived
under state/sessions/.dead/<sid>.<epoch>, and the wakes it never drained
follow their tasks: to the inbox of the task's live owner if it has one (the
task was handed over), else to state/unrouted/, where the task's next
claimant adopts them.

The same pass sweeps orphan leases — leases whose owner has no session at
all — back to "queued".

Run this periodically from every live session; any session's heartbeat pass
reaps on behalf of the whole home.

environment:
  HIYA_HOME         home directory (default ./home)
  HIYA_SESSION_TTL  heartbeat age in seconds before a session is declared
                    dead (default 120)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -ne 1 ]; then
  usage >&2
  exit 1
fi

sid=$1
hiya_require_home
session_touch "$sid" || hiya_die "unknown or dead session '$sid' (did you join?)"
printf 'heartbeat %s\n' "$sid"

reap_impl() {
  local now d s hb mt age lf task owner released dead f seq dest
  now=$(hiya_now)
  for d in "$(hiya_sessions_dir)"/*/; do
    [ -d "$d" ] || continue
    s=$(basename "$d")
    hb="$d/heartbeat"
    [ -f "$hb" ] || continue
    mt=$(hiya_mtime "$hb") || continue
    age=$(( now - mt ))
    [ "$age" -gt "$HIYA_SESSION_TTL" ] || continue
    released=
    for lf in "$HIYA_HOME/state/leases"/*; do
      [ -f "$lf" ] || continue
      [ "$(awk -F= '$1 == "owner" { print $2 }' "$lf")" = "$s" ] || continue
      task=$(basename "$lf")
      rm -f "$lf"
      backlog_set_state "$task" queued
      released="$released $task"
    done
    # archive FIRST: once the dir is gone from sessions/ nothing new can land
    # in its inbox, so the sweep below sees every record it ever received
    dead="$(hiya_sessions_dir)/.dead/$s.$now"
    mv "$d" "$dead" || continue
    printf 'reaped %s (heartbeat %ss old)' "$s" "$age"
    if [ -n "$released" ]; then
      printf '; released:%s' "$released"
    fi
    printf '\n'
    for f in "$dead/inbox"/*; do
      [ -f "$f" ] || continue
      seq=${f##*/}
      case $seq in
        *[!0-9]*) continue ;;
      esac
      task=$(wake_file_task "$f")
      if dest=$(wake_rehome "$f"); then
        printf 're-routed wake %s (%s) -> %s\n' "$((10#$seq))" "$task" "$dest"
      fi
    done
  done
  # orphan leases: the owner has no session at all (it vanished without a
  # reap), so no pass over live sessions would ever release them
  for lf in "$HIYA_HOME/state/leases"/*; do
    [ -f "$lf" ] || continue
    owner=$(awk -F= '$1 == "owner" { print $2 }' "$lf")
    if [ -n "$owner" ] && session_alive "$owner"; then
      continue
    fi
    task=$(basename "$lf")
    rm -f "$lf"
    backlog_set_state "$task" queued
    printf 'swept orphan lease %s (owner %s has no session)\n' "$task" "${owner:-?}"
  done
  return 0
}

# lock order: sessions before backlog, everywhere both are held
with_lock sessions with_lock backlog reap_impl
