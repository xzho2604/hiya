#!/usr/bin/env bash
# watcher liveness (report probe p2): the watch loop heartbeats, so a session
# that is only watching is not reaped; if its session IS reaped it exits and
# frees the watcher lock, so a live session takes over and no wake is lost;
# and a watcher killed mid-sleep frees the lock at once.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
cleanup() {
  # stop only this test's own still-running background jobs
  for p in $(jobs -p); do kill "$p" 2> /dev/null; done
  rm -rf "$work"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
join() { "$bin/hiya-join.sh" | awk '/^sid:/ { print $2 }'; }

wait_until() {
  # wait_until <seconds> <cmd> [args...] — poll until cmd succeeds
  local n=$(( $1 * 20 )) i=0
  shift
  while ! "$@" > /dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le "$n" ] || return 1
    sleep 0.05
  done
}

s1=$(join)
s2=$(join)
"$bin/hiya-add.sh" t1 "Unowned task" > /dev/null || fail "add failed"

# --- the loop heartbeats: an aged heartbeat is refreshed by the next pass
HIYA_WATCH_INTERVAL=0.2 "$bin/hiya-watch.sh" "$s1" > "$work/w1.log" 2>&1 &
w1=$!
wait_until 5 grep -q "$s1 is the watcher" "$work/w1.log" \
  || fail "watcher never started: $(cat "$work/w1.log")"
hb="$HIYA_HOME/state/sessions/$s1/heartbeat"
touch -t 202101010000 "$work/ref"
touch -t 202001010000 "$hb"
refreshed() { [ -n "$(find "$hb" -newer "$work/ref" 2> /dev/null)" ]; }
wait_until 3 refreshed || fail "the watch loop never refreshed its own heartbeat"
out=$("$bin/hiya-heartbeat.sh" "$s2") || fail "heartbeat failed: $out"
printf '%s\n' "$out" | grep -q "reaped $s1" && fail "a watching session was reaped: $out"

# --- session reaped under a stalled watcher: it must step down, not linger
kill -STOP "$w1"
touch -t 202001010000 "$hb"
out=$("$bin/hiya-heartbeat.sh" "$s2") || fail "heartbeat failed: $out"
printf '%s\n' "$out" | grep -q "reaped $s1" || fail "setup: $s1 was not reaped: $out"
kill -CONT "$w1"
stepped_down() { ! kill -0 "$w1" 2> /dev/null; }
wait_until 5 stepped_down || fail "watcher kept running after its session was reaped"
if wait "$w1"; then
  fail "a watcher whose session is gone must exit non-zero"
fi
grep -q "session $s1 is gone" "$work/w1.log" \
  || fail "no step-down message: $(cat "$work/w1.log")"

# ...so a live session takes over and the wake is delivered, not lost
"$bin/hiya-wake.sh" t1 "ci failed on t1" > /dev/null || fail "wake failed"
out=$("$bin/hiya-watch.sh" "$s2" --once) || fail "watch --once failed: $out"
printf '%s\n' "$out" | grep -q "$s2 is the watcher" || fail "takeover blocked: $out"
grep -rq "ci failed on t1" "$HIYA_HOME/state/unrouted" \
  || fail "wake for an unowned task was lost: $out"

# --- killed mid-sleep: the lock must not live on in the orphaned sleep child
s3=$(join)
HIYA_WATCH_INTERVAL=3 "$bin/hiya-watch.sh" "$s3" > "$work/w3.log" 2>&1 &
w3=$!
wait_until 5 grep -q "$s3 is the watcher" "$work/w3.log" \
  || fail "second watcher never started: $(cat "$work/w3.log")"
sleep 0.5   # the first pass is over; the loop is in its 3s sleep
kill -9 "$w3"
wait "$w3" 2> /dev/null
out=$("$bin/hiya-watch.sh" "$s2" --once) || fail "watch --once failed: $out"
printf '%s\n' "$out" | grep -q "$s2 is the watcher" \
  || fail "lock not freed by the watcher's death: $out"

printf 'PASS: watcher liveness\n'
