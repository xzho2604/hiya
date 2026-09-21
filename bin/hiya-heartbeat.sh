#!/usr/bin/env bash
# hiya-heartbeat.sh — refresh own liveness, then reap expired sessions.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-heartbeat.sh <sid> [--help]

Touch <sid>'s heartbeat file (mtime = liveness), then reap: any session whose
heartbeat is older than HIYA_SESSION_TTL seconds is expired. An expired
session's dir is archived under state/sessions/.dead/<sid>.<epoch>, its
leases are released back to "queued", and the wakes it never drained follow
their tasks: to the inbox of the task's live owner if it has one (the task
was handed over), else to state/unrouted/, where the task's next claimant
adopts them. A wake that cannot be moved stays in the archive, is reported,
and is retried on every later pass.

The same pass sweeps orphan leases — leases whose owner has no session at
all — back to "queued", and delivers wakes parked in state/unrouted/ whose
task has a live owner by now.

Run this periodically from every live session; any session's heartbeat pass
reaps on behalf of the whole home.

environment:
  HIYA_HOME         home directory (default ./home)
  HIYA_SESSION_TTL  heartbeat age in seconds before a session is declared
                    dead (default 120)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -ne 1 ]; then
  usage >&2
  exit 1
fi

sid=$1
hiya_require_home
session_touch "$sid" || hiya_die "unknown or dead session '$sid' (did you join?)"
printf 'heartbeat %s\n' "$sid"

# shellcheck disable=SC2329  # invoked indirectly via with_lock
reap_impl() {
  local now d s hb mt age lf task owner released dead f seq dest
  now=$(hiya_now)
  for d in "$(hiya_sessions_dir)"/*/; do
    [ -d "$d" ] || continue
    s=$(basename "$d")
    hb="$d/heartbeat"
    [ -f "$hb" ] || continue
    mt=$(hiya_mtime "$hb") || continue
    age=$(( now - mt ))
    [ "$age" -gt "$HIYA_SESSION_TTL" ] || continue
    # archive FIRST: once the dir is gone from sessions/ the session is dead to
    # everyone and nothing new can land in its inbox. If the move fails,
    # nothing has changed yet and the next pass simply retries.
    dead="$(hiya_sessions_dir)/.dead/$s.$now"
    mv "$d" "$dead" || continue
    released=
    for lf in "$HIYA_HOME/state/leases"/*; do
      [ -f "$lf" ] || continue
      [ "$(awk -F= '$1 == "owner" { print $2 }' "$lf")" = "$s" ] || continue
      task=$(basename "$lf")
      rm -f "$lf"
      backlog_set_state "$task" queued
      released="$released $task"
    done
    printf 'reaped %s (heartbeat %ss old)' "$s" "$age"
    if [ -n "$released" ]; then
      printf '; released:%s' "$released"
    fi
    printf '\n'
  done
  # orphan leases: the owner has no session at all (it vanished without a
  # reap), so no pass over live sessions would ever release them
  for lf in "$HIYA_HOME/state/leases"/*; do
    [ -f "$lf" ] || continue
    owner=$(awk -F= '$1 == "owner" { print $2 }' "$lf")
    if [ -n "$owner" ] && session_alive "$owner"; then
      continue
    fi
    task=$(basename "$lf")
    rm -f "$lf"
    backlog_set_state "$task" queued
    printf 'swept orphan lease %s (owner %s has no session)\n' "$task" "${owner:-?}"
  done
  # Undrained wakes of reaped sessions follow their tasks. EVERY archive is
  # swept on every pass: nothing else ever looks under .dead/, so a record
  # that could not be moved this time must be found again next time.
  for f in "$(hiya_sessions_dir)"/.dead/*/inbox/*; do
    [ -f "$f" ] || continue
    seq=${f##*/}
    case $seq in
      *[!0-9]*) continue ;;
    esac
    task=$(wake_file_task "$f")
    if dest=$(wake_rehome "$f"); then
      printf 're-routed wake %s (%s) -> %s\n' "$((10#$seq))" "$task" "$dest"
    else
      printf 'hiya-heartbeat: cannot re-home wake %s (%s); it stays in %s and is retried next pass\n' \
        "$((10#$seq))" "${task:-?}" "${f%/*}" >&2
    fi
  done
  return 0
}

deliver_parked() {
  # A wake is parked in state/unrouted/ while its task has no live owner. If
  # the task has one by now — the owner's inbox could not be written when the
  # wake was routed, or a claim was rolled back — hand it over. Lock-free on
  # purpose: records move by atomic rename, and an owner reaped mid-move
  # either makes the rename fail or gets the record swept from its archive.
  local f seq task owner
  for f in "$(hiya_unrouted_dir)"/*; do
    [ -f "$f" ] || continue
    seq=${f##*/}
    case $seq in
      *[!0-9]*) continue ;;
    esac
    task=$(wake_file_task "$f")
    [ -n "$task" ] || continue
    owner=$(wake_live_owner "$task")
    [ -n "$owner" ] || continue
    if mv -f "$f" "$(hiya_session_dir "$owner")/inbox/$seq" 2> /dev/null; then
      printf 'delivered parked wake %s (%s) -> %s\n' "$((10#$seq))" "$task" "$owner"
    fi
  done
}

# lock order: sessions before backlog, everywhere both are held
with_lock sessions with_lock backlog reap_impl || exit 1
deliver_parked
exit 0
