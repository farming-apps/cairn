#!/usr/bin/env bash
# Layout 1 -> 2: project-memories/<p>/pending/ becomes projects/<p>/memory/.
# Usage: 002-projects-memory.sh <memory-repo>
# Idempotent; never stages or commits. Afterwards: git -C <memory-repo> add -A && git commit.
# Work repos still point at the old paths until `tools/projects.sh sync` (or new-project.sh) rewrites
# their CLAUDE.local.md, GEMINI.md and autoMemoryDirectory.
set -euo pipefail

data="${1:?usage: 002-projects-memory.sh <memory-repo>}"
cd "$data"
say() { printf '  %s\n' "$*"; }

# 1. project-memories/ -> projects/
if [ -d project-memories ]; then
  mkdir -p projects
  for src in project-memories/* project-memories/.[!.]*; do
    [ -e "$src" ] || continue
    dst="projects/${src#project-memories/}"
    if [ -e "$dst" ]; then
      echo "002: both $src and $dst exist; merge them by hand and re-run" >&2
      exit 1
    fi
    mv "$src" "$dst"
  done
  rmdir project-memories
  say "moved project-memories/ -> projects/"
fi

# 2. projects/<p>/pending/ -> projects/<p>/memory/ (auto-memory written by the clients, git-ignored)
for p in projects/*/; do
  p="${p%/}"
  [ -d "$p/pending" ] || continue
  if [ -d "$p/memory" ]; then
    for f in "$p/pending"/* "$p/pending"/.[!.]*; do
      [ -e "$f" ] || continue
      if [ -e "$p/memory/${f##*/}" ]; then
        [ "${f##*/}" = .gitkeep ] && { rm -f "$f"; continue; }
        echo "002: $f also exists in $p/memory/; merge it by hand and re-run" >&2
        exit 1
      fi
      mv "$f" "$p/memory/"
    done
    rmdir "$p/pending"
  else
    mv "$p/pending" "$p/memory"
  fi
  say "moved $p/pending/ -> $p/memory/"
done

# 3. Text that names the old paths: ignore rules, the README tree, the global rule about proposals.
python3 -I - <<'PY'
import os, re

def edit(path, fn):
    if not os.path.exists(path):
        return
    old = open(path, encoding="utf-8").read()
    new = fn(old)
    if new != old:
        open(path, "w", encoding="utf-8").write(new)
        print(f"  updated {path}")

def gitignore(text):
    text = text.replace("project-memories/*/pending/", "projects/*/memory/")
    lines = text.splitlines()
    for rule in ("projects/*/memory/*", "!projects/*/memory/.gitkeep"):
        if rule not in lines:
            lines.append(rule)
    return "\n".join(lines) + "\n"

def paths(text):
    text = text.replace("project-memories", "projects")
    return re.sub(r"(?<![\w-])pending/", "memory/", text)

edit(".gitignore", gitignore)
edit("README.md", paths)
edit("global/AGENTS.md", lambda t: t.replace("the project's `pending/`", "the project's `memory/`"))
PY

printf '2\n' >.ai-memory-layout
say "layout 2 written to .ai-memory-layout"
