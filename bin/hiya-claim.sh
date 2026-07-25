#!/usr/bin/env bash
# hiya-claim.sh — atomically claim a queued task for a session.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-claim.sh <sid> <task-id> [--help]

Claim-on-dispatch: under the backlog lock, verify the task is "queued" and
unleased, then write the lease (owner=<sid>, claimed_at=<epoch>) AND flip the
backlog state to "claimed" in the same critical section. Losing a claim race
exits non-zero with "already claimed by <sid>".

With HIYA_REPO set, a claim also gets an isolated git worktree, provisioned
immediately after the claim critical section (the lease serializes workspace
access; the "workspaces" lock guards the registry). A fresh claim creates
$HIYA_HOME/work/<task-id> on new branch hiya/<task-id> and records it under
state/workspaces/<task-id>; a task with an existing record (requeued after a
crash, or transferred) re-attaches to its surviving workspace instead, so
half-done work carries over. If provisioning fails the claim is rolled back
(task returns to "queued") and the tool exits 1.

exit status:
  0  claim won
  1  claim lost (already claimed / not queued / unknown task), or
     workspace provisioning failed and the claim was rolled back

environment:
  HIYA_HOME  home directory (default ./home)
  HIYA_REPO  git repository to provision per-task worktrees from (optional;
             unset = claims carry no workspace)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -ne 2 ]; then
  usage >&2
  exit 1
fi

sid=$1
task=$2
hiya_require_home
session_alive "$sid" || hiya_die "unknown or dead session '$sid' (did you join?)"

claim_impl() {
  local st owner
  owner=$(lease_owner "$task")
  if [ -n "$owner" ]; then
    printf 'hiya-claim: %s already claimed by %s\n' "$task" "$owner" >&2
    return 1
  fi
  st=$(backlog_state "$task")
  if [ -z "$st" ]; then
    printf 'hiya-claim: unknown task %s\n' "$task" >&2
    return 1
  fi
  if [ "$st" != "queued" ]; then
    printf 'hiya-claim: %s is %s, not queued\n' "$task" "$st" >&2
    return 1
  fi
  {
    printf 'owner=%s\n' "$sid"
    printf 'claimed_at=%s\n' "$(hiya_now)"
  } | atomic_write "$(hiya_lease_file "$task")"
  backlog_set_state "$task" claimed
  printf '%s claimed by %s\n' "$task" "$sid"
}

# shellcheck disable=SC2329  # invoked indirectly via with_lock
provision_impl() {
  # Provision (or re-attach) the task workspace. Runs under the workspaces
  # lock, after the claim critical section: the lease already names $sid the
  # only legitimate workspace user, so the lock only guards registry writes.
  local rec wpath branch repo_abs
  rec=$(hiya_workspace_rec "$task")
  if [ -f "$rec" ]; then
    wpath=$(workspace_field "$task" path)
    branch=$(workspace_field "$task" branch)
    if [ -d "$wpath" ]; then
      printf 're-attached workspace %s (branch %s)\n' "$wpath" "$branch"
      return 0
    fi
    # record without a worktree (removed by hand): rebuild it on the
    # recorded branch so committed work is not lost
    repo_abs=$(workspace_field "$task" repo)
    git -C "$repo_abs" worktree prune 2>/dev/null
    if git -C "$repo_abs" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$repo_abs" worktree add "$wpath" "$branch" || return 1
    else
      git -C "$repo_abs" worktree add "$wpath" -b "$branch" || return 1
    fi
    printf 're-attached workspace %s (branch %s, worktree rebuilt)\n' \
      "$wpath" "$branch"
    return 0
  fi
  repo_abs=$(cd "$HIYA_REPO" 2>/dev/null && pwd) || {
    printf 'hiya-claim: HIYA_REPO %s does not exist\n' "$HIYA_REPO" >&2
    return 1
  }
  branch="hiya/$task"
  mkdir -p "$HIYA_HOME/work" "${rec%/*}"
  wpath="$(cd "$HIYA_HOME/work" && pwd)/$task"
  git -C "$repo_abs" worktree add "$wpath" -b "$branch" || return 1
  {
    printf 'path=%s\n' "$wpath"
    printf 'branch=%s\n' "$branch"
    printf 'repo=%s\n' "$repo_abs"
    printf 'created_at=%s\n' "$(hiya_now)"
  } | atomic_write "$rec"
  printf 'provisioned workspace %s (branch %s)\n' "$wpath" "$branch"
}

# shellcheck disable=SC2329  # invoked indirectly via with_lock
rollback_impl() {
  # claim won but the workspace could not be provisioned: undo the claim
  [ "$(lease_owner "$task")" = "$sid" ] || return 0
  rm -f "$(hiya_lease_file "$task")"
  backlog_set_state "$task" queued
}

with_lock backlog claim_impl || exit 1

[ -n "$HIYA_REPO" ] || exit 0
if ! with_lock workspaces provision_impl; then
  with_lock backlog rollback_impl
  hiya_die "workspace provisioning failed for $task; claim rolled back to queued"
fi
