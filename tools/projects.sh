#!/usr/bin/env bash
# Tracks and syncs projects across arbitrary sections defined in an external YAML file.
# Default file: $CAIRN_PROJECTS or $CAIRN_LOCAL/projects.yml (~/.config/cairn/projects.yml).
# Default encrypted backup path: $CAIRN_PROJECTS_ENC (or passed as argument).
#
# Usage:
#   projects.sh [list] [--section <sec>] [--status <st>] [--file <yml>]
#   projects.sh sync   [--section <sec>] [--dry-run]     [--file <yml>]
#   projects.sh paths  [--section <sec>]                 [--file <yml>]
#   projects.sh encrypt [dest-file]                      [--file <yml>]
#   projects.sh decrypt [src-file]                       [--file <yml>]
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJECTS_FILE="${CAIRN_PROJECTS:-$LOCAL_DIR/projects.yml}"
ENC_FILE="${CAIRN_PROJECTS_ENC:-}"

cmd="list"
section=""
status_filter=""
dry_run=0
pos_arg=""

while [ $# -gt 0 ]; do
  case "$1" in
    list|sync|paths|encrypt|decrypt) cmd="$1"; shift ;;
    -s|--section) section="${2:-}"; shift 2 ;;
    --status)     status_filter="${2:-}"; shift 2 ;;
    -f|--file)    PROJECTS_FILE="${2:-}"; shift 2 ;;
    --dry-run)    dry_run=1; shift ;;
    -h|--help)    sed -n '2,11p' "$0"; exit 0 ;;
    -*)           echo "projects: unknown option: $1" >&2; exit 2 ;;
    *)            pos_arg="$1"; shift ;;
  esac
done
PROJECTS_FILE="${PROJECTS_FILE/#\~/$HOME}"

parse_projects() {
  python3 - "$PROJECTS_FILE" "$section" "$status_filter" <<'PY'
import os, sys

path, sec_filter, st_filter = sys.argv[1:4]
if not os.path.isfile(path):
    sys.exit(0)

def parse_simple_yaml(lines):
    data = {}
    cur_sec = None
    cur_proj = None
    for raw in lines:
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip()
        if ":" not in stripped:
            continue
        k, v = [x.strip() for x in stripped.split(":", 1)]
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
            v = v[1:-1]
        if indent == 0:
            cur_sec = k
            data.setdefault(cur_sec, {})
            cur_proj = None
        elif indent == 2 and cur_sec is not None:
            cur_proj = k
            data[cur_sec].setdefault(cur_proj, {})
        elif indent >= 4 and cur_sec is not None and cur_proj is not None:
            data[cur_sec][cur_proj][k] = v
    return data

with open(path, encoding="utf-8") as fh:
    text = fh.read()

try:
    import yaml  # type: ignore
    raw_data = yaml.safe_load(text) or {}
except Exception:
    raw_data = parse_simple_yaml(text.splitlines())

if not isinstance(raw_data, dict):
    sys.exit(0)

for sec, projs in raw_data.items():
    if sec_filter and str(sec) != sec_filter:
        continue
    if not isinstance(projs, dict):
        continue
    for name, cfg in projs.items():
        if not isinstance(cfg, dict):
            cfg = {}
        st = str(cfg.get("status", "active")).strip() or "active"
        if st_filter and st != st_filter:
            continue
        p = str(cfg.get("path", "")).strip()
        p_exp = os.path.expanduser(p) if p else ""
        agents = "1" if str(cfg.get("agents", "")).lower() in ("true", "1", "yes") else "0"
        # memory: false -> registered repo without cairn bridges or project memory (default true)
        memory = "0" if str(cfg.get("memory", "true")).lower() in ("false", "0", "no") else "1"
        # kind: workspace -> a plain folder holding several repos; one memory for the whole folder
        kind = "workspace" if str(cfg.get("kind", "")).strip().lower() == "workspace" else "repo"
        notes = str(cfg.get("notes", "")).replace("\t", " ").strip()
        print(f"{sec}\t{name}\t{st}\t{p}\t{p_exp}\t{agents}\t{memory}\t{kind}\t{notes}")
PY
}

