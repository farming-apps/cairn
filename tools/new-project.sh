#!/usr/bin/env bash
# Creates <data>/projects/<name>/ from the template and, if given, connects a work repo
# for Claude Code, Antigravity CLI (agy) and GitHub Copilot CLI without dirtying
# its git status: all personal bridges and skills go to .git/info/exclude.
# Re-running it on a repo repairs the bridges: lines pointing at a previous memory path are dropped.
#
# Usage: new-project.sh <name> [repo-path] [--agents] [--workspace] [--dry-run]
#   --agents   also creates <repo>/AGENTS.md as a symlink to the flat bundle (build/<name>/AGENTS.md)
#              for clients without imports (OpenCode, Codex, Aider). Opt-in: many teams already
#              version their own AGENTS.md.
#   --workspace  the path is a plain folder that holds several repos, not a git repository itself.
#              Same bridges, one memory for the whole folder; nothing to exclude, so step 8 is skipped.
#
# In the work repo it writes (all excluded in .git/info/exclude):
#   CLAUDE.local.md                              Claude Code imports of AGENTS.md and state.md
#   .claude/settings.local.json                  autoMemoryDirectory -> projects/<name>/memory
#   GEMINI.md (or .agents/rules/cairn.md)    Antigravity CLI @[label](path) includes
#   .github/instructions/cairn.instructions.md  GitHub Copilot CLI symlink -> build/<name>/copilot.instructions.md
#   .claude/skills/<s*> & .agents/skills/<s*>    shared skills from skills/ and projects/<name>/skills/
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
name=""; repo=""; AGENTS=0; DRY=0; WORKSPACE=0
for a in "$@"; do
  case "$a" in
    --agents) AGENTS=1 ;;
    --workspace) WORKSPACE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "new-project: unknown argument: $a" >&2; exit 2 ;;
    *) if [ -z "$name" ]; then name="$a"; elif [ -z "$repo" ]; then repo="$a"; else echo "new-project: too many arguments" >&2; exit 2; fi ;;
  esac
done
[ -n "$name" ] || { sed -n '2,18p' "$0"; exit 2; }
case "$name" in *[!A-Za-z0-9._-]*|_template) echo "new-project: invalid name: $name" >&2; exit 2 ;; esac

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" -eq 1 ]; then say "  + $*"; else "$@"; fi; }

pdir="$PM_DIR/$name"
template="$ROOT/templates/data/projects/_template"
say "1. project memory: $DATA_TILDE/projects/$name"
if [ -d "$pdir" ]; then
  say "  ok   already exists, left untouched"
  [ -d "$pdir/memory" ] || { say "  create $name/memory/ (auto-memory)"; run mkdir -p "$pdir/memory"; run touch "$pdir/memory/.gitkeep"; }
  [ -d "$pdir/plans" ] || { say "  create $name/plans/ (plans left pending)"; run mkdir -p "$pdir/plans"; run touch "$pdir/plans/.gitkeep"; }
else
  say "  create from templates/data/projects/_template"
  if [ "$DRY" -eq 0 ]; then
    mkdir -p "$pdir/memory" "$pdir/plans"; touch "$pdir/memory/.gitkeep" "$pdir/plans/.gitkeep"
    for f in AGENTS.md architecture.md state.md decisions.md; do
      sed "s/<proyecto>/$name/g; s/<AAAA-MM-DD>/$(date +%F)/g" "$template/$f" >"$pdir/$f"
    done
  fi
fi

[ -n "$repo" ] || { say "Done. To connect a repo: new-project.sh $name <repo-path>"; exit 0; }

