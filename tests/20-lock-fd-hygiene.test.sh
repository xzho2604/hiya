#!/usr/bin/env bash
# lock fd hygiene: a kernel lock lives as long as ANY process holds its open
# file, and children inherit open fds. git runs hooks (and may start daemons,
# e.g. fsmonitor) while hiya holds the workspaces lock, so a long-lived
# process started by git must not inherit — and so keep — hiya's locks.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
export HIYA_HOME="$work/home"
export HOOK_PIDFILE="$work/hook.pids"
cleanup() {
  # stop only the sleeps our own hook started: by their recorded pids, and
  # only while that pid still IS a sleep (BusyBox ps has no -p: use /proc)
  local p
  if [ -f "$HOOK_PIDFILE" ]; then
    while read -r p; do
      case $(ps -p "$p" -o comm= 2> /dev/null || cat "/proc/$p/comm" 2> /dev/null) in
        *sleep) kill "$p" 2> /dev/null ;;
      esac
    done < "$HOOK_PIDFILE"
  fi
  rm -rf "$work"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
join() { "$bin/hiya-join.sh" | awk '/^sid:/ { print $2 }'; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
repo="$work/repo"
git -c init.defaultBranch=main init -q "$repo" || fail "git init failed"
git -C "$repo" commit -q --allow-empty -m init || fail "seed commit failed"
export HIYA_REPO="$repo"

# a hook that leaves a long-lived process behind, as a daemon would. It must
# outlive every assertion below even on a slow host, or they prove nothing;
# cleanup stops it by its recorded pid.
cat > "$repo/.git/hooks/post-checkout" <<'EOF'
#!/bin/sh
sleep 60 > /dev/null 2>&1 &
echo "$!" >> "$HOOK_PIDFILE"
EOF
chmod +x "$repo/.git/hooks/post-checkout"

s1=$(join)
"$bin/hiya-add.sh" t1 "Starts the daemon" > /dev/null || fail "add t1 failed"
"$bin/hiya-add.sh" t2 "Needs the same locks" > /dev/null || fail "add t2 failed"

"$bin/hiya-claim.sh" "$s1" t1 > /dev/null 2>&1 || fail "claim t1 failed"
[ -s "$HOOK_PIDFILE" ] || fail "setup: the post-checkout hook did not run"
read -r hp < "$HOOK_PIDFILE"
kill -0 "$hp" 2> /dev/null || fail "setup: the hook's background process is not running"

# the daemon is alive; every lock the claim held must be free regardless
out=$(HIYA_LOCK_WAIT=1 "$bin/hiya-claim.sh" "$s1" t2 2>&1) \
  || fail "a process started by git kept hiya's locks: $out"
out=$(HIYA_LOCK_WAIT=1 "$bin/hiya-release.sh" "$s1" t2 --done 2>&1) \
  || fail "locks still held after the second claim: $out"
kill -0 "$hp" 2> /dev/null \
  || fail "the hook's process exited before the assertions ran: they proved nothing"

printf 'PASS: lock fd hygiene\n'
