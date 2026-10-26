#!/usr/bin/env python3
"""PreToolUse hook for shell commands. Serves two clients with the same policy:

  Claude Code (Bash tool; stdin with `tool_input.command`, `cwd`):
    - nothing (exit 0)         -> no opinion; normal permission rules apply
    - permissionDecision=ask   -> asks for confirmation even if an allow rule matches
    - permissionDecision=deny  -> blocks
  Antigravity CLI / agy (run_command tool; stdin with `toolCall.args.CommandLine`,
  `toolCall.args.Cwd` or `workspacePaths`):
    - {"decision": "ask"|"deny", "reason": ...}
    - no opinion -> {"decision": NEUTRAL}. agy treats `{}` as a denial, so an explicit value
      is required; NEUTRAL comes from $AI_MEMORY_GUARD_NEUTRAL (default "ask", which honors
      allow rules and the user's "Always Allow" cache).

  GitHub Copilot CLI (PreToolUse hook, PascalCase event: same input as Claude Code, with the
  command in `tool_input.command` or `tool_input.bash`); selected with `--out copilot`:
    - nothing (exit 0)                                         -> no opinion
    - {"permissionDecision": "ask"|"deny", "permissionDecisionReason": ...}  (flat, no wrapper)

The agy format is detected by the presence of `toolCall` in the input; Copilot cannot be told
apart from Claude Code by the payload, hence the explicit `--out copilot` argument.

Policy: irreversible and wide-scope -> deny; irreversible but bounded -> ask; everything else
is left alone. The `permissions.deny` rules cover the obvious prefixes; this script covers the
variants those rules miss (`rm -fr`, `rm -r -f`, `sudo rm`, `sh -c "rm -rf ..."`, empty
variables, `find -delete`, `curl | sh`).

Manual test:
  echo '{"tool_input":{"command":"rm -rf ~/x"},"cwd":"/tmp"}' | python3 -I tools/guard-bash.py
  echo '{"toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf ~/x"}},"workspacePaths":["/tmp"]}' \
    | python3 -I tools/guard-bash.py
"""
import json
import os
import re
import shlex
import sys

HOME = os.path.expanduser("~")
RANK = {"ask": 1, "deny": 2}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish"}
DANGEROUS_TARGETS = {"/", "/*", "~", "~/", "~/*", "*", "/.", ".", "./", "..", ".*", "/.*"}
TMP_ROOTS = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", "/var/tmp/")

# Wrappers stripped from the front to reach the real command.
# name: (flags that take a value, positional args consumed before the command)
WRAPPERS = {
    "sudo": ({"-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t", "-T", "--user", "--group"}, 0),
    "doas": ({"-u", "-C"}, 0),
    "env": ({"-u", "-C", "-S", "--unset", "--chdir"}, 0),
    "command": (set(), 0), "builtin": (set(), 0), "exec": (set(), 0), "nohup": (set(), 0),
    "time": (set(), 0), "nocorrect": (set(), 0), "noglob": (set(), 0), "caffeinate": (set(), 0),
    "nice": ({"-n", "--adjustment"}, 0),
    "ionice": ({"-c", "-n", "-p"}, 0),
    "timeout": ({"-s", "-k", "--signal", "--kill-after"}, 0),
    "arch": ({"-arch"}, 0),
    "stdbuf": ({"-i", "-o", "-e"}, 0),
    "setsid": (set(), 0),
    "xargs": ({"-I", "-L", "-n", "-P", "-s", "-d", "-a", "-E", "-J", "-R", "-S"}, 0),
    "watch": ({"-n", "-d", "--interval"}, 0),
    "chroot": ({"--userspec", "--groups"}, 1),
    "flock": ({"-w", "-E", "--timeout"}, 1),
    "unshare": (set(), 0),
}

# Environment variables set in front of a command (`VAR=x cmd`, `export VAR=x`, `env VAR=x`).
# Network: proxy, CA bundle or base URL for the agent's own traffic (CVE-2026-21852).
ENV_NETWORK = {
    "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy",
    "https_proxy", "all_proxy", "NO_PROXY", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR",
    "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "NODE_TLS_REJECT_UNAUTHORIZED", "GIT_SSL_NO_VERIFY",
    "GIT_SSL_CAINFO", "PYTHONHTTPSVERIFY",
}
# Inject: change what code later processes run (preload, interpreter options, rc files, the
# editor/pager other tools spawn, a relocated HOME).
ENV_INJECT = {
    "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONHOME",
    "PERL5OPT", "PERL5LIB", "RUBYOPT", "RUBYLIB", "BASH_ENV", "ENV", "ZDOTDIR", "PROMPT_COMMAND",
    "GIT_SSH_COMMAND", "GIT_SSH", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_COUNT", "GIT_EXEC_PATH", "GIT_ASKPASS", "GIT_EXTERNAL_DIFF", "GIT_PAGER", "GIT_EDITOR",
    "GIT_TEMPLATE_DIR", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "EDITOR", "VISUAL", "PAGER", "HOME",
    "XDG_CONFIG_HOME", "XDG_DATA_HOME", "IFS", "CDPATH", "SHELL", "HISTFILE", "HISTSIZE",
}
ENV_ASSIGN_RX = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
# Repo rule: secrets are named by variable, never by value.
SECRET_NAME_RX = re.compile(r"(API_KEY|APIKEY|TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE_KEY)$", re.I)
SAFE_PATH_PREFIX = ("/usr/", "/bin", "/sbin", "/opt/", "/nix/", "$PATH", "${PATH}", "~/.", "$HOME/.",
                    HOME + "/.", "/etc/paths", "/Library/", "/Applications/")