repo="$(cd "$repo" && pwd -P)"
exclude_file=""
if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  exclude_file="$(git -C "$repo" rev-parse --git-path info/exclude)"
  case "$exclude_file" in /*) ;; *) exclude_file="$repo/$exclude_file" ;; esac
elif [ "$WORKSPACE" -eq 0 ]; then
  echo "new-project: $repo is not a git repository (use --workspace for a folder that holds several repos)" >&2
  exit 1
fi
excluded=()

ensure_line() { # file line
  if [ -f "$1" ] && grep -qxF -- "$2" "$1"; then return; fi
  if [ "$DRY" -eq 1 ]; then say "  + add '$2' to $1"; else mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >>"$1"; fi
}

# Lines that import this project's memory from a previous location (old root, old projects/ name).
name_re="$(printf '%s' "$name" | sed 's/[.[\*^$]/\\&/g')"
stale_re="/(projects|project-memories)/$name_re/(AGENTS|state)\.md"
drop_stale_lines() { # file wanted-line...  removes lines matching $stale_re unless they are a wanted line
  local file="$1" tmp line keep k; shift
  [ -f "$file" ] || return 0
  grep -Eq -- "$stale_re" "$file" || return 0
  tmp="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    if printf '%s\n' "$line" | grep -Eq -- "$stale_re"; then
      keep=0; for k in "$@"; do [ "$line" = "$k" ] && keep=1; done
      # stdout is the new file here: report on stderr so the message never lands in the bridge
      [ "$keep" -eq 1 ] || { printf '  drop stale import: %s\n' "$line" >&2; continue; }
    fi
    printf '%s\n' "$line"
  done <"$file" >"$tmp"
  if cmp -s "$tmp" "$file" || [ "$DRY" -eq 1 ]; then rm -f "$tmp"; else mv "$tmp" "$file"; fi
}

say "2. Claude Code in $repo"
claude_local="$repo/CLAUDE.local.md"
[ -f "$claude_local" ] && say "  CLAUDE.local.md already exists; adding the import if missing" || say "  create CLAUDE.local.md"
drop_stale_lines "$claude_local" "@$pdir/AGENTS.md" "@$pdir/state.md"
ensure_line "$claude_local" "@$pdir/AGENTS.md"
ensure_line "$claude_local" "@$pdir/state.md"
if [ -f "$repo/AGENTS.md" ] && [ ! -f "$repo/CLAUDE.md" ] && [ ! -f "$repo/.claude/CLAUDE.md" ]; then
  say "  the repo uses AGENTS.md without CLAUDE.md: importing it too so it is not lost"
  ensure_line "$claude_local" "@AGENTS.md"
fi
excluded+=("CLAUDE.local.md")

say "3. Auto-memory & statusLine link -> projects/$name/memory"
# Existing memory repos may still have the old ignore rules from before this layout change.
ensure_line "$DATA/.gitignore" "projects/*/memory/*"
ensure_line "$DATA/.gitignore" "!projects/*/memory/.gitkeep"
settings="$repo/.claude/settings.local.json"
if [ "$DRY" -eq 1 ]; then
  say "  + autoMemoryDirectory in $settings"
else
  mkdir -p "$repo/.claude"
  python3 - "$settings" "$pdir/memory" <<'PY'
import json, os, sys
path, target = sys.argv[1:3]
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read().strip()
    data = json.loads(text) if text else {}
data["autoMemoryDirectory"] = target
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False); fh.write("\n")
PY
fi
excluded+=(".claude/settings.local.json")

say "4. Antigravity CLI / Gemini in $repo"
# Use .agents/rules/cairn.md if GEMINI.md is tracked by git or already has non-cairn content.
use_agy_rule=0
if git -C "$repo" ls-files --error-unmatch GEMINI.md >/dev/null 2>&1; then
  use_agy_rule=1
elif [ -f "$repo/GEMINI.md" ] && ! grep -qE '@\[(cairn|ai-memory)\]' "$repo/GEMINI.md" 2>/dev/null; then
  use_agy_rule=1
fi
if [ "$use_agy_rule" -eq 1 ]; then
  rule="$repo/.agents/rules/cairn.md"
  say "  the repo already has its own GEMINI.md; using .agents/rules/cairn.md"
  old_rule="$repo/.agents/rules/ai-memory.md"   # name before the rename to cairn
  if [ -f "$old_rule" ]; then
    if [ -f "$rule" ]; then say "  remove the pre-rename $old_rule"; run rm -f "$old_rule"
    else say "  rename the pre-rename $old_rule -> cairn.md"; run mv "$old_rule" "$rule"; fi
  fi
  if [ ! -f "$rule" ]; then
    if [ "$DRY" -eq 1 ]; then say "  + create $rule"; else
      mkdir -p "$(dirname "$rule")"
      printf -- '---\ntrigger: always_on\ndescription: project memory (cairn)\n---\n' >"$rule"
    fi
  fi
  agy_agents="@[cairn]($DATA_TILDE/projects/$name/AGENTS.md)"
  agy_state="@[state]($DATA_TILDE/projects/$name/state.md)"
  drop_stale_lines "$rule" "$agy_agents" "$agy_state"
  ensure_line "$rule" "$agy_agents"
  ensure_line "$rule" "$agy_state"
  excluded+=(".agents/rules/cairn.md")
