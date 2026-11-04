#!/usr/bin/env python3
"""Merges the client policy into the machine's real config file.

Two sources, combined before touching the target:
  FLOOR  ai-memory/policy/<client>/...json: the security baseline shipped with the tool
         (deny/ask rules, guard-bash hooks, sandbox). It can never be weakened.
  PREFS  <data>/settings/<client>/settings.json: the user's preferences (defaultMode, statusLine,
         attribution, extra deny/ask...). Optional; it adds to the floor and can drop floor rules
         only explicitly, through its `floorRemove` key (see below).
Combination: lists are united (floor first, extras appended); on any other conflict the floor
wins; `hooks` come from the floor only (put your own hooks in the client's file directly).

Floor overrides: PREFS may hold `floorRemove`, shaped like the floor. A list removes those items
from the floor's list; `null` removes that key entirely (also from the target, if it still holds
the floor's value). `hooks` cannot be removed. Each removal is printed; `floorRemove` itself is
never written to the target.

Merge into the target (Claude Code, Antigravity CLI, Copilot CLI or VS Code settings.json):
  - keys whose value is a dict (e.g. `permissions`): merged one level deep; the combined subkeys
    (deny, ask...) replace the target's and the rest (allow, defaultMode...) are kept.
  - `hooks`: for each event, managed entries are removed and the combined ones are added; user
    hooks are kept. An entry is managed when `# ai-memory` appears in its command: Claude Code
    format (`{"matcher", "hooks": [{"command"}]}`) or Copilot CLI format (flat `{"bash"|"command"|"args"}`).
  - any other key replaces the target's.

--replace-keys mode (Antigravity CLI hooks.json): each top-level key replaces the same-named key
in the target; the rest of the file (e.g. the `cmux` key) is left untouched.

--check mode: makes no change; exits 1 and lists what is missing if the target does not contain
the floor (every list item present, every other value equal; `hooks` are checked by doctor.sh).

Substitutions in both sources: {{AI_MEMORY_ROOT}} -> tool repo, {{AI_MEMORY_DATA}} -> memory repo
(--data, default the tool repo), {{HOME}} -> user's home.

--check mode with PREFS: checks against the floor minus PREFS' `floorRemove`.

Usage: merge-settings.py [--dry-run] [--replace-keys] [--data DIR] FLOOR [PREFS] TARGET REPO_ROOT
       merge-settings.py --check [--data DIR] FLOOR [PREFS] TARGET REPO_ROOT
Exits 0 if nothing changed, 3 if it did (or would with --dry-run), 1 on error or failed check.
"""
import difflib
import json
import os
import sys
import time

MARKER = "# ai-memory"
REMOVE_KEY = "floorRemove"


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


def combine(floor, prefs, path=""):
    """Floor plus preferences: lists united, floor wins elsewhere; hooks only from the floor."""
    if isinstance(floor, dict) and isinstance(prefs, dict):
        out = {k: v for k, v in prefs.items() if not (path == "" and k == "hooks")}
        for key, value in floor.items():
            out[key] = combine(value, prefs[key], f"{path}.{key}") if key in prefs and key != "hooks" else value
        return out
    if isinstance(floor, list) and isinstance(prefs, list):
        return floor + [x for x in prefs if x not in floor]
    return floor


def apply_removals(floor, removals):
    """Floor minus `floorRemove`. Returns (reduced floor, removed descriptions, warnings, dropped).

    dropped holds (key path, floor value) for keys removed with `null`, so they can be dropped
    from the target too."""
    removed, warnings, dropped = [], [], []

    def walk(fl, rm, keys):
        if not isinstance(rm, dict):
            warnings.append(f"{REMOVE_KEY}{'.' if keys else ''}{'.'.join(keys)} must be an object; ignored")
            return fl
        out = dict(fl)
        for key, spec in rm.items():
            here = keys + (key,)
            name = ".".join(here)
            if not keys and key == "hooks":
                warnings.append(f"{REMOVE_KEY}.hooks ignored: the guard-bash hooks cannot be removed")
            elif key not in out:
                warnings.append(f"{REMOVE_KEY}.{name}: not in the floor; ignored")
            elif spec is None:
                dropped.append((here, out.pop(key)))
                removed.append(f"{name} (whole key)")
            elif isinstance(spec, list):
                if not isinstance(out[key], list):
                    warnings.append(f"{REMOVE_KEY}.{name}: the floor value is not a list; ignored")
                    continue
                for item in spec:
                    if item in out[key]:
                        removed.append(f"{name} {item!r}")
                    else:
                        warnings.append(f"{REMOVE_KEY}.{name}: {item!r} not in the floor; ignored")
                out[key] = [x for x in out[key] if x not in spec]
            elif isinstance(spec, dict) and isinstance(out[key], dict):
                out[key] = walk(out[key], spec, here)
            else:
                warnings.append(f"{REMOVE_KEY}.{name}: use a list of items, an object or null; ignored")
        return out

    reduced = floor if removals is None else walk(floor, removals, ())
    return reduced, removed, warnings, dropped


