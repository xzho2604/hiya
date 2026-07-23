#!/usr/bin/env bash
# CAS memory write: stale base hash journals instead of clobbering.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

"$bin/hiya-join.sh" > /dev/null || fail "join failed"

h0=$("$bin/hiya-mem-write.sh" --show-hash notes)
[ "$h0" = "-" ] || fail "hash of missing file should be '-', got '$h0'"

printf 'A: first write\n' > "$work/a.md"
printf 'B: conflicting write\n' > "$work/b.md"

"$bin/hiya-mem-write.sh" notes "$work/a.md" --base-hash "$h0" \
  || fail "first CAS write should land"
grep -q "A: first write" "$HIYA_HOME/data/memory/notes.md" || fail "A content missing"

# second writer still holds the stale base hash h0
"$bin/hiya-mem-write.sh" notes "$work/b.md" --base-hash "$h0" 2> "$work/err"
rc=$?
[ "$rc" -eq 3 ] || fail "conflict should exit 3, got $rc"
grep -q "A: first write" "$HIYA_HOME/data/memory/notes.md" || fail "A was clobbered"
grep -q "B: conflicting write" "$HIYA_HOME/data/memory/notes.md" \
  && fail "B reached memory despite conflict"
set -- "$HIYA_HOME/data/journal"/notes__*
[ -f "$1" ] || fail "no journal intent written"
grep -q "B: conflicting write" "$1" || fail "intent lacks B content"

# a fresh read-modify-write cycle succeeds
h1=$("$bin/hiya-mem-write.sh" --show-hash notes)
printf 'A+B merged by hand\n' > "$work/c.md"
"$bin/hiya-mem-write.sh" notes "$work/c.md" --base-hash "$h1" \
  || fail "CAS with fresh hash should land"

printf 'PASS: cas\n'
