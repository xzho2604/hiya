#!/usr/bin/env bash
# hiya-inbox.sh — list or drain a session's inbox, or the unrouted wakes.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-inbox.sh <sid> [--drain] [--help]
       hiya-inbox.sh --unrouted [--drain]

Print the wake records in <sid>'s inbox in seq order (inbox files are named
by zero-padded seq, so lexical order is seq order). With --drain, each
record is removed after printing.

--unrouted lists the home-level state/unrouted/ instead: wakes whose task
had no live owner when they were routed. They are not lost — the task's next
claimant adopts them — so --drain here is for wakes nobody will ever claim
(say, a task id that does not exist).

Delivery is at-least-once: after a watcher crash a record can show up again.
The seq (second field) identifies a record.

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

sid=
drain=0
unrouted=0
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --drain) drain=1 ;;
    --unrouted) unrouted=1 ;;
    -*) usage >&2; exit 1 ;;
    *)
      if [ -z "$sid" ]; then sid=$1; else usage >&2; exit 1; fi
      ;;
  esac
  shift
done
if [ "$unrouted" -eq 1 ] && [ -n "$sid" ]; then
  usage >&2
  exit 1
fi
if [ "$unrouted" -eq 0 ] && [ -z "$sid" ]; then
  usage >&2
  exit 1
fi

hiya_require_home
if [ "$unrouted" -eq 1 ]; then
  inbox=$(hiya_unrouted_dir)
  [ -d "$inbox" ] || exit 0   # a home from before unrouted/ existed
else
  inbox="$(hiya_session_dir "$sid")/inbox"
  [ -d "$inbox" ] || hiya_die "unknown or dead session '$sid'"
fi

for f in "$inbox"/*; do
  [ -f "$f" ] || continue
  cat "$f"
  if [ "$drain" -eq 1 ]; then
    rm -f "$f"
  fi
done
exit 0
