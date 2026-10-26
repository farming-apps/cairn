#!/usr/bin/env bash
# Warns when a memory file exceeds its token budget.
# Estimate: AI_MEMORY_CHARS_PER_TOKEN characters per token (4 by default). Deliberately
# approximate: the goal is to keep memory from growing without bound, not an exact count.
#
# Usage:
#   check-size.sh                      every versioned .md in global/ and project-memories/ of the memory repo
#   check-size.sh --staged             staged files only (index of the repo in the current directory, for the hook)
#   check-size.sh PATH...              specific files
#   check-size.sh --as REL FILE        measures FILE with the limit that applies to REL
#                                      (used by promote.sh to simulate the result)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
RATIO="${AI_MEMORY_CHARS_PER_TOKEN:-4}"

limit_for() { # token budget per memory file; 0 = no limit (tool docs, templates, third-party skills)
  case "$1" in
    global/AGENTS.md)               echo 400 ;;
    global/*.md)                    echo 3000 ;;
    project-memories/*/state.md)    echo 1500 ;;
    project-memories/*/AGENTS.md)   echo 800 ;;
    project-memories/*/skills/*)    echo 0 ;;
    project-memories/*/*.md)        echo 3000 ;;
    *)                              echo 0 ;;
  esac
}

tokens_of_bytes() { echo $(( ($1 + RATIO - 1) / RATIO )); }

status=0
report() { # rel bytes
  local rel="$1" bytes="$2" limit tokens
  limit="$(limit_for "$rel")"
  [ "$limit" -gt 0 ] || return 0
  tokens="$(tokens_of_bytes "$bytes")"
  if [ "$tokens" -gt "$limit" ]; then
    printf 'check-size: %s ~%s tokens > limit %s\n' "$rel" "$tokens" "$limit" >&2
    status=1
  else
    printf 'check-size: %s ~%s/%s\n' "$rel" "$tokens" "$limit"
  fi
}

if [ "${1:-}" = "--as" ]; then
  [ $# -eq 3 ] || { echo "usage: check-size.sh --as REL FILE" >&2; exit 2; }
  report "$2" "$(wc -c <"$3" | tr -d ' ')"
elif [ "${1:-}" = "--staged" ]; then
  repo="$(git rev-parse --show-toplevel 2>/dev/null || echo "$DATA")"
  while IFS= read -r -d '' rel; do
    case "$rel" in *.md) ;; *) continue ;; esac
    report "$rel" "$(git -C "$repo" show ":$rel" | wc -c | tr -d ' ')"
  done < <(git -C "$repo" diff --cached --name-only --no-renames --diff-filter=ACMT -z)
elif [ $# -gt 0 ]; then
  for f in "$@"; do
    abs="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
    report "${abs#"$DATA"/}" "$(wc -c <"$abs" | tr -d ' ')"
  done
else
  while IFS= read -r -d '' rel; do
    report "$rel" "$(wc -c <"$DATA/$rel" | tr -d ' ')"
  done < <(git -C "$DATA" ls-files -z -- 'global/*.md' 'project-memories/*/*.md')
fi

exit $status