def check_env_assignment(tok):
    m = ENV_ASSIGN_RX.match(tok)
    if not m:
        return None
    name, value = m.group(1), m.group(2)
    if name in ENV_NETWORK:
        return "ask", f"{name} redirects or weakens the agent's own network traffic"
    if name in ENV_INJECT:
        return "ask", f"{name} changes what code later processes run"
    if name == "PATH" and not value.split(":")[0].startswith(SAFE_PATH_PREFIX):
        return "ask", "PATH prepends a non-standard directory: shadows system commands"
    if SECRET_NAME_RX.search(name) and len(value) >= 4 and not value.startswith("$"):
        return "ask", f"{name} given by value on the command line; use the variable instead"
    return None


# Sensitive paths. The Read/Edit rules in settings.json never see Bash; this table mirrors them.
#   secret   -> deny when named          envfile/keyfile -> deny when read, ask otherwise
#   policy   -> deny when written (hooks in agent settings run code: CVE-2025-59536, CVE-2026-25725)
#   agent    -> ask when written (other agents'/editors' config: CVE-2026-48124)
#   startup  -> ask when written (runs later on its own: rc files, LaunchAgents, git hooks, CI)
#   system   -> deny when written        usrlocal -> ask when written
SECRET_RX = re.compile(
    r"^(~/(\.ssh|\.aws|\.gnupg|\.azure|\.codex|\.kube|\.config/gh|\.config/gcloud|\.config/op|\.netrc|\.npmrc"
    r"|\.pypirc|\.git-credentials|\.password-store|\.1password|\.docker/config\.json|\.claude/\.credentials\.json"
    r"|\.gemini/oauth_creds\.json|\.gemini/google_accounts\.json|\.cargo/credentials(\.toml)?|\.local/share/keyrings"
    r"|Library/Keychains|Library/Cookies|Library/Application Support/(Google/Chrome|Firefox|BraveSoftware|Microsoft Edge))"
    r"|/etc/(shadow|sudoers|master\.passwd)|/(private/)?var/db/dslocal)(/.*)?$", re.I)
ENVFILE_RX = re.compile(r"(^|/)\.env(\.(?!example$|sample$|template$|dist$)[^/]+)?$", re.I)
KEYFILE_RX = re.compile(r"(^|/)(id_(rsa|ed25519|ecdsa|dsa)|[^/]+\.(pem|key|p12|pfx|kdbx|keystore|jks))$", re.I)
POLICY_RX = re.compile(
    r"^(~/\.claude/(settings(\.local)?\.json|CLAUDE\.md|hooks(/.*)?|managed-settings\.json)|~/\.claude\.json"
    r"|~/\.gemini/(GEMINI\.md|AGENTS\.md|config/hooks\.json|antigravity-cli/settings\.json)"
    r"|~/\.copilot/(hooks(/.*)?|permissions-config\.json|settings\.json)"
    r"|~/\.config/(ai-memory|git-projects)(/.*)?"   # ai-memory machine config (env, registry, forbidden terms): edited by hand only
    r"|(.*/)?guard-bash\.py)$", re.I)
AGENT_RX = re.compile(
    r"^(~/\.(claude|gemini|copilot|codex)(/.*)?|(.*/)?\.(claude|cursor|vscode|gemini|agents|codex|windsurf|continue"
    r"|aider|kiro|copilot|idea)(/.*)?|(.*/)?\.?mcp\.json|.*claude_desktop_config\.json|(.*/)?(CLAUDE|AGENTS|GEMINI)\.md"
    r"|(.*/)?\.cursorrules|(.*/)?\.github/copilot-instructions\.md"
    r"|~/Library/Application Support/(Claude|Code|Cursor)(/.*)?)$", re.I)
STARTUP_RX = re.compile(
    r"^(~/\.(zshrc|zshenv|zprofile|zlogin|zlogout|bashrc|bash_profile|bash_login|bash_logout|profile|gitconfig"
    r"|zsh_history|bash_history|tmux\.conf|hushlogin|config/git(/.*)?|config/fish(/.*)?|config/pip(/.*)?)"
    r"|~/Library/LaunchAgents(/.*)?|/Library/LaunchAgents(/.*)?|/Library/LaunchDaemons(/.*)?"
    r"|(.*/)?\.envrc|(.*/)?\.git/(config|hooks(/.*)?|info/attributes)|(.*/)?\.(githooks|husky)(/.*)?"
    r"|(.*/)?\.pre-commit-config\.yaml|(.*/)?\.github/workflows(/.*)?"
    r"|(.*/)?\.(npmrc|pypirc|yarnrc(\.yml)?|gitattributes|gitmodules))$", re.I)
