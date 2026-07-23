#!/usr/bin/env bash
# hiya-release.sh — release a task lease held by a session.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-release.sh <sid> <task-id> [--done] [--help]

Release <sid>'s lease on <task-id>. The task goes back to "queued", or to
"done" with --done. Refuses (exit 2) if <sid> does not hold the lease.

exit status:
  0  released
  2  refused: caller does not hold the lease

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

sid=
task=
new_state=queued
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --done) new_state="done" ;;
    -*) usage >&2; exit 1 ;;
    *)
      if [ -z "$sid" ]; then sid=$1
      elif [ -z "$task" ]; then task=$1
      else usage >&2; exit 1
      fi
      ;;
  esac
  shift
done
if [ -z "$sid" ] || [ -z "$task" ]; then
  usage >&2
  exit 1
fi

hiya_require_home

release_impl() {
  local owner
  owner=$(lease_owner "$task")
  if [ -z "$owner" ]; then
    printf 'hiya-release: refused: %s is not leased\n' "$task" >&2
    return 2
  fi
  if [ "$owner" != "$sid" ]; then
    printf 'hiya-release: refused: %s is held by %s, not %s\n' \
      "$task" "$owner" "$sid" >&2
    return 2
  fi
  rm -f "$(hiya_lease_file "$task")"
  backlog_set_state "$task" "$new_state"
  printf '%s released by %s -> %s\n' "$task" "$sid" "$new_state"
}

with_lock backlog release_impl
