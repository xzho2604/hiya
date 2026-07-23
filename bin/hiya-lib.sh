#!/usr/bin/env bash
# hiya-lib.sh — shared helpers for the hiya multi-session coordination tools.
# Source this file from bin/hiya-*.sh; it is not meant to be executed.
#
# Locking uses atomic mkdir, which works on stock macOS bash 3.2 (Darwin has
# no flock(1)). A lock is a directory under state/locks/ holding the owner's
# pid. A lock whose owner pid is dead is reclaimed; reclaim is race-free
# because contenders race on an atomic rename of the stale lock dir and only
# one wins. hiya is single-host by design: pid liveness checks are only
# meaningful for processes on the same machine.

set -u

# shellcheck disable=SC2034  # config vars are consumed by the sourcing tools
HIYA_HOME="${HIYA_HOME:-./home}"
# shellcheck disable=SC2034
HIYA_SESSION_TTL="${HIYA_SESSION_TTL:-120}"  # secs before a silent session is dead
HIYA_LOCK_TTL="${HIYA_LOCK_TTL:-30}"         # grace for a lock dir with no pid file yet
HIYA_LOCK_WAIT="${HIYA_LOCK_WAIT:-10}"       # secs to wait for a busy lock

# ---------------------------------------------------------------- primitives

hiya_die() { printf 'hiya: %s\n' "$*" >&2; exit 1; }

hiya_now() { date +%s; }

hiya_mtime() {
  # print mtime of a file as epoch seconds (BSD stat first, then GNU)
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

hiya_hash() {
  # content hash of a file; "-" stands for "file does not exist yet"
  if [ -f "$1" ]; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    printf -- '-\n'
  fi
}

atomic_write() {
  # atomic_write <dest> — write stdin to dest atomically (tmp file + rename)
  local dest=$1 tmp
  tmp="$dest.tmp.$$"
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dest"
}

cas_commit() {
  # cas_commit <dest> <base-hash> <content-file>
  # Commit content only if dest still hashes to base-hash (what the caller
  # read before editing). Returns 0 on commit, 3 on a lost race.
  # Caller must hold the lock that serializes writers of <dest>.
  local dest=$1 base=$2 src=$3 cur
  cur=$(hiya_hash "$dest")
  if [ "$cur" != "$base" ]; then
    return 3
  fi
  atomic_write "$dest" < "$src"
}

# ------------------------------------------------------------------- locking

hiya_lockdir() { printf '%s/state/locks/%s.lock' "$HIYA_HOME" "$1"; }

hiya_lock_reclaim_stale() {
  # Reclaim <lockdir> only when its holder is provably gone:
  #   - a pid file is present and that pid is dead, or
  #   - no pid file and the lock dir is older than HIYA_LOCK_TTL
  #     (holder crashed between mkdir and writing its pid).
  # A live holder is never preempted. The rename is the atomic step: of any
  # number of concurrent reclaimers, exactly one wins the mv.
  local lockdir=$1 pid now mt trash
  [ -d "$lockdir" ] || return 0
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null && return 0
  else
    now=$(hiya_now)
    mt=$(hiya_mtime "$lockdir" 2>/dev/null || printf '%s' "$now")
    [ $(( now - mt )) -le "$HIYA_LOCK_TTL" ] && return 0
  fi
  trash="$lockdir.reclaim.$$"
  if mv "$lockdir" "$trash" 2>/dev/null; then
    rm -rf "$trash"
  fi
}

lock_acquire() {
  # lock_acquire <name> [wait-seconds] — 0 on success, 1 on timeout.
  # wait-seconds 0 means a single non-blocking attempt.
  local name=$1 wait=${2:-$HIYA_LOCK_WAIT} lockdir deadline
  lockdir=$(hiya_lockdir "$name")
  mkdir -p "${lockdir%/*}"
  deadline=$(( $(hiya_now) + wait ))
  while :; do
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" > "$lockdir/pid"
      return 0
    fi
    hiya_lock_reclaim_stale "$lockdir"
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" > "$lockdir/pid"
      return 0
    fi
    if [ "$(hiya_now)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 0.2
  done
}

lock_release() {
  # lock_release <name> — release only if this process is the holder
  local name=$1 lockdir pid
  lockdir=$(hiya_lockdir "$name")
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if [ "$pid" = "$$" ]; then
    rm -rf "$lockdir"
  fi
}

with_lock() {
  # with_lock <name> <cmd> [args...] — run cmd under the named lock,
  # propagating its exit status. Composes: with_lock a with_lock b cmd.
  # Locals are prefixed because bash locals are dynamically scoped: an
  # unprefixed "name" here would shadow the caller's globals inside cmd.
  local wl_name=$1 wl_rc
  shift
  lock_acquire "$wl_name" || hiya_die "timed out waiting for lock '$wl_name'"
  "$@"
  wl_rc=$?
  lock_release "$wl_name"
  return $wl_rc
}

# ---------------------------------------------------------------- home paths

hiya_sessions_dir() { printf '%s/state/sessions' "$HIYA_HOME"; }
hiya_session_dir()  { printf '%s/state/sessions/%s' "$HIYA_HOME" "$1"; }
hiya_lease_file()   { printf '%s/state/leases/%s' "$HIYA_HOME" "$1"; }
hiya_backlog()      { printf '%s/data/backlog.md' "$HIYA_HOME"; }

hiya_layout() {
  # create the home layout; never clobbers existing data (a pre-seeded
  # backlog survives bootstrap)
  mkdir -p "$HIYA_HOME/state/sessions/.dead" \
           "$HIYA_HOME/state/leases" \
           "$HIYA_HOME/state/locks" \
           "$HIYA_HOME/data/memory" \
           "$HIYA_HOME/data/journal"
  [ -f "$HIYA_HOME/state/wake-queue" ] || : > "$HIYA_HOME/state/wake-queue"
  [ -f "$(hiya_backlog)" ] || : > "$(hiya_backlog)"
}

hiya_require_home() {
  [ -f "$HIYA_HOME/state/.bootstrapped" ] \
    || hiya_die "home '$HIYA_HOME' is not bootstrapped (run hiya-join.sh first)"
}

# ------------------------------------------------------- sessions and leases

session_alive() {
  # a session is alive if its dir (with heartbeat) exists; heartbeat age is
  # judged by the reaper, which removes expired session dirs
  [ -f "$(hiya_session_dir "$1")/heartbeat" ]
}

lease_owner() {
  # print the sid owning a task's lease; empty if unleased
  awk -F= '$1 == "owner" { print $2 }' "$(hiya_lease_file "$1")" 2>/dev/null
}

backlog_state() {
  # print a task's state (queued|claimed|done); empty if unknown
  awk -F '\t' -v id="$1" '$1 == id { print $2 }' "$(hiya_backlog)"
}

backlog_set_state() {
  # backlog_set_state <task-id> <state> — caller must hold the backlog lock
  local f tmp
  f=$(hiya_backlog)
  tmp="$f.tmp.$$"
  awk -F '\t' -v OFS='\t' -v id="$1" -v st="$2" \
    '$1 == id { $2 = st } { print }' "$f" > "$tmp" && mv -f "$tmp" "$f"
}
