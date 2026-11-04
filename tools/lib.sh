#!/usr/bin/env bash
# Shared path resolution for every script in tools/. Source it; do not execute it.
#
#   ROOT        this repository (the tool): tools/, policy/, templates/, .githooks/
#   LOCAL_DIR   per-machine config, never versioned ($CAIRN_LOCAL or ~/.config/cairn)
#   DATA        the memory repository: global/, projects/, skills/, prompts/, presets/, settings/, build/
#               resolved from, in order: $CAIRN_DATA, the CAIRN_DATA line in $LOCAL_DIR/env,
#               and finally $ROOT itself (single-repo layout, as before the split)
#   PM_DIR      $DATA/projects        BUILD_DIR  $DATA/build (git-ignored bundles)
#   INSTALL_DIR the installed copy: a detached worktree of origin/main made by install.sh
#               ($CAIRN_INSTALL_DIR or ~/.local/share/cairn); client hooks point there
#   ROOT_TILDE / DATA_TILDE   the same with $HOME written as ~ (agy documents ~/ paths in its includes)
#
# Usage from a script:  . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$_lib_dir/.." && pwd -P)"
unset _lib_dir

# Renamed from ai-memory: the old AI_MEMORY_* variables are still honoured (with a warning) when the
# CAIRN_* one is unset. Remove this block once every machine has migrated.
_cairn_old_vars=""
for _pair in DATA:PROJECTS_DATA LOCAL:LOCAL INSTALL_DIR:INSTALL_DIR PROJECTS_ENC:PROJECTS_ENC \
             PROJECTS:PROJECTS CHARS_PER_TOKEN:CHARS_PER_TOKEN NO_UPDATE_CHECK:NO_UPDATE_CHECK; do
  _new="CAIRN_${_pair%%:*}"; _old="AI_MEMORY_${_pair##*:}"
  if [ -z "${!_new:-}" ] && [ -n "${!_old:-}" ]; then
    export "$_new=${!_old}"; _cairn_old_vars="$_cairn_old_vars $_old"
  fi
done
if [ -n "$_cairn_old_vars" ] && [ -z "${_CAIRN_OLD_VARS_WARNED:-}" ]; then
  export _CAIRN_OLD_VARS_WARNED=1
  echo "cairn: deprecated variables set:$_cairn_old_vars; rename them to CAIRN_* in your shell profile" >&2
fi
unset _pair _new _old _cairn_old_vars

# Old per-machine locations (before the rename), used while the new ones do not exist yet;
# install.sh moves the config dir and creates the new installed copy.
OLD_LOCAL_DIR="$HOME/.config/ai-memory"
OLD_INSTALL_DIR="$HOME/.local/share/ai-memory"
LOCAL_DIR="${CAIRN_LOCAL:-$HOME/.config/cairn}"
LOCAL_DIR="${LOCAL_DIR/#\~/$HOME}"
if [ -z "${CAIRN_LOCAL:-}" ] && [ ! -d "$LOCAL_DIR" ] && [ -d "$OLD_LOCAL_DIR" ]; then LOCAL_DIR="$OLD_LOCAL_DIR"; fi
INSTALL_DIR="${CAIRN_INSTALL_DIR:-$HOME/.local/share/cairn}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

if [ -z "${CAIRN_DATA:-}" ] && [ -f "$LOCAL_DIR/env" ]; then
  # Only the CAIRN_DATA line is read (or the pre-rename AI_MEMORY_PROJECTS_DATA one); install.sh --data writes it.
  CAIRN_DATA="$(sed -n -E 's/^(CAIRN_DATA|AI_MEMORY_PROJECTS_DATA)=//p' "$LOCAL_DIR/env" | tail -1 | sed 's/^"\(.*\)"$/\1/')"
fi
tilde_path() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }
ROOT_TILDE="$(tilde_path "$ROOT")"

set_data() { # path  — (re)points DATA and the paths derived from it; install.sh --data uses it
  DATA="${1/#\~/$HOME}"
  [ -d "$DATA" ] && DATA="$(cd "$DATA" && pwd -P)"
  DATA_TILDE="$(tilde_path "$DATA")"
  PM_DIR="$DATA/projects"
  BUILD_DIR="$DATA/build"
  export CAIRN_DATA="$DATA"   # child scripts (projects.sh -> new-project.sh -> build.sh) see the same memory repo
}
set_data "${CAIRN_DATA:-$ROOT}"

