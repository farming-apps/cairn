#!/usr/bin/env python3
"""Last safety net before something sensitive reaches Git or the memory.

Looks for secrets in known formats, high-entropy strings, PII (emails, private IPs),
absolute home paths and per-machine forbidden terms. Never redacts silently: it lists the
findings and exits with code 1 so you decide.

Usage:
  sanitize.py [--check] PATH...   scan files or directories
  sanitize.py --staged            scan the *staged* content (git index), not the disk
  sanitize.py --all               scan every tracked file

Exceptions:
  - a line containing the marker  sanitize:allow  is skipped
  - files in EXCLUDED_PATHS contain patterns on purpose and are skipped
  - forbidden terms (client names, internal domains): one term per line in
    $AI_MEMORY_LOCAL/forbidden-terms.txt (default ~/.config/ai-memory). That list is
    sensitive: it lives outside the repository.

Standard library only (Python 3.9+). detect-secrets or gitleaks remain the main barrier in
the hook; this covers what they do not look at (PII, paths, custom terms).
"""
import argparse
import math
import os
import re
import subprocess
import sys

MARKER = "sanitize:allow"
EXCLUDED_PATHS = ("tools/sanitize.py", ".gitleaks.toml")
MAX_FILE_BYTES = 2_000_000

# (id, regex). Known provider formats + PII + paths.
RULES = [
    ("aws-access-key", re.compile(r"\b(AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("openai-key", re.compile(r"\bsk-(proj-)?[A-Za-z0-9_-]{20,}\b")),
    ("anthropic-key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b")),
    ("github-token", re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{60,}\b")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("private-key-block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b")),
    ("url-with-credentials", re.compile(r"[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s:@]+@")),
    ("assignment-secret", re.compile(
        r"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key)\b\s*[:=]\s*['\"]?([^\s'\"]{8,})")),
    ("email-address", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")),
    ("private-ipv4", re.compile(
        r"\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b")),
    ("home-path", re.compile(r"(/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|[A-Za-z]:\\Users\\[A-Za-z0-9._-]+)")),
]

# Generic secret candidates: long base64/mixed-hex-like strings. Pure hex (commit hashes)
# has entropy <= 4 bits and stays below the threshold; so do UUIDs.
ENTROPY_CANDIDATE = re.compile(r"[A-Za-z0-9+/=_-]{32,}")
ENTROPY_THRESHOLD = 4.5
# Markers that are not secrets even though they are long and varied.
ENTROPY_SKIP = re.compile(r"^(sha256-|sha384-|sha512-|[0-9a-f]{32,}$)")
# Assignment values that are references, not secrets: os.environ/X, ${X}, $X, <placeholder>,
# or an uppercase variable name.
REFERENCE_VALUE = re.compile(r"^(os\.environ/|\$\{?|<|env:|secrets\.|[A-Z][A-Z0-9_]*$)")


def shannon(s):
    if not s:
        return 0.0
    counts = {}
    for ch in s:
        counts[ch] = counts.get(ch, 0) + 1
    n = float(len(s))
    return -sum(c / n * math.log2(c / n) for c in counts.values())


def mask(s):
    if len(s) <= 8:
        return "*" * len(s)
    return s[:4] + "…" + s[-2:]


def load_forbidden_terms():
    base = os.environ.get("AI_MEMORY_LOCAL") or os.path.join(os.path.expanduser("~"), ".config", "ai-memory")
    path = os.path.join(os.path.expanduser(base), "forbidden-terms.txt")
    terms = []
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                t = line.strip()
                if t and not t.startswith("#"):
                    terms.append(t.lower())
    return terms


def scan_text(rel_path, text, forbidden):
    findings = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if MARKER in line:
            continue
        for rule_id, rx in RULES:
            for m in rx.finditer(line):
                if rule_id == "assignment-secret" and REFERENCE_VALUE.match(m.group(2)):
                    continue
                findings.append((rel_path, lineno, rule_id, mask(m.group(0))))
        for m in ENTROPY_CANDIDATE.finditer(line):
            tok = m.group(0)
            if ENTROPY_SKIP.match(tok):
                continue
            if shannon(tok) >= ENTROPY_THRESHOLD:
                findings.append((rel_path, lineno, "high-entropy", mask(tok)))
        low = line.lower()
        for t in forbidden:
            if t in low:
                findings.append((rel_path, lineno, "forbidden-term", mask(t)))
    return findings


def is_binary(data):
    return b"\x00" in data[:8000]


def repo_root():
    try:
        out = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], stderr=subprocess.DEVNULL)
        return out.decode().strip()
    except (subprocess.CalledProcessError, OSError):
        return os.getcwd()


def rel_to_root(path, root):
    try:
        return os.path.relpath(os.path.abspath(path), root)
    except ValueError:
        return path


def iter_disk_files(paths):
    for p in paths:
        if os.path.isdir(p):
            for dirpath, dirnames, filenames in os.walk(p):
                dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__", "build", "node_modules")]
                for f in filenames:
                    yield os.path.join(dirpath, f)
        elif os.path.isfile(p):
            yield p
        else:
            print(f"sanitize: not found: {p}", file=sys.stderr)


def read_disk(path):
    with open(path, "rb") as fh:
        return fh.read(MAX_FILE_BYTES + 1)


def staged_files(root):
    # --no-renames: a moved-and-edited file would otherwise be status R and skip the ACM filter.
    # T: a symlink replaced by a regular file carries new content too.
    out = subprocess.check_output(
        ["git", "-C", root, "diff", "--cached", "--name-only", "--no-renames", "--diff-filter=ACMT", "-z"])
    return [p for p in out.decode().split("\0") if p]


def read_staged(root, rel):
    return subprocess.check_output(["git", "-C", root, "show", ":" + rel])


def tracked_files(root):
    out = subprocess.check_output(["git", "-C", root, "ls-files", "-z"])
    return [p for p in out.decode().split("\0") if p]


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--check", action="store_true", help="default mode; scan the given paths")
    ap.add_argument("--staged", action="store_true", help="scan the repository's staged content")
    ap.add_argument("--all", action="store_true", help="scan every tracked file")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args(argv)

    root = repo_root()
    forbidden = load_forbidden_terms()
    sources = []  # (rel_path, bytes)

    if args.staged:
        for rel in staged_files(root):
            sources.append((rel, read_staged(root, rel)))
    elif args.all:
        for rel in tracked_files(root):
            full = os.path.join(root, rel)
            if os.path.isfile(full):
                sources.append((rel, read_disk(full)))
    else:
        if not args.paths:
            ap.error("give paths, --staged or --all")
        for p in iter_disk_files(args.paths):
            sources.append((rel_to_root(p, root), read_disk(p)))

    findings = []
    for rel, data in sources:
        if rel.replace(os.sep, "/") in EXCLUDED_PATHS:
            continue
        if is_binary(data):
            continue
        if len(data) > MAX_FILE_BYTES:
            findings.append((rel, 0, "file-too-large", f"{len(data)} bytes"))
            continue
        findings.extend(scan_text(rel, data.decode("utf-8", errors="replace"), forbidden))

    if findings:
        for rel, lineno, rule_id, snippet in findings:
            print(f"{rel}:{lineno}: [{rule_id}] {snippet}")
        print(f"\nsanitize: {len(findings)} finding(s). Fix it or mark the line with '{MARKER}' if it is a false positive.",
              file=sys.stderr)
        return 1
    if not args.quiet:
        print(f"sanitize: clean ({len(sources)} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
