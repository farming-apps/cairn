#!/usr/bin/env bash
# Prepares this machine to use the repository. Idempotent: re-run it after a git pull.
# Resolves its own path, so the repo can live anywhere.
# None of the three AI clients (claude, agy, copilot) is mandatory: each one is configured
# automatically if installed (or if its config dir exists), or when forced via flags.
#
# Source: by default it checks out origin/main (local main without a remote) in a detached worktree
# ($AI_MEMORY_INSTALL_DIR or ~/.local/share/ai-memory) and continues from there, so client hooks,
# the status line and the memory repo's pre-commit hook run what was merged, not whatever branch is
# checked out in this clone. Re-run it after merging to update the installed copy.
#
# Usage: install.sh [--data <path>] [--dev] [--dry-run] [--yes] [--module <m>] [--claude|--no-claude] [--gemini|--no-gemini] [--copilot|--no-copilot] [--vscode|--no-vscode]
#   --data <path>          where the memory repository lives (global/, projects/, skills/...).
#                          Remembered in ~/.config/ai-memory/env; created from templates/data/ if missing.
#                          Without it, and with no env file, memory is expected inside this repo (single-repo layout).
#   --dev                  install from this clone as it is (current branch, uncommitted changes), no worktree
#   --dry-run             show what would be done without touching anything
#   --yes                  install missing tools (gitleaks, jq) with Homebrew without asking
#   --module <m>           comma-separated modules to run: hardening, memory, projects, all (default: all)
#   --claude|--no-claude   force or skip Claude Code (default: auto)
#   --gemini|--no-gemini   force or skip Antigravity CLI / Gemini (default: auto)
#   --copilot|--no-copilot force or skip GitHub Copilot CLI (default: auto)
#   --vscode|--no-vscode   force or skip VS Code (built-in Copilot off in sensitive file types) (default: auto)
#
# Modules:
#   hardening  tools check (git, python3, gitleaks, jq), git hooks, forbidden-terms.txt, client
#              policies (permissions, guard-bash PreToolUse hook, statusLine, sandbox) and VS Code
#              (built-in Copilot disabled for .env, credentials and other sensitive file types)
#   memory     global/profile.private.md, global instructions (CLAUDE.md, GEMINI.md,
#              copilot-instructions.md) and global skills (skills/* -> ~/.claude, ~/.gemini, ~/.copilot)
#   projects   ~/.config/ai-memory/projects.yml template and sync of active registered projects
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DRY=0; YES=0
CLAUDE=auto; GEMINI=auto; COPILOT=auto; VSCODE=auto
MODULES="all"
DATA_ARG=""
DEV=0; FROM_WORKTREE=0
ORIG_ARGS=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --data)       DATA_ARG="${2:-}"; shift 2 ;;
    --data=*)     DATA_ARG="${1#*=}"; shift ;;
    --dev)        DEV=1; shift ;;
    --from-worktree) FROM_WORKTREE=1; shift ;;   # internal: added by the re-exec into the worktree
    --dry-run)    DRY=1; shift ;;
    --yes)        YES=1; shift ;;
    -m|--module)  MODULES="${2:-}"; shift 2 ;;
    --module=*)   MODULES="${1#*=}"; shift ;;
    --claude)     CLAUDE=yes; shift ;;
    --no-claude)  CLAUDE=no; shift ;;
    --gemini)     GEMINI=yes; shift ;;
    --no-gemini)  GEMINI=no; shift ;;
    --copilot)    COPILOT=yes; shift ;;
    --no-copilot) COPILOT=no; shift ;;
    --vscode)     VSCODE=yes; shift ;;
    --no-vscode)  VSCODE=no; shift ;;
    -h|--help)    awk 'NR>1 && /^set -euo pipefail/{exit} NR>1{print}' "$0"; exit 0 ;;
    *)            echo "install: unknown argument: $1" >&2; exit 2 ;;
  esac
done

has_module() {
  case ",$MODULES," in
    *,all,*|*,"$1",*) return 0 ;;
    *) return 1 ;;
  esac
}
for m in ${MODULES//,/ }; do
  case "$m" in
    all|hardening|memory|projects) ;;
    *) echo "install: unknown module '$m' (expected: hardening, memory, projects, all)" >&2; exit 2 ;;
  esac
done

[ -n "$DATA_ARG" ] && set_data "$DATA_ARG"

