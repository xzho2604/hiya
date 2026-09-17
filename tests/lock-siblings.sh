#!/usr/bin/env bash
# tests/lock-siblings.sh — test helper (not a test): two sibling SUBSHELLS of
# one process contend for the same lock.
#
# usage: lock-siblings.sh <work-dir>
#
# Subshells share $$ with their parent, so a lock that identifies its holder
# by pid must still tell the siblings apart — or at least never let one take
# the other's live lock. mkdir is the overlap detector, as in
# lock-contender.sh; the critical section is long enough that the siblings
# are certain to overlap in time.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$here/../bin/hiya-lib.sh"

work=$1

# shellcheck disable=SC2329  # invoked indirectly via with_lock
crit() {
  if ! mkdir "$work/inside.d" 2> /dev/null; then
    printf 'overlap\n' >> "$work/overlaps"
    sleep 0.3
    return 0
  fi
  sleep 0.3
  rmdir "$work/inside.d"
  printf 'x\n' >> "$work/completed"
}

( with_lock sib crit ) &
a=$!
( with_lock sib crit ) &
b=$!
rc=0
wait "$a" || rc=1
wait "$b" || rc=1
exit "$rc"
