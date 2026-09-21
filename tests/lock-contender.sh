#!/usr/bin/env bash
# tests/lock-contender.sh — test helper (not a test): one contender in the
# mutual-exclusion stress test.
#
# usage: lock-contender.sh <work-dir> [lock-name]
#
# Runs a short critical section under the lock (default "res"). mkdir is the
# overlap detector: it is atomic, so a second process inside the critical
# section cannot create <work-dir>/inside.d and records the overlap instead.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$here/../bin/hiya-lib.sh"

work=$1
lock=${2:-res}

crit() {
  if ! mkdir "$work/inside.d" 2> /dev/null; then
    printf 'overlap\n' >> "$work/overlaps"
    sleep 0.02
    return 0
  fi
  sleep 0.02
  rmdir "$work/inside.d"
  printf 'x\n' >> "$work/completed"
}

with_lock "$lock" crit
