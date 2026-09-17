#!/usr/bin/env bash
# hiya-add (report probe p4): tasks are added under the backlog lock, so no
# row is lost to concurrent claim/release rewrites (hand appends lost 17 of
# 300); duplicate ids and malformed ids/titles are refused.
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
backlog="$HIYA_HOME/data/backlog.md"
rows_of() { awk -F '\t' -v id="$1" '$1 == id { n++ } END { print n + 0 }' "$backlog"; }
tab=$(printf '\t')

# a home must exist first
"$bin/hiya-add.sh" t1 "Too early" > /dev/null 2> "$work/err" && fail "add into a missing home must fail"
grep -q "not bootstrapped" "$work/err" || fail "wrong error: $(cat "$work/err")"

s1=$(join)

# --- basics
out=$("$bin/hiya-add.sh" t1 "First task") || fail "add failed: $out"
[ "$out" = "t1 added (queued)" ] || fail "unexpected output: $out"
[ "$(cat "$backlog")" = "t1${tab}queued${tab}First task" ] || fail "bad row: $(cat "$backlog")"
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null || fail "an added task must be claimable"

# --- duplicates are refused whatever the task's state
"$bin/hiya-add.sh" t1 "Again" > /dev/null 2> "$work/err"
[ $? -eq 2 ] || fail "duplicate id must exit 2"
grep -q "already exists" "$work/err" || fail "wrong refusal: $(cat "$work/err")"
[ "$(rows_of t1)" -eq 1 ] || fail "duplicate row written"

# --- malformed input is refused and changes nothing
before=$(cat "$backlog")
refused() {
  # refused <task-id> <title> — the add must exit exactly 1 (invalid input)
  "$bin/hiya-add.sh" "$1" "$2" > /dev/null 2>&1
  [ $? -eq 1 ]
}
for bad in "" "a b" "a/b" "../x" "-x" ".x" "a${tab}b"; do
  refused "$bad" "Bad id" || fail "id '$bad' must be refused with exit 1"
done
refused t2 "" || fail "empty title must be refused"
refused t2 "a${tab}b" || fail "title with a tab must be refused"
refused t2 "two
lines" || fail "multi-line title must be refused"
[ "$(cat "$backlog")" = "$before" ] || fail "a refused add changed the backlog"

# --- a last line without its newline must not swallow the new row
"$bin/hiya-release.sh" "$s1" t1 > /dev/null || fail "release failed"
printf 'tz\tqueued\tno trailing newline' >> "$backlog"   # nothing else is running
"$bin/hiya-add.sh" ty "After the ragged line" > /dev/null || fail "add after ragged line failed"
[ "$(rows_of tz)" -eq 1 ] && [ "$(rows_of ty)" -eq 1 ] || fail "ragged last line glued rows: $(cat "$backlog")"

# --- concurrent adds while a session churns claim/release on another task
"$bin/hiya-add.sh" t0 "Churn task" > /dev/null || fail "add t0 failed"
(
  i=0
  while [ "$i" -lt 12 ]; do
    i=$((i + 1))
    "$bin/hiya-claim.sh" "$s1" t0 > /dev/null 2>&1
    "$bin/hiya-release.sh" "$s1" t0 > /dev/null 2>&1
  done
) &
churn=$!
adders=
for k in a b c d; do
  (
    i=0
    while [ "$i" -lt 10 ]; do
      i=$((i + 1))
      "$bin/hiya-add.sh" "$k$i" "Added by $k" > /dev/null || exit 1
    done
  ) &
  adders="$adders $!"
done
for p in $adders; do
  wait "$p" || fail "an adder failed"
done
wait "$churn"

for k in a b c d; do
  i=0
  while [ "$i" -lt 10 ]; do
    i=$((i + 1))
    [ "$(rows_of "$k$i")" -eq 1 ] || fail "row $k$i present $(rows_of "$k$i") times"
  done
done
[ "$(rows_of t0)" -eq 1 ] || fail "churn task row lost"
want=$((4 + 40))   # t1 tz ty t0 + 40 added
[ "$(wc -l < "$backlog")" -eq "$want" ] || fail "backlog has $(wc -l < "$backlog") rows, want $want"
awk -F '\t' 'NF != 3 { bad++ } END { exit bad > 0 }' "$backlog" || fail "malformed row(s) in the backlog"

printf 'PASS: add\n'
