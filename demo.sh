#!/usr/bin/env bash
# demo.sh — end-to-end narrative demo of hiya.
#
# Two sessions share one home: they race for a task (exactly one wins), get
# wakes routed to the right inboxes, collide on a memory file (CAS lands one
# write, journals the other), curation folds the journal, and a dead
# session's lease is reaped. Runs in ./demo-home (wiped at start).
set -u

here=$(cd "$(dirname "$0")" && pwd)
bin="$here/bin"
export HIYA_HOME="${HIYA_DEMO_HOME:-$here/demo-home}"
rm -rf "$HIYA_HOME"

step() { printf '\n== %s\n' "$*"; }
run()  { printf '$ %s\n' "$*"; "$@"; }

step "Seed a backlog (one task per line: id<TAB>state<TAB>title)"
mkdir -p "$HIYA_HOME/data"
printf 't1\tqueued\tShip the release notes\nt2\tqueued\tTriage the flaky test\nt3\tqueued\tRefactor the parser\n' \
  > "$HIYA_HOME/data/backlog.md"
cat "$HIYA_HOME/data/backlog.md"

step "Two sessions join; only the FIRST joiner bootstraps the home"
out=$("$bin/hiya-join.sh")
printf '%s\n' "$out"
s1=$(printf '%s\n' "$out" | awk '/^sid:/ { print $2 }')
printf -- '---\n'
out=$("$bin/hiya-join.sh")
printf '%s\n' "$out"
s2=$(printf '%s\n' "$out" | awk '/^sid:/ { print $2 }')

step "Both sessions race to claim t1 — exactly one may win"
"$bin/hiya-claim.sh" "$s1" t1 > "$HIYA_HOME/.race-a" 2>&1 &
pa=$!
"$bin/hiya-claim.sh" "$s2" t1 > "$HIYA_HOME/.race-b" 2>&1 &
pb=$!
wait "$pa"; ra=$?
wait "$pb"; rb=$?
printf '[%s] exit %s: %s\n' "$s1" "$ra" "$(cat "$HIYA_HOME/.race-a")"
printf '[%s] exit %s: %s\n' "$s2" "$rb" "$(cat "$HIYA_HOME/.race-b")"
wins=0
[ "$ra" -eq 0 ] && wins=$((wins + 1))
[ "$rb" -eq 0 ] && wins=$((wins + 1))
if [ "$wins" -ne 1 ]; then
  printf 'demo: BROKEN INVARIANT: expected exactly one winner, got %s\n' "$wins" >&2
  exit 1
fi
if [ "$ra" -eq 0 ]; then winner=$s1 loser=$s2; else winner=$s2 loser=$s1; fi
printf '%s won the race; %s lost cleanly\n' "$winner" "$loser"

step "The loser picks up a different task instead"
run "$bin/hiya-claim.sh" "$loser" t2

step "Wakes are enqueued, then the elected watcher routes them"
run "$bin/hiya-wake.sh" t1 "ci: build green"
run "$bin/hiya-wake.sh" t2 "review requested"
run "$bin/hiya-wake.sh" t9 "orphan ping (nobody leases t9)"
run "$bin/hiya-watch.sh" "$winner" --once

step "Each session drains its own inbox (orphan fell to the watcher)"
printf '[%s inbox]\n' "$winner"
run "$bin/hiya-inbox.sh" "$winner" --drain
printf '[%s inbox]\n' "$loser"
run "$bin/hiya-inbox.sh" "$loser" --drain

step "Both sessions edit the same memory — CAS lands one, journals the other"
h0=$("$bin/hiya-mem-write.sh" --show-hash notes)
printf 'both sessions read base hash: %s\n' "$h0"
printf '# notes\n\n%s: the parser refactor plan looks good\n' "$winner" > "$HIYA_HOME/.mem-a"
printf '# notes\n\n%s: the flaky test is a timezone bug\n' "$loser" > "$HIYA_HOME/.mem-b"
run "$bin/hiya-mem-write.sh" notes "$HIYA_HOME/.mem-a" --base-hash "$h0"
if "$bin/hiya-mem-write.sh" notes "$HIYA_HOME/.mem-b" --base-hash "$h0"; then
  printf 'demo: BROKEN INVARIANT: second write should have conflicted\n' >&2
  exit 1
else
  printf '(exit %s: journaled, not clobbered)\n' "$?"
fi

step "Curation folds the journaled intent into the memory file"
run "$bin/hiya-curate.sh"
printf -- '--- data/memory/notes.md ---\n'
cat "$HIYA_HOME/data/memory/notes.md"

step "A session goes silent (heartbeat aged); the reaper frees its lease"
touch -t 202001010000 "$HIYA_HOME/state/sessions/$loser/heartbeat"
printf 'aged %s heartbeat to January 2020\n' "$loser"
run "$bin/hiya-heartbeat.sh" "$winner"
printf -- '--- backlog after reap (t2 back to queued) ---\n'
cat "$HIYA_HOME/data/backlog.md"

step "A late session joins and sees the digest of what remains"
run "$bin/hiya-join.sh"

step "Demo complete"
exit 0