SYSTEM_RX = re.compile(r"^/(etc|private/etc|bin|sbin|System|Library|usr(?!/local)|var/root|private/var/db|Applications)(/.*)?$", re.I)
USRLOCAL_RX = re.compile(r"^/usr/local(/.*)?$")
PATH_CATEGORIES = (("secret", SECRET_RX), ("envfile", ENVFILE_RX), ("keyfile", KEYFILE_RX), ("policy", POLICY_RX),
                   ("agent", AGENT_RX), ("startup", STARTUP_RX), ("usrlocal", USRLOCAL_RX), ("system", SYSTEM_RX))
# Readers pull a file's content out; writers take every non-flag argument as a destination.
READERS = {"cat", "less", "more", "head", "tail", "grep", "egrep", "fgrep", "rg", "ag", "awk", "sed", "cut",
           "sort", "uniq", "tr", "od", "hexdump", "xxd", "strings", "base64", "source", ".", "bat", "nl",
           "tac", "rev", "jq", "yq", "scp", "rsync"}
WRITERS = {"tee", "cp", "mv", "install", "ln", "rsync", "truncate", "touch", "chmod", "chown", "chgrp",
           "chflags", "patch", "dd", "mkdir", "rm", "rmdir", "unlink", "shred", "srm", "wipe", "xattr",
           "ex", "ed", "vi", "vim", "nano", "ditto", "unzip", "tar"}
INPLACE_RX = re.compile(r"^(-[a-zA-Z]*i|--in-place)")


def norm_path(t):
    t = t.strip("'\"")
    for pre in ("${HOME}", "$HOME"):
        if t.startswith(pre):
            t = "~" + t[len(pre):]
    if HOME and t.startswith(HOME):
        t = "~" + t[len(HOME):]
    return t.rstrip("/") if len(t) > 1 else t


def classify_path(t):
    p = norm_path(t)
    if not p or p.startswith("-") or ("/" not in p and "." not in p):
        return None
    for cat, rx in PATH_CATEGORIES:
        if (rx.search(p) if cat in ("envfile", "keyfile") else rx.match(p)):
            return cat
    return None


def written_targets(name, toks):
    """Tokens a segment writes to: redirection targets plus the arguments of writer commands."""
    out, args = set(), toks[1:]
    for i, t in enumerate(toks):
        m = re.match(r"^(\d?>>?|&>)(.*)$", t)
        if m and m.group(2):
            out.add(m.group(2))
        elif m and i + 1 < len(toks):
            out.add(toks[i + 1])
    if name in WRITERS or (name in INPLACE_EDITORS and any(INPLACE_RX.match(a) for a in args)):
        out.update(a for a in args if not a.startswith("-"))
    return out


INPLACE_EDITORS = {"sed", "perl"}

