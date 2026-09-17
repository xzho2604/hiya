#!/usr/bin/env bash
# wake routing: owner inbox, state/unrouted/ for unleased/dead-owner tasks,
# adoption by the next claimant, non-holder election message, inbox drain.
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

s1=$(join)
s2=$(join)
for t in t1 t2 t3; do
  "$bin/hiya-add.sh" "$t" "Task $t" > /dev/null || fail "add $t failed"
done
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null || fail "claim t1 failed"

"$bin/hiya-wake.sh" t1 "hello-owner" > /dev/null || fail "wake t1 failed"
"$bin/hiya-wake.sh" t2 "orphan-msg" > /dev/null || fail "wake t2 failed"
"$bin/hiya-watch.sh" "$s2" --once > /dev/null || fail "watch --once failed"

grep -rq "hello-owner" "$HIYA_HOME/state/sessions/$s1/inbox" \
  || fail "leased wake not routed to owner inbox"
grep -rq "orphan-msg" "$HIYA_HOME/state/unrouted" \
  || fail "unleased wake was not parked in state/unrouted"
grep -rq "orphan-msg" "$HIYA_HOME/state/sessions" \
  && fail "unleased wake wrongly reached a session inbox"

# dead-owner: lease exists but the owner session dir is gone
s3=$(join)
"$bin/hiya-claim.sh" "$s3" t3 > /dev/null || fail "claim t3 failed"
rm -rf "$HIYA_HOME/state/sessions/$s3"
"$bin/hiya-wake.sh" t3 "dead-owner-msg" > /dev/null || fail "wake t3 failed"
"$bin/hiya-watch.sh" "$s2" --once > /dev/null || fail "watch --once (2) failed"
grep -rq "dead-owner-msg" "$HIYA_HOME/state/unrouted" \
  || fail "dead-owner wake was not parked in state/unrouted"

# unrouted wakes list in seq order, and the join digest points at them
out=$("$bin/hiya-inbox.sh" --unrouted) || fail "inbox --unrouted failed"
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] || fail "expected 2 unrouted wakes: $out"
printf '%s\n' "$out" | head -1 | grep -q "orphan-msg" || fail "seq order broken: $out"
"$bin/hiya-join.sh" | grep -q "^unrouted wakes: 2 " || fail "digest does not count unrouted wakes"

# the next claimant of a task adopts ITS parked wakes, and only those
out=$("$bin/hiya-claim.sh" "$s2" t2) || fail "claim t2 failed: $out"
printf '%s\n' "$out" | grep -q "adopted 1 unrouted wake(s) for t2" || fail "no adoption: $out"
out=$("$bin/hiya-inbox.sh" "$s2") || fail "inbox list failed"
printf '%s\n' "$out" | grep -q "orphan-msg" || fail "claimant did not get the parked wake: $out"
printf '%s\n' "$out" | grep -q "dead-owner-msg" && fail "claimant adopted another task's wake: $out"
out=$("$bin/hiya-inbox.sh" --unrouted) || fail "inbox --unrouted failed"
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "adopted wake still parked: $out"

# non-holder: a live watcher holds the lock
HIYA_WATCH_INTERVAL=0.2 "$bin/hiya-watch.sh" "$s2" > "$work/w.log" 2>&1 &
wp=$!
i=0
until grep -q "$s2 is the watcher" "$work/w.log" 2> /dev/null; do
  i=$((i + 1))
  [ "$i" -le 100 ] || fail "background watcher never started: $(cat "$work/w.log")"
  sleep 0.05
done
out=$("$bin/hiya-watch.sh" "$s1" --once) || fail "non-holder watch must exit 0"
printf '%s\n' "$out" | grep -q "watcher held by $s2" \
  || fail "expected 'watcher held by $s2', got: $out"
kill "$wp"
wait "$wp" 2> /dev/null

# drain: prints records in seq order, then empties
out=$("$bin/hiya-inbox.sh" "$s1" --drain) || fail "inbox drain failed"
printf '%s\n' "$out" | grep -q "hello-owner" || fail "drain output missing record"
out=$("$bin/hiya-inbox.sh" "$s1") || fail "inbox list failed"
[ -z "$out" ] || fail "inbox not empty after drain: $out"
out=$("$bin/hiya-inbox.sh" --unrouted --drain) || fail "unrouted drain failed"
printf '%s\n' "$out" | grep -q "dead-owner-msg" || fail "unrouted drain output missing record"
[ -z "$("$bin/hiya-inbox.sh" --unrouted)" ] || fail "unrouted not empty after drain"

printf 'PASS: wake routing\n'
