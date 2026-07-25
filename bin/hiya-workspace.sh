#!/usr/bin/env bash
# hiya-workspace.sh — inspect or clean up a task's git workspace.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-workspace.sh <task-id> [--path|--status|--discard] [--help]

Inspect or explicitly clean up the git workspace of a task (registry record
under state/workspaces/<task-id>, worktree under $HIYA_HOME/work/<task-id>).

  --status   (default) print the registry record, the lease owner, and the
             workspace state: clean, dirty, or missing (worktree gone).
  --path     print just the worktree path.
  --discard  DESTRUCTIVE: force-remove the worktree (uncommitted changes and
             untracked files are lost; commits on the branch survive) and
             delete the registry record. Meant for orphaned workspaces —
             refused while the task is leased (the owner should use
             hiya-release.sh instead).

exit status:
  0  ok
  1  no workspace record for the task
  2  refused: --discard while the task is leased

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

task=
mode=status
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --path) mode=path ;;
    --status) mode=status ;;
    --discard) mode=discard ;;
    -*) usage >&2; exit 1 ;;
    *)
      if [ -z "$task" ]; then task=$1
      else usage >&2; exit 1
      fi
      ;;
  esac
  shift
done
if [ -z "$task" ]; then
  usage >&2
  exit 1
fi

hiya_require_home
rec=$(hiya_workspace_rec "$task")

# shellcheck disable=SC2329  # invoked indirectly via with_lock
discard_impl() {
  # Runs under backlog -> workspaces locks (the home's lock order), so the
  # lease check and the teardown are one atomic decision.
  local owner wpath wrepo wbranch
  if [ ! -f "$rec" ]; then
    printf 'hiya-workspace: no workspace for %s\n' "$task" >&2
    return 1
  fi
  owner=$(lease_owner "$task")
  if [ -n "$owner" ]; then
    printf 'hiya-workspace: refused: %s is leased by %s (use hiya-release.sh)\n' \
      "$task" "$owner" >&2
    return 2
  fi
  wpath=$(workspace_field "$task" path)
  wrepo=$(workspace_field "$task" repo)
  wbranch=$(workspace_field "$task" branch)
  if [ -d "$wpath" ]; then
    if ! git -C "$wrepo" worktree remove --force "$wpath" 2>/dev/null; then
      # repo gone or worktree unregistered: fall back to deleting the dir
      rm -rf "$wpath"
      git -C "$wrepo" worktree prune 2>/dev/null || true
    fi
  else
    git -C "$wrepo" worktree prune 2>/dev/null || true
  fi
  rm -f "$rec"
  printf 'workspace for %s discarded (branch %s kept)\n' "$task" "$wbranch"
}

case $mode in
  path)
    [ -f "$rec" ] || hiya_die "no workspace for '$task'"
    workspace_field "$task" path
    ;;
  status)
    [ -f "$rec" ] || hiya_die "no workspace for '$task'"
    cat "$rec"
    owner=$(lease_owner "$task")
    printf 'lease=%s\n' "${owner:-none}"
    wpath=$(workspace_field "$task" path)
    if [ ! -d "$wpath" ]; then
      printf 'state=missing\n'
    elif workspace_dirty "$wpath"; then
      printf 'state=dirty\n'
    else
      printf 'state=clean\n'
    fi
    ;;
  discard)
    with_lock backlog with_lock workspaces discard_impl
    ;;
esac
