#!/usr/bin/env bash
# tests/lib-call.sh — test helper (not a test): call one hiya-lib.sh function
# in a fresh process and exit with its status.
#
# usage: lib-call.sh <function> [args...]
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$here/../bin/hiya-lib.sh"

"$@"
