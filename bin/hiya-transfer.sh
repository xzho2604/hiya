#!/usr/bin/env bash
# hiya-transfer.sh — hand a task lease from one session to another.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-transfer.sh <from-sid> <to-sid> <task-id> [--help]

Explicit lease handoff: rewrite the lease on <task-id> from <from-sid> to
<to-sid>. Refuses (exit 2) if <from-sid> does not hold the lease or <to-sid>
is not a live session. The backlog state stays "claimed".

exit status:
  0  transferred
  1  usage error, or the lease could not be written (it stays with <from-sid>)
  2  refused: authority or liveness check failed

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -ne 3 ]; then
  usage >&2
  exit 1
fi

from=$1
to=$2
task=$3
hiya_require_home

transfer_impl() {
  local owner
  owner=$(lease_owner "$task")
  if [ -z "$owner" ] || [ "$owner" != "$from" ]; then
    printf 'hiya-transfer: refused: %s is held by %s, not %s\n' \
      "$task" "${owner:-nobody}" "$from" >&2
    return 2
  fi
  if ! session_alive "$to"; then
    printf 'hiya-transfer: refused: no live session %s\n' "$to" >&2
    return 2
  fi
  if ! {
    printf 'owner=%s\n' "$to"
    printf 'claimed_at=%s\n' "$(hiya_now)"
  } | atomic_write "$(hiya_lease_file "$task")"; then
    # the old lease is intact (the write is atomic): say so, do not claim success
    printf 'hiya-transfer: cannot write the lease for %s; it stays with %s\n' \
      "$task" "$from" >&2
    return 1
  fi
  printf '%s transferred %s -> %s\n' "$task" "$from" "$to"
}

with_lock backlog transfer_impl
