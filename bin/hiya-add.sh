#!/usr/bin/env bash
# hiya-add.sh — add a task to the backlog.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-add.sh <task-id> <title> [--help]

Add <task-id> to data/backlog.md as "queued". The row is written under the
backlog lock, like every other backlog change, so it can never be lost to a
concurrent claim, release, or reap (those rewrite the whole file). Refuses
(exit 2) a task id that is already in the backlog, whatever its state.

backlog.md is written ONLY by the hiya tools. Never append to it by hand
while sessions are live: a hand append races the tools' rewrite-and-rename
and rows get lost.

<task-id> is a simple token: letters, digits, ".", "_" and "-", starting
with a letter or digit (it names a lease file, a worktree dir, and a git
branch). <title> is a single line without tabs.

exit status:
  0  task added
  1  usage error, or invalid task id / title
  2  refused: the task id already exists

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -ne 2 ]; then
  usage >&2
  exit 1
fi

task=$1
title=$2
nl='
'
tab=$(printf '\t')
case $task in
  ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*)
    hiya_die "invalid task id '$task' (letters, digits, '.', '_', '-'; must start with a letter or digit)"
    ;;
esac
case $title in
  '') hiya_die "title must not be empty" ;;
  *"$nl"*|*"$tab"*) hiya_die "title must be a single line without tabs" ;;
esac

hiya_require_home

add_impl() {
  local f tmp st
  f=$(hiya_backlog)
  st=$(backlog_state "$task")
  if [ -n "$st" ]; then
    printf 'hiya-add: refused: %s already exists (%s)\n' "$task" "$st" >&2
    return 2
  fi
  # rewrite + rename like every other backlog writer: a lock-free reader
  # never sees a half-written row, and a backlog whose last line lacks its
  # newline cannot glue the new row onto it
  tmp="$f.tmp.$$"
  if ! {
    awk '{ print }' "$f" && printf '%s\tqueued\t%s\n' "$task" "$title"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$f" || return 1
  printf '%s added (queued)\n' "$task"
}

with_lock backlog add_impl
