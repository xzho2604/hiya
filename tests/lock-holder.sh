#!/usr/bin/env bash
# tests/lock-holder.sh — test helper (not a test): hold a hiya lock until killed.
#
# usage: lock-holder.sh <lock-name> <ready-file> [seconds]
#
# Takes the lock through hiya-lib.sh, creates <ready-file>, then execs sleep,
# so the holder stays ONE pid: a test releases the lock (kill) or simulates a
# crashed holder (kill -9) by signalling exactly the pid it started.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$here/../bin/hiya-lib.sh"

lock_acquire "$1" || exit 1
: > "$2"
exec sleep "${3:-30}"
