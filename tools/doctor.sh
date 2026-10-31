#!/usr/bin/env bash
# Checks that this machine is set up correctly across the active modules (hardening, memory, projects).
# None of the three AI clients (claude, agy, copilot) is mandatory: only installed clients are required
# to pass; missing ones are reported as WARN (skipped). Exits 1 if there is any FAIL.
#
# Usage: doctor.sh [--module <hardening,memory,projects,all>] [work-repo-path ...]
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
case "$(uname -s)" in
  Darwin) VSCODE_DIR="${VSCODE_USER_DIR:-$HOME/Library/Application Support/Code/User}" ;;
  *)      VSCODE_DIR="${VSCODE_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/Code/User}" ;;
esac
MODULES="all"
args_repos=()

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--module) MODULES="${2:-}"; shift 2 ;;
    --module=*)  MODULES="${1#*=}"; shift ;;
    -h|--help)   sed -n '2,6p' "$0"; exit 0 ;;
    -*)          echo "doctor: unknown argument: $1" >&2; exit 2 ;;
    *)           args_repos+=("$1"); shift ;;
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
    *) echo "doctor: unknown module '$m' (expected: hardening, memory, projects, all)" >&2; exit 2 ;;
  esac
done

fails=0
ok()   { printf '  OK   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }
warn() { printf '  WARN %s\n' "$*"; }

has_claude=0; has_agy=0; has_copilot=0; has_vscode=0
if command -v code >/dev/null 2>&1 || [ -f "$VSCODE_DIR/settings.json" ]; then has_vscode=1; fi
if command -v claude >/dev/null 2>&1 || [ -f "$HOME/.claude/settings.json" ] || [ -f "$HOME/.claude/CLAUDE.md" ]; then has_claude=1; fi
if command -v agy >/dev/null 2>&1 || command -v gemini >/dev/null 2>&1 || [ -f "$HOME/.gemini/antigravity-cli/settings.json" ] || [ -f "$HOME/.gemini/GEMINI.md" ]; then has_agy=1; fi
if command -v copilot >/dev/null 2>&1 || [ -f "$COPILOT_DIR/settings.json" ] || [ -f "$COPILOT_DIR/copilot-instructions.md" ]; then has_copilot=1; fi

HOOK_ROOT="$(hook_root)"   # what client hooks and the memory repo's core.hooksPath must point to
echo "ai-memory: $ROOT (modules: $MODULES)"
if data_is_separate; then echo "memory:    $DATA"; else echo "memory:    $ROOT (single-repo layout)"; fi
if [ "$HOOK_ROOT" != "$ROOT" ]; then echo "installed: $HOOK_ROOT"; fi

echo "base tools"
for t in git python3; do command -v "$t" >/dev/null 2>&1 && ok "$t" || fail "missing $t"; done
if [ "$has_claude" -eq 0 ] && [ "$has_agy" -eq 0 ] && [ "$has_copilot" -eq 0 ]; then
  warn "none of claude, agy or copilot is installed on this machine"
fi

# =============================================================================================
# MODULE 1: HARDENING
# =============================================================================================
if has_module hardening; then
  echo
  echo "=== Module: hardening ==="
  command -v jq >/dev/null 2>&1 && ok "jq" || warn "missing jq: the status line (tools/statusline.sh) will show no data (tools/install.sh offers to install it)"
  command -v gitleaks >/dev/null 2>&1 && ok "gitleaks $(gitleaks version 2>/dev/null | head -1)" || fail "missing gitleaks (tools/install.sh --yes, or brew install gitleaks); the hook blocks commits without it"

  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    hp="$(git -C "$ROOT" config --get core.hooksPath || true)"
    [ "$hp" = ".githooks" ] && ok "core.hooksPath = .githooks" || fail "core.hooksPath = '${hp:-<empty>}' (run tools/install.sh)"
    [ -x "$ROOT/.githooks/pre-commit" ] && ok "pre-commit executable" || fail ".githooks/pre-commit is not executable"
    if (cd "$ROOT" && python3 "$ROOT/tools/sanitize.py" --all -q >/dev/null 2>&1); then ok "sanitize --all clean (tool)"; else fail "sanitize --all found something in $ROOT (run it to see what)"; fi
  else
    fail "$ROOT is not a git repository"
  fi
  if [ -f "$INSTALL_DIR/tools/guard-bash.py" ]; then
    inst_head="$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || true)"
    inst_ref="origin/main"; git -C "$INSTALL_DIR" rev-parse -q --verify "refs/remotes/$inst_ref" >/dev/null || inst_ref="main"
    inst_tip="$(git -C "$INSTALL_DIR" rev-parse -q --verify "$inst_ref" 2>/dev/null || true)"
    if [ -n "$(git -C "$INSTALL_DIR" status --porcelain 2>/dev/null)" ]; then
      fail "installed copy $INSTALL_DIR has local changes (it is generated: discard them and re-run tools/install.sh)"
    elif [ -n "$inst_tip" ] && [ "$inst_head" != "$inst_tip" ]; then
      warn "installed copy is at ${inst_head:0:7}, $inst_ref is at ${inst_tip:0:7} (re-run tools/install.sh to update)"
    else
      ok "installed copy at ${inst_head:0:7} ($inst_ref, detached worktree)"
    fi
  else
    warn "no installed copy in $INSTALL_DIR: hooks run from this clone, so switching branches changes them (tools/install.sh without --dev)"
  fi
  if data_is_separate; then
    if git -C "$DATA" rev-parse --git-dir >/dev/null 2>&1; then
      hp="$(git -C "$DATA" config --get core.hooksPath || true)"
      [ "$hp" = "$HOOK_ROOT/.githooks" ] && ok "memory repo core.hooksPath -> tool .githooks" || fail "memory repo core.hooksPath = '${hp:-<empty>}' (run tools/install.sh)"
    else
      fail "memory repo $DATA is not a git repository (tools/install.sh --data $DATA)"
    fi
  fi
  [ -f "$LOCAL_DIR/forbidden-terms.txt" ] && ok "$LOCAL_DIR/forbidden-terms.txt" || warn "no forbidden-terms list in $LOCAL_DIR"

  if out="$(python3 -I "$ROOT/tools/test-guard.py" -q 2>&1)"; then
    ok "guard-bash test battery: ${out##*$'\n'}"
  else
    fail "guard-bash test battery failed (python3 -I tools/test-guard.py):"$'\n'"$out"
  fi

  echo "Claude Code (hardening)"
  settings="$HOME/.claude/settings.json"
  if [ "$has_claude" -eq 1 ]; then
    if [ -f "$settings" ]; then
      if python3 - "$settings" "$HOOK_ROOT" <<'PY'
import json, sys
path, root = sys.argv[1:3]
try:
    d = json.load(open(path, encoding="utf-8"))
except Exception as e:
    print(f"  FAIL {path} is not valid JSON: {e}"); sys.exit(1)
ok = True
deny = d.get("permissions", {}).get("deny", [])
if not any(r.startswith("Bash(rm -rf") for r in deny):
    print("  FAIL settings.json has no ai-memory deny rules (tools/install.sh)"); ok = False
hooks = [h for e in d.get("hooks", {}).get("PreToolUse", []) for h in e.get("hooks", [])
         if "# ai-memory" in (h.get("command") or "")]
if not hooks:
    print("  FAIL settings.json has no guard-bash hook (tools/install.sh)"); ok = False
elif root + "/tools/guard-bash.py" not in hooks[0]["command"]:
    print("  FAIL the guard-bash hook points to another path; re-run tools/install.sh"); ok = False
sl = d.get("statusLine") or {}
if root + "/tools/statusline.sh" not in (sl.get("command") or ""):
    print("  FAIL settings.json has no ai-memory statusLine or it points to another path; re-run tools/install.sh"); ok = False
if ok:
    print(f"  OK   claude: policy applied ({len(deny)} deny, {len(d['permissions'].get('ask', []))} ask), guard-bash hook, statusLine")
sys.exit(0 if ok else 1)
PY
      then :; else fails=$((fails+1)); fi
    else
      fail "claude: $settings does not exist (tools/install.sh)"
    fi
  else
    warn "claude not installed (skipped)"
  fi

  echo "Antigravity CLI / Gemini (hardening)"
  agy_settings="$HOME/.gemini/antigravity-cli/settings.json"; agy_hooks="$HOME/.gemini/config/hooks.json"
  if [ "$has_agy" -eq 1 ]; then
    if python3 - "$agy_settings" "$agy_hooks" "$HOOK_ROOT" <<'PY'
import json, sys
settings, hooks_path, root = sys.argv[1:4]
ok = True
try:
    s = json.load(open(settings, encoding="utf-8"))
    deny = s.get("permissions", {}).get("deny", [])
    if "command(sudo rm)" in deny:
        sl = (s.get("statusLine") or {}).get("command", "")
        extra = "statusLine" if root + "/tools/statusline.sh" in sl else "NO statusLine (tools/install.sh)"
        print(f"  OK   agy: policy applied ({len(deny)} deny, {len(s['permissions'].get('ask', []))} ask), {extra}")
    else:
        print("  FAIL agy: antigravity-cli/settings.json has no ai-memory deny rules (tools/install.sh)"); ok = False
except FileNotFoundError:
    print(f"  FAIL agy: {settings} does not exist (tools/install.sh)"); ok = False
except Exception as e:
    print(f"  FAIL agy: {settings} is not valid JSON: {e}"); ok = False
try:
    h = json.load(open(hooks_path, encoding="utf-8"))
    entry = h.get("ai-memory", {})
    cmds = [x.get("command", "") for g in entry.get("PreToolUse", []) for x in g.get("hooks", [])]
    if not cmds:
        print("  FAIL agy: config/hooks.json has no ai-memory key (tools/install.sh)"); ok = False
    elif root + "/tools/guard-bash.py" not in cmds[0]:
        print("  FAIL agy: the ai-memory hook points to another path; re-run tools/install.sh"); ok = False
    else:
        others = [k for k in h if k != "ai-memory"]
        print(f"  OK   agy: guard-bash hook in hooks.json (other hooks kept: {', '.join(others) or 'none'})")
except FileNotFoundError:
    print(f"  FAIL agy: {hooks_path} does not exist (tools/install.sh)"); ok = False
except Exception as e:
    print(f"  FAIL agy: {hooks_path} is not valid JSON: {e}"); ok = False
sys.exit(0 if ok else 1)
PY
    then :; else fails=$((fails+1)); fi
    if echo '{"toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf ~/x"}},"workspacePaths":["/tmp"]}' \
         | python3 -I "$ROOT/tools/guard-bash.py" | grep -q '"deny"'; then
      ok "guard-bash responds in agy format"
    else
      fail "guard-bash does not deny 'rm -rf ~/x' in agy format"
    fi
  else
    warn "agy / gemini not installed (skipped)"
  fi

  echo "GitHub Copilot CLI (hardening)"
  copilot_settings="$COPILOT_DIR/settings.json"
  if [ "$has_copilot" -eq 1 ]; then
    if [ ! -f "$copilot_settings" ]; then
      fail "copilot: $copilot_settings does not exist (tools/install.sh)"
    elif python3 - "$copilot_settings" "$HOOK_ROOT" <<'PY'
import json, sys
path, root = sys.argv[1:3]
try:
    d = json.load(open(path, encoding="utf-8"))
except Exception as e:
    print(f"  FAIL copilot: {path} is not valid JSON: {e}"); sys.exit(1)
ok = True
cmd = (d.get("statusLine") or {}).get("command") or ""
if root + "/tools/statusline.sh" in cmd:
    print("  OK   copilot: statusLine points to tools/statusline.sh")
else:
    print("  FAIL copilot: settings.json has no ai-memory statusLine or it points elsewhere; re-run tools/install.sh"); ok = False
hooks = (d.get("hooks") or {}).get("PreToolUse") or []
mine = [h for h in hooks if isinstance(h, dict) and "# ai-memory" in (h.get("bash") or h.get("command") or "")]
if not mine:
    print("  FAIL copilot: settings.json has no ai-memory PreToolUse hook (tools/install.sh)"); ok = False
elif root + "/tools/guard-bash.py" not in mine[0].get("bash", "") or "--out copilot" not in mine[0].get("bash", ""):
    print("  FAIL copilot: the guard-bash hook points elsewhere or lacks --out copilot; re-run tools/install.sh"); ok = False
else:
    print(f"  OK   copilot: guard-bash PreToolUse hook (timeoutSec {mine[0].get('timeoutSec', 30)})")
if (d.get("sandbox") or {}).get("enabled") is True:
    print("  OK   copilot: command sandbox enabled")
else:
    print("  FAIL copilot: sandbox.enabled is not true (tools/install.sh)"); ok = False
sys.exit(0 if ok else 1)
PY
    then :; else fails=$((fails+1)); fi
    if echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf ~/x"},"cwd":"/tmp"}' \
        | python3 -I "$ROOT/tools/guard-bash.py" --out copilot 2>/dev/null | grep -q '^{"permissionDecision": "deny"'; then
      ok "guard-bash responds in copilot format"
    else
      fail "guard-bash does not deny 'rm -rf ~/x' in copilot format (--out copilot)"
    fi
  else
    warn "copilot not installed (skipped)"
  fi

  echo "VS Code (hardening)"
  vscode_settings="$VSCODE_DIR/settings.json"
  if [ "$has_vscode" -eq 1 ]; then
    if [ ! -f "$vscode_settings" ]; then
      fail "vscode: $vscode_settings does not exist (tools/install.sh)"
    elif python3 - "$vscode_settings" "$ROOT/settings/vscode/settings.json" <<'PY'
import json, sys
path, template = sys.argv[1:3]
try:
    d = json.load(open(path, encoding="utf-8"))
except Exception as e:
    print(f"  FAIL vscode: {path} is not valid JSON: {e}"); sys.exit(1)
want = json.load(open(template, encoding="utf-8"))["github.copilot.enable"]
have = d.get("github.copilot.enable") or {}
missing = [k for k, v in want.items() if v is False and have.get(k) is not False]
if missing:
    print(f"  FAIL vscode: Copilot still enabled for {', '.join(missing)} (tools/install.sh)"); sys.exit(1)
off = sum(1 for v in have.values() if v is False)
print(f"  OK   vscode: built-in Copilot off in {off} file type(s), on elsewhere")
PY
    then :; else fails=$((fails+1)); fi
  else
    warn "VS Code not installed (skipped)"
  fi
fi

# =============================================================================================
# MODULE 2: MEMORY
# =============================================================================================
check_imports() { # file — accepts "@path" (Claude Code) and "@[label](path)" (agy)
  local f="$1" found=0 line p
  [ -f "$f" ] || { fail "$f does not exist"; return; }
  while IFS= read -r line; do
    case "$line" in
      @\[*\]\(*\)) p="${line#*\](}"; p="${p%)}" ;;
      @*) p="${line#@}" ;;
      *) continue ;;
    esac
    found=1; p="${p/#\~/$HOME}"
    case "$p" in /*) ;; *) p="$(dirname "$f")/$p" ;; esac
    [ -f "$p" ] && ok "$f -> ${p#"$HOME"/}" || fail "$f imports a nonexistent file: $p"
  done <"$f"
  [ "$found" -eq 1 ] || fail "$f has no imports"
}

if has_module memory; then
  echo
  echo "=== Module: memory ==="
  if [ ! -d "$DATA" ]; then
    fail "memory repo $DATA does not exist (tools/install.sh --data $DATA creates it)"
  elif git -C "$DATA" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$DATA" check-ignore -q projects/x/memory/x.md && ok "memory/ ignored" || fail "projects/*/memory/ is not ignored in $DATA"
    git -C "$DATA" check-ignore -q global/profile.private.md && ok "profile.private.md ignored" || fail "global/profile.private.md is not ignored in $DATA"
    remote="$(git -C "$DATA" remote get-url origin 2>/dev/null || true)"
    [ -n "$remote" ] && ok "memory remote: ${remote%%:*}…" || warn "memory repo has no remote configured (backup pending)"
    if "$ROOT/tools/check-size.sh" >/dev/null 2>&1; then ok "sizes within limits"; else fail "some file exceeds its limit (tools/check-size.sh)"; fi
    if (cd "$DATA" && python3 "$ROOT/tools/sanitize.py" --all -q >/dev/null 2>&1); then ok "sanitize --all clean (memory)"; else fail "sanitize --all found something in $DATA (run it there to see what)"; fi
  else
    fail "memory repo $DATA is not a git repository"
  fi
  [ -f "$DATA/global/AGENTS.md" ] && ok "global/AGENTS.md" || fail "missing $DATA/global/AGENTS.md (install.sh copies the default)"
  [ -f "$DATA/global/profile.private.md" ] && ok "global/profile.private.md" || fail "missing $DATA/global/profile.private.md (install.sh creates it)"

  echo "Claude Code (memory)"
  if [ "$has_claude" -eq 1 ]; then
    check_imports "$HOME/.claude/CLAUDE.md"
  else
    warn "claude not installed (skipped)"
  fi

  echo "Antigravity CLI / Gemini (memory)"
  if [ "$has_agy" -eq 1 ]; then
    check_imports "$HOME/.gemini/GEMINI.md"
    if grep -qE '^@[^[]' "$HOME/.gemini/GEMINI.md" 2>/dev/null; then
      fail "~/.gemini/GEMINI.md uses '@path' (Claude syntax); agy needs '@[label](path)'. Re-run tools/install.sh"
    fi
  else
    warn "agy / gemini not installed (skipped)"
  fi

  echo "GitHub Copilot CLI (memory)"
  if [ "$has_copilot" -eq 1 ]; then
    copilot_mem="$COPILOT_DIR/copilot-instructions.md"
    if [ -f "$copilot_mem" ] && grep -q "ai-memory" "$copilot_mem" 2>/dev/null; then
      ok "$copilot_mem (ai-memory block present)"
    else
      fail "copilot: $copilot_mem missing or has no ai-memory block (run tools/install.sh)"
    fi
  else
    warn "copilot not installed (skipped)"
  fi