else
  [ -f "$repo/GEMINI.md" ] && say "  ok   GEMINI.md" || say "  create GEMINI.md"
  agy_agents="@[cairn]($DATA_TILDE/projects/$name/AGENTS.md)"
  agy_state="@[state]($DATA_TILDE/projects/$name/state.md)"
  drop_stale_lines "$repo/GEMINI.md" "$agy_agents" "$agy_state"
  ensure_line "$repo/GEMINI.md" "$agy_agents"
  ensure_line "$repo/GEMINI.md" "$agy_state"
  excluded+=("GEMINI.md")
fi

say "5. GitHub Copilot CLI in $repo"
run "$ROOT/tools/build.sh" "$name" >/dev/null
copilot_instr="$repo/.github/instructions/cairn.instructions.md"
old_instr="$repo/.github/instructions/ai-memory.instructions.md"   # name before the rename to cairn
if [ -L "$old_instr" ]; then say "  remove the pre-rename link $old_instr"; run rm -f "$old_instr"; fi
if [ "$DRY" -eq 1 ]; then
  say "  + link $copilot_instr -> build/$name/copilot.instructions.md"
else
  mkdir -p "$(dirname "$copilot_instr")"
  ln -sfn "$BUILD_DIR/$name/copilot.instructions.md" "$copilot_instr"
  say "  link .github/instructions/cairn.instructions.md -> build/$name/copilot.instructions.md"
fi
excluded+=(".github/instructions/cairn.instructions.md")

say "6. Shared skills (Claude Code, Antigravity CLI, GitHub Copilot CLI)"
skill_count=0
for sdir in "$DATA/skills"/* "$pdir/skills"/*; do
  [ -d "$sdir" ] && [ -f "$sdir/SKILL.md" ] || continue
  sname="$(basename "$sdir")"
  for target_rel in ".claude/skills/$sname" ".agents/skills/$sname"; do
    if [ "$DRY" -eq 1 ]; then
      say "  + link $repo/$target_rel -> $sdir"
    else
      mkdir -p "$(dirname "$repo/$target_rel")"
      ln -sfn "$sdir" "$repo/$target_rel"
    fi
    excluded+=("$target_rel")
  done
  skill_count=$((skill_count + 1))
done
[ "$skill_count" -gt 0 ] && say "  linked $skill_count skill(s) into .claude/skills and .agents/skills" || say "  no custom skills in skills/ or projects/$name/skills/ (skipped)"

say "7. flat AGENTS.md for other clients"
if [ "$AGENTS" -eq 1 ]; then
  if [ -e "$repo/AGENTS.md" ] && [ ! -L "$repo/AGENTS.md" ]; then
    say "  the repo already has AGENTS.md; left untouched"
  else
    say "  link AGENTS.md -> build/$name/AGENTS.md (regenerate with tools/build.sh $name)"
    if [ "$DRY" -eq 1 ]; then say "  + ln -sfn $BUILD_DIR/$name/AGENTS.md $repo/AGENTS.md"; else ln -sfn "$BUILD_DIR/$name/AGENTS.md" "$repo/AGENTS.md"; fi
    excluded+=("AGENTS.md")
  fi
else
  say "  skipped (use --agents if you work with OpenCode/Codex/Aider in this repo)"
fi

say "8. .git/info/exclude"
if [ -n "$exclude_file" ]; then
  for e in "${excluded[@]}"; do ensure_line "$exclude_file" "$e"; done
  say "  excluded: ${excluded[*]}"
else
  say "  skipped (workspace folder, not a git repository: nothing to exclude)"
fi

say
say "Done. Project '$name' is ready in $repo for Claude Code, Antigravity CLI (agy) and GitHub Copilot CLI."