# --- source: detached worktree of origin/main -----------------------------------------------------
# Everything after this block runs from the worktree (ROOT = INSTALL_DIR), so the paths written into
# the clients' settings and the memory repo's core.hooksPath point at the installed copy.
if [ "$FROM_WORKTREE" -eq 0 ] && [ "$DEV" -eq 0 ]; then
  install_real="$INSTALL_DIR"; [ -d "$INSTALL_DIR" ] && install_real="$(cd "$INSTALL_DIR" && pwd -P)"
  if [ "$ROOT" = "$install_real" ]; then
    printf 'source: running the installed copy (%s); to update it, run tools/install.sh from your clone\n' "$INSTALL_DIR"
  elif ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'source: %s is not a git repository; installing from it as it is (--dev)\n' "$ROOT"
  elif ! data_is_separate; then
    printf 'source: single-repo layout (memory inside this clone); installing from it as it is (--dev)\n'
  else
    # prefer the remote main (what has been merged); fall back to the local branch without a remote
    if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
      git -C "$ROOT" fetch --quiet origin main 2>/dev/null || printf 'source: could not fetch origin (offline?); using the last known origin/main\n'
    fi
    if git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then ref="origin/main"; else ref="main"; fi
    if [ "$DRY" -eq 1 ]; then
      printf 'source: would check out %s (%s, detached) in %s\n' "$ref" "$(git -C "$ROOT" rev-parse --short "$ref")" "$INSTALL_DIR"
      if [ ! -f "$INSTALL_DIR/tools/install.sh" ]; then
        printf 'source: (dry-run) %s does not exist yet; showing the rest from this clone\n' "$INSTALL_DIR"
        FROM_WORKTREE=1
      fi
    elif [ -e "$INSTALL_DIR/.git" ]; then
      if [ -n "$(git -C "$INSTALL_DIR" status --porcelain 2>/dev/null)" ]; then
        printf 'install: %s has local changes (git -C %s status); it is a generated copy: discard them and re-run\n' "$INSTALL_DIR" "$INSTALL_DIR" >&2
        exit 1
      fi
      git -C "$INSTALL_DIR" checkout --quiet --detach "$ref"
      printf 'source: %s updated to %s (%s)\n' "$INSTALL_DIR" "$ref" "$(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
    else
      git -C "$ROOT" worktree prune
      mkdir -p "$(dirname "$INSTALL_DIR")"
      git -C "$ROOT" worktree add --quiet --detach "$INSTALL_DIR" "$ref"
      printf 'source: %s checked out at %s (%s)\n' "$INSTALL_DIR" "$ref" "$(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
    fi
    if [ "$FROM_WORKTREE" -eq 0 ]; then
      exec bash "$INSTALL_DIR/tools/install.sh" --from-worktree ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
  fi
fi

COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
# VS Code user settings dir: $VSCODE_USER_DIR overrides; macOS and Linux defaults otherwise.
case "$(uname -s)" in
  Darwin) VSCODE_DIR="${VSCODE_USER_DIR:-$HOME/Library/Application Support/Code/User}" ;;
  *)      VSCODE_DIR="${VSCODE_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/Code/User}" ;;
esac

has_claude() {
  [ "$CLAUDE" = yes ] || { [ "$CLAUDE" = auto ] && { command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ]; }; }
}
has_gemini() {
  [ "$GEMINI" = yes ] || { [ "$GEMINI" = auto ] && { command -v agy >/dev/null 2>&1 || command -v gemini >/dev/null 2>&1 || [ -d "$HOME/.gemini" ]; }; }
}
has_copilot() {
  [ "$COPILOT" = yes ] || { [ "$COPILOT" = auto ] && { command -v copilot >/dev/null 2>&1 || [ -d "$COPILOT_DIR" ]; }; }
}
has_vscode() {
  [ "$VSCODE" = yes ] || { [ "$VSCODE" = auto ] && { command -v code >/dev/null 2>&1 || [ -d "$VSCODE_DIR" ]; }; }
}

say()  { printf '%s\n' "$*"; }
run()  { if [ "$DRY" -eq 1 ]; then say "  + $*"; else "$@"; fi; }
copy_if_absent() { # src dst
  if [ -e "$2" ]; then say "  ok   $2 (already exists)"; else say "  create $2"; run mkdir -p "$(dirname "$2")"; run cp "$1" "$2"; fi
}

