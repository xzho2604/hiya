#!/usr/bin/env bash
# first-joiner-only bootstrap: one bootstrap no matter how many joiners.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
join() { "$bin/hiya-join.sh" | awk '/^sid:/ { print $2 }'; }

s1=$(join)
[ "$s1" = "s1" ] || fail "expected sid s1, got '$s1'"
[ -d "$HIYA_HOME/state/sessions/s1/inbox" ] || fail "session dir/inbox missing"
[ -f "$HIYA_HOME/state/sessions/s1/heartbeat" ] || fail "heartbeat missing"
[ -f "$HIYA_HOME/state/sessions/s1/meta" ] || fail "meta missing"
[ -f "$HIYA_HOME/state/.bootstrapped" ] || fail "bootstrap marker missing"
[ -f "$HIYA_HOME/data/backlog.md" ] || fail "backlog missing"
[ -d "$HIYA_HOME/data/journal" ] || fail "journal dir missing"
m1=$(cat "$HIYA_HOME/state/.bootstrapped")

sleep 1  # a re-bootstrap would stamp a different epoch
s2=$(join)
[ "$s2" = "s2" ] || fail "expected sid s2, got '$s2'"
m2=$(cat "$HIYA_HOME/state/.bootstrapped")
[ "$m1" = "$m2" ] || fail "second joiner re-ran bootstrap"

# concurrent joins into a fresh home: both succeed, distinct sids, one bootstrap
rm -rf "$HIYA_HOME"
"$bin/hiya-join.sh" > "$work/ja" 2>&1 &
pa=$!
"$bin/hiya-join.sh" > "$work/jb" 2>&1 &
pb=$!
wait "$pa" || fail "concurrent join A failed: $(cat "$work/ja")"
wait "$pb" || fail "concurrent join B failed: $(cat "$work/jb")"
sa=$(awk '/^sid:/ { print $2 }' "$work/ja")
sb=$(awk '/^sid:/ { print $2 }' "$work/jb")
[ -n "$sa" ] || fail "join A printed no sid"
[ -n "$sb" ] || fail "join B printed no sid"
[ "$sa" != "$sb" ] || fail "concurrent joins got the same sid '$sa'"
n=$(cat "$work/ja" "$work/jb" | grep -c '^bootstrapped ')
[ "$n" -eq 1 ] || fail "expected exactly 1 bootstrap, saw $n"

printf 'PASS: bootstrap\n'
