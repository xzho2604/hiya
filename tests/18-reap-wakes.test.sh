#!/usr/bin/env bash
# reaping keeps wakes and leases consistent (report probe p3): a reaped
# session's undelivered wakes follow their task to its next claimant, a wake
# for a task that moved on is re-routed to its live owner, a failed re-home is
# retried, a parked wake reaches an owner that turns up, a lease whose owner
# has no session is swept, and a claim re-checks its session under the lock.
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
state_of() { awk -F '\t' -v id="$1" '$1 == id { print $2 }' "$HIYA_HOME/data/backlog.md"; }

wait_for() {
  # wait_for <file> — bounded (10s) wait for a marker file
  local i=0
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -le 200 ] || return 1
    sleep 0.05
  done
}

s1=$(join)
s2=$(join)
s3=$(join)
for t in t1 t2 t7 t8 t9; do
  "$bin/hiya-add.sh" "$t" "Task $t" > /dev/null || fail "add $t failed"
done

# --- stranded wakes: s1 owns t1 and t2, both get a wake routed to s1's inbox;
#     t2 is then handed to s3, its (already routed) wake stays with s1
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null || fail "claim t1 failed"
"$bin/hiya-claim.sh" "$s1" t2 > /dev/null || fail "claim t2 failed"
"$bin/hiya-wake.sh" t1 "review requested on t1" > /dev/null || fail "wake t1 failed"
"$bin/hiya-wake.sh" t2 "review requested on t2" > /dev/null || fail "wake t2 failed"
"$bin/hiya-watch.sh" "$s2" --once > /dev/null || fail "watch --once failed"
grep -rq "review requested on t1" "$HIYA_HOME/state/sessions/$s1/inbox" \
  || fail "setup: wake not routed to the owner"
"$bin/hiya-transfer.sh" "$s1" "$s3" t2 > /dev/null || fail "transfer failed"

# s1 dies with both wakes unread; s2's heartbeat pass reaps it
touch -t 202001010000 "$HIYA_HOME/state/sessions/$s1/heartbeat"
out=$("$bin/hiya-heartbeat.sh" "$s2") || fail "heartbeat failed: $out"
printf '%s\n' "$out" | grep -q "reaped $s1" || fail "no reap reported: $out"
[ "$(state_of t1)" = "queued" ] || fail "t1 not requeued"

# t2's wake follows t2 to its live owner right away
grep -rq "review requested on t2" "$HIYA_HOME/state/sessions/$s3/inbox" \
  || fail "wake for a transferred task did not reach its live owner: $out"

# t1 has no owner yet: its wake waits, then reaches the next claimant
"$bin/hiya-claim.sh" "$s2" t1 > /dev/null || fail "re-claim of t1 failed"
out=$("$bin/hiya-inbox.sh" "$s2") || fail "inbox failed"
printf '%s\n' "$out" | grep -q "review requested on t1" \
  || fail "the next claimant never saw the dead session's wake: '$out'"
printf '%s\n' "$out" | grep -q "review requested on t2" \
  && fail "t1's claimant got another task's wake: $out"

# --- orphan lease: the owner's session dir vanished without a reap
s4=$(join)
"$bin/hiya-claim.sh" "$s4" t7 > /dev/null || fail "claim t7 failed"
rm -rf "$HIYA_HOME/state/sessions/$s4"
out=$("$bin/hiya-heartbeat.sh" "$s2") || fail "heartbeat failed: $out"
[ ! -e "$HIYA_HOME/state/leases/t7" ] || fail "orphan lease not swept: $out"
[ "$(state_of t7)" = "queued" ] || fail "t7 is '$(state_of t7)' after the sweep, not queued"
"$bin/hiya-claim.sh" "$s2" t7 > /dev/null || fail "t7 not claimable after the sweep"

