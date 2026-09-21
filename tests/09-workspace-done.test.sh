#!/usr/bin/env bash
# workspace done: --done with a clean worktree removes the worktree and the
# registry record; the task branch survives in the repo.
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
"$bin/hiya-add.sh" t1 "Clean finish" > /dev/null || fail "add failed"
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null 2>&1 || fail "claim failed"

# commit some work so the branch has something to keep
wt="$HIYA_HOME/work/t1"
printf 'result\n' > "$wt/result.txt"
git -C "$wt" add result.txt || fail "git add failed"
git -C "$wt" commit -q -m "task work" || fail "git commit failed"

out=$("$bin/hiya-release.sh" "$s1" t1 --done 2>&1) || fail "done failed: $out"
printf '%s\n' "$out" | grep -q "workspace .* removed" \
  || fail "no teardown message: $out"

[ ! -e "$wt" ] || fail "worktree still present"
[ ! -e "$HIYA_HOME/state/workspaces/t1" ] || fail "registry record survived"
[ ! -e "$HIYA_HOME/state/leases/t1" ] || fail "lease survived"
st=$(awk -F '\t' '$1 == "t1" { print $2 }' "$HIYA_HOME/data/backlog.md")
[ "$st" = "done" ] || fail "backlog state is '$st', not done"
git -C "$repo" worktree list | grep -q "work/t1" && fail "worktree still registered"

# the branch (the deliverable) is kept, with the commit on it
git -C "$repo" show-ref --verify --quiet refs/heads/hiya/t1 \
  || fail "branch hiya/t1 was deleted"
git -C "$repo" log --oneline hiya/t1 | grep -q "task work" \
  || fail "commit missing from kept branch"

printf 'PASS: workspace done\n'
