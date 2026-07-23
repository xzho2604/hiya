#!/usr/bin/env bash
# wake routing: owner inbox, watcher fallback for unleased/dead-owner,
# non-holder election message, inbox drain.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
join() { "$bin/hiya-join.sh" | awk '/^sid:/ { print $2 }'; }

s1=$(join)
s2=$(join)
printf 't1\tqueued\tA\nt2\tqueued\tB\nt3\tqueued\tC\n' > "$HIYA_HOME/data/backlog.md"
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null || fail "claim t1 failed"

"$bin/hiya-wake.sh" t1 "hello-owner" > /dev/null || fail "wake t1 failed"
"$bin/hiya-wake.sh" t2 "orphan-msg" > /dev/null || fail "wake t2 failed"
"$bin/hiya-watch.sh" "$s2" --once > /dev/null || fail "watch --once failed"

grep -rq "hello-owner" "$HIYA_HOME/state/sessions/$s1/inbox" \
  || fail "leased wake not routed to owner inbox"
grep -rq "orphan-msg" "$HIYA_HOME/state/sessions/$s2/inbox" \
  || fail "unleased wake did not fall to watcher inbox"
grep -rq "orphan-msg" "$HIYA_HOME/state/sessions/$s1/inbox" \
  && fail "unleased wake wrongly reached non-watcher"

# dead-owner: lease exists but the owner session dir is gone
s3=$(join)
"$bin/hiya-claim.sh" "$s3" t3 > /dev/null || fail "claim t3 failed"
rm -rf "$HIYA_HOME/state/sessions/$s3"
"$bin/hiya-wake.sh" t3 "dead-owner-msg" > /dev/null || fail "wake t3 failed"
"$bin/hiya-watch.sh" "$s2" --once > /dev/null || fail "watch --once (2) failed"
grep -rq "dead-owner-msg" "$HIYA_HOME/state/sessions/$s2/inbox" \
  || fail "dead-owner wake did not fall to watcher inbox"

# non-holder: a live foreign watcher holds the lock
lockdir="$HIYA_HOME/state/locks/watcher.lock"
mkdir "$lockdir"
printf '%s\n' "$$" > "$lockdir/pid"
printf 's99\n' > "$lockdir/sid"
out=$("$bin/hiya-watch.sh" "$s1" --once) || fail "non-holder watch must exit 0"
printf '%s\n' "$out" | grep -q "watcher held by s99" \
  || fail "expected 'watcher held by s99', got: $out"
rm -rf "$lockdir"

# drain: prints records in seq order, then empties
out=$("$bin/hiya-inbox.sh" "$s1" --drain) || fail "inbox drain failed"
printf '%s\n' "$out" | grep -q "hello-owner" || fail "drain output missing record"
out=$("$bin/hiya-inbox.sh" "$s1") || fail "inbox list failed"
[ -z "$out" ] || fail "inbox not empty after drain: $out"

# watcher inbox saw both fallbacks, in seq order
out=$("$bin/hiya-inbox.sh" "$s2")
first=$(printf '%s\n' "$out" | head -1)
printf '%s\n' "$first" | grep -q "orphan-msg" || fail "seq order broken: $out"

printf 'PASS: wake routing\n'
