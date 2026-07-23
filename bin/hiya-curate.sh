#!/usr/bin/env bash
# hiya-curate.sh — fold journaled memory intents into their memory files.
set -u

HIYA_BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/hiya-lib.sh
. "$HIYA_BIN/hiya-lib.sh"

usage() {
  cat <<'EOF'
usage: hiya-curate.sh [--help]

Fold every intent under data/journal/ into its memory file, appending under
a dated "## Curated" section, then remove the intent. Runs under the memory
lock so curation never races a CAS write. Intent files are named
<name>__<epoch>__<pid>.md, so lexical order within a memory name is
roughly arrival order.

environment:
  HIYA_HOME  home directory (default ./home)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 1 ;;
esac

hiya_require_home

curate_impl() {
  local n f base name memf
  n=0
  for f in "$HIYA_HOME/data/journal"/*.md; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .md)
    name=${base%%__*}
    memf="$HIYA_HOME/data/memory/$name.md"
    {
      printf '\n## Curated %s (from %s)\n\n' "$(date +%Y-%m-%d)" "$base"
      cat "$f"
    } >> "$memf"
    rm -f "$f"
    n=$((n + 1))
    printf 'curated %s -> %s.md\n' "$base" "$name"
  done
  printf '%d intent(s) curated\n' "$n"
  return 0
}

with_lock memory curate_impl
