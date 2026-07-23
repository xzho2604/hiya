#!/usr/bin/env bash
# hiya-mem-write.sh — compare-and-swap write to a shared memory file.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-mem-write.sh <name> <content-file> --base-hash <h> [--help]
       hiya-mem-write.sh --show-hash <name>

CAS write to data/memory/<name>.md. Pass as --base-hash the hash you read
before editing (--show-hash prints it; "-" means the file does not exist
yet). Under the memory lock, the write commits only if the file still
matches that hash. On a mismatch — someone else wrote in between — the
content is journaled as an intent under data/journal/ instead of clobbering
their write, and the exit code is 3 so the caller knows. hiya-curate.sh
later folds journaled intents into the memory file.

exit status:
  0  write landed
  3  conflict: content journaled for curation

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

name=
src=
base=
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --show-hash)
      [ $# -eq 2 ] || { usage >&2; exit 1; }
      hiya_require_home
      hiya_hash "$HIYA_HOME/data/memory/$2.md"
      exit 0
      ;;
    --base-hash)
      [ $# -ge 2 ] || { usage >&2; exit 1; }
      base=$2
      shift
      ;;
    -*) usage >&2; exit 1 ;;
    *)
      if [ -z "$name" ]; then name=$1
      elif [ -z "$src" ]; then src=$1
      else usage >&2; exit 1
      fi
      ;;
  esac
  shift
done
if [ -z "$name" ] || [ -z "$src" ] || [ -z "$base" ]; then
  usage >&2
  exit 1
fi

hiya_require_home
[ -f "$src" ] || hiya_die "no such content file '$src'"

write_impl() {
  local memf cur intent
  memf="$HIYA_HOME/data/memory/$name.md"
  if cas_commit "$memf" "$base" "$src"; then
    printf 'memory %s.md updated (hash %s)\n' "$name" "$(hiya_hash "$memf")"
    return 0
  fi
  cur=$(hiya_hash "$memf")
  intent="$HIYA_HOME/data/journal/${name}__$(hiya_now)__$$.md"
  atomic_write "$intent" < "$src" || return 1
  printf 'conflict on %s.md (base %s, now %s): journaled as %s\n' \
    "$name" "$base" "$cur" "$(basename "$intent")" >&2
  return 3
}

with_lock memory write_impl
