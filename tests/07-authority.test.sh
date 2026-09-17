#!/usr/bin/env bash
# authority: release/transfer refuse callers that do not hold the lease.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
join() { "$bin/hiya-join.sh" | awk '/^sid:/ { print $2 }'; }
owner_of() { awk -F= '$1 == "owner" { print $2 }' "$HIYA_HOME/state/leases/$1"; }

s1=$(join)
s2=$(join)
"$bin/hiya-add.sh" t1 "Guarded task" > /dev/null || fail "add failed"
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null || fail "claim failed"

# non-owner release refused
"$bin/hiya-release.sh" "$s2" t1 2> "$work/err" && fail "non-owner release must fail"
grep -q "refused" "$work/err" || fail "no refusal message: $(cat "$work/err")"
[ "$(owner_of t1)" = "$s1" ] || fail "lease changed by refused release"

# non-owner transfer refused
"$bin/hiya-transfer.sh" "$s2" "$s2" t1 2> "$work/err" && fail "non-owner transfer must fail"
grep -q "refused" "$work/err" || fail "no refusal message: $(cat "$work/err")"
[ "$(owner_of t1)" = "$s1" ] || fail "lease changed by refused transfer"

# transfer to a dead session refused
"$bin/hiya-transfer.sh" "$s1" s99 t1 2> "$work/err" && fail "transfer to dead sid must fail"
grep -q "refused" "$work/err" || fail "no refusal message: $(cat "$work/err")"

# owner transfer succeeds; new owner can finish the task
"$bin/hiya-transfer.sh" "$s1" "$s2" t1 > /dev/null || fail "owner transfer failed"
[ "$(owner_of t1)" = "$s2" ] || fail "transfer did not move the lease"
"$bin/hiya-release.sh" "$s1" t1 2> /dev/null && fail "old owner must lose authority"
"$bin/hiya-release.sh" "$s2" t1 --done > /dev/null || fail "new owner release failed"
st=$(awk -F '\t' '$1 == "t1" { print $2 }' "$HIYA_HOME/data/backlog.md")
[ "$st" = "done" ] || fail "backlog state is '$st', not done"
[ ! -e "$HIYA_HOME/state/leases/t1" ] || fail "lease survived release"

# releasing an unleased task refused
"$bin/hiya-release.sh" "$s2" t1 2> "$work/err" && fail "release of unleased task must fail"
grep -q "not leased" "$work/err" || fail "wrong refusal: $(cat "$work/err")"

printf 'PASS: authority\n'
