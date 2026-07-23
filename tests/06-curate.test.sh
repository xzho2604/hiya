#!/usr/bin/env bash
# curation: journal intents fold into memory files and the journal empties.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

"$bin/hiya-join.sh" > /dev/null || fail "join failed"

printf 'A: landed\n' > "$work/a.md"
printf 'B: journaled\n' > "$work/b.md"
"$bin/hiya-mem-write.sh" notes "$work/a.md" --base-hash "-" > /dev/null \
  || fail "seed write failed"
"$bin/hiya-mem-write.sh" notes "$work/b.md" --base-hash "-" 2> /dev/null
[ $? -eq 3 ] || fail "expected journaled conflict"

out=$("$bin/hiya-curate.sh") || fail "curate failed: $out"
printf '%s\n' "$out" | grep -q "1 intent(s) curated" || fail "wrong count: $out"

mem="$HIYA_HOME/data/memory/notes.md"
grep -q "A: landed" "$mem" || fail "original content lost"
grep -q "## Curated" "$mem" || fail "no Curated section"
grep -q "B: journaled" "$mem" || fail "intent content not folded"
awk '/A: landed/ { a = NR } /B: journaled/ { b = NR } END { exit !(a && b && a < b) }' "$mem" \
  || fail "curated content should append after original"

set -- "$HIYA_HOME/data/journal"/*
[ ! -e "$1" ] || fail "journal not emptied: $1"

# idempotent on an empty journal
out=$("$bin/hiya-curate.sh") || fail "curate on empty journal failed"
printf '%s\n' "$out" | grep -q "0 intent(s) curated" || fail "empty journal miscounted"

printf 'PASS: curate\n'
