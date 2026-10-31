#!/usr/bin/env python3
"""Renders the MCP server catalog of the memory repo into each AI client's own config.

Catalog: <memory repo>/mcp/servers.json
  {"servers": {"<name>": {
      "enabled": true,                                  # optional, default true
      "clients": ["claude", "agy", "copilot", "vscode"],# optional, default all
      "command": "npx", "args": ["-y", "@scope/pkg@1.2.3"], "env": {"API_KEY": "${PKG_API_KEY}"},
      # or, for a remote server:
      "url": "https://host/mcp", "headers": {"Authorization": "Bearer ${PKG_TOKEN}"}, "type": "http"|"sse"
  }}}

Rules enforced (exit 1): secret-looking env/header values must be ${VAR} references, URLs carry no
credentials, names are [A-Za-z0-9_-]. Warned: packages run with npx/uvx/bunx/pnpm dlx without a pinned
version, and ${VAR} references missing from the current environment. Values are never resolved: each
client expands the references itself (VS Code gets ${env:VAR}).

Only entries recorded in the state file (<LOCAL_DIR>/mcp-managed.json) are updated or removed; servers
the user added by hand are left alone, and a catalog name that collides with one of them is skipped.

Targets:
  claude   `claude mcp add-json -s user` / `claude mcp remove -s user` (reads ~/.claude.json to diff)
  agy      ~/.gemini/config/mcp_config.json      {"mcpServers": {...}}  (remote: "serverUrl")
  copilot  $COPILOT_HOME/mcp-config.json         {"mcpServers": {...}}  (type local|http|sse, tools ["*"])
  vscode   <VS Code user dir>/mcp.json           {"servers": {...}}

Usage: render-mcp.py [--dry-run | --check] [--clients claude,agy,copilot,vscode]
                     --catalog PATH --state PATH [--copilot-dir DIR] [--vscode-dir DIR]
  --dry-run  show what would change, write nothing
  --check    validate the catalog and report drift (for doctor.sh); write nothing
Exits 0 if nothing changed (or --check is clean), 3 if something changed / would change / drifted, 1 on error.
"""
import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
CLIENTS = ("claude", "agy", "copilot", "vscode")
NAME_RX = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
REF_RX = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
SECRET_KEY_RX = re.compile(r"(TOKEN|SECRET|PASS|PWD|KEY|AUTH|CRED|COOKIE|SESSION|PRIVATE)", re.I)
RUNNERS = {"npx", "bunx", "uvx", "pnpx"}
problems, warnings = [], []


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
        sys.exit(f"render-mcp: {path} is not valid JSON ({e}); fix it by hand before continuing")


def dump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def tilde(p):
    return "~" + p[len(HOME):] if p.startswith(HOME) else p


# --- catalog validation ---------------------------------------------------------------------------
def check_values(name, field, values):
    for k, v in (values or {}).items():
        if not isinstance(v, str):
            problems.append(f"{name}.{field}.{k}: value must be a string")
            continue
        refs = REF_RX.findall(v)
        if SECRET_KEY_RX.search(k) and not refs:
            problems.append(f"{name}.{field}.{k}: looks secret; write it as a reference, e.g. \"${{{k.upper()}}}\"")
        for var in refs:
            if var not in os.environ:
                warnings.append(f"{name}: ${{{var}}} is not set in this environment")


def check_pinned(name, command, args):
    base = os.path.basename(command or "")
    pkgs = [a for a in args if not a.startswith("-")]
    if base in ("pnpm", "yarn") and pkgs[:1] == ["dlx"]:
        pkgs = pkgs[1:]
    elif base not in RUNNERS:
        return
    if not pkgs:
        return
    pkg = pkgs[0]
    bare = pkg[1:] if pkg.startswith("@") else pkg
    if not re.search(r"(@|==)\d", bare):
        warnings.append(f"{name}: '{pkg}' is not pinned to a version (use {pkg}@<x.y.z>)")


