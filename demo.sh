#!/usr/bin/env bash
# demo.sh — end-to-end narrative demo of hiya.
#
# Two sessions share one home: they race for a task (exactly one wins, and
# gets an isolated git worktree for it), get wakes routed to the right
# inboxes (a wake for a task nobody owns waits for its next claimant),
# collide on a memory file (CAS lands one write, journals the other),
# curation folds the journal, and a dead session's lease is reaped — its
# half-done worktree survives for the next claimant, who must commit or
# --discard before the task can go done. Runs in ./demo-home (wiped at start).
set -u

here=$(cd "$(dirname "$0")" && pwd)
bin="$here/bin"
export HIYA_HOME="${HIYA_DEMO_HOME:-$here/demo-home}"
rm -rf "$HIYA_HOME"

step() { printf '\n== %s\n' "$*"; }
run()  { printf '$ %s\n' "$*"; "$@"; }

step "Seed a toy git repo — HIYA_REPO gives every claim an isolated worktree"
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@hiya \
       GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@hiya
repo="$HIYA_HOME/repo"
mkdir -p "$HIYA_HOME"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" commit -q --allow-empty -m "initial commit"
export HIYA_REPO="$repo"
printf 'HIYA_REPO=%s\n' "$HIYA_REPO"

step "The first session joins — and, being first, bootstraps the home"
out=$("$bin/hiya-join.sh")
printf '%s\n' "$out"
s1=$(printf '%s\n' "$out" | awk '/^sid:/ { print $2 }')

step "Tasks enter the backlog through hiya-add.sh (never by hand: it is lock-protected)"
run "$bin/hiya-add.sh" t1 "Ship the release notes"
run "$bin/hiya-add.sh" t2 "Triage the flaky test"
run "$bin/hiya-add.sh" t3 "Refactor the parser"
if "$bin/hiya-add.sh" t3 "Refactor the parser, again"; then
  printf 'demo: BROKEN INVARIANT: a duplicate task id must be refused\n' >&2
  exit 1
else
  printf '(exit %s: duplicate id refused)\n' "$?"
fi

step "A second session joins; its digest shows the queued tasks"
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
printf '%s won the race; %s lost cleanly (only the winner got a worktree)\n' \
  "$winner" "$loser"

step "The loser picks up a different task instead — and gets its worktree"
run "$bin/hiya-claim.sh" "$loser" t2

step "The loser starts on t2 in its isolated worktree (uncommitted so far)"
printf 'flaky test root cause: timezone assumption\n' \
  > "$HIYA_HOME/work/t2/findings.txt"
printf 'wrote work/t2/findings.txt (not committed)\n'
run "$bin/hiya-workspace.sh" t2 --status

step "Wakes are enqueued, then the elected watcher routes them"
run "$bin/hiya-wake.sh" t1 "ci: build green"
run "$bin/hiya-wake.sh" t2 "review requested"
run "$bin/hiya-wake.sh" t3 "design doc updated (nobody owns t3 yet)"
run "$bin/hiya-watch.sh" "$winner" --once

step "Each session drains its own inbox; the unowned wake is parked, not lost"
printf '[%s inbox]\n' "$winner"
run "$bin/hiya-inbox.sh" "$winner" --drain
printf '[%s inbox]\n' "$loser"
run "$bin/hiya-inbox.sh" "$loser" --drain
printf '[unrouted]\n'
run "$bin/hiya-inbox.sh" --unrouted

step "Whoever claims t3 next adopts the wake that was waiting for it"
run "$bin/hiya-claim.sh" "$winner" t3
run "$bin/hiya-inbox.sh" "$winner" --drain

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

step "The crashed session's worktree survived the reap — work is not lost"
run "$bin/hiya-workspace.sh" t2 --status
printf -- '--- work/t2/findings.txt ---\n'
cat "$HIYA_HOME/work/t2/findings.txt"

step "The next claimant re-attaches to the surviving workspace"
run "$bin/hiya-claim.sh" "$winner" t2
printf 'findings.txt is still there: "%s"\n' "$(cat "$HIYA_HOME/work/t2/findings.txt")"

step "Done with uncommitted work is refused — nothing is silently lost"
if "$bin/hiya-release.sh" "$winner" t2 --done; then
  printf 'demo: BROKEN INVARIANT: dirty done must be refused\n' >&2
  exit 1
else
  printf '(exit %s: dirty workspace; the lease and the work are untouched)\n' "$?"
fi

step "Commit the inherited work, then done tears the worktree down cleanly"
git -C "$HIYA_HOME/work/t2" add findings.txt
git -C "$HIYA_HOME/work/t2" commit -q -m "triage: flaky test is a timezone bug"
run "$bin/hiya-release.sh" "$winner" t2 --done
printf 'branch hiya/t2 kept in the repo: %s\n' \
  "$(git -C "$repo" log --oneline -1 hiya/t2)"

step "t1 went nowhere — scribbles are discarded explicitly, never silently"
printf 'dead end\n' > "$HIYA_HOME/work/t1/scratch.txt"
if "$bin/hiya-release.sh" "$winner" t1 --done 2>/dev/null; then
  printf 'demo: BROKEN INVARIANT: dirty done must be refused\n' >&2
  exit 1
else
  printf '(exit %s: refused again — so we opt in to losing the scratch)\n' "$?"
fi
run "$bin/hiya-release.sh" "$winner" t1 --done --discard

step "A late session joins and sees the digest of what remains"
run "$bin/hiya-join.sh"

step "Demo complete"
exit 0