fi

# =============================================================================================
# MODULE 3: PROJECTS
# =============================================================================================
PROJECTS_FILE="${AI_MEMORY_PROJECTS:-$LOCAL_DIR/projects.yml}"; PROJECTS_FILE="${PROJECTS_FILE/#\~/$HOME}"
if has_module projects || [ "${#args_repos[@]}" -gt 0 ]; then
  echo
  echo "=== Module: projects ==="
  [ -f "$PROJECTS_FILE" ] && ok "$PROJECTS_FILE" || warn "no projects registry at $PROJECTS_FILE (install.sh creates it)"

  repos=("${args_repos[@]+"${args_repos[@]}"}")
  if [ "${#repos[@]}" -eq 0 ] && [ -x "$ROOT/tools/projects.sh" ] && [ -f "$PROJECTS_FILE" ]; then
    while IFS= read -r p; do [ -n "$p" ] && repos+=("$p"); done < <("$ROOT/tools/projects.sh" paths)
  fi

  for repo in "${repos[@]+"${repos[@]}"}"; do
    [ -n "$repo" ] || continue
    echo "work repo: $repo"
    if [ -f "$repo/CLAUDE.local.md" ]; then check_imports "$repo/CLAUDE.local.md"; else fail "no CLAUDE.local.md (tools/new-project.sh <name> $repo)"; fi
    if [ -f "$repo/.claude/settings.local.json" ] && grep -q autoMemoryDirectory "$repo/.claude/settings.local.json"; then
      ok "autoMemoryDirectory configured"
    else
      warn "no autoMemoryDirectory: Claude auto-memory will go to the default directory"
    fi
    if [ -f "$repo/.agents/rules/ai-memory.md" ]; then
      check_imports "$repo/.agents/rules/ai-memory.md"
    elif [ -f "$repo/GEMINI.md" ]; then
      check_imports "$repo/GEMINI.md"
    else
      fail "no GEMINI.md or .agents/rules/ai-memory.md for agy (tools/new-project.sh <name> $repo)"
    fi
    copilot_instr="$repo/.github/instructions/ai-memory.instructions.md"
    if [ -f "$copilot_instr" ]; then
      ok "$copilot_instr (copilot instructions ready)"
    else
      fail "no $copilot_instr for copilot (tools/new-project.sh <name> $repo)"
    fi
    if [ -n "$(git -C "$repo" status --porcelain -- CLAUDE.local.md .claude/settings.local.json .claude/skills GEMINI.md .agents/rules/ai-memory.md .agents/skills .github/instructions/ai-memory.instructions.md 2>/dev/null)" ]; then
      fail "personal files visible in the repo's git status (check .git/info/exclude)"
    else
      ok "git status clean of personal files"
    fi
  done
fi

echo
if [ "$fails" -eq 0 ]; then echo "doctor: all good"; else echo "doctor: $fails problem(s)"; exit 1; fi
