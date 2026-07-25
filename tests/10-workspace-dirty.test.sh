#!/usr/bin/env bash
# workspace dirty guard: --done on a dirty worktree is refused with exit 3
# and changes nothing; --done --discard then forces the teardown.
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
printf 't1\tqueued\tMessy task\n' > "$HIYA_HOME/data/backlog.md"
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null 2>&1 || fail "claim failed"
wt="$HIYA_HOME/work/t1"
printf 'half-done\n' > "$wt/wip.txt"   # untracked file = dirty

"$bin/hiya-release.sh" "$s1" t1 --done > /dev/null 2> "$work/err"
rc=$?
[ "$rc" -eq 3 ] || fail "dirty done exited $rc, expected 3: $(cat "$work/err")"
grep -q "uncommitted work" "$work/err" || fail "wrong refusal: $(cat "$work/err")"

# the refusal left everything untouched
[ -f "$wt/wip.txt" ] || fail "dirty file lost by refused done"
[ -f "$HIYA_HOME/state/workspaces/t1" ] || fail "registry record lost"
[ "$(awk -F= '$1 == "owner" { print $2 }' "$HIYA_HOME/state/leases/t1")" = "$s1" ] \
  || fail "lease lost by refused done"
st=$(awk -F '\t' '$1 == "t1" { print $2 }' "$HIYA_HOME/data/backlog.md")
[ "$st" = "claimed" ] || fail "backlog state is '$st', not claimed"
"$bin/hiya-workspace.sh" t1 --status | grep -q "^state=dirty$" \
  || fail "status does not report dirty"

# --discard forces the teardown through
out=$("$bin/hiya-release.sh" "$s1" t1 --done --discard 2>&1) \
  || fail "discard done failed: $out"
[ ! -e "$wt" ] || fail "worktree survived --discard"
[ ! -e "$HIYA_HOME/state/workspaces/t1" ] || fail "record survived --discard"
st=$(awk -F '\t' '$1 == "t1" { print $2 }' "$HIYA_HOME/data/backlog.md")
[ "$st" = "done" ] || fail "backlog state is '$st', not done"

printf 'PASS: workspace dirty guard\n'
