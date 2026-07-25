#!/usr/bin/env bash
# workspace survives reap: a reaped session's workspace (and its uncommitted
# file) is untouched, and the next claimant re-attaches to it.
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
printf 't1\tqueued\tSurvivor task\n' > "$HIYA_HOME/data/backlog.md"
"$bin/hiya-claim.sh" "$s2" t1 > /dev/null 2>&1 || fail "claim failed"
wt="$HIYA_HOME/work/t1"
printf 'half-done work\n' > "$wt/progress.txt"   # uncommitted, pre-crash

# s2 crashes (heartbeat ages out); s1's heartbeat pass reaps it
touch -t 202001010000 "$HIYA_HOME/state/sessions/$s2/heartbeat"
out=$("$bin/hiya-heartbeat.sh" "$s1") || fail "heartbeat failed: $out"
printf '%s\n' "$out" | grep -q "reaped $s2" || fail "no reap reported: $out"
st=$(awk -F '\t' '$1 == "t1" { print $2 }' "$HIYA_HOME/data/backlog.md")
[ "$st" = "queued" ] || fail "task not requeued: $st"

# the workspace outlives the lease
[ -f "$HIYA_HOME/state/workspaces/t1" ] || fail "registry record reaped"
[ -f "$wt/progress.txt" ] || fail "pre-crash file lost"

# next claimant re-attaches and finds the half-done work
out=$("$bin/hiya-claim.sh" "$s1" t1 2>&1) || fail "re-claim failed: $out"
printf '%s\n' "$out" | grep -q "re-attached workspace" \
  || fail "no re-attach message: $out"
[ -f "$wt/progress.txt" ] || fail "file lost across re-attach"
[ "$(cat "$wt/progress.txt")" = "half-done work" ] || fail "file content changed"
br=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
[ "$br" = "hiya/t1" ] || fail "re-attached worktree on '$br', not hiya/t1"

printf 'PASS: workspace survives reap\n'
