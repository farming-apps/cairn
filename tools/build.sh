#!/usr/bin/env bash
# Generates flat memory bundles in <data>/build/<project>/ (data = the memory repo, see tools/lib.sh):
#   - build/<project>/AGENTS.md                (global + project memory for OpenCode, Codex, Aider, `ai`)
#   - build/<project>/copilot.instructions.md  (project memory with applyTo frontmatter for GitHub Copilot CLI)
# build/ is ignored by git. Regenerate it whenever the memory changes (promote.sh does this automatically).
#
# Usage: build.sh <project> [--full] [--with-profile]
#   --full          include architecture.md and decisions.md (more tokens)
#   --with-profile  include global/profile.private.md (local use only)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
project="${1:-}"; [ -n "$project" ] || { sed -n '2,9p' "$0"; exit 2; }
shift
full=0; with_profile=0
for a in "$@"; do
  case "$a" in
    --full) full=1 ;;
    --with-profile) with_profile=1 ;;
    *) echo "build: unknown argument: $a" >&2; exit 2 ;;
  esac
done

pdir="$PM_DIR/$project"
[ -d "$pdir" ] || { echo "build: $pdir does not exist" >&2; exit 1; }
out_dir="$BUILD_DIR/$project"; mkdir -p "$out_dir"
out="$out_dir/AGENTS.md"
copilot_out="$out_dir/copilot.instructions.md"

# Expands "@file" lines relative to the file that contains them (one level, enough here).
expand() { # file
  local f="$1" dir; dir="$(dirname "$f")"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      @*) inc="${line#@}"; inc="${inc#./}"
          [ -f "$dir/$inc" ] && { cat "$dir/$inc"; echo; } || echo "<!-- import not found: $inc -->" ;;
      *)  printf '%s\n' "$line" ;;
    esac
  done <"$f"
}

{
  expand "$DATA/global/AGENTS.md"; echo
  if [ "$with_profile" -eq 1 ] && [ -f "$DATA/global/profile.private.md" ]; then
    expand "$DATA/global/profile.private.md"; echo
  fi
  expand "$pdir/AGENTS.md"; echo
  [ -f "$pdir/state.md" ] && { cat "$pdir/state.md"; echo; }
  if [ "$full" -eq 1 ]; then
    for f in architecture.md decisions.md; do
      [ -f "$pdir/$f" ] && { cat "$pdir/$f"; echo; }
    done
  fi
} >"$out"

{
  printf -- '---\napplyTo: "**"\n---\n'
  expand "$pdir/AGENTS.md"; echo
  [ -f "$pdir/state.md" ] && { cat "$pdir/state.md"; echo; }
  if [ "$full" -eq 1 ]; then
    for f in architecture.md decisions.md; do
      [ -f "$pdir/$f" ] && { cat "$pdir/$f"; echo; }
    done
  fi
} >"$copilot_out"

python3 "$ROOT/tools/sanitize.py" -q "$out" "$copilot_out"
echo "build: $out ($(wc -c <"$out" | tr -d ' ') bytes, ~$(( ($(wc -c <"$out") + 3) / 4 )) tokens)"