# (regex over the full normalized command, decision, reason)
PATTERNS = [
    (re.compile(r"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|perl)\b"), "deny",
     "download-and-run in one step (curl|sh) is not allowed; download, review, then run"),
    (re.compile(r"\bmkfs(\.\w+)?\b"), "deny", "mkfs formats a device"),
    (re.compile(r"\bdd\b.*\bof=/dev/"), "deny", "dd onto a device"),
    (re.compile(r">\s*/dev/(sd|disk|nvme|hd)"), "deny", "direct write to a device"),
    (re.compile(r"\bchmod\b.*\b-R\b.*\b777\b\s+/(\s|$)"), "deny", "chmod -R 777 on /"),
    (re.compile(r":\(\)\s*\{\s*:\|:&\s*\};:"), "deny", "fork bomb"),
    (re.compile(r"\bgit\s+push\b.*(\s--force(-with-lease)?\b|\s-f\b)"), "ask", "forced git push"),
    (re.compile(r"\bgit\s+reset\s+--hard\b"), "ask", "git reset --hard discards changes"),
    (re.compile(r"\bgit\s+clean\b"), "ask", "git clean deletes untracked files"),
    (re.compile(r"\bgit\s+branch\s+(-D|--delete\s+--force)\b"), "ask", "forced branch deletion"),
    (re.compile(r"\bfind\b.*\s(-delete|-exec\s+rm)\b"), "ask", "find with delete"),
    (re.compile(r"\b(shutil\.rmtree|os\.remove|fs\.rm(Sync)?\(|rimraf)\b"), "ask", "recursive delete from code"),
    # --- filter evasion
    (re.compile(r"\$\{?IFS\}?"), "deny", "$IFS stands in for spaces, splitting one token into arguments"),
    (re.compile(r"<\(\s*(curl|wget|fetch)\b"), "deny", "process substitution feeding downloaded bytes to a command"),
    (re.compile(r"\b(base64\s+(-d|--decode|-D)|xxd\s+-r|openssl\s+enc\b[^|]*-d|gunzip|zcat|uudecode)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|dash|python3?|perl|ruby|node|php)\b"),
     "deny", "decoding bytes straight into an interpreter"),
    (re.compile(r"\|\s*(sudo\s+)?(sh|bash|zsh|dash|ksh|python3?|perl|ruby|node|php)\b(\s|$|;)"),
     "ask", "piping output into an interpreter"),
    # --- remote shells
    (re.compile(r"/dev/(tcp|udp)/"), "deny", "bash /dev/tcp socket (reverse shell)"),
    (re.compile(r"\b(nc|ncat|netcat|socat)\b.*(-e\b|-c\b|exec[:=]|EXEC[:=])"), "deny", "netcat/socat executing a program"),
    # --- remote package runners: download and run a package in one step
    (re.compile(r"\b(npx|bunx|pnpx)\b.*(-y\b|--yes\b|--package\b|https?://)"), "ask", "runs a remote package without review"),
    (re.compile(r"\b(uvx|pipx\s+run|pnpm\s+dlx|deno\s+run)\b"), "ask", "runs a remote package without review"),
    # --- exfiltration
    (re.compile(r"\|\s*(curl|wget|nc|ncat|socat|telnet|openssl\s+s_client)\b"), "deny", "piping local data to a network client"),
    (re.compile(r"\bsecurity\s+(find-(generic|internet)-password|dump-keychain|export|unlock-keychain)\b"),
     "deny", "reads the macOS Keychain"),
    (re.compile(r"\b(169\.254\.169\.254|metadata\.google\.internal|100\.100\.100\.200)\b"), "ask", "cloud metadata endpoint"),
    (re.compile(r"\b(ngrok|cloudflared|localtunnel|\blt\b|bore)\b|\btailscale\s+(funnel|serve)\b"), "ask", "opens an outbound tunnel"),
    # --- registry redirection: changes where every future install comes from
    (re.compile(r"\bnpm\s+config\s+set\s+registry\b|\bpip\s+config\s+set\b.*index-url|\byarn\s+config\s+set\s+registry\b"),
     "ask", "changes the package registry for all future installs"),
    # --- destructive from code / databases / infra
    (re.compile(r"(?i)\bdrop\s+(database|table)\b|\btruncate\s+table\b|\bdelete\s+from\s+\w+\s*;"), "ask", "destructive SQL"),
    (re.compile(r"(?i)\bredis-cli\b.*\bflush(all|db)\b"), "ask", "redis flush"),
    (re.compile(r"\bterraform\s+destroy\b|\bterraform\s+apply\b.*-auto-approve|\bpulumi\s+destroy\b"), "ask", "destroys infrastructure"),
    (re.compile(r"\bkubectl\s+delete\b.*(\s-A\b|--all\b|\bnamespace\b|\bns\b)"), "ask", "wide kubectl delete"),
    (re.compile(r"\bdocker\s+(system|volume)\s+prune\b"), "ask", "docker prune"),
    (re.compile(r"\bdocker\s+run\b.*(--privileged|--pid=host|-v\s*/var/run/docker\.sock|--cap-add=SYS_ADMIN)"),
     "ask", "privileged container with host access"),
    (re.compile(r"\b(npm\s+publish|twine\s+upload|cargo\s+publish|gem\s+push|docker\s+push)\b"), "ask", "publishes a package"),
    (re.compile(r"\bgit\s+(filter-repo|filter-branch)\b|\bgit\s+reflog\s+expire\b|\bgit\s+update-ref\s+-d\b"),
     "ask", "rewrites git history"),
    (re.compile(r"\b(shred|srm|wipe)\b"), "deny", "secure-erase a file"),
    # --- macOS defenses that docs/security.md relies on
    (re.compile(r"\bcsrutil\b|\bspctl\s+--(master|global)-disable\b|\bfdesetup\s+disable\b|\bnvram\b|\bkextload\b"),
     "deny", "disables a macOS security control (SIP, Gatekeeper, FileVault)"),
    (re.compile(r"\bdiskutil\s+(eraseDisk|eraseVolume|partitionDisk|reformat)\b|\btmutil\s+(disable|delete|deletelocalsnapshots)\b"),
     "deny", "erases a disk or Time Machine history"),
    (re.compile(r"\bnetworksetup\s+-set(dnsservers|.*proxy)\b|\bsocketfilterfw\b.*--setglobalstate\s+off|\bpfctl\s+-d\b"),
     "deny", "changes DNS/proxy or disables the firewall"),
    (re.compile(r"\bxattr\s+(-d\s+com\.apple\.quarantine|-c)\b|\bspctl\b.*--add"), "ask", "removes the macOS quarantine flag"),
    # --- agent CLIs launched without their own permission prompts
    (re.compile(r"\b(claude|gemini|agy|codex|copilot|cursor-agent|aider|amp)\b.*"
                r"(--dangerously-skip-permissions|--permission-mode\s+bypassPermissions|--yolo\b|--approval-mode\s+yolo"
                r"|--full-auto|--dangerously-bypass-approvals-and-sandbox|--allow-all-tools|--yes-always|--dangerously-allow-all)"),
     "deny", "launches an agent with its safety prompts disabled"),
    (re.compile(r"\bclaude\s+mcp\s+(add|add-json)\b"), "ask", "registers an MCP server (an arbitrary command)"),
    # --- persistence
    (re.compile(r"\bcrontab\b"), "ask", "crontab schedules commands to run later"),
    (re.compile(r"\blaunchctl\s+(load|bootstrap|submit|enable)\b|\bsystemctl\s+enable\b|\bdirenv\s+allow\b"),
     "ask", "installs something that runs on its own later"),
]


def neutral(fmt):
    """'No opinion' response. Claude Code and Copilot: nothing. agy: explicit decision (see docstring)."""
    if fmt == "agy":
        print(json.dumps({"decision": os.environ.get("AI_MEMORY_GUARD_NEUTRAL", "ask")}))
    sys.exit(0)