def drop_keys(target, dropped):
    """Removes keys dropped from the floor from the target while they still hold the floor's value."""
    out = json.loads(json.dumps(target))
    for keys, value in dropped:
        node = out
        for k in keys[:-1]:
            node = node.get(k) if isinstance(node, dict) else None
        if isinstance(node, dict) and node.get(keys[-1]) == value:
            del node[keys[-1]]
    return out


def missing_floor(floor, target, path=""):
    """Items of the floor absent from the target (hooks excluded)."""
    if isinstance(floor, dict):
        if not isinstance(target, dict):
            return [f"{path or '/'}: expected an object"]
        out = []
        for key, value in floor.items():
            if path == "" and key == "hooks":
                continue
            if key not in target:
                out.append(f"{path}.{key}: missing")
            else:
                out += missing_floor(value, target[key], f"{path}.{key}")
        return out
    if isinstance(floor, list):
        have = target if isinstance(target, list) else []
        return [f"{path}: missing {x!r}" for x in floor if x not in have]
    return [] if floor == target else [f"{path}: {target!r}, expected {floor!r}"]


def read_template(path, subs):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    for k, v in subs.items():
        text = text.replace(k, v)
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        sys.exit(f"merge-settings: {path} is not valid JSON ({e})")


def dump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def main(argv):
    flags = {"--dry-run", "--replace-keys", "--check"}
    args, data = [], None
    it = iter(argv)
    for a in it:
        if a == "--data":
            data = next(it, None)
        elif a.startswith("--data="):
            data = a.split("=", 1)[1]
        elif a in flags:
            pass
        elif a.startswith("--"):
            sys.exit(f"merge-settings: unknown flag {a}\n{__doc__}")
        else:
            args.append(a)
    dry, replace_keys, check = "--dry-run" in argv, "--replace-keys" in argv, "--check" in argv
    if len(args) == 3:
        floor_path, prefs_path, target_path, root = args[0], None, args[1], args[2]
    elif len(args) == 4:
        floor_path, prefs_path, target_path, root = args
    else:
        sys.exit(__doc__)
    subs = {"{{AI_MEMORY_ROOT}}": root, "{{AI_MEMORY_DATA}}": data or root, "{{HOME}}": os.path.expanduser("~")}

    floor = read_template(floor_path, subs)
    target = load(target_path)
    prefs = read_template(prefs_path, subs) if prefs_path and os.path.exists(prefs_path) else {}
    if not isinstance(prefs, dict):
        sys.exit(f"merge-settings: {prefs_path} must hold a JSON object")
    floor, removed, warnings, dropped = apply_removals(floor, prefs.pop(REMOVE_KEY, None))
    for w in warnings:
        print(f"  warning: {w} ({prefs_path})")
    for r in removed:
        print(f"  floor override: removed {r} ({prefs_path})")
    if check:
        missing = missing_floor(floor, target)
        for m in missing:
            print(f"  missing from {target_path}: {m.lstrip('.')}")
        return 1 if missing else 0

    if isinstance(prefs.get("hooks"), dict) and prefs["hooks"]:
        print(f"  warning: {prefs_path} defines hooks; ignored (hooks come from the policy floor only)")
    merged = merge(drop_keys(target, dropped), combine(floor, prefs), replace_keys)

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
