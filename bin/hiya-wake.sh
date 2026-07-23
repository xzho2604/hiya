#!/usr/bin/env bash
# hiya-wake.sh — enqueue a wake record on the durable wake queue.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-wake.sh <task-id> <payload> [--help]

Append a wake record to the durable, append-only wake queue
(state/wake-queue). Appends are serialized under the wake lock and the
sequence number is monotonically increasing across all producers. The
elected watcher (hiya-watch.sh) routes records to inboxes.

Record format: epoch<TAB>seq<TAB>task-id<TAB>payload (one line; payloads
must not contain newlines).

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
payload=$2
hiya_require_home
nl='
'
case $payload in
  *"$nl"*) hiya_die "payload must be a single line" ;;
esac

wake_impl() {
  local seqf seq
  seqf="$HIYA_HOME/state/.wake-seq"
  seq=$(cat "$seqf" 2>/dev/null || printf '0')
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seqf"
  printf '%s\t%s\t%s\t%s\n' "$(hiya_now)" "$seq" "$task" "$payload" \
    >> "$HIYA_HOME/state/wake-queue"
  printf 'wake %s queued for %s\n' "$seq" "$task"
}

with_lock wake wake_impl