def respond(decision, reason, fmt):
    if fmt == "agy":
        print(json.dumps({"decision": decision, "reason": f"guard-bash: {reason}"}))
    elif fmt == "copilot":
        print(json.dumps({"permissionDecision": decision, "permissionDecisionReason": f"guard-bash: {reason}"}))
    else:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": f"guard-bash: {reason}",
            }
        }))
    sys.exit(0)


def scan(cmd):
    """Splits on ; | || && & and newlines, honouring quotes. Returns [(segment, separator)].
    Does not understand $(...) or heredocs: their lines are treated as commands. The bodies of
    $(...), <(...) and backticks are inspected separately by substitution_findings()."""
    out, buf, quote, i, n = [], [], None, 0, len(cmd)

    def flush(sep):
        out.append(("".join(buf), sep))
        buf.clear()

    while i < n:
        c = cmd[i]
        if quote:
            buf.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                buf.append(cmd[i + 1])
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"":
            quote = c
            buf.append(c)
        elif c == "\\" and i + 1 < n:
            buf.append(c)
            buf.append(cmd[i + 1])
            i += 1
        elif c in ";\n":
            flush(";")
        elif c == "|":
            if cmd[i:i + 2] == "||":
                i += 1
                flush("||")
            else:
                flush("|")
        elif c == "&":
            if cmd[i:i + 2] == "&&":
                i += 1
                flush("&&")
            elif cmd[i:i + 2] == "&>" or (buf and buf[-1] == ">"):
                buf.append(c)  # &> and >& redirections
            else:
                flush("&")
        else:
            buf.append(c)
        i += 1
    flush("")
    return out


def substitutions(cmd):
    """Bodies of $(...), <(...), >(...) and `...` in cmd, outermost first. Single quotes are
    literal in the shell, so nothing inside them is expanded and nothing is returned for them."""
    out, i, n, quote = [], 0, len(cmd), None
    while i < n:
        c = cmd[i]
        if quote == "'":
            if c == "'":
                quote = None
        elif c == "\\" and i + 1 < n:
            i += 1
        elif c == "'" and quote is None:
            quote = "'"
        elif c == '"':
            quote = None if quote == '"' else '"'
        elif c in "$<>" and cmd[i + 1:i + 2] == "(":
            depth, j = 1, i + 2
            while j < n and depth:
                if cmd[j] == "\\":
                    j += 1
                elif cmd[j] == "(":
                    depth += 1
                elif cmd[j] == ")":
                    depth -= 1
                j += 1
            out.append(cmd[i + 2:j - 1] if not depth else cmd[i + 2:])
            i = j - 1
        elif c == "`":
            j = cmd.find("`", i + 1)
            out.append(cmd[i + 1:j] if j != -1 else cmd[i + 1:])
            i = j if j != -1 else n
        i += 1
    return out


def substitution_findings(cmd, cwd, depth=0):
    """Inspects each command substitution body as a command of its own, recursing into nested ones."""
    found = []
    if depth >= 3:
        return found
    for body in substitutions(cmd):
        if body.strip():
            found.extend(inspect_inner(body, cwd, depth))
            found.extend(substitution_findings(body, cwd, depth + 1))
    return found


def split_segments(cmd):
    return [s.strip() for s, _ in scan(cmd) if s.strip()]


def canonicalize(cmd):
    """The command as bash sees it after quote removal, separators kept. Split quotes inside a
    word (`r''m`) no longer hide it from the regexes."""
    parts = []
    for seg, sep in scan(cmd):
        if seg.strip():
            parts.append(" ".join(tokens_of(seg)))
        if sep:
            parts.append(sep)
    return " ".join(parts)


def tokens_of(segment):
    try:
        return shlex.split(segment, posix=True)
    except ValueError:
        return segment.split()


def strip_wrappers(toks):
    """Strips leading sudo/env/VAR=x/timeout/xargs/... and returns (tokens, flags, findings).
    flags: set of wrapper names seen. findings: [(decision, reason)] from the wrappers themselves."""
    seen, findings = set(), []
    while toks:
        t = toks[0]
        if t in WRAPPERS:
            value_flags, positional = WRAPPERS[t]
            seen.add(t)
            toks = toks[1:]
            while toks and toks[0].startswith("-"):
                flag = toks[0]
                toks = toks[1:]
                if flag == "--":
                    break
                if t == "sudo" and flag in ("-S", "--stdin"):
                    findings.append(("deny", "sudo reading the password from stdin"))
                if t == "sudo" and flag in ("-i", "-s", "--login", "--shell"):
                    findings.append(("deny", "interactive root shell"))
                if flag in value_flags and toks:
                    toks = toks[1:]
            if t == "timeout" and toks and re.match(r"^\d+(\.\d+)?[smhd]?$", toks[0]):
                toks = toks[1:]
            elif positional and toks:
                toks = toks[positional:]
            if t == "sudo" and toks and (toks[0] in SHELLS or toks[0] == "su"):
                findings.append(("deny", "interactive root shell"))
            continue
        hit = check_env_assignment(t)
        if hit:
            findings.append(hit)
            toks = toks[1:]
            continue
        if ENV_ASSIGN_RX.match(t):
            toks = toks[1:]
            continue
        break
    return toks, seen, findings


