#!/usr/bin/env bash
# tests/run.sh — run every tests/*.test.sh and summarize.
set -u

here=$(cd "$(dirname "$0")" && pwd)
pass=0
fail=0
for t in "$here"/*.test.sh; do
  [ -f "$t" ] || continue
  name=$(basename "$t")
  if out=$(bash "$t" 2>&1); then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$name"
    printf '%s\n' "$out" | sed 's/^/     /'
  fi
done
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