def load_catalog(path):
    data = load(path)
    servers = data.get("servers", {}) if isinstance(data, dict) else {}
    if not isinstance(servers, dict):
        sys.exit(f"render-mcp: {path}: 'servers' must be an object")
    wanted = {}
    for name, s in servers.items():
        if not NAME_RX.match(name):
            problems.append(f"{name!r}: invalid name (letters, digits, - and _)")
            continue
        if not isinstance(s, dict) or s.get("enabled", True) is False:
            continue
        clients = s.get("clients", list(CLIENTS))
        bad = [c for c in clients if c not in CLIENTS]
        if bad:
            problems.append(f"{name}: unknown client(s) {', '.join(bad)}")
        if bool(s.get("command")) == bool(s.get("url")):
            problems.append(f"{name}: give exactly one of 'command' or 'url'")
            continue
        if s.get("url"):
            netloc = re.sub(r"^[a-z]+://", "", s["url"]).split("/", 1)[0]
            if "@" in netloc or re.search(r"[?&](token|key|secret|auth)[^=]*=(?!\$\{)", s["url"], re.I):
                problems.append(f"{name}: the url carries credentials; move them to a header with ${{VAR}}")
            check_values(name, "headers", s.get("headers"))
        else:
            args = s.get("args", [])
            if not all(isinstance(a, str) for a in args):
                problems.append(f"{name}: args must be strings")
                continue
            check_pinned(name, s["command"], args)
            check_values(name, "env", s.get("env"))
        wanted[name] = s
    return wanted


# --- per-client shapes ----------------------------------------------------------------------------
def to_vscode_refs(obj):
    return json.loads(REF_RX.sub(r"${env:\1}", json.dumps(obj)))


def shape(client, s):
    remote = bool(s.get("url"))
    kind = s.get("type", "http") if remote else "stdio"
    if client in ("claude", "vscode"):
        out = {"type": kind}
        out.update({"url": s["url"]} if remote else {"command": s["command"], "args": s.get("args", [])})
        extra = s.get("headers") if remote else s.get("env")
        if extra:
            out["headers" if remote else "env"] = extra
        return to_vscode_refs(out) if client == "vscode" else out
    if client == "copilot":
        out = {"type": kind if remote else "local", "tools": s.get("tools", ["*"])}
        out.update({"url": s["url"]} if remote else {"command": s["command"], "args": s.get("args", [])})
        extra = s.get("headers") if remote else s.get("env")
        if extra:
            out["headers" if remote else "env"] = extra
        return out
    if client == "agy":
        out = {"serverUrl": s["url"]} if remote else {"command": s["command"], "args": s.get("args", [])}
        extra = s.get("headers") if remote else s.get("env")
        if extra:
            out["headers" if remote else "env"] = extra
        return out
    raise ValueError(client)


# --- apply ----------------------------------------------------------------------------------------
def plan(current, desired, managed):
    """current/desired: {name: cfg}. Returns (new_current, adds_or_updates, removals, skipped)."""
    out, changed, removed, skipped = dict(current), [], [], []
    for name, cfg in desired.items():
        if name in current and name not in managed:
            skipped.append(name)
            continue
        if current.get(name) != cfg:
            out[name] = cfg
            changed.append(name)
    for name in managed:
        if name not in desired and name in out:
            del out[name]
            removed.append(name)
    return out, changed, removed, skipped


def json_target(path, key, desired, managed, mode):
    doc = load(path)
    current = doc.get(key) if isinstance(doc.get(key), dict) else {}
    new, changed, removed, skipped = plan(current, desired, managed)
    for n in skipped:
        warnings.append(f"{tilde(path)}: '{n}' already exists and is not managed by ai-memory; skipped")
    owned = sorted(n for n in desired if n not in skipped)
    if not changed and not removed:
        print(f"  ok   {tilde(path)} (no changes)")
        return False, owned
    after = dict(doc)
    after[key] = new
    before = dump(doc) if doc else ""
    for line in difflib.unified_diff(before.splitlines(), dump(after).splitlines(),
                                     fromfile=tilde(path), tofile=tilde(path) + " (new)", lineterm=""):
        print("  " + line)
    if mode == "write":
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.exists(path):
            bak = f"{path}.bak.{time.strftime('%Y%m%d%H%M%S')}"
            shutil.copy2(path, bak)
            print(f"  backup: {tilde(bak)}")
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(dump(after))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        print(f"  write {tilde(path)}")
    return True, owned