def rm_is_recursive(flags):
    for f in flags:
        if f in ("--recursive", "-R", "-r"):
            return True
        if re.match(r"^-[a-zA-Z]+$", f) and ("r" in f or "R" in f):
            return True
    return False


def target_is_dangerous(t, cwd):
    if t in DANGEROUS_TARGETS:
        return "deletes root, home or the current directory"
    if re.search(r"\$\{?\w+\}?|\$\(|`", t):
        return "path with unresolved variable or subcommand (if empty, deletes root)"
    if t.startswith("~") or t.startswith("$HOME"):
        return "path inside home, outside the project"
    if t.rstrip("/").endswith(".git") or t.startswith(".git/") or "/.git" in t:
        return "deletes git history"
    if ".." in t.split("/"):
        return "escapes the current directory via .."
    if t.startswith("/"):
        if cwd and (os.path.normpath(t) + "/").startswith(os.path.normpath(cwd) + "/"):
            return None
        if t.startswith(TMP_ROOTS) and len(t.rstrip("/").split("/")) > 3:
            return None
        return "absolute path outside the working directory"
    return None


def inspect_rm(toks, cwd):
    flags = [t for t in toks[1:] if t.startswith("-") and t != "--"]
    targets = [t for t in toks[1:] if not t.startswith("-") or t == "-"]
    if "--no-preserve-root" in flags:
        return "deny", "rm --no-preserve-root"
    if not rm_is_recursive(flags):
        for t in targets:
            if t in DANGEROUS_TARGETS or target_is_dangerous(t, cwd):
                return "ask", f"rm {t}: outside the project"
        return None, None
    if not targets:
        return "deny", "recursive rm without an explicit target"
    for t in targets:
        why = target_is_dangerous(t, cwd)
        if why:
            return "deny", f"rm -r {t}: {why}"
    return "ask", "recursive rm on " + ", ".join(targets[:3])


def inspect_inner(text, cwd, depth):
    """Inspects a string that is itself a shell command (sh -c, eval, ssh, -exec ...)."""
    found = []
    if depth < 3:
        for inner in split_segments(text):
            found.extend(inspect_segment(inner, cwd, depth + 1))
    return found


def rejoin(toks):
    """Rejoin a token list so re-tokenizing preserves grouping (an inner `sh -c '...'` stays one arg)."""
    return " ".join(shlex.quote(t) for t in toks)


def inspect_segment(segment, cwd, depth=0):
    """Returns [(decision, reason)] for one pipeline segment."""
    toks, wrappers, found = strip_wrappers(tokens_of(segment))
    if not toks:
        return found
    name = os.path.basename(toks[0])
    if re.search(r"\$\(|`|\$\{", toks[0]):
        found.append(("deny", "command name computed at run time"))
    if name == "rm":
        d, why = inspect_rm(toks, cwd)
        if d == "deny" and "xargs" in wrappers and why.startswith("recursive rm without"):
            d = "ask"
        if d:
            found.append((d, why))
    elif name in SHELLS:
        for i, t in enumerate(toks):
            if t == "-c" and i + 1 < len(toks):
                found.extend(inspect_inner(toks[i + 1], cwd, depth))
    elif name == "eval":
        if any("$" in t for t in toks[1:]):
            found.append(("ask", "eval of a variable"))
        found.extend(inspect_inner(" ".join(toks[1:]), cwd, depth))
    for hook in SEGMENT_HOOKS:
        found.extend(hook(name, toks, cwd, depth))
    if "sudo" in wrappers or "doas" in wrappers:
        found.append(("ask", "uses sudo"))
    return found


def inspect_paths(name, toks, cwd, depth):
    found, written = [], written_targets(name, toks)
    for t in toks:
        cat = classify_path(t)
        if not cat:
            continue
        w = t in written
        if cat == "secret":
            found.append(("deny", f"{t}: credentials directory or file"))
        elif cat in ("envfile", "keyfile"):
            found.append(("deny" if name in READERS and not w else "ask", f"{t}: secrets file"))
        elif cat == "policy" and (w or depth):
            found.append(("deny", f"{t}: the agent's own policy; edit the template and re-run install.sh"))
        elif cat == "agent" and (w or depth):
            found.append(("ask", f"{t}: agent or editor configuration"))
        elif cat == "startup" and (w or depth):
            found.append(("ask", f"{t}: runs on its own later (startup, hooks, CI)"))
        elif cat == "system" and w:
            found.append(("deny", f"{t}: system path"))
        elif cat == "usrlocal" and w:
            found.append(("ask", f"{t}: outside the project"))
    return found


GIT_CALLBACK_KEY_RX = re.compile(
    r"^(core\.(fsmonitor|hookspath|sshcommand|askpass|pager|editor|gitproxy|alternaterefscommand)"
    r"|credential(\.[^.]+)?\.helper|filter\.[^.]+\.(clean|smudge|process)|diff\.[^.]+\.(textconv|command)"
    r"|diff\.external|merge\.[^.]+\.driver|(merge|diff)tool\.[^.]+\.cmd|uploadpack\.packobjectshook"
    r"|hooks?\.[^.]+\.command|alias\.[^.]+|sequence\.editor|gpg(\.[^.]+)?\.program|ssh\.variant"
    r"|remote\.[^.]+\.(uploadpack|receivepack|vcs|proxy)|url\.[^.]+\.insteadof|protocol\.allow"
    r"|include(if\.[^.]+)?\.path|safe\.directory|http\.(proxy|sslcainfo|sslverify))$", re.I)
