#!/usr/bin/env bash
# Shared path resolution for every script in tools/. Source it; do not execute it.
#
#   ROOT        this repository (the tool): tools/, settings/, templates/, .githooks/
#   LOCAL_DIR   per-machine config, never versioned ($AI_MEMORY_LOCAL or ~/.config/ai-memory)
#   DATA        the memory repository: global/, project-memories/, skills/, prompts/, presets/, build/
#               resolved from, in order: $AI_MEMORY_PROJECTS_DATA, the AI_MEMORY_PROJECTS_DATA line in $LOCAL_DIR/env,
#               and finally $ROOT itself (single-repo layout, as before the split)
#   PM_DIR      $DATA/project-memories        BUILD_DIR  $DATA/build (git-ignored bundles)
#   ROOT_TILDE / DATA_TILDE   the same with $HOME written as ~ (agy documents ~/ paths in its includes)
#
# Usage from a script:  . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$_lib_dir/.." && pwd -P)"
unset _lib_dir

LOCAL_DIR="${AI_MEMORY_LOCAL:-$HOME/.config/ai-memory}"
LOCAL_DIR="${LOCAL_DIR/#\~/$HOME}"

if [ -z "${AI_MEMORY_PROJECTS_DATA:-}" ] && [ -f "$LOCAL_DIR/env" ]; then
  # Only the AI_MEMORY_PROJECTS_DATA line is read; the file is written by install.sh --data.
  AI_MEMORY_PROJECTS_DATA="$(sed -n 's/^AI_MEMORY_PROJECTS_DATA=//p' "$LOCAL_DIR/env" | tail -1 | sed 's/^"\(.*\)"$/\1/')"
fi
tilde_path() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }
ROOT_TILDE="$(tilde_path "$ROOT")"

set_data() { # path  — (re)points DATA and the paths derived from it; install.sh --data uses it
  DATA="${1/#\~/$HOME}"
  [ -d "$DATA" ] && DATA="$(cd "$DATA" && pwd -P)"
  DATA_TILDE="$(tilde_path "$DATA")"
  PM_DIR="$DATA/project-memories"
  BUILD_DIR="$DATA/build"
  export AI_MEMORY_PROJECTS_DATA="$DATA"   # child scripts (projects.sh -> new-project.sh -> build.sh) see the same memory repo
}
set_data "${AI_MEMORY_PROJECTS_DATA:-$ROOT}"

# 0 when memory lives in its own repository, 1 in the single-repo layout.
data_is_separate() { [ "$DATA" != "$ROOT" ]; }

# Tool release version (bumped by release-please) and the memory-repo layout this version understands.
# The layout lives in $DATA/.ai-memory-layout (a single integer; missing means 1). Bump DATA_LAYOUT_SUPPORTED
# only together with a migration in migrations/ that update.sh can run.
ai_memory_version() { if [ -f "$ROOT/VERSION" ]; then tr -d '[:space:]' <"$ROOT/VERSION"; else printf 'unknown'; fi; }
DATA_LAYOUT_SUPPORTED=1
data_layout() { # prints the layout of $DATA
  local v=1
  [ -f "$DATA/.ai-memory-layout" ] && v="$(tr -dc '0-9' <"$DATA/.ai-memory-layout")"
  printf '%s' "${v:-1}"
}
