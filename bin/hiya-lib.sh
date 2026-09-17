#!/usr/bin/env bash
# hiya-lib.sh — shared helpers for the hiya multi-session coordination tools.
# Source this file from bin/hiya-*.sh; it is not meant to be executed.
#
# Locking prefers kernel locks (flock(2)), which the OS drops the moment the
# holder dies, so there is no stale lock to clean up and nothing to race on:
# the fd form of /usr/bin/lockf on macOS/BSD, flock(1) on Linux. Hosts with
# neither fall back to a token lock built on atomic rename(2). See the
# "locking" section below. hiya is single-host by design: neither flock(2)
# nor pid liveness means anything across machines.

set -u

# shellcheck disable=SC2034  # config vars are consumed by the sourcing tools
HIYA_HOME="${HIYA_HOME:-./home}"
# shellcheck disable=SC2034
HIYA_SESSION_TTL="${HIYA_SESSION_TTL:-120}"  # secs before a silent session is dead
HIYA_LOCK_WAIT="${HIYA_LOCK_WAIT:-10}"       # secs to wait for a busy lock
HIYA_LOCK_BACKEND="${HIYA_LOCK_BACKEND:-}"   # pin a NEW home to kernel|token (default: detect)
HIYA_LOCKF="${HIYA_LOCKF:-/usr/bin/lockf}"   # BSD lockf(1); needs its fd form
# shellcheck disable=SC2034
HIYA_REPO="${HIYA_REPO:-}"                   # git repo for per-task worktrees (empty = off)

# ---------------------------------------------------------------- primitives

hiya_die() { printf 'hiya: %s\n' "$*" >&2; exit 1; }

hiya_now() { date +%s; }

hiya_mtime() {
  # print mtime of a file as epoch seconds. GNU form first, and the output
  # must be all digits: on GNU coreutils `stat -f` means "filesystem status",
  # so it prints a block to stdout AND exits 1 — a BSD-first `a || b` chain
  # glues that block onto the fallback's answer.
  local out
  out=$(stat -c %Y "$1" 2> /dev/null)
  case $out in
    ''|*[!0-9]*) out=$(stat -f %m "$1" 2> /dev/null) ;;
  esac
  case $out in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
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
  # atomic_write <dest> — write stdin to dest atomically (tmp file + rename).
  # The temp file is hidden, so a writer killed mid-write never leaves
  # something a `dir/*` glob (leases, workspaces) mistakes for a record.
  local dest=$1 tmp
  case $dest in
    */*) tmp="${dest%/*}/.${dest##*/}.tmp.$$" ;;
    *) tmp=".$dest.tmp.$$" ;;
  esac
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
#
# Two backends sit behind lock_acquire / lock_release / with_lock:
#
#   kernel  A flock(2) lock on state/locks/<name>.flock, held through an fd
#           this shell keeps open (pool: fds 9..5). lockf(1) and flock(1) both
#           take flock(2) locks, so they exclude each other too. The kernel
#           releases the lock when the last holder of that open file exits —
#           a crashed holder leaves nothing behind.
#   token   Fallback for hosts where no tool can lock an fd. Each lock is a
#           directory state/locks/<name>.token/ holding exactly ONE token
#           file, which only ever moves between names by atomic rename(2):
#             free  ->  held.<pid>.<nonce>    acquire (one renamer wins)
#             held.<pid>.<nonce>  ->  free    release
#             held.<dead>.<n>  ->  held.<me>  take over a dead holder's lock
#           The takeover names the DEAD holder's token as its source, so it is
#           a compare-and-swap: it can only ever hit the incarnation that was
#           judged dead, never a newer live holder, and one contender wins it.
#           There is no moment without a holder identity and nothing is ever
#           deleted, so there is no stale-cleanup step left to race on.
#
# kernel and token locks do NOT exclude each other, so a home is pinned to one
# backend by its first user (state/locks/.backend). Without the pin, a session
# with flock(1) on its PATH and one without would silently run unlocked
# against each other.
#
# Children inherit open fds, and a flock lives as long as ANY process holds
# its open file. Anything long-lived started while a lock is held (git and
# whatever its hooks spawn, the watcher's sleep) must go through
# hiya_unlocked.
#
# A lock belongs to the PROCESS that took it ($$, which a subshell shares with
# its parent): take and release it in the same process, never from a
# backgrounded subshell that may outlive its parent.

