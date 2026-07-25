#!/usr/bin/env bash
# workspace + transfer: the workspace is task-keyed, so a lease handoff needs
# no workspace work — the new owner uses the same worktree and can finish.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
join() { "$bin/hiya-join.sh" | awk '/^sid:/ { print $2 }'; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
repo="$work/repo"
git -c init.defaultBranch=main init -q "$repo" || fail "git init failed"
git -C "$repo" commit -q --allow-empty -m init || fail "seed commit failed"
export HIYA_REPO="$repo"

s1=$(join)
s2=$(join)
printf 't1\tqueued\tHandoff task\n' > "$HIYA_HOME/data/backlog.md"
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null 2>&1 || fail "claim failed"
wt="$HIYA_HOME/work/t1"
printf 's1 started this\n' > "$wt/handoff.txt"
rec_before=$(cat "$HIYA_HOME/state/workspaces/t1")

"$bin/hiya-transfer.sh" "$s1" "$s2" t1 > /dev/null || fail "transfer failed"

# the workspace record and worktree are untouched by the handoff
[ "$(cat "$HIYA_HOME/state/workspaces/t1")" = "$rec_before" ] \
  || fail "transfer changed the workspace record"
[ -f "$wt/handoff.txt" ] || fail "worktree file lost in transfer"

# new owner finishes: commit the inherited work, then a clean done
git -C "$wt" add handoff.txt || fail "git add failed"
git -C "$wt" commit -q -m "finish handoff" || fail "git commit failed"
"$bin/hiya-release.sh" "$s2" t1 --done > /dev/null || fail "done by new owner failed"
[ ! -e "$wt" ] || fail "worktree survived done"
[ ! -e "$HIYA_HOME/state/workspaces/t1" ] || fail "record survived done"
git -C "$repo" log --oneline hiya/t1 | grep -q "finish handoff" \
  || fail "handoff commit missing from kept branch"

printf 'PASS: workspace transfer\n'
