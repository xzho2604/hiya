#!/usr/bin/env bash
# workspace claim: with HIYA_REPO set, a claim provisions a git worktree on
# the task branch and records it in the workspace registry.
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
"$bin/hiya-add.sh" t1 "Worktree task" > /dev/null || fail "add failed"
out=$("$bin/hiya-claim.sh" "$s1" t1 2>&1) || fail "claim failed: $out"
printf '%s\n' "$out" | grep -q "provisioned workspace" \
  || fail "no provision message: $out"

wt="$HIYA_HOME/work/t1"
[ -e "$wt/.git" ] || fail "no worktree at $wt"
br=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
[ "$br" = "hiya/t1" ] || fail "worktree on '$br', not hiya/t1"

rec="$HIYA_HOME/state/workspaces/t1"
[ -f "$rec" ] || fail "no registry record"
grep -q "^branch=hiya/t1$" "$rec" || fail "record missing branch: $(cat "$rec")"
grep -q "^path=" "$rec" || fail "record missing path"
grep -q "^created_at=" "$rec" || fail "record missing created_at"
rpath=$(awk -F= '$1 == "path" { print $2 }' "$rec")
[ -d "$rpath" ] || fail "recorded path '$rpath' does not exist"

# the status tool sees a clean, leased workspace
st=$("$bin/hiya-workspace.sh" t1 --status) || fail "workspace status failed"
printf '%s\n' "$st" | grep -q "^state=clean$" || fail "not clean: $st"
printf '%s\n' "$st" | grep -q "^lease=$s1$" || fail "wrong lease: $st"
[ "$("$bin/hiya-workspace.sh" t1 --path)" = "$rpath" ] || fail "--path mismatch"

printf 'PASS: workspace claim\n'