# Keeps a delimited block inside a file that may also hold the user's own content.
BEGIN_MARK='<!-- >>> ai-memory (generated by tools/install.sh; do not edit by hand) >>> -->'
END_MARK='<!-- <<< ai-memory <<< -->'
# Marker written by versions before the switch to English; replaced in place on the next install.
OLD_BEGIN_MARK='<!-- >>> ai-memory (generado por tools/install.sh; no editar a mano) >>> -->'
write_block() { # file content
  local file="$1" content="$2" new
  new="$(python3 - "$file" "$BEGIN_MARK" "$END_MARK" "$content" "$OLD_BEGIN_MARK" <<'PY'
import os, sys
path, b, e, content, old_b = sys.argv[1:6]
block = f"{b}\n{content}\n{e}\n"
old = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
start = b if b in old else old_b if old_b in old else None
if start and e in old:
    pre, rest = old.split(start, 1); _, post = rest.split(e, 1)
    new = pre + block.rstrip("\n") + post
else:
    new = (old.rstrip("\n") + "\n\n" if old.strip() else "") + block
sys.stdout.write(new)
PY
)"
  if [ -f "$file" ] && [ "$(cat "$file")" = "${new%$'\n'}" ]; then say "  ok   $file (no changes)"; return; fi
  if [ -f "$file" ]; then
    local bak; bak="$file.bak.$(date +%Y%m%d%H%M%S)"
    say "  backup: $bak"; run cp "$file" "$bak"
  fi
  say "  write $file"
  if [ "$DRY" -eq 0 ]; then mkdir -p "$(dirname "$file")"; printf '%s\n' "$new" >"$file"; fi
}

