#!/usr/bin/env bash
# hiya-join.sh — register a new session with the hiya home.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-join.sh [--help]

Register a new session with the hiya home (HIYA_HOME, default ./home).
The FIRST joiner bootstraps the home layout, guarded by the bootstrap lock,
so exactly one bootstrap happens no matter how many sessions join at once.
A backlog seeded before the first join is kept, not clobbered.

Prints the allocated session id (first line, "sid: <sid>") followed by a
digest of the home: live sessions, current leases, queued tasks, and — if
there are any — the number of unrouted wakes.

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 1 ;;
esac

# shellcheck disable=SC2329  # invoked indirectly via with_lock
bootstrap_impl() {
  if [ ! -f "$HIYA_HOME/state/.bootstrapped" ]; then
    hiya_layout
    hiya_now > "$HIYA_HOME/state/.bootstrapped"
    printf 'bootstrapped %s\n' "$HIYA_HOME"
  fi
}

sid=
# shellcheck disable=SC2329  # invoked indirectly via with_lock
alloc_impl() {
  local counter n dir
  counter="$HIYA_HOME/state/.sid-counter"
  n=$(cat "$counter" 2>/dev/null || printf '0')
  n=$((n + 1))
  printf '%s\n' "$n" > "$counter"
  sid="s$n"
  dir=$(hiya_session_dir "$sid")
  mkdir -p "$dir/inbox"
  : > "$dir/heartbeat"
  {
    printf 'pid=%s\n' "$$"
    printf 'started_at=%s\n' "$(hiya_now)"
  } > "$dir/meta"
}

with_lock bootstrap bootstrap_impl || exit 1
with_lock sessions alloc_impl || exit 1

printf 'sid: %s\n' "$sid"

printf 'live sessions:'
for d in "$(hiya_sessions_dir)"/*/; do
  [ -d "$d" ] || continue
  printf ' %s' "$(basename "$d")"
done
printf '\n'

printf 'leases:\n'
n=0
for f in "$HIYA_HOME/state/leases"/*; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  printf '  %s %s\n' "$(basename "$f")" "$(tr '\n' ' ' < "$f")"
done
if [ "$n" -eq 0 ]; then
  printf '  (none)\n'
fi

printf 'queued tasks:\n'
awk -F '\t' '$2 == "queued" { printf "  %s\t%s\n", $1, $3; n++ }
             END { if (!n) print "  (none)" }' "$(hiya_backlog)"

n=0
for f in "$(hiya_unrouted_dir)"/*; do
  [ -f "$f" ] || continue
  n=$((n + 1))
done
if [ "$n" -gt 0 ]; then
  printf 'unrouted wakes: %s (hiya-inbox.sh --unrouted; a task'\''s next claimant adopts its own)\n' "$n"
fi

exit 0