GIT_INLINE_VALUE_RX = re.compile(
    r"(^|[\s;|&(])(sh|bash|zsh|dash|python3?|perl|ruby|node|curl|wget|base64|nc|ncat|eval)\b|\s-c\s"
    r"|/tmp/|/var/tmp/|/var/folders/|/dev/shm/|\$TMPDIR|\$\(|`|\|")
GIT_CONFIG_VALUE_FLAGS = {"--file", "-f", "--blob", "--type", "--default", "--fixed-value"}


def git_config_finding(key, value, scope):
    if GIT_CALLBACK_KEY_RX.match(key):
        if value and GIT_INLINE_VALUE_RX.search(value):
            return ("deny", f"git config {key}: a command that git will run on its own")
        return ("ask", f"git config {key}: git runs this on its own (hook-like key)")
    if scope:
        return ("ask", f"git config {scope} {key}: outside the project")
    return None


def inspect_git(name, toks, cwd, depth):
    if name != "git":
        return []
    found, i, scope = [], 1, None
    while i < len(toks) and toks[i].startswith("-"):
        if toks[i] == "-c" and i + 1 < len(toks):
            k, _, v = toks[i + 1].partition("=")
            f = git_config_finding(k, v, None)
            if f:
                found.append(f)
            i += 1
        elif toks[i] in ("-C", "--git-dir", "--work-tree", "--namespace"):
            i += 1
        i += 1
    if i >= len(toks):
        return found
    sub, rest = toks[i], toks[i + 1:]
    if sub == "config":
        positional = []
        j = 0
        while j < len(rest):
            a = rest[j]
            if a in ("--global", "--system"):
                scope = a
            elif a in GIT_CONFIG_VALUE_FLAGS:
                j += 1
            elif not a.startswith("-"):
                positional.append(a)
            j += 1
        if positional and positional[0] in ("set", "get", "list", "unset", "edit", "remove-section", "rename-section"):
            positional = positional[1:] if positional[0] == "set" else []
        if len(positional) >= 2:
            f = git_config_finding(positional[0], positional[1], scope)
            if f:
                found.append(f)
    elif sub == "worktree" and rest[:1] == ["add"]:
        if any(os.path.basename(a.rstrip("/")) == ".git" for a in rest[1:]):
            found.append(("deny", "git worktree named .git (CVE-2026-55607)"))
    return found


INTERPRETERS = {"python", "python2", "python3", "perl", "ruby", "node", "nodejs", "php", "osascript", "awk",
                "gawk", "mawk", "nawk", "lua"}
CODE_FLAGS = {"-c", "-e", "-E", "-r", "-p", "--eval"}
PROC_SPAWN_RX = re.compile(
    r"os\.system|subprocess|os\.popen|os\.exec|child_process|execSync|spawn(Sync)?\(|\bsystem\(|popen\("
    r"|Runtime\.exec|Process\.Start|do shell script|%x\{|\bexec\(|\beval\(|__import__", re.I)
STRING_LITERAL_RX = re.compile(r"'([^']*)'|\"((?:[^\"\\]|\\.)*)\"")
SSH_VALUE_FLAGS = set("bBcDEeFIiJLlmOopQRSWw")
RECON_TOOLS = {"find", "fd", "fdfind", "rg", "grep", "egrep", "locate", "mdfind", "ag", "ack"}
SECRET_SCANNERS = {"trufflehog", "gitleaks", "detect-secrets", "noseyparker"}
ARCHIVERS = {"zip", "tar", "7z", "7za", "7zz"}
BROAD_SCOPE_RX = re.compile(r"^(~|/|/Users|/home|/Volumes|~/(Library|Documents|Desktop|Downloads))$")
SECRET_HUNT_RX = re.compile(r"(?i)(id_rsa|id_ed25519|\.pem\b|\.p12\b|\.kdbx|wallet|mnemonic|keystore|\.env\b"
                            r"|credential|secret|\.npmrc|\.netrc|\.pypirc|token|passw|api[_-]?key|private[_-]?key)")
RESOLVERS = {"ping", "nslookup", "dig", "host", "whois", "traceroute", "curl", "wget"}
DYNAMIC_RX = re.compile(r"\$\(|`|\$\{?[A-Za-z_]")


def inline_code(name, toks):
    if name.endswith("awk"):
        args = [t for t in toks[1:] if not t.startswith("-")]
        return args[:1]
    return [toks[i + 1] for i, t in enumerate(toks[:-1]) if t in CODE_FLAGS]