# A file of the memory repo, or its default in templates/data/ when the memory repo lacks it
# (dry-run before the repo exists, or the single-repo layout).
data_file() { # rel-path
  if [ -f "$DATA/$1" ]; then printf '%s' "$DATA/$1"; else printf '%s' "$ROOT/templates/data/$1"; fi
}

# 0 when memory lives in its own repository, 1 in the single-repo layout.
data_is_separate() { [ "$DATA" != "$ROOT" ]; }

# Root the client hooks should point to: the installed worktree if there is one, else this repo (--dev).
hook_root() {
  if [ -f "$INSTALL_DIR/tools/guard-bash.py" ]; then (cd "$INSTALL_DIR" && pwd -P); else printf '%s' "$ROOT"; fi
}

# Tool release version (bumped by release-please) and the memory-repo layout this version understands.
# The layout lives in $DATA/.cairn-layout (a single integer; missing means 1). Bump DATA_LAYOUT_SUPPORTED
# only together with a migration in migrations/ that update.sh can run.
#   1  project-memories/<p>/pending/
#   2  projects/<p>/memory/            (migrations/002-projects-memory.sh)
cairn_version() { if [ -f "$ROOT/VERSION" ]; then tr -d '[:space:]' <"$ROOT/VERSION"; else printf 'unknown'; fi; }
#   3  .ai-memory-layout -> .cairn-layout, settings/ placeholders renamed (migrations/003-rename-cairn.sh)
DATA_LAYOUT_SUPPORTED=3
data_layout() { # prints the layout of $DATA (.ai-memory-layout is the pre-rename name, layouts 1-2)
  local v=1
  if [ -f "$DATA/.cairn-layout" ]; then v="$(tr -dc '0-9' <"$DATA/.cairn-layout")"
  elif [ -f "$DATA/.ai-memory-layout" ]; then v="$(tr -dc '0-9' <"$DATA/.ai-memory-layout")"; fi
  printf '%s' "${v:-1}"
}

# Runs the migrations between the memory repo's layout and DATA_LAYOUT_SUPPORTED, asking before each one.
# Their changes stay unstaged: nothing is ever committed in the memory repo. 1 if one is declined.
run_migrations() { # dry(0|1) yes(0|1)
  local dry="$1" yes="$2" layout m n reply
  data_is_separate && [ -d "$DATA" ] || return 0
  layout="$(data_layout)"
  for m in "$ROOT"/migrations/[0-9][0-9][0-9]-*.sh; do
    [ -f "$m" ] || continue
    n="$(basename "$m" | cut -c1-3)"; n=$((10#$n))
    [ "$n" -gt "$layout" ] && [ "$n" -le "$DATA_LAYOUT_SUPPORTED" ] || continue
    printf 'migration %s on %s (changes stay unstaged; review with git status and commit)\n' "$(basename "$m")" "$DATA"
    if [ "$dry" -eq 1 ]; then printf '  + bash %s %s\n' "$m" "$DATA"; continue; fi
    if [ "$yes" -ne 1 ]; then
      [ -t 0 ] || { printf '  no terminal to ask; re-run with --yes\n' >&2; return 1; }
      printf '  run it? [y/N] '; read -r reply
      case "$reply" in y|Y|yes|YES) ;; *) printf 'migration declined; the memory repo stays at layout %s\n' "$layout" >&2; return 1 ;; esac
    fi
    bash "$m" "$DATA" || return 1
    layout="$(data_layout)"
  done
}

# Memory repo older than this tool: say how to migrate, once per run (scripts would look in the wrong place).
if data_is_separate && [ -d "$DATA" ] && [ "$(data_layout)" -lt "$DATA_LAYOUT_SUPPORTED" ] && [ -z "${_CAIRN_OLD_LAYOUT_WARNED:-}" ]; then
  export _CAIRN_OLD_LAYOUT_WARNED=1
  echo "cairn: memory repo layout $(data_layout) is older than this tool's ($DATA_LAYOUT_SUPPORTED); run tools/install.sh or tools/update.sh to migrate it" >&2
fi
