#!/usr/bin/env python3
"""Test battery for tools/guard-bash.py.

Runs the guard exactly as the hook does (subprocess, JSON on stdin) and compares the decision
with the expected one. Cases live in tools/guard-cases.tsv, one per line:

    <expected><TAB><command>        expected = none | ask | deny

Lines starting with # are comments. Keep one case per rule plus the everyday commands that must
stay silent, and rerun after every change to the guard.

Usage: python3 -I tools/test-guard.py [-q] [--guard PATH] [--cases PATH]
Exit 0 if every case passes, 1 otherwise.
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CWD = "/srv/proj"


def run_guard(guard, command):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}, "cwd": CWD})
    proc = subprocess.run([sys.executable, "-I", guard], input=payload, capture_output=True, text=True)
    if proc.returncode != 0:
        return "error", proc.stderr.strip().splitlines()[-1:] or ["exit %d" % proc.returncode]
    if not proc.stdout.strip():
        return "none", ""
    try:
        out = json.loads(proc.stdout)["hookSpecificOutput"]
    except (ValueError, KeyError):
        return "error", "bad output: " + proc.stdout.strip()[:120]
    return out["permissionDecision"], out.get("permissionDecisionReason", "")


def load_cases(path):
    cases = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            expected, _, command = line.partition("\t")
            if expected not in ("none", "ask", "deny") or not command:
                sys.exit(f"{path}:{n}: expected 'none|ask|deny<TAB>command', got: {line!r}")
            cases.append((n, expected, command))
    return cases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--guard", default=os.path.join(HERE, "guard-bash.py"))
    ap.add_argument("--cases", default=os.path.join(HERE, "guard-cases.tsv"))
    args = ap.parse_args()

    failed = 0
    cases = load_cases(args.cases)
    for n, expected, command in cases:
        got, reason = run_guard(args.guard, command)
        ok = got == expected
        failed += not ok
        if not ok or not args.quiet:
            mark = "ok  " if ok else "FAIL"
            print(f"{mark} line {n}: {command}\n      expected {expected}, got {got} {reason}")
    print(f"{len(cases) - failed}/{len(cases)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