hiya_lk_class=   # this home's pinned backend, resolved once per process
hiya_lk_tool=    # kernel backend: the tool that works here (lockf | flock)
hiya_lk_flock=   # kernel backend: which flock(1) this is (util-linux | basic)
hiya_lk_held=()  # kernel backend: name of the lock held on each pool fd
# token backend: tells this process from a dead one that had its pid. Seeded
# HERE, once, and never lazily: subshells share $$, so siblings that each made
# up their own nonce would take each other for a dead predecessor and steal a
# live token.
hiya_lk_nonce=${hiya_lk_nonce:-$RANDOM$RANDOM}

hiya_lk_open() {
  # hiya_lk_open <fd> <file> — open <file> for append on pool fd <fd>. eval
  # because bash 3.2 has no {var}>file; the 2>/dev/null belongs to eval, so
  # only the lock fd outlives this call.
  eval "exec $1>>\"\$2\"" 2> /dev/null
}

hiya_lk_close() { eval "exec $1>&-"; }

hiya_unlocked() {
  # hiya_unlocked <cmd> [args...] — run cmd without this shell's lock fds
  "$@" 9>&- 8>&- 7>&- 6>&- 5>&-
}

hiya_lk_flock_poll() {
  # hiya_lk_flock_poll <fd> <wait-seconds> — BusyBox flock has no -w: poll -n.
  # It exits 1 for busy and broken alike, so here a broken lock is a timeout.
  local deadline=$(( SECONDS + $2 ))
  while :; do
    flock -n "$1" 2> /dev/null && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

hiya_lk_tool_try() {
  # hiya_lk_tool_try <tool> <fd> <wait-seconds> — lock the open <fd>.
  # 0 = locked, 1 = busy for the whole wait, 2 = this tool cannot lock an fd
  local rc
  case $1 in
    lockf)
      # an older lockf has no fd form: it takes "<fd>" for a file name with no
      # command and exits EX_USAGE (64) before touching anything
      [ -x "$HIYA_LOCKF" ] || return 2
      "$HIYA_LOCKF" -s -t "$3" "$2" 2> /dev/null
      rc=$?
      ;;
    flock)
      command -v flock > /dev/null 2>&1 || return 2
      if [ -z "$hiya_lk_flock" ]; then
        case $(flock --version 2> /dev/null) in
          *util-linux*) hiya_lk_flock=util-linux ;;
          *) hiya_lk_flock=basic ;;   # BusyBox: no -w, no -E
        esac
      fi
      if [ "$hiya_lk_flock" = basic ]; then
        hiya_lk_flock_poll "$2" "$3"
        return $?
      fi
      # -E tells "held by someone else" (75) from a real failure, which must
      # surface as one instead of looking like a busy lock
      if [ "$3" -eq 0 ]; then
        flock -n -E 75 "$2" 2> /dev/null
      else
        flock -w "$3" -E 75 "$2" 2> /dev/null
      fi
      rc=$?
      ;;
    *) return 2 ;;
  esac
  case $rc in
    0) return 0 ;;
    75) return 1 ;;   # EX_TEMPFAIL: held by someone else
    *) return 2 ;;
  esac
}

hiya_lk_detect() {
  # print the backend a NEW home gets: "kernel" if a tool can lock an fd on
  # this host, else "token". Runs in a command substitution, so the probe fd
  # never reaches the caller.
  local probe tool found=token
  probe="$HIYA_HOME/state/locks/.probe.$$"
  if hiya_lk_open 9 "$probe"; then
    for tool in lockf flock; do
      if hiya_lk_tool_try "$tool" 9 0; then
        found=kernel
        break
      fi
    done
  fi
  rm -f "$probe"
  printf '%s\n' "$found"
}

hiya_lk_resolve() {
  # resolve this home's pinned backend, pinning it if we are its first user
  [ -z "$hiya_lk_class" ] || return 0
  local dir marker want tmp
  dir="$HIYA_HOME/state/locks"
  marker="$dir/.backend"
  mkdir -p "$dir" || hiya_die "cannot create $dir"
  if [ ! -s "$marker" ]; then
    want=$HIYA_LOCK_BACKEND
    [ -n "$want" ] || want=$(hiya_lk_detect)
    case $want in
      kernel|token) ;;
      *) hiya_die "HIYA_LOCK_BACKEND must be 'kernel' or 'token', not '$want'" ;;
    esac
    # ln creates the marker only if it is absent, content included, in one
    # atomic step: of any number of first users exactly one pins the home and
    # the rest adopt its choice. (noclobber covers filesystems without links.)
    tmp="$marker.tmp.$$"
    printf '%s\n' "$want" > "$tmp"
    ln "$tmp" "$marker" 2> /dev/null \
      || ( set -C; cat "$tmp" > "$marker" ) 2> /dev/null
    rm -f "$tmp"
  fi
  # the noclobber path creates the pin empty for an instant: re-read briefly
  for _ in 1 2 3 4 5; do
    hiya_lk_class=$(cat "$marker" 2> /dev/null)
    [ -z "$hiya_lk_class" ] || break
    sleep 0.05
  done
  case $hiya_lk_class in
    kernel|token) ;;
    *) hiya_die "cannot read the lock backend pin $marker" ;;
  esac
  if [ -n "$HIYA_LOCK_BACKEND" ] && [ "$HIYA_LOCK_BACKEND" != "$hiya_lk_class" ]; then
    hiya_die "home is pinned to '$hiya_lk_class' locks; HIYA_LOCK_BACKEND=$HIYA_LOCK_BACKEND cannot change that"
  fi
}

