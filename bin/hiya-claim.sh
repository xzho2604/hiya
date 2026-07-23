#!/usr/bin/env bash
# hiya-claim.sh — atomically claim a queued task for a session.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-claim.sh <sid> <task-id> [--help]

Claim-on-dispatch: under the backlog lock, verify the task is "queued" and
unleased, then write the lease (owner=<sid>, claimed_at=<epoch>) AND flip the
backlog state to "claimed" in the same critical section. Losing a claim race
exits non-zero with "already claimed by <sid>".

exit status:
  0  claim won
  1  claim lost (already claimed / not queued / unknown task)

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -ne 2 ]; then
  usage >&2
  exit 1
fi

sid=$1
task=$2
hiya_require_home
session_alive "$sid" || hiya_die "unknown or dead session '$sid' (did you join?)"

claim_impl() {
  local st owner
  owner=$(lease_owner "$task")
  if [ -n "$owner" ]; then
    printf 'hiya-claim: %s already claimed by %s\n' "$task" "$owner" >&2
    return 1
  fi
  st=$(backlog_state "$task")
  if [ -z "$st" ]; then
    printf 'hiya-claim: unknown task %s\n' "$task" >&2
    return 1
  fi
  if [ "$st" != "queued" ]; then
    printf 'hiya-claim: %s is %s, not queued\n' "$task" "$st" >&2
    return 1
  fi
  {
    printf 'owner=%s\n' "$sid"
    printf 'claimed_at=%s\n' "$(hiya_now)"
  } | atomic_write "$(hiya_lease_file "$task")"
  backlog_set_state "$task" claimed
  printf '%s claimed by %s\n' "$task" "$sid"
}

with_lock backlog claim_impl
