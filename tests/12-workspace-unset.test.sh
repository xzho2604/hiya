#!/usr/bin/env bash
# HIYA_REPO unset: claim/release behave exactly as before and the home gets
# no workspace artifacts at all.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
join() { "$bin/hiya-join.sh" | awk '/^sid:/ { print $2 }'; }

unset HIYA_REPO

s1=$(join)
printf 't1\tqueued\tPlain task\nt2\tqueued\tOther task\n' \
  > "$HIYA_HOME/data/backlog.md"

out=$("$bin/hiya-claim.sh" "$s1" t1 2>&1) || fail "claim failed: $out"
printf '%s\n' "$out" | grep -qi "workspace" && fail "claim mentioned workspace: $out"
[ "$out" = "t1 claimed by $s1" ] || fail "unexpected claim output: $out"

# release back to queued, then claim + done — the plain lifecycle
out=$("$bin/hiya-release.sh" "$s1" t1 2>&1) || fail "release failed: $out"
[ "$out" = "t1 released by $s1 -> queued" ] || fail "unexpected release output: $out"
"$bin/hiya-claim.sh" "$s1" t1 > /dev/null || fail "re-claim failed"
out=$("$bin/hiya-release.sh" "$s1" t1 --done 2>&1) || fail "done failed: $out"
[ "$out" = "t1 released by $s1 -> done" ] || fail "unexpected done output: $out"
st=$(awk -F '\t' '$1 == "t1" { print $2 }' "$HIYA_HOME/data/backlog.md")
[ "$st" = "done" ] || fail "backlog state is '$st', not done"

# no workspace artifacts anywhere in the home
[ ! -e "$HIYA_HOME/work" ] || fail "work/ dir created without HIYA_REPO"
[ ! -e "$HIYA_HOME/state/workspaces" ] || fail "workspace registry created"
[ ! -e "$HIYA_HOME/state/locks/workspaces.lock" ] || fail "workspaces lock taken"

printf 'PASS: workspace unset\n'