def inspect_misc(name, toks, cwd, depth):
    found, args = [], toks[1:]
    if name in INTERPRETERS:
        for code in inline_code(name, toks):
            if PROC_SPAWN_RX.search(code):
                found.append(("ask", f"{name} inline code that spawns processes"))
            for m in STRING_LITERAL_RX.finditer(code):
                found.extend(inspect_inner(m.group(1) or m.group(2) or "", cwd, depth))
    elif name == "ssh":
        i = 0
        while i < len(args) and args[i].startswith("-"):
            if args[i] in ("-R", "-L", "-D", "-w") or (args[i] == "-o" and i + 1 < len(args)
                                                        and "forward" in args[i + 1].lower()):
                found.append(("ask", "ssh tunnel or port forwarding"))
            if len(args[i]) == 2 and args[i][1] in SSH_VALUE_FLAGS:
                i += 1
            i += 1
        remote = args[i + 1:]
        if remote:
            found.append(("ask", "ssh runs a command on another machine"))
            # ssh concatenates the remote args with spaces and the remote shell re-parses them.
            found.extend(inspect_inner(" ".join(remote), cwd, depth))
    elif name in ("docker", "kubectl", "podman", "nerdctl"):
        if any(a in SHELLS for a in args) and "-c" in args:
            found.append(("ask", f"{name} runs a shell inside a container"))
            found.extend(inspect_inner(args[args.index("-c") + 1] if args.index("-c") + 1 < len(args) else "", cwd, depth))
    elif name == "find":
        for flag in ("-exec", "-execdir", "-ok", "-okdir"):
            if flag in args:
                j = args.index(flag) + 1
                sub = []
                while j < len(args) and args[j] not in (";", "\\;", "+"):
                    sub.append(args[j])
                    j += 1
                if sub and os.path.basename(sub[0]) != "rm":
                    found.extend(inspect_inner(rejoin(sub), cwd, depth))
    elif name in ("chmod", "chown", "chgrp"):
        flags = [a for a in args if a.startswith("-")]
        if any(f in ("-R", "--recursive") or re.match(r"^-[a-zA-Z]*R", f) for f in flags):
            for t in args:
                if not t.startswith("-") and (t in DANGEROUS_TARGETS or target_is_dangerous(t, cwd)):
                    found.append(("deny", f"{name} -R {t}: outside the project"))
        if name == "chmod" and any(re.match(r"^([ugoa]*\+[rwxX]*s|[2467][0-7]{3})$", a) for a in args):
            found.append(("deny", "chmod setuid/setgid"))
    elif name == "mv":
        for t in args:
            if t in DANGEROUS_TARGETS or os.path.basename(t.rstrip("/")) == ".git":
                found.append(("ask", f"mv {t}: root, home, cwd or git history"))
    elif name in ("curl", "wget"):
        for i, a in enumerate(args[:-1]):
            if a in ("-o", "--output", "-O", "--output-document"):
                dest = args[i + 1]
                if dest.startswith("/") and target_is_dangerous(dest, cwd) or norm_path(dest).startswith("~/."):
                    found.append(("ask", f"download written outside the project: {dest}"))
        if any(a in ("-T", "--upload-file", "--post-file", "--body-file") or
               (a in ("-d", "--data", "--data-binary", "--data-raw", "-F", "--form") and i + 1 < len(args)
                and ("@" in args[i + 1].split("=", 1)[-1][:1] or "=@" in args[i + 1]))
               for i, a in enumerate(args)):
            found.append(("ask", f"{name} uploads a local file"))
    if name in RECON_TOOLS | SECRET_SCANNERS | ARCHIVERS:
        broad = any(BROAD_SCOPE_RX.match(norm_path(a)) for a in args)
        if broad and (name in SECRET_SCANNERS or name in ARCHIVERS or SECRET_HUNT_RX.search(" ".join(args))):
            found.append(("ask", f"{name} over the whole home or disk"))
    if name in RESOLVERS and any(DYNAMIC_RX.search(a) or re.search(r"[A-Za-z0-9_-]{41,}\.", a) for a in args):
        found.append(("deny", f"{name} with a computed or oversized argument (CVE-2025-55284)"))
    return found


SEGMENT_HOOKS = [inspect_paths, inspect_git, inspect_misc]


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    fmt = "claude"
    if "--out" in sys.argv[1:]:
        fmt = sys.argv[sys.argv.index("--out") + 1:][:1] or ["claude"]
        fmt = fmt[0]
    if isinstance(data.get("toolCall"), dict):
        fmt = "agy"
    if fmt == "agy":
        args = data["toolCall"].get("args") or {}
        cmd = args.get("CommandLine") or ""
        workspaces = data.get("workspacePaths") or []
        cwd = args.get("Cwd") or (workspaces[0] if workspaces else os.getcwd())
    else:
        tool_input = data.get("tool_input") or {}
        cmd = tool_input.get("command") or tool_input.get("bash") or ""
        cwd = data.get("cwd") or os.getcwd()
    if not cmd.strip():
        neutral(fmt)

    normalized = re.sub(r"\s+", " ", cmd)
    canonical = re.sub(r"\s+", " ", canonicalize(cmd))
    found = []
    for rx, decision, reason in PATTERNS:
        if rx.search(normalized) or rx.search(canonical):
            found.append((decision, reason))
    for seg in split_segments(cmd):
        found.extend(inspect_segment(seg, cwd))
    found.extend(substitution_findings(cmd, cwd))

    if found:
        decision, reason = max(found, key=lambda f: RANK[f[0]])
        respond(decision, reason, fmt)
    neutral(fmt)


if __name__ == "__main__":
    sys.exit(main())
