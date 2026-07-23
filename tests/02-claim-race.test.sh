#!/usr/bin/env bash
# claim race: two concurrent claims for the same task, exactly one wins.
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
printf 't1\tqueued\tContested task\n' > "$HIYA_HOME/data/backlog.md"

"$bin/hiya-claim.sh" "$s1" t1 > "$work/a" 2>&1 &
pa=$!
"$bin/hiya-claim.sh" "$s2" t1 > "$work/b" 2>&1 &
pb=$!
wait "$pa"; ra=$?
wait "$pb"; rb=$?

wins=0
[ "$ra" -eq 0 ] && wins=$((wins + 1))
[ "$rb" -eq 0 ] && wins=$((wins + 1))
[ "$wins" -eq 1 ] || fail "expected exactly one winner, got $wins (a=$ra b=$rb)"

if [ "$ra" -eq 0 ]; then winner=$s1 loserout="$work/b"; else winner=$s2 loserout="$work/a"; fi
grep -q "already claimed by $winner" "$loserout" \
  || fail "loser lacks 'already claimed by $winner': $(cat "$loserout")"

st=$(awk -F '\t' '$1 == "t1" { print $2 }' "$HIYA_HOME/data/backlog.md")
[ "$st" = "claimed" ] || fail "backlog state is '$st', not claimed"
owner=$(awk -F= '$1 == "owner" { print $2 }' "$HIYA_HOME/state/leases/t1")
[ "$owner" = "$winner" ] || fail "lease owner '$owner' is not winner '$winner'"

printf 'PASS: claim race\n'