# --- a re-home that fails is reported and retried, never dropped: nothing but
#     the reaper ever looks under .dead/, so a one-shot sweep would lose it
s5=$(join)
"$bin/hiya-claim.sh" "$s5" t9 > /dev/null || fail "claim t9 failed"
"$bin/hiya-wake.sh" t9 "review requested on t9" > /dev/null || fail "wake t9 failed"
"$bin/hiya-watch.sh" "$s2" --once > /dev/null || fail "watch --once failed"
mv "$HIYA_HOME/state/unrouted" "$HIYA_HOME/state/unrouted.real"
: > "$HIYA_HOME/state/unrouted"       # a file where the directory should be
touch -t 202001010000 "$HIYA_HOME/state/sessions/$s5/heartbeat"
out=$("$bin/hiya-heartbeat.sh" "$s2" 2> "$work/err") || fail "heartbeat failed: $out"
printf '%s\n' "$out" | grep -q "reaped $s5" || fail "no reap reported: $out"
grep -q "cannot re-home wake" "$work/err" \
  || fail "a failed re-home must be reported: $out $(cat "$work/err")"
set -- "$HIYA_HOME/state/sessions/.dead/$s5".*/inbox/*
[ -f "$1" ] || fail "the record that could not be moved is gone"
rm -f "$HIYA_HOME/state/unrouted"
mv "$HIYA_HOME/state/unrouted.real" "$HIYA_HOME/state/unrouted"
out=$("$bin/hiya-heartbeat.sh" "$s2") || fail "heartbeat failed: $out"
printf '%s\n' "$out" | grep -q "re-routed wake" || fail "the retry did not re-home: $out"
grep -rq "review requested on t9" "$HIYA_HOME/state/unrouted" \
  || fail "record not re-homed on the retry"

# --- a wake parked while its task HAS a live owner (the owner's inbox could
#     not be written when it was routed) is delivered by the next pass
mv "$HIYA_HOME/state/sessions/$s2/inbox" "$HIYA_HOME/state/sessions/$s2/inbox.away"
"$bin/hiya-wake.sh" t7 "parked despite a live owner" > /dev/null || fail "wake t7 failed"
"$bin/hiya-watch.sh" "$s2" --once > /dev/null || fail "watch --once failed"
grep -rq "parked despite a live owner" "$HIYA_HOME/state/unrouted" \
  || fail "setup: the wake was not parked"
mv "$HIYA_HOME/state/sessions/$s2/inbox.away" "$HIYA_HOME/state/sessions/$s2/inbox"
out=$("$bin/hiya-heartbeat.sh" "$s2") || fail "heartbeat failed: $out"
printf '%s\n' "$out" | grep -q "delivered parked wake" || fail "parked wake not delivered: $out"
"$bin/hiya-inbox.sh" "$s2" | grep -q "parked despite a live owner" \
  || fail "the live owner never got its parked wake"
grep -rq "parked despite a live owner" "$HIYA_HOME/state/unrouted" \
  && fail "delivered wake is still parked"

# --- claim re-checks liveness under the lock: a session reaped while its claim
#     waits for the backlog lock must not end up owning a lease
s6=$(join)
"$here/lock-holder.sh" backlog "$work/held" 30 &
hp=$!
wait_for "$work/held" || fail "lock holder never got the backlog lock"
"$bin/hiya-claim.sh" "$s6" t8 > "$work/claim.out" 2>&1 &
cp=$!
sleep 0.5   # the claim is past its pre-lock check, waiting for the lock
mv "$HIYA_HOME/state/sessions/$s6" "$HIYA_HOME/state/sessions/.dead/$s6.test"
kill "$hp"
wait "$hp" 2> /dev/null
wait "$cp" && fail "a claim by a session reaped mid-wait must fail: $(cat "$work/claim.out")"
# refused by the re-check under the lock — or, on a slow host, by the check
# before it; never by anything else (a lock timeout, say)
grep -Eq "session $s6 is gone|unknown or dead session '$s6'" "$work/claim.out" \
  || fail "the claim failed for another reason: $(cat "$work/claim.out")"
[ ! -e "$HIYA_HOME/state/leases/t8" ] \
  || fail "orphan lease created for a dead session: $(cat "$HIYA_HOME/state/leases/t8")"
[ "$(state_of t8)" = "queued" ] || fail "t8 is '$(state_of t8)', not queued"

printf 'PASS: reap wakes\n'
