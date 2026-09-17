#!/usr/bin/env bash
# hiya-release.sh — release a task lease held by a session.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-release.sh <sid> <task-id> [--done [--discard]] [--help]

Release <sid>'s lease on <task-id>. The task goes back to "queued", or to
"done" with --done. Refuses (exit 2) if <sid> does not hold the lease.

Workspace lifecycle (only when the task has a workspace record):
  - plain release: the worktree and branch are preserved untouched; the
    next claimant re-attaches to them.
  - --done: the worktree is torn down and the registry record removed
    (branch hiya/<task-id> is kept — it holds the committed work). If the
    worktree is DIRTY (uncommitted changes or untracked files) the WHOLE
    done is refused with exit 3 and nothing changes: commit the work in
    the worktree, or pass --discard.
  - --done --discard: DESTRUCTIVE — tears down a dirty worktree, throwing
    away uncommitted changes and untracked files (commits on the branch
    survive).

exit status:
  0  released
  1  usage error, or worktree teardown failed (lease untouched)
  2  refused: caller does not hold the lease
  3  refused: --done on a dirty workspace (lease untouched)

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

sid=
task=
new_state=queued
discard=
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --done) new_state="done" ;;
    --discard) discard=1 ;;
    -*) usage >&2; exit 1 ;;
    *)
      if [ -z "$sid" ]; then sid=$1
      elif [ -z "$task" ]; then task=$1
      else usage >&2; exit 1
      fi
      ;;
  esac
  shift
done
if [ -z "$sid" ] || [ -z "$task" ]; then
  usage >&2
  exit 1
fi
if [ -n "$discard" ] && [ "$new_state" != "done" ]; then
  printf 'hiya-release: --discard only makes sense with --done\n' >&2
  exit 1
fi

hiya_require_home

# shellcheck disable=SC2329  # invoked indirectly via with_lock
teardown_impl() {
  # Tear down the task workspace for --done. Runs under the workspaces lock
  # (inside the backlog lock — lock order: sessions -> backlog -> workspaces).
  # Returns 3 without touching anything when the worktree is dirty and
  # --discard was not given, so the whole done is refused.
  local rec wpath wrepo wbranch
  rec=$(hiya_workspace_rec "$task")
  [ -f "$rec" ] || return 0
  wpath=$(workspace_field "$task" path)
  wrepo=$(workspace_field "$task" repo)
  wbranch=$(workspace_field "$task" branch)
  if [ -d "$wpath" ]; then
    if [ -z "$discard" ] && workspace_dirty "$wpath"; then
      printf 'hiya-release: refused: workspace %s has uncommitted work\n' \
        "$wpath" >&2
      printf 'hiya-release: commit it there, or force teardown with --done --discard\n' >&2
      return 3
    fi
    # git runs without our lock fds (hiya_unlocked): whatever it spawns must
    # not outlive this critical section holding the backlog lock
    if [ -n "$discard" ]; then
      hiya_unlocked git -C "$wrepo" worktree remove --force "$wpath" || return 1
    else
      hiya_unlocked git -C "$wrepo" worktree remove "$wpath" || return 1
    fi
  else
    hiya_unlocked git -C "$wrepo" worktree prune 2>/dev/null || true
  fi
  rm -f "$rec"
  printf 'workspace %s removed (branch %s kept)\n' "$wpath" "$wbranch"
}

release_impl() {
  local owner ws_rc
  owner=$(lease_owner "$task")
  if [ -z "$owner" ]; then
    printf 'hiya-release: refused: %s is not leased\n' "$task" >&2
    return 2
  fi
  if [ "$owner" != "$sid" ]; then
    printf 'hiya-release: refused: %s is held by %s, not %s\n' \
      "$task" "$owner" "$sid" >&2
    return 2
  fi
  # no record, no workspace work: a home without HIYA_REPO never even touches
  # the workspaces lock. (Safe to check first: we hold the task's lease and
  # the backlog lock, so nothing can be provisioning this task right now.)
  if [ "$new_state" = "done" ] && [ -f "$(hiya_workspace_rec "$task")" ]; then
    ws_rc=0
    with_lock workspaces teardown_impl || ws_rc=$?
    [ "$ws_rc" -eq 0 ] || return "$ws_rc"
  fi
  rm -f "$(hiya_lease_file "$task")"
  backlog_set_state "$task" "$new_state"
  printf '%s released by %s -> %s\n' "$task" "$sid" "$new_state"
}

with_lock backlog release_impl
