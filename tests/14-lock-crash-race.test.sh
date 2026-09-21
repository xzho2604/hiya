#!/usr/bin/env bash
# lock mutual exclusion after a crashed holder (report probe p5b). Each round
# a holder is killed -9 while it holds the lock, then N separate processes
# contend for it: critical sections must never overlap, and every contender
# must get its turn. Runs on the home's default lock backend and on the
# forced token fallback, and checks that a LIVE holder is never preempted —
# not by a waiter, and not by a sibling subshell sharing its pid.
set -u
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
cleanup() {
  # stop only this test's own still-running background jobs
  for p in $(jobs -p); do kill "$p" 2> /dev/null; done
  rm -rf "$work"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

rounds=${HIYA_TEST_LOCK_ROUNDS:-4}
contenders=${HIYA_TEST_LOCK_CONTENDERS:-10}

wait_for() {
  # wait_for <file> — bounded (10s) wait for a marker file
  local i=0
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -le 200 ] || return 1
    sleep 0.05
  done
}

crash_rounds() {
  # crash_rounds <label> — backend comes from HIYA_HOME / HIYA_LOCK_BACKEND
  local label=$1 r i p hp cps n
  r=0
  while [ "$r" -lt "$rounds" ]; do
    r=$((r + 1))
    rm -f "$work/held" "$work/overlaps" "$work/completed"
    rm -rf "$work/inside.d"

    # a holder dies without releasing: whatever it leaves behind is stale
    "$here/lock-holder.sh" res "$work/held" 30 2> "$work/holder.err" &
    hp=$!
    wait_for "$work/held" \
      || fail "$label round $r: holder never got the lock: $(cat "$work/holder.err")"
    kill -9 "$hp"
    wait "$hp" 2> /dev/null

    cps=
    i=0
    while [ "$i" -lt "$contenders" ]; do
      i=$((i + 1))
      "$here/lock-contender.sh" "$work" 2>> "$work/contender.err" &
      cps="$cps $!"
    done
    for p in $cps; do
      wait "$p" || fail "$label round $r: a contender failed: $(cat "$work/contender.err")"
    done

    [ ! -e "$work/overlaps" ] \
      || fail "$label round $r: $(wc -l < "$work/overlaps") overlapping critical section(s)"
    n=$(wc -l < "$work/completed")
    [ "$n" -eq "$contenders" ] \
      || fail "$label round $r: $n of $contenders contenders ran their critical section"
  done
  [ ! -s "$work/contender.err" ] \
    || fail "$label: contenders wrote to stderr: $(head -5 "$work/contender.err")"
}

live_holder_contract() {
  # a live holder keeps the lock: no-wait attempts fail at once, waiters time
  # out instead of preempting, and the lock is usable again once it is freed
  local label=$1 hp rc
  rm -f "$work/held" "$work/completed" "$work/overlaps"
  "$here/lock-holder.sh" busy "$work/held" 30 &
  hp=$!
  wait_for "$work/held" || fail "$label: holder never got the lock"

  # exactly 1 = "busy"; any other status means the helper itself broke
  "$here/lib-call.sh" lock_acquire busy 0
  rc=$?
  [ "$rc" -eq 1 ] || fail "$label: no-wait acquire of a held lock returned $rc, want 1 (busy)"
  HIYA_LOCK_WAIT=1 "$here/lock-contender.sh" "$work" busy 2> "$work/wait.err" \
    && fail "$label: a waiter got a lock its live holder never released"
  grep -q "timed out waiting for lock" "$work/wait.err" \
    || fail "$label: wrong timeout error: $(cat "$work/wait.err")"
  [ ! -e "$work/completed" ] || fail "$label: critical section ran under a held lock"
  kill -0 "$hp" 2> /dev/null || fail "$label: the live holder was disturbed"

  kill "$hp"
  wait "$hp" 2> /dev/null
  "$here/lock-contender.sh" "$work" busy 2> "$work/wait.err" \
    || fail "$label: lock unusable after its holder exited: $(cat "$work/wait.err")"
  [ -e "$work/completed" ] || fail "$label: critical section did not run"
  "$here/lib-call.sh" lock_acquire busy 0 \
    || fail "$label: no-wait acquire of a free lock failed"
}

sibling_subshells() {
  # subshells share $$ with their parent: a holder identified by pid must not
  # be mistaken, by its own sibling, for a dead predecessor to take over from
  local label=$1 n
  rm -f "$work/overlaps" "$work/completed"
  rm -rf "$work/inside.d"
  "$here/lock-siblings.sh" "$work" 2> "$work/sib.err" \
    || fail "$label: sibling subshells failed: $(cat "$work/sib.err")"
  [ ! -e "$work/overlaps" ] || fail "$label: sibling subshells held the lock at the same time"
  n=$(wc -l < "$work/completed")
  [ "$n" -eq 2 ] || fail "$label: $n of 2 sibling subshells ran their critical section"
}

export HIYA_HOME="$work/home-default"
crash_rounds default
live_holder_contract default
sibling_subshells default

export HIYA_HOME="$work/home-token" HIYA_LOCK_BACKEND=token
crash_rounds token
live_holder_contract token
sibling_subshells token

printf 'PASS: lock crash race\n'
