#!/usr/bin/env bash
# stat flavors (report probe p7): dead-session reaping must work whether the
# first `stat` on PATH is GNU or BSD. Both flavors are emulated with PATH
# shims, so each host tests the flavor it does not ship. The GNU shim
# reproduces the trap exactly: `stat -f` means "filesystem status" there, so
# it prints a block to stdout AND exits 1.
set -u
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/../bin"
work=$(mktemp -d "${TMPDIR:-/tmp}/hiya-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
join() { "$bin/hiya-join.sh" | awk '/^sid:/ { print $2 }'; }

real=$(command -v stat) || fail "no stat on PATH"
if "$real" -c %Y "$work" > /dev/null 2>&1; then
  real_opt=-c real_fmt=%Y
else
  real_opt=-f real_fmt=%m
fi

mkdir "$work/gnu" "$work/bsd"
cat > "$work/gnu/stat" <<EOF
#!/bin/sh
# GNU-like: -c FORMAT works; -f is "file system status"
case \$1 in
  -c) [ "\$2" = %Y ] || exit 1; exec "$real" $real_opt $real_fmt "\$3" ;;
  -f)
    echo "stat: cannot read file system information for '\$2': No such file or directory" >&2
    printf '  File: "%s"\n    ID: 100001200000018 Namelen: ?       Type: apfs\n' "\$3"
    printf 'Block size: 4096       Fundamental block size: 4096\n'
    exit 1
    ;;
  *) exit 1 ;;
esac
EOF
cat > "$work/bsd/stat" <<EOF
#!/bin/sh
# BSD-like: -f FORMAT works; -c is an illegal option
case \$1 in
  -f) [ "\$2" = %m ] || exit 1; exec "$real" $real_opt $real_fmt "\$3" ;;
  *)
    echo "stat: illegal option -- c" >&2
    echo "usage: stat [-FLnq] [-f format | -l | -r | -s | -x] [-t timefmt] [file ...]" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$work/gnu/stat" "$work/bsd/stat"

printf 'x\n' > "$work/probe-file"
touch -t 202001010000 "$work/probe-file"
want=$("$real" "$real_opt" "$real_fmt" "$work/probe-file") \
  || fail "cannot read the reference mtime"

for flavor in gnu bsd; do
  (
    PATH="$work/$flavor:$PATH"
    export PATH HIYA_HOME="$work/home-$flavor"

    # the primitive: exactly one all-digit line, equal to the real mtime
    got=$("$here/lib-call.sh" hiya_mtime "$work/probe-file") \
      || fail "$flavor stat: hiya_mtime failed"
    [ "$got" = "$want" ] || fail "$flavor stat: hiya_mtime printed '$got', want '$want'"

    # the consequence: a dead session is reaped and its task requeued
    s1=$(join)
    s2=$(join)
    "$bin/hiya-add.sh" t1 "Doomed task" > /dev/null || fail "$flavor stat: add failed"
    "$bin/hiya-claim.sh" "$s2" t1 > /dev/null || fail "$flavor stat: claim failed"
    touch -t 202001010000 "$HIYA_HOME/state/sessions/$s2/heartbeat"
    out=$("$bin/hiya-heartbeat.sh" "$s1" 2> "$work/err") \
      || fail "$flavor stat: heartbeat failed: $out $(cat "$work/err")"
    [ ! -s "$work/err" ] || fail "$flavor stat: heartbeat wrote to stderr: $(cat "$work/err")"
    printf '%s\n' "$out" | grep -q "reaped $s2" || fail "$flavor stat: no reap reported: $out"
    [ ! -e "$HIYA_HOME/state/leases/t1" ] || fail "$flavor stat: lease not released"
    st=$(awk -F '\t' '$1 == "t1" { print $2 }' "$HIYA_HOME/data/backlog.md")
    [ "$st" = "queued" ] || fail "$flavor stat: backlog state is '$st', not queued"
    [ -d "$HIYA_HOME/state/sessions/$s1" ] || fail "$flavor stat: live session was reaped"
  ) || exit 1
done

printf 'PASS: stat flavors\n'