def claude_target(desired, managed, mode):
    current = load(os.path.join(HOME, ".claude.json")).get("mcpServers") or {}
    _, changed, removed, skipped = plan(current, desired, managed)
    for n in skipped:
        warnings.append(f"claude: '{n}' already exists in user scope and is not managed by ai-memory; skipped")
    owned = sorted(n for n in desired if n not in skipped)
    if not changed and not removed:
        print("  ok   claude user scope (no changes)")
        return False, owned
    for n in changed:
        print(f"  {'update' if n in current else 'add'} claude mcp {n}")
    for n in removed:
        print(f"  remove claude mcp {n}")
    if mode == "write":
        if not shutil.which("claude"):
            problems.append("claude: CLI not found in PATH; cannot register servers")
            return True, sorted(managed)
        for n in changed + removed:
            if n in current:
                subprocess.run(["claude", "mcp", "remove", "-s", "user", n], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for n in changed:
            r = subprocess.run(["claude", "mcp", "add-json", "-s", "user", n, json.dumps(desired[n])],
                               capture_output=True, text=True)
            if r.returncode != 0:
                problems.append(f"claude: add-json {n} failed: {(r.stderr or r.stdout).strip()[:200]}")
    return True, owned


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--clients", default=",".join(CLIENTS))
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--copilot-dir", default=os.environ.get("COPILOT_HOME", os.path.join(HOME, ".copilot")))
    ap.add_argument("--vscode-dir", default="")
    ap.add_argument("-h", "--help", action="store_true")
    a = ap.parse_args(argv)
    if a.help:
        print(__doc__)
        return 0
    mode = "check" if a.check else "dry" if a.dry_run else "write"
    clients = [c for c in a.clients.split(",") if c]
    for c in clients:
        if c not in CLIENTS:
            sys.exit(f"render-mcp: unknown client '{c}'")

    wanted = load_catalog(a.catalog) if os.path.exists(a.catalog) else {}
    if not os.path.exists(a.catalog):
        print(f"  ok   no catalog at {tilde(a.catalog)} (nothing to render)")
    if problems:
        for p in problems:
            print(f"  FAIL {p}")
        return 1

    state = load(a.state)
    if os.path.exists(a.catalog) and not wanted and not any(state.get(c) for c in clients):
        print(f"  ok   {tilde(a.catalog)}: no enabled servers")
    targets = {
        "agy": (os.path.join(HOME, ".gemini", "config", "mcp_config.json"), "mcpServers"),
        "copilot": (os.path.join(a.copilot_dir, "mcp-config.json"), "mcpServers"),
        "vscode": (os.path.join(a.vscode_dir, "mcp.json"), "servers") if a.vscode_dir else None,
    }
    any_change = False
    for c in clients:
        desired = {n: shape(c, s) for n, s in wanted.items() if c in s.get("clients", CLIENTS)}
        managed = set(state.get(c, []))
        if not desired and not managed:
            continue
        print(f"  {c}:")
        sub = "dry" if mode == "check" else mode
        if c == "claude":
            changed, owned = claude_target(desired, managed, sub)
        elif targets.get(c):
            path, key = targets[c]
            changed, owned = json_target(path, key, desired, managed, sub)
        else:
            continue
        any_change |= changed
        if mode == "write":
            state[c] = owned

    if mode == "write" and state != load(a.state):
        os.makedirs(os.path.dirname(a.state), exist_ok=True)
        with open(a.state, "w", encoding="utf-8") as fh:
            fh.write(dump(state))
    for w in warnings:
        print(f"  WARN {w}")
    for p in problems:
        print(f"  FAIL {p}")
    if problems:
        return 1
    if mode == "check" and any_change:
        print("  WARN clients drift from the catalog (tools/install.sh --module mcp)")
    return 3 if any_change else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
