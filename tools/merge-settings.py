#!/usr/bin/env python3
"""Merges a versioned JSON template into the machine's real config file.

Normal mode (Claude Code or Antigravity CLI settings.json):
  - keys whose value is a dict (e.g. `permissions`): merged one level deep; the template's
    subkeys (deny, ask...) replace the target's and the rest (allow, defaultMode...) are kept.
  - `hooks`: for each event, managed entries are removed and the template's are added; user hooks
    are kept. An entry is managed when `# ai-memory` appears in its command: Claude Code format
    (`{"matcher", "hooks": [{"command"}]}`) or Copilot CLI format (flat `{"bash"|"command"|"args"}`).
  - any other template key replaces the target's.

--replace-keys mode (Antigravity CLI hooks.json): each top-level template key replaces the
same-named key in the target; the rest of the file (e.g. the `cmux` key) is left untouched.

Template substitutions: {{AI_MEMORY_ROOT}} -> repo root, {{HOME}} -> user's home.

Usage: merge-settings.py [--dry-run] [--replace-keys] TEMPLATE TARGET REPO_ROOT
Exits 0 if nothing changed, 3 if it did (or would with --dry-run), 1 on error.
"""
import difflib
import json
import os
import sys
import time

MARKER = "# ai-memory"


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as fh:
        text = fh.read().strip()
    if not text:
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        sys.exit(f"merge-settings: {path} is not valid JSON ({e}); fix it by hand before continuing")


def is_managed(entry):
    # Claude Code: {"matcher": ..., "hooks": [{"command": ...}]}
    if any(MARKER in (h.get("command") or "") for h in entry.get("hooks", []) if isinstance(h, dict)):
        return True
    # Copilot CLI: flat {"type": "command", "bash": ...} or {"exec": ..., "args": [...]}
    texts = [entry.get(k) or "" for k in ("bash", "powershell", "command")]
    texts += [a for a in entry.get("args", []) if isinstance(a, str)]
    return any(MARKER in t for t in texts)


def merge(target, template, replace_keys=False):
    out = json.loads(json.dumps(target))  # deep copy
    for key, value in template.items():
        if replace_keys:
            out[key] = value
        elif key == "hooks" and isinstance(value, dict):
            hooks = out.get("hooks") if isinstance(out.get("hooks"), dict) else {}
            for event, entries in value.items():
                kept = [e for e in hooks.get(event, []) if isinstance(e, dict) and not is_managed(e)]
                hooks[event] = kept + entries
            out["hooks"] = hooks
        elif isinstance(value, dict) and isinstance(out.get(key), dict):
            merged = dict(out[key])
            merged.update(value)
            out[key] = merged
        else:
            out[key] = value
    return out


def dump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def main(argv):
    dry = "--dry-run" in argv
    replace_keys = "--replace-keys" in argv
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 3:
        sys.exit(__doc__)
    template_path, target_path, root = args

    with open(template_path, encoding="utf-8") as fh:
        text = fh.read().replace("{{AI_MEMORY_ROOT}}", root).replace("{{HOME}}", os.path.expanduser("~"))
    template = json.loads(text)
    target = load(target_path)
    merged = merge(target, template, replace_keys)

    before, after = dump(target) if target else "", dump(merged)
    if before == after:
        print(f"  ok   {target_path} (no changes)")
        return 0

    diff = difflib.unified_diff(before.splitlines(), after.splitlines(),
                                fromfile=target_path, tofile=target_path + " (new)", lineterm="")
    for line in diff:
        print("  " + line)
    if dry:
        return 3

    os.makedirs(os.path.dirname(target_path) or ".", exist_ok=True)
    if os.path.exists(target_path):
        bak = f"{target_path}.bak.{time.strftime('%Y%m%d%H%M%S')}"
        os.replace(target_path, bak)
        print(f"  backup: {bak}")
    with open(target_path, "w", encoding="utf-8") as fh:
        fh.write(after)
    print(f"  writes {target_path}")
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
