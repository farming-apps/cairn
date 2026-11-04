#!/usr/bin/env bash
# Layout 2 -> 3: the tool was renamed from ai-memory to cairn.
#   .ai-memory-layout                 -> .cairn-layout
#   settings/<client>/settings.json   {{AI_MEMORY_ROOT}} -> {{CAIRN_ROOT}}, {{AI_MEMORY_DATA}} -> {{CAIRN_DATA}},
#                                     "# ai-memory" marker -> "# cairn"
# Usage: 003-rename-cairn.sh <memory-repo>
# Idempotent; never stages or commits. Afterwards: git -C <memory-repo> add -A && git commit.
# Per-machine paths (~/.config/ai-memory, ~/.local/share/ai-memory) are handled by install.sh, and the
# bridges in work repos by `tools/projects.sh sync` (or new-project.sh).
set -euo pipefail

data="${1:?usage: 003-rename-cairn.sh <memory-repo>}"
cd "$data"
say() { printf '  %s\n' "$*"; }

for f in settings/*/settings.json; do
  [ -f "$f" ] || continue
  if grep -qE '\{\{AI_MEMORY_(ROOT|DATA)\}\}|# ai-memory' "$f"; then
    sed -i.bak -e 's/{{AI_MEMORY_ROOT}}/{{CAIRN_ROOT}}/g' -e 's/{{AI_MEMORY_DATA}}/{{CAIRN_DATA}}/g' \
      -e 's/# ai-memory/# cairn/g' "$f"
    rm -f "$f.bak"
    say "renamed placeholders in $f"
  fi
done

rm -f .ai-memory-layout
printf '3\n' >.cairn-layout
say "layout 3 written to .cairn-layout"
