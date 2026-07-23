#!/usr/bin/env bash
# reaper: a dead session's lease is released and its dir archived.
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
printf 't1\tqueued\tDoomed task\n' > "$HIYA_HOME/data/backlog.md"
"$bin/hiya-claim.sh" "$s2" t1 > /dev/null || fail "claim failed"

touch -t 202001010000 "$HIYA_HOME/state/sessions/$s2/heartbeat"
out=$("$bin/hiya-heartbeat.sh" "$s1") || fail "heartbeat failed: $out"
printf '%s\n' "$out" | grep -q "reaped $s2" || fail "no reap reported: $out"

[ ! -e "$HIYA_HOME/state/leases/t1" ] || fail "lease not released"
st=$(awk -F '\t' '$1 == "t1" { print $2 }' "$HIYA_HOME/data/backlog.md")
[ "$st" = "queued" ] || fail "backlog state is '$st', not queued"
[ ! -d "$HIYA_HOME/state/sessions/$s2" ] || fail "dead session dir still present"
set -- "$HIYA_HOME/state/sessions/.dead/$s2".*
[ -d "$1" ] || fail "dead session not archived under .dead/"
[ -d "$HIYA_HOME/state/sessions/$s1" ] || fail "live session was reaped"

printf 'PASS: reap\n'
