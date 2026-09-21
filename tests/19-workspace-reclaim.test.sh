#!/usr/bin/env bash
# re-claim with a kept branch (report probe p1): task branches outlive --done
# and workspace --discard by design, so a fresh claim must attach to the kept
# branch — and the commits on it — instead of dying on `worktree add -b`.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
join() { "$bin/hiya-join.sh" | awk '/^sid:/ { print $2 }'; }
state_of() { awk -F '\t' -v id="$1" '$1 == id { print $2 }' "$HIYA_HOME/data/backlog.md"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
repo="$work/repo"
git -c init.defaultBranch=main init -q "$repo" || fail "git init failed"
git -C "$repo" commit -q --allow-empty -m init || fail "seed commit failed"
export HIYA_REPO="$repo"

s1=$(join)
"$bin/hiya-add.sh" t1 "Discarded then resumed" > /dev/null || fail "add t1 failed"
"$bin/hiya-add.sh" t2 "Done then reopened" > /dev/null || fail "add t2 failed"

commit_in() {
  # commit_in <task> <file> — commit one file in the task's worktree
  printf 'work on %s\n' "$1" > "$HIYA_HOME/work/$1/$2"
  git -C "$HIYA_HOME/work/$1" add "$2" || fail "git add failed"
  git -C "$HIYA_HOME/work/$1" commit -q -m "work on $1" || fail "git commit failed"
}

# --- path 1: release, discard the orphaned workspace, claim again
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null 2>&1 || fail "claim t1 failed"
commit_in t1 first.txt
"$bin/hiya-release.sh" "$s1" t1 > /dev/null || fail "release t1 failed"
"$bin/hiya-workspace.sh" t1 --discard > /dev/null || fail "discard t1 failed"
git -C "$repo" show-ref --verify --quiet refs/heads/hiya/t1 || fail "setup: branch not kept"

out=$("$bin/hiya-claim.sh" "$s1" t1 2>&1) || fail "re-claim after --discard failed: $out"
printf '%s\n' "$out" | grep -q "provisioned workspace" || fail "no provision message: $out"
[ "$(state_of t1)" = "claimed" ] || fail "t1 is '$(state_of t1)', not claimed"
br=$(git -C "$HIYA_HOME/work/t1" rev-parse --abbrev-ref HEAD)
[ "$br" = "hiya/t1" ] || fail "re-claimed worktree on '$br', not hiya/t1"
[ -f "$HIYA_HOME/work/t1/first.txt" ] || fail "kept branch's commit missing from the worktree"
[ -f "$HIYA_HOME/state/workspaces/t1" ] || fail "no registry record after re-claim"

# --- path 2: finish the task, reopen it, claim again
"$bin/hiya-claim.sh" "$s1" t2 > /dev/null 2>&1 || fail "claim t2 failed"
commit_in t2 second.txt
"$bin/hiya-release.sh" "$s1" t2 --done > /dev/null || fail "done t2 failed"
# reopen t2. No tool requeues a done task; editing backlog.md by hand is safe
# only because nothing else is running against this home right now.
awk -F '\t' -v OFS='\t' '$1 == "t2" { $2 = "queued" } { print }' \
  "$HIYA_HOME/data/backlog.md" > "$work/backlog.new" \
  && mv "$work/backlog.new" "$HIYA_HOME/data/backlog.md"

out=$("$bin/hiya-claim.sh" "$s1" t2 2>&1) || fail "re-claim after --done failed: $out"
[ "$(state_of t2)" = "claimed" ] || fail "t2 is '$(state_of t2)', not claimed"
[ -f "$HIYA_HOME/work/t2/second.txt" ] || fail "kept branch's commit missing after --done"

# a failed provision still rolls the claim back (the guard the fix must keep)
"$bin/hiya-add.sh" t3 "Unprovisionable" > /dev/null || fail "add t3 failed"
mkdir -p "$HIYA_HOME/work/t3"
printf 'in the way\n' > "$HIYA_HOME/work/t3/blocker"
"$bin/hiya-claim.sh" "$s1" t3 > /dev/null 2>&1 && fail "claim over a blocked path must fail"
[ "$(state_of t3)" = "queued" ] || fail "failed provision left t3 '$(state_of t3)'"
[ ! -e "$HIYA_HOME/state/leases/t3" ] || fail "failed provision left a lease"

printf 'PASS: workspace re-claim\n'