hiya_lk_kernel_acquire() {
  # hiya_lk_kernel_acquire <name> <wait-seconds> — 0 locked, 1 busy
  local fd file tool rc
  file="$HIYA_HOME/state/locks/$1.flock"
  for fd in 9 8 7 6 5 none; do
    [ "$fd" != none ] || hiya_die "too many locks held at once (lock '$1')"
    [ -n "${hiya_lk_held[$fd]:-}" ] || break
  done
  hiya_lk_open "$fd" "$file" || hiya_die "cannot open lock file $file"
  rc=2
  if [ -n "$hiya_lk_tool" ]; then
    hiya_lk_tool_try "$hiya_lk_tool" "$fd" "$2"
    rc=$?
  else
    for tool in lockf flock; do
      hiya_lk_tool_try "$tool" "$fd" "$2"
      rc=$?
      if [ "$rc" -ne 2 ]; then
        hiya_lk_tool=$tool
        break
      fi
    done
  fi
  case $rc in
    0) hiya_lk_held[fd]=$1; return 0 ;;
    1) hiya_lk_close "$fd"; return 1 ;;
  esac
  hiya_lk_close "$fd"
  hiya_die "home is pinned to 'kernel' locks, but neither $HIYA_LOCKF (fd form) nor flock(1) works here"
}

hiya_lk_token_init() {
  # hiya_lk_token_init <dir> — create the lock dir WITH its token in one atomic
  # step: build it privately, then rename it into place. Losing the race is
  # harmless: rename(2) refuses to replace a non-empty dir, and mv(1) drops a
  # late loser INSIDE the winner's dir, where it is no token and is removed.
  local dir=$1 seed
  seed="$dir.init.$$"
  rm -rf "$seed"   # ours by name: only a dead process that had our pid left it
  mkdir "$seed" 2> /dev/null || return 0
  : > "$seed/free"
  mv "$seed" "$dir" 2> /dev/null
  rm -rf "$seed" "${dir:?}/${seed##*/}"
}

hiya_lk_token_try() {
  # hiya_lk_token_try <name> — one attempt: 0 acquired, 1 busy
  local dir mine h pid
  dir="$HIYA_HOME/state/locks/$1.token"
  [ -d "$dir" ] || hiya_lk_token_init "$dir"
  mine="$dir/held.$$.$hiya_lk_nonce"
  mv -f "$dir/free" "$mine" 2> /dev/null && return 0
  # busy. Take over only from a holder that is provably gone: its pid is dead,
  # or it is OUR pid under another nonce (an earlier process, pid since reused).
  for h in "$dir"/held.*; do
    [ -e "$h" ] || continue
    [ "$h" != "$mine" ] || continue   # held by this very process
    pid=${h##*/held.}
    pid=${pid%%.*}
    case $pid in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$pid" != "$$" ] && kill -0 "$pid" 2> /dev/null; then
      continue
    fi
    mv -f "$h" "$mine" 2> /dev/null && return 0
  done
  return 1
}

lock_acquire() {
  # lock_acquire <name> [wait-seconds] — 0 on success, 1 on timeout.
  # wait-seconds 0 means a single non-blocking attempt.
  local name=$1 wait=${2:-$HIYA_LOCK_WAIT} deadline
  case $wait in
    ''|*[!0-9]*) hiya_die "lock wait must be whole seconds, not '$wait' (HIYA_LOCK_WAIT)" ;;
  esac
  hiya_lk_resolve
  if [ "$hiya_lk_class" = kernel ]; then
    hiya_lk_kernel_acquire "$name" "$wait"
    return $?
  fi
  deadline=$(( SECONDS + wait ))
  while :; do
    hiya_lk_token_try "$name" && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}