case "$cmd" in
  list)
    if [ ! -f "$PROJECTS_FILE" ]; then
      echo "projects: $PROJECTS_FILE does not exist (run tools/install.sh or set CAIRN_PROJECTS)" >&2
      exit 1
    fi
    printf '%-12s %-18s %-9s %-12s %-8s %s\n' "SECTION" "PROJECT" "STATUS" "REPO" "MEMORY" "PATH / NOTES"
    printf '%-12s %-18s %-9s %-12s %-8s %s\n' "-------" "-------" "------" "----" "------" "------------"
    found=0
    while IFS=$'\t' read -r sec name st p p_exp agents mem kind notes; do
      [ -n "$name" ] || continue
      found=1
      if [ -z "$p_exp" ]; then
        repo_st="no-path"
      elif [ ! -d "$p_exp" ]; then
        repo_st="missing"
      elif [ "$kind" = "workspace" ]; then
        repo_st="workspace"
      elif ! git -C "$p_exp" rev-parse --git-dir >/dev/null 2>&1; then
        repo_st="not-git"
      elif [ -n "$(git -C "$p_exp" status --porcelain 2>/dev/null)" ]; then
        repo_st="dirty"
      else
        repo_st="clean"
      fi
      pdir="$PM_DIR/$name"
      if [ "$mem" = "0" ]; then
        mem_st="off"
      elif [ ! -d "$pdir" ]; then
        mem_st="none"
      else
        pend="$(find "$pdir/memory" -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')"
        [ "$pend" -gt 0 ] && mem_st="pend:$pend" || mem_st="ok"
      fi
      tail_info="${p:-}"
      [ -n "$notes" ] && tail_info="${tail_info:+$tail_info — }$notes"
      printf '%-12s %-18s %-9s %-12s %-8s %s\n' "$sec" "$name" "$st" "$repo_st" "$mem_st" "$tail_info"
    done < <(parse_projects)
    [ "$found" -eq 1 ] || echo "(no projects matched in $PROJECTS_FILE)"
    ;;

  paths)
    status_filter="${status_filter:-active}"
    while IFS=$'\t' read -r sec name st p p_exp agents mem kind notes; do
      [ "$mem" = "1" ] && [ -n "$p_exp" ] && [ -d "$p_exp" ] && printf '%s\n' "$p_exp"
    done < <(parse_projects)
    ;;

  sync)
    if [ ! -f "$PROJECTS_FILE" ]; then
      echo "projects: $PROJECTS_FILE does not exist" >&2
      exit 1
    fi
    status_filter="${status_filter:-active}"
    while IFS=$'\t' read -r sec name st p p_exp agents mem kind notes; do
      [ -n "$name" ] || continue
      if [ "$mem" = "0" ]; then
        echo "[$sec/$name] memory: false (skipped)"
        continue
      fi
      echo "[$sec/$name]"
      args=("$name")
      if [ -n "$p_exp" ] && [ -d "$p_exp" ]; then
        args+=("$p_exp")
      elif [ -n "$p" ]; then
        echo "  note: local path $p not found on this machine; syncing memory dir only"
      fi
      [ "$agents" = "1" ] && args+=(--agents)
      [ "$kind" = "workspace" ] && args+=(--workspace)
      [ "$dry_run" -eq 1 ] && args+=(--dry-run)
      "$ROOT/tools/new-project.sh" "${args[@]}"
    done < <(parse_projects)
    ;;

  encrypt)
    dest="${pos_arg:-$ENC_FILE}"
    [ -n "$dest" ] || { echo "usage: projects.sh encrypt <dest-file> (or set CAIRN_PROJECTS_ENC)" >&2; exit 2; }
    dest="${dest/#\~/$HOME}"
    [ -f "$PROJECTS_FILE" ] || { echo "projects: source $PROJECTS_FILE does not exist" >&2; exit 1; }
    mkdir -p "$(dirname "$dest")"
    if command -v age >/dev/null 2>&1; then
      if [ -n "${AGE_RECIPIENT:-}" ]; then
        age -r "$AGE_RECIPIENT" -o "$dest" "$PROJECTS_FILE"
      elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        age -R "$HOME/.ssh/id_ed25519.pub" -o "$dest" "$PROJECTS_FILE"
      else
        age -p -o "$dest" "$PROJECTS_FILE"
      fi
      echo "encrypted -> $dest (age)"
    elif command -v gpg >/dev/null 2>&1; then
      gpg --yes --symmetric --cipher-algo AES256 -o "$dest" "$PROJECTS_FILE"
      echo "encrypted -> $dest (gpg)"
    else
      echo "projects: install 'age' (brew install age) or 'gpg' to encrypt" >&2
      exit 1
    fi
    ;;

  decrypt)
    src="${pos_arg:-$ENC_FILE}"
    [ -n "$src" ] || { echo "usage: projects.sh decrypt <src-file> (or set CAIRN_PROJECTS_ENC)" >&2; exit 2; }
    src="${src/#\~/$HOME}"
    [ -f "$src" ] || { echo "projects: encrypted file $src does not exist" >&2; exit 1; }
    mkdir -p "$(dirname "$PROJECTS_FILE")"
    if command -v age >/dev/null 2>&1; then
      if [ -n "${AGE_IDENTITY:-}" ]; then
        age -d -i "$AGE_IDENTITY" -o "$PROJECTS_FILE" "$src"
      elif [ -f "$HOME/.ssh/id_ed25519" ]; then
        age -d -i "$HOME/.ssh/id_ed25519" -o "$PROJECTS_FILE" "$src"
      else
        age -d -o "$PROJECTS_FILE" "$src"
      fi
      echo "decrypted -> $PROJECTS_FILE (age)"
    elif command -v gpg >/dev/null 2>&1; then
      gpg --yes -d -o "$PROJECTS_FILE" "$src"
      echo "decrypted -> $PROJECTS_FILE (gpg)"
    else
      echo "projects: install 'age' (brew install age) or 'gpg' to decrypt" >&2
      exit 1
    fi
    ;;
esac
