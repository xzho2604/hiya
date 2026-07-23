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
session's leases are released back to "queued" and its session dir is
archived under state/sessions/.dead/<sid>.<epoch>.

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
session_alive "$sid" || hiya_die "unknown or dead session '$sid' (did you join?)"

touch "$(hiya_session_dir "$sid")/heartbeat"
printf 'heartbeat %s\n' "$sid"

reap_impl() {
  local now d s hb age lf task released
  now=$(hiya_now)
  for d in "$(hiya_sessions_dir)"/*/; do
    [ -d "$d" ] || continue
    s=$(basename "$d")
    hb="$d/heartbeat"
    [ -f "$hb" ] || continue
    age=$(( now - $(hiya_mtime "$hb") ))
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
    mv "$d" "$(hiya_sessions_dir)/.dead/$s.$now"
    printf 'reaped %s (heartbeat %ss old)' "$s" "$age"
    if [ -n "$released" ]; then
      printf '; released:%s' "$released"
    fi
    printf '\n'
  done
  return 0
}

# lock order: sessions before backlog, everywhere both are held
with_lock sessions with_lock backlog reap_impl
