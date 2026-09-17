#!/usr/bin/env bash
# wake delivery integrity (report probe p2): a record is never dropped. The
# cursor advances only past records that were really written; an owner whose
# inbox cannot be written falls back to state/unrouted/; and when nothing can
# be written the pass fails, keeps its cursor, and a later pass delivers.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
join() { "$bin/hiya-join.sh" | awk '/^sid:/ { print $2 }'; }
cursor() { cat "$HIYA_HOME/state/.wake-cursor" 2> /dev/null || printf '0\n'; }

s1=$(join)
s2=$(join)
"$bin/hiya-add.sh" t1 "Owned task" > /dev/null || fail "add failed"
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null || fail "claim failed"

# --- the owner looks alive but its inbox is gone: fall back, do not drop
rm -rf "$HIYA_HOME/state/sessions/$s1/inbox"
"$bin/hiya-wake.sh" t1 "inbox-vanished" > /dev/null || fail "wake failed"
"$bin/hiya-watch.sh" "$s2" --once > "$work/out" 2> "$work/err" \
  || fail "watch --once failed: $(cat "$work/out" "$work/err")"
grep -rq "inbox-vanished" "$HIYA_HOME/state/unrouted" \
  || fail "undeliverable wake was dropped: $(cat "$work/out" "$work/err")"
[ "$(cursor)" = "1" ] || fail "cursor is $(cursor) after one delivered record"

# --- nowhere to write at all: the pass fails and the cursor stays put
"$bin/hiya-wake.sh" t9 "parked-later" > /dev/null || fail "wake failed"
mv "$HIYA_HOME/state/unrouted" "$HIYA_HOME/state/unrouted.real"
: > "$HIYA_HOME/state/unrouted"       # a file where the directory should be
"$bin/hiya-watch.sh" "$s2" --once > "$work/out" 2> "$work/err" \
  && fail "a pass that could not deliver must exit non-zero"
grep -q "cannot write wake 2 (t9)" "$work/err" \
  || fail "the pass failed for another reason: $(cat "$work/out" "$work/err")"
[ "$(cursor)" = "1" ] || fail "cursor advanced to $(cursor) past an undelivered record"

# ...and the record is delivered once the home is writable again
rm -f "$HIYA_HOME/state/unrouted"
mv "$HIYA_HOME/state/unrouted.real" "$HIYA_HOME/state/unrouted"
"$bin/hiya-watch.sh" "$s2" --once > "$work/out" 2> "$work/err" \
  || fail "retry pass failed: $(cat "$work/out" "$work/err")"
grep -rq "parked-later" "$HIYA_HOME/state/unrouted" || fail "record lost after the retry"
[ "$(cursor)" = "2" ] || fail "cursor is $(cursor) after the retry"

# --- inbox files are written atomically: no partial or temp files are listed
"$bin/hiya-add.sh" t2 "Second owned task" > /dev/null || fail "add failed"
"$bin/hiya-claim.sh" "$s2" t2 > /dev/null || fail "claim failed"
"$bin/hiya-wake.sh" t2 "hello-owner" > /dev/null || fail "wake failed"
"$bin/hiya-watch.sh" "$s2" --once > /dev/null || fail "watch --once failed"
out=$("$bin/hiya-inbox.sh" "$s2") || fail "inbox failed"
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "expected exactly 1 record: $out"
printf '%s\n' "$out" | grep -q "hello-owner" || fail "record missing: $out"
set -- "$HIYA_HOME/state/sessions/$s2/inbox"/.tmp.*
[ ! -e "$1" ] || fail "temp file left in the inbox: $1"

printf 'PASS: wake delivery\n'