lock_release() {
  # lock_release <name> — release only if this process is the holder
  local name=$1 fd
  if [ "$hiya_lk_class" = kernel ]; then
    for fd in 9 8 7 6 5; do
      if [ "${hiya_lk_held[$fd]:-}" = "$name" ]; then
        hiya_lk_close "$fd"   # closing the fd drops the flock
        hiya_lk_held[fd]=
        return 0
      fi
    done
  elif [ "$hiya_lk_class" = token ]; then
    mv -f "$HIYA_HOME/state/locks/$name.token/held.$$.$hiya_lk_nonce" \
      "$HIYA_HOME/state/locks/$name.token/free" 2> /dev/null
  fi
  return 0
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
hiya_unrouted_dir() { printf '%s/state/unrouted' "$HIYA_HOME"; }
hiya_watcher_sid()  { printf '%s/state/locks/watcher.sid' "$HIYA_HOME"; }

hiya_workspace_rec() { printf '%s/state/workspaces/%s' "$HIYA_HOME" "$1"; }

workspace_field() {
  # workspace_field <task-id> <key> — print one field of a registry record
  awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2) }' \
    "$(hiya_workspace_rec "$1")" 2>/dev/null
}

workspace_dirty() {
  # a worktree is dirty if it has uncommitted changes or untracked files
  [ -n "$(hiya_unlocked git -C "$1" status --porcelain 2>/dev/null)" ]
}

hiya_layout() {
  # create the home layout; never clobbers existing data (a pre-seeded
  # backlog survives bootstrap)
  mkdir -p "$HIYA_HOME/state/sessions/.dead" \
           "$HIYA_HOME/state/leases" \
           "$HIYA_HOME/state/locks" \
           "$HIYA_HOME/state/unrouted" \
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

session_touch() {
  # session_touch <sid> — refresh a session's heartbeat; fails if the session
  # is gone. -c: never re-create the heartbeat of a session the reaper has
  # just archived.
  local hb
  hb="$(hiya_session_dir "$1")/heartbeat"
  touch -c "$hb" 2> /dev/null
  [ -f "$hb" ]
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

# --------------------------------------------------------------- wake records
#
# A wake record is one file, named by its zero-padded seq, holding
# epoch<TAB>seq<TAB>task-id<TAB>payload. It lives in exactly one place: the
# inbox of the live session leasing its task, or the home-level
# state/unrouted/ while the task has no live owner — from where the task's
# next claimant adopts it. Records only ever move by rename, so a reader
# never sees a partial one and none is dropped on the way.

wake_live_owner() {
  # wake_live_owner <task-id> — print the sid wakes for the task go to: its
  # lease owner, if that session is alive; nothing otherwise
  local owner
  owner=$(lease_owner "$1")
  if [ -n "$owner" ] && session_alive "$owner"; then
    printf '%s\n' "$owner"
  fi
}

wake_put() {
  # wake_put <dir> <seq> <record> — write one record into <dir>, atomically:
  # a hidden temp file (listings glob "*", which skips dotfiles) renamed into
  # place. Fails without leaving anything behind if <dir> cannot be written.
  local wp_dir=$1 wp_name wp_tmp
  printf -v wp_name '%08d' "$2"
  wp_tmp="$wp_dir/.tmp.$wp_name.$$"
  if { printf '%s\n' "$3" > "$wp_tmp"; } 2> /dev/null \
    && mv -f "$wp_tmp" "$wp_dir/$wp_name" 2> /dev/null; then
    return 0
  fi
  rm -f "$wp_tmp" 2> /dev/null
  return 1
}

wake_file_task() {
  # wake_file_task <record-file> — print the record's task id
  local task=
  { IFS=$'\t' read -r _ _ task _ < "$1"; } 2> /dev/null
  printf '%s\n' "$task"
}

wake_rehome() {
  # wake_rehome <record-file> — move a record to where its task lives NOW: the
  # live lease owner's inbox, else state/unrouted/. Prints the destination
  # ("<sid>" or "unrouted"); fails if the record could not be moved.
  local wr_file=$1 wr_task wr_owner wr_dir
  wr_task=$(wake_file_task "$wr_file")
  [ -n "$wr_task" ] || return 1
  wr_owner=$(wake_live_owner "$wr_task")
  if [ -n "$wr_owner" ] \
    && mv -f "$wr_file" "$(hiya_session_dir "$wr_owner")/inbox/${wr_file##*/}" 2> /dev/null; then
    printf '%s\n' "$wr_owner"
    return 0
  fi
  wr_dir=$(hiya_unrouted_dir)
  mkdir -p "$wr_dir" 2> /dev/null
  mv -f "$wr_file" "$wr_dir/${wr_file##*/}" 2> /dev/null || return 1
  printf 'unrouted\n'
}
