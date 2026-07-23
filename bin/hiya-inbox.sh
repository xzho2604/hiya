#!/usr/bin/env bash
# hiya-inbox.sh — list or drain a session's inbox.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-inbox.sh <sid> [--drain] [--help]

Print the wake records in <sid>'s inbox in seq order (inbox files are named
by zero-padded seq, so lexical order is seq order). With --drain, each
record is removed after printing.

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

sid=
drain=0
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --drain) drain=1 ;;
    -*) usage >&2; exit 1 ;;
    *)
      if [ -z "$sid" ]; then sid=$1; else usage >&2; exit 1; fi
      ;;
  esac
  shift
done
if [ -z "$sid" ]; then
  usage >&2
  exit 1
fi

hiya_require_home
inbox="$(hiya_session_dir "$sid")/inbox"
[ -d "$inbox" ] || hiya_die "unknown or dead session '$sid'"

for f in "$inbox"/*; do
  [ -f "$f" ] || continue
  cat "$f"
  if [ "$drain" -eq 1 ]; then
    rm -f "$f"
  fi
done
exit 0