link_global_skills() { # target-skills-dir
  local dest_dir="$1" count=0 sdir sname
  for sdir in "$DATA/skills"/*; do
    [ -d "$sdir" ] && [ -f "$sdir/SKILL.md" ] || continue
    sname="$(basename "$sdir")"
    if [ "$DRY" -eq 1 ]; then
      say "  + link $dest_dir/$sname -> $sdir"
    else
      mkdir -p "$dest_dir"
      ln -sfn "$sdir" "$dest_dir/$sname"
    fi
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] && say "  ok   linked $count skill(s) in $dest_dir" || true
}

say "ai-memory at: $ROOT (modules: $MODULES)"
if data_is_separate; then say "memory at:    $DATA"; else say "memory at:    $ROOT (single-repo layout; use --data <path> to keep it in its own repository)"; fi
[ "$DRY" -eq 1 ] && say "(dry-run: nothing is modified)"

# --- memory repository ----------------------------------------------------------------------------
# Remembers --data in $LOCAL_DIR/env and makes sure the memory repo has the skeleton from templates/data/.
if [ -n "$DATA_ARG" ]; then
  say "memory repository: remember $DATA in $LOCAL_DIR/env"
  if [ "$DRY" -eq 1 ]; then
    say "  + AI_MEMORY_PROJECTS_DATA=$DATA"
  else
    mkdir -p "$LOCAL_DIR"
    { [ -f "$LOCAL_DIR/env" ] && grep -v -E '^AI_MEMORY_(PROJECTS_)?DATA=' "$LOCAL_DIR/env"; printf 'AI_MEMORY_PROJECTS_DATA=%s\n' "$DATA"; } >"$LOCAL_DIR/env.tmp" || true
    mv "$LOCAL_DIR/env.tmp" "$LOCAL_DIR/env"
  fi
fi
if data_is_separate; then
  if [ ! -d "$DATA" ]; then
    say "memory repository: create $DATA from templates/data/"
    if [ "$DRY" -eq 1 ]; then
      say "  + mkdir, git init, copy skeleton, initial commit"
    else
      mkdir -p "$DATA"
      git -C "$DATA" init -q -b main 2>/dev/null || git -C "$DATA" init -q   # -b needs git 2.28+
      cp -R "$ROOT/templates/data/." "$DATA/"
      git -C "$DATA" add -A
      git -C "$DATA" -c core.hooksPath=/dev/null commit -q -m "Initial memory layout" || say "  warning: initial commit failed (git identity?); commit by hand"
      say "  ok   created; add a private remote and push when ready"
    fi
  else
    say "memory repository: $DATA"
    git -C "$DATA" rev-parse --git-dir >/dev/null 2>&1 || say "  warning: $DATA is not a git repository; run 'git init' there so the hook can protect it"
    while IFS= read -r rel; do
      copy_if_absent "$ROOT/templates/data/$rel" "$DATA/$rel"
    done < <(cd "$ROOT/templates/data" && find . -type f ! -name README.md | sed 's|^\./||' | sort)
  fi
elif [ ! -f "$ROOT/global/AGENTS.md" ] && { has_module memory || has_module projects; }; then
  say "install: no memory here: this clone holds only the tool. Run: tools/install.sh --data <path-to-memory-repo>" >&2
  say "         (it is created from templates/data/ if the path does not exist yet)" >&2
  exit 2
fi

# --- tools check (always verify git & python3) -----------------------------------------------
tool_version() { # name -> first line of its version output, or empty
  case "$1" in
    gitleaks) gitleaks version 2>/dev/null | head -1 ;;
    jq)       jq --version 2>/dev/null ;;
    *)        "$1" --version 2>/dev/null | head -1 ;;
  esac
}
confirm() { # question -> 0 to proceed. --yes and --dry-run proceed; no terminal -> skip.
  [ "$YES" -eq 1 ] || [ "$DRY" -eq 1 ] && return 0
  if [ ! -t 0 ]; then say "  skipped: no terminal to ask; re-run with --yes to install it"; return 1; fi
  printf '%s [y/N] ' "$1"; read -r reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) say "  skipped"; return 1 ;; esac
}
ensure_tool() { # name purpose -> installs with Homebrew if missing and confirmed; never fails the script
  if command -v "$1" >/dev/null 2>&1; then say "  ok   $1 $(tool_version "$1")"; return; fi
  say "  missing $1: $2"
  if ! command -v brew >/dev/null 2>&1; then
    say "  no Homebrew here: install $1 with your package manager (apt/dnf/pacman install $1) and re-run"
    return
  fi
  confirm "  install $1 with Homebrew (brew install $1)?" || return 0
  run brew install "$1"
  if [ "$DRY" -eq 0 ]; then
    if command -v "$1" >/dev/null 2>&1; then say "  ok   $1 $(tool_version "$1") (installed)"; else say "  FAILED: $1 still not found after brew install"; fi
  fi
}

say "0. base tools"
missing=0
for t in git python3; do
  if command -v "$t" >/dev/null 2>&1; then say "  ok   $t $(tool_version "$t")"; else say "  MISSING $t"; missing=1; fi
done
if [ "$missing" -eq 1 ]; then
  say "install: git and python3 are required before anything else (macOS: xcode-select --install; Debian/Ubuntu: apt install git python3). Re-run afterwards." >&2
  exit 1
fi

# =============================================================================================
# MODULE 1: HARDENING (hooks, sanitize terms, permissions, guard-bash, statusLine, sandbox)
# =============================================================================================
if has_module hardening; then
  say
  say "=== Module: hardening ==="
  ensure_tool gitleaks "the pre-commit hook blocks every commit without it"
  ensure_tool jq "the status line (tools/statusline.sh) shows no data without it"

  say "1. git hooks & forbidden terms"
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    run git -C "$ROOT" config core.hooksPath .githooks
    run chmod +x "$ROOT"/.githooks/* "$ROOT"/tools/*.sh "$ROOT"/tools/*.py "$ROOT"/tools/ai
  else
    say "  warning: $ROOT is not a git repository; run 'git init' and re-run"
  fi
  if data_is_separate && git -C "$DATA" rev-parse --git-dir >/dev/null 2>&1; then
    say "  memory repo hook -> $ROOT_TILDE/.githooks"
    run git -C "$DATA" config core.hooksPath "$ROOT/.githooks"
  fi
  copy_if_absent "$ROOT/templates/forbidden-terms.txt" "$LOCAL_DIR/forbidden-terms.txt"

  say "2. Claude Code policy (permissions, guard-bash hook and statusLine)"
  if has_claude; then
    merge_args=("$ROOT/settings/claude/settings.json" "$HOME/.claude/settings.json" "$ROOT")
    [ "$DRY" -eq 1 ] && merge_args+=(--dry-run)
    python3 "$ROOT/tools/merge-settings.py" "${merge_args[@]}" || [ $? -eq 3 ]
  else
    say "  skipped (claude not installed; use --claude to force it)"
  fi

  say "3. Antigravity CLI / Gemini policy (permissions, guard-bash hook and statusLine)"
  if has_gemini; then
    say "  permissions (antigravity-cli/settings.json)"
    merge_args=("$ROOT/settings/agy/settings.json" "$HOME/.gemini/antigravity-cli/settings.json" "$ROOT")
    [ "$DRY" -eq 1 ] && merge_args+=(--dry-run)
    python3 "$ROOT/tools/merge-settings.py" "${merge_args[@]}" || [ $? -eq 3 ]
    say "  guard-bash hook (config/hooks.json)"
    merge_args=(--replace-keys "$ROOT/settings/agy/hooks.json" "$HOME/.gemini/config/hooks.json" "$ROOT")
    [ "$DRY" -eq 1 ] && merge_args+=(--dry-run)
    python3 "$ROOT/tools/merge-settings.py" "${merge_args[@]}" || [ $? -eq 3 ]
  else
    say "  skipped (neither agy nor gemini installed; use --gemini to force it)"
  fi

  say "4. GitHub Copilot CLI policy (statusLine, guard-bash hook and sandbox)"
  if has_copilot; then
    merge_args=("$ROOT/settings/copilot/settings.json" "$COPILOT_DIR/settings.json" "$ROOT")
    [ "$DRY" -eq 1 ] && merge_args+=(--dry-run)
    python3 "$ROOT/tools/merge-settings.py" "${merge_args[@]}" || [ $? -eq 3 ]
  else
    say "  skipped (copilot not installed; use --copilot to force it)"
  fi

  say "5. VS Code policy (built-in Copilot off in sensitive file types)"
  if has_vscode; then
    merge_args=("$ROOT/settings/vscode/settings.json" "$VSCODE_DIR/settings.json" "$ROOT")
    [ "$DRY" -eq 1 ] && merge_args+=(--dry-run)
    python3 "$ROOT/tools/merge-settings.py" "${merge_args[@]}" || [ $? -eq 3 ]
  else
    say "  skipped (VS Code not installed; use --vscode to force it)"
  fi
fi

# =============================================================================================
# MODULE 2: MEMORY (global rules, profile, and skills across installed clients)
# =============================================================================================
if has_module memory; then
  say
  say "=== Module: memory ==="
  say "1. private profile (outside git)"
  copy_if_absent "$ROOT/templates/data/global/profile.private.md.example" "$DATA/global/profile.private.md"

  say "2. Claude Code global memory & skills"
  if has_claude; then
    write_block "$HOME/.claude/CLAUDE.md" "@$DATA/global/AGENTS.md
@$DATA/global/profile.private.md"
    link_global_skills "$HOME/.claude/skills"
  else
    say "  skipped (claude not installed; use --claude to force it)"
  fi

  say "3. Antigravity CLI / Gemini global memory & skills"
  if has_gemini; then
    # agy include syntax: @[label](path). A bare "@path" inserts nothing.
    write_block "$HOME/.gemini/GEMINI.md" "@[AGENTS]($DATA_TILDE/global/AGENTS.md)
@[profile]($DATA_TILDE/global/profile.private.md)"
    link_global_skills "$HOME/.gemini/skills"
  else
    say "  skipped (neither agy nor gemini installed; use --gemini to force it)"
  fi

  say "4. GitHub Copilot CLI global memory & skills"
  if has_copilot; then
    # Copilot CLI reads ~/.copilot/copilot-instructions.md without @path expansion, so inline the global rules + profile.
    profile_src="$DATA/global/profile.private.md"
    [ -f "$profile_src" ] || profile_src="$ROOT/templates/data/global/profile.private.md.example"
    agents_src="$DATA/global/AGENTS.md"
    [ -f "$agents_src" ] || agents_src="$ROOT/templates/data/global/AGENTS.md"   # dry-run before the memory repo exists
    copilot_content="$(cat "$agents_src"; printf '\n\n'; cat "$profile_src")"
    write_block "$COPILOT_DIR/copilot-instructions.md" "$copilot_content"
    link_global_skills "$COPILOT_DIR/skills"
  else
    say "  skipped (copilot not installed; use --copilot to force it)"
  fi
fi

# =============================================================================================
# MODULE 3: PROJECTS (external YAML registry & sync)
# =============================================================================================
if has_module projects; then
  say
  say "=== Module: projects ==="
  copy_if_absent "$ROOT/templates/projects.yml" "$LOCAL_DIR/projects.yml"
  if [ -x "$ROOT/tools/projects.sh" ] && [ -f "$LOCAL_DIR/projects.yml" ]; then
    active_count="$("$ROOT/tools/projects.sh" paths 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$active_count" -gt 0 ]; then
      say "  syncing $active_count active local project(s) from projects.yml"
      sync_args=(sync)
      [ "$DRY" -eq 1 ] && sync_args+=(--dry-run)
      "$ROOT/tools/projects.sh" "${sync_args[@]}"
    else
      say "  ok   projects.yml ready (no active projects configured yet)"
    fi
  fi
fi

say
if has_module hardening && ! command -v gitleaks >/dev/null 2>&1; then
  say "MISSING gitleaks: the hook will block commits until it is installed (install.sh --yes, or brew install gitleaks)."
fi
say "Next: tools/doctor.sh   ·   projects: tools/projects.sh list   ·   new project: tools/new-project.sh <name> [repo-path]"
