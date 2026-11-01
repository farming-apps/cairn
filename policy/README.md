# policy/

The **security floor** for the AI clients: deny/ask permissions, the guard-bash hooks and the
Copilot sandbox. It ships with the tool and cannot be weakened from the memory repo. Your own
preferences live in the memory repo, `<data>/settings/<client>/settings.json` (defaults in
`templates/data/settings/`). `install.sh` combines both and merges the result into the real files
on each machine with `tools/merge-settings.py`.

| Client | Floor (here) | Preferences (memory repo) | Destination on the machine |
|--------|--------------|---------------------------|----------------------------|
| Claude Code | `claude/settings.json` | `settings/claude/settings.json` | `~/.claude/settings.json` |
| Antigravity CLI (`agy`) | `agy/settings.json` | `settings/agy/settings.json` | `~/.gemini/antigravity-cli/settings.json` (permissions) |
| Antigravity CLI (`agy`) | `agy/hooks.json` | — | `~/.gemini/config/hooks.json` (hook) |
| GitHub Copilot CLI | `copilot/settings.json` | `settings/copilot/settings.json` | `~/.copilot/settings.json` |
| VS Code | `vscode/settings.json` | `settings/vscode/settings.json` | `~/Library/Application Support/Code/User/settings.json` (macOS) or `~/.config/Code/User/settings.json`; override with `$VSCODE_USER_DIR` |

## Floor, preferences and machine
- **Floor** (this directory): `permissions.deny`, `permissions.ask`, `hooks` marked `# ai-memory`,
  Copilot's `sandbox` and VS Code's `github.copilot.enable`/`files.associations`.
- **Preferences** (`<data>/settings/`): by default `permissions.defaultMode` (every session starts in
  plan mode), `statusLine` (`tools/statusline.sh`) and `attribution` (empty `commit`/`pr` and
  `sessionUrl: false`: no `Co-Authored-By` or "Generated with" lines in commits and PRs; the same rule
  for every client is in `global/AGENTS.md`). You may add any other key, and extra `deny`/`ask` rules.
- **Combination**: lists are united (floor first, your extras after); on any other conflict the floor
  wins; `hooks` come from the floor only. Removing a floor rule from your preferences changes nothing.
  Each `install.sh` replaces the combined keys in the machine file.
- **Machine** (preserved): `model`, `theme`, `tui`, `permissions.allow` (what you accept with
  "always allow"), your own unmarked hooks, and any other key.
- Claude Code's own `language` key in `~/.claude/settings.json` is a machine-level setting never
  touched; the repo's language rule lives in the profile's working-language field
  (`global/profile.private.md`) instead.

`{{AI_MEMORY_ROOT}}` (tool repo), `{{AI_MEMORY_DATA}}` (memory repo) and `{{HOME}}` are replaced with
real paths at install time; this way the files contain no home paths and pass the gitleaks hook.

## Why preferences cannot loosen the policy
The memory repo is where models write (`memory/`, `plans/`), so it must not be able to relax the next install:
1. **Floor + extras**: the security rules are not in the memory repo at all; preferences can only add.
2. **Write ban**: the floor denies editing `policy/` and `<data>/settings/` (Claude `Edit(//…)`, agy
   `write_file(…)`), and `guard-bash.py` denies writing `policy/<client>/` and `settings/<client>/` from
   the shell. Edit your preferences by hand.
3. **Review before applying**: if `<data>/settings/` has uncommitted changes, `install.sh` shows the
   diff and asks; answering no applies only the floor. `doctor.sh` fails if an installed file misses
   any floor rule (`merge-settings.py --check`).

## Three layers against destructive operations
1. `permissions.deny` / `ask`: prefix rules. Fast, but `rm -fr`, `rm -r -f`, `sudo rm` or
   `sh -c "rm -rf …"` get around them.
2. `PreToolUse` hook → `tools/guard-bash.py`: tokenises each shell command (quote-aware, so
   `r''m` or `cu"rl"` do not slip through) and judges every pipeline segment. It covers what the
   prefix rules miss:
   - **Deletion**: `rm -r` on `/`, `~`, `..`, `.git`, outside the cwd or with unresolved variables,
     and `mkfs`/`dd of=/dev/…`/`shred` → deny; `rm -r` on normal paths, `find -delete`,
     `… | xargs rm -rf` → ask.
   - **Filter evasion**: `$IFS`, a command name built with `$(…)`, `… | base64 -d | sh`,
     `<(curl …)` → deny; any pipe into an interpreter → ask.
   - **Remote exec / exfiltration**: `/dev/tcp`, `nc -e`, `curl|sh`, decoded pipelines → deny;
     `… | curl`, DNS lookups with a computed argument, the macOS Keychain → deny; remote package
     runners (`npx -y`, `uvx`), uploads, tunnels, `ssh host "cmd"`, metadata endpoints → ask.
   - **Sensitive paths** (mirrors the `Read`/`Edit` rules so `cat`/`>` cannot bypass them):
     credential files → deny; the agent's own policy, `guard-bash.py`, `policy/<client>/`,
     `<data>/settings/<client>/` and the ai-memory machine config (`~/.config/ai-memory/`, `~/.config/git-projects/`) → deny on write; other
     agents' config, shell rc files, LaunchAgents, git hooks, CI workflows → ask on write.
   - **git as a hook**: `git config`/`-c` on a callback key (`core.fsmonitor`, `core.hooksPath`,
     `credential.helper`, …) → ask, or deny if the value is an inline command; `git worktree add ./.git`,
     history rewrites → deny/ask.
   - **Env, agents, persistence, infra**: `ANTHROPIC_BASE_URL`/proxy/`LD_PRELOAD`-style variables,
     an agent CLI launched with `--yolo`/`--dangerously-skip-permissions`, `crontab`/`launchctl`,
     destructive SQL, `terraform destroy`, `docker --privileged`, package publishing, and macOS
     controls (SIP, Gatekeeper, FileVault, firewall, DNS) → ask or deny.

   The rationale and CVE references live in short comments in the script. The exact decisions are
   pinned by `tools/guard-cases.tsv` / `tools/test-guard.py` (94 cases); run it after any change.
   With `onFailure: block`: if the script does not exist (repo moved), Bash stays blocked until
   you re-run `install.sh`. This is intentional.
3. `Edit(~/.claude/settings.json)` denied: the model cannot remove its own rules.
   To change the policy, edit `policy/` (floor) or `<data>/settings/` (preferences) by hand and re-run `install.sh`.

## Status line
`statusLine` runs `tools/statusline.sh` with the session JSON Claude Code sends on stdin
(it only needs `jq`). Two lines:

```
[Fable] ai-memory  main*  effort:high
[███████░░░] 70% 140k/200k  $0.42 12m  5h 23% 7d 41%  mem: ai-memory · 2 pending · 1 plan · state 16d
```
- Line 1: model, current folder (last component only), branch (`*` if there are uncommitted
  changes), effort level and agent if you are inside a subagent.
- Line 2: context bar (green <70 %, amber ≥70 %, red ≥85 % with `⚠ compact`), tokens in the
  window / window size, session cost and duration, 5h/7d limits (if your plan sends them) and the
  project's memory status: name, pending `.md` files in `memory/`, plans waiting in `plans/` and days since `state.md` was
  last touched once past 14. With no associated project it shows `no memory`.
- Fields missing from the JSON are omitted. With the status line active, Claude Code stops showing
  almost all footer hints (`esc to interrupt`, `? for shortcuts`).

The project is resolved from `autoMemoryDirectory` in `<repo>/.claude/settings.local.json` (written
by `new-project.sh`) or, failing that, from `<data>/projects/<repo-name>`.

The same script serves Antigravity CLI and GitHub Copilot CLI, whose `statusLine` setting has the
same shape (`type`, `command`, `padding`, `refreshInterval`) and also sends JSON on stdin. Copilot
differs in the payload: its `used_percentage`/`context_window_size` are null and the live values are
`current_context_used_percentage`, `current_context_tokens` and `displayed_context_limit`; its
`total_*_tokens` are session totals (ignored); it has no USD cost but `total_premium_requests`,
shown as `7 premium`; and it sends no rate limits, effort or agent. Example under Copilot:

```
[Claude Sonnet 4.5] ai-memory  main*
[█████░░░░░] 50% 64k/128k  7 premium 10m  mem: ai-memory · 2 pending
```

## Testing
```sh
python3 -I tools/test-guard.py    # 94-case battery for guard-bash.py (expected decision per rule)
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf ~/x"},"cwd":"/tmp"}' | python3 -I tools/guard-bash.py
tools/install.sh --dry-run        # shows the diff it would apply to ~/.claude/settings.json
tools/doctor.sh                   # confirms the rules, the hook and the status line are active
echo '{}' | tools/statusline.sh   # the status line must not fail even with empty JSON
```
After installing, in Claude Code `/hooks` shows the hook and `/permissions` the rules. Changes to
`~/.claude/settings.json` load in the next session.

## VS Code: built-in Copilot off in sensitive files
Recent VS Code ships GitHub Copilot as a built-in component, so inline suggestions send the open
file to GitHub even if you never installed an extension. `vscode/settings.json` keeps code
completion on but turns it off by language id for the types that hold secrets:
`github.copilot.enable` with `plaintext`, `dotenv`, `ini` and `properties` set to `false`, plus
`files.associations` that route credential files (`*.pem`, `*.key`, `*.p12`, `*.tfvars`, `.netrc`,
`.npmrc`, `.pypirc`, `.git-credentials`, `.ssh/config`, `.aws/credentials`) to `plaintext` and
`.env*` to `dotenv`. Copilot's filter is per language, not per path, which is why the associations
are needed; path-based "content exclusions" exist only in Copilot Business/Enterprise. The merge is
one level deep: your own entries under both keys are kept. To also silence it in `yaml`, `json` or
`markdown`, add them with `false` to `<data>/settings/vscode/settings.json`. To turn off every built-in AI feature instead,
set `chat.disableAIFeatures: true` in your own settings.

## GitHub Copilot CLI
`copilot/settings.json` (floor: hook and sandbox) plus `<data>/settings/copilot/settings.json`
(preference: status line) are merged into `~/.copilot/settings.json` (or `$COPILOT_HOME/settings.json`)
when the `copilot` binary is present. Three keys:

- **`statusLine`** → `tools/statusline.sh`, see above. In Copilot CLI 1.0.103 it is a regular setting
  (`copilot help config`); older builds gated it behind `experimental: true` or
  `feature_flags.enabled: ["STATUS_LINE"]`. If the line does not appear, check `copilot config statusLine`.
- **`hooks.PreToolUse`** → the same `tools/guard-bash.py`, invoked with `--out copilot`. Copilot accepts
  inline hooks in the user `settings.json` with the same schema as `.github/hooks/*.json`. The
  PascalCase event name selects the Claude-compatible payload (`tool_name: "Bash"`, `tool_input`,
  `cwd`); the reply differs, so the guard prints a flat `{"permissionDecision", "permissionDecisionReason"}`
  instead of Claude's `hookSpecificOutput` wrapper, which is what `--out copilot` selects. Entries are
  recognised as managed by the `# ai-memory` marker in `bash`, like Claude's `command`.
- **`sandbox.enabled: true`** → command sandboxing on. Every shell command Copilot runs is launched
  inside an OS sandbox (Seatbelt via `sandbox-exec` on macOS, bubblewrap on Linux, through Microsoft's
  MXC library). Without it, commands run with your full user access: anything you can read, write,
  delete or reach over the network, the agent can too. With it:
  - filesystem access outside the allowed paths (the repo and the temp dir) fails instead of touching
    the rest of the system; network is constrained to what the policy permits;
  - `git` and `gh` authenticate through a masking proxy, so the command never sees the token;
  - built-in file edits are not OS-sandboxed but follow the same path policy on a best-effort basis;
  - the sandbox still inherits your shell environment minus a fixed blocklist, so exported secrets such
    as `AWS_ACCESS_KEY_ID` remain visible unless you configure masking.
  It complements the hook: the guard reads the command text and can be fooled, the sandbox acts when
  the command runs. Expect legitimate commands that leave the repo (installing into the home, writing
  `~/.config`) to fail; Copilot offers a per-command bypass prompt, and `/sandbox disable` turns it off
  for the current session only. Because the key is part of the floor, `install.sh` re-enables it and
  `doctor.sh` fails without it; to opt out on one machine, remove `sandbox` from `policy/copilot/settings.json` locally.

How Copilot's three layers compare with Claude's:
1. **Tool permissions** (`--allow-tool` / `--deny-tool shell(git push)`) are session flags, not saved.
   For a permanent personal deny list, launch through an alias, e.g.
   `alias copilot='copilot --deny-tool "shell(sudo:*)" --deny-tool "shell(git push --force)"'`.
   Patterns are prefix-based with no regex, so they do not replace the guard.
2. **Path access** is limited to the cwd plus the temp dir (`--add-dir` extends it, `--allow-all-paths`
   disables it); there is no per-path read deny like Claude's `Read(~/.ssh/**)`. The enforceable layer
   is the sandbox described above, which the floor turns on.
3. **The hook** is the equivalent of Claude's guard. Failure semantics: a crash or non-zero exit denies
   (same as our `onFailure: block`), exit code 2 always denies, but a **timeout fails open**, hence
   `timeoutSec: 5`. In autopilot mode `ask` becomes `deny`, so `git push --force` or a relative `rm -r`
   are refused there instead of prompting.

Copilot also loads repo-level hooks from `.github/hooks/*.json` and from the work repo's
`.claude/settings.json` / `.claude/settings.local.json`; it does not read `~/.claude/settings.json`.

Test by hand:
```sh
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf ~/x"},"cwd":"/tmp"}' | python3 -I tools/guard-bash.py --out copilot
```

## Antigravity CLI (`agy`)
It is the "Gemini" of this setup (the `agy` binary; Gemini CLI is not installed). It reuses
`~/.gemini/` but with its own paths and syntax:

- **Permissions** → `agy/settings.json` (plus your `<data>/settings/agy/settings.json`), merged into `~/.gemini/antigravity-cli/settings.json` under
  `permissions.{deny,ask}`; `allow` and `trustedWorkspaces` are preserved. `command(...)`,
  `read_file(...)`, `write_file(...)` rules: token prefix, each part of an `&&`/`;`/`|` chain is
  evaluated separately, and `regex:` nests a regex per token. Deny > Ask > Allow. `{{HOME}}` is
  replaced at install time.
- **Hook** → `agy/hooks.json`, merged into `~/.gemini/config/hooks.json` as the `ai-memory` key
  (other keys, e.g. `cmux`, are left alone). agy does not load hooks placed inside `settings.json`.
  The same `tools/guard-bash.py` detects the agy format (`toolCall.args.CommandLine`) and
  replies `{"decision": "deny"|"ask", "reason"}`; with no opinion it replies `{}`.
- **Global rules** → `~/.gemini/GEMINI.md`. The include that inserts content is
  `@[label](path)`; a bare `@path` (Claude Code syntax) inserts nothing. That is why
  `global/GEMINI.md` says `@[AGENTS](AGENTS.md)` and the `AGENTS.md` files carry no nested imports:
  each wrapper imports `AGENTS.md` and `state.md` in its own syntax.
- **Neutral hook reply**: agy treats `{}` as a denial (tested), so with no opinion the guard
  replies `{"decision": "ask"}` (configurable with `AI_MEMORY_GUARD_NEUTRAL`). `ask` respects
  your `allow` rules and the "Always Allow" cache.
- **Status line** → the same `tools/statusline.sh` as Claude Code, declared in
  `<data>/settings/agy/settings.json` (`statusLine`). The agy JSON differs only in `cost.total_usd` and
  `model.effort`, covered by fallbacks; it sends no duration or 5h/7d limits, which are omitted.
  If you prefer to keep agy's own bar underneath, add `"stack_with_default": true`.
- **Known limits**: what agy does if the hook fails or is slow is undocumented; that is why the
  static `deny` rules cover the critical cases without depending on the hook.

Check: in agy, `/permissions` and `/hooks`; `tools/doctor.sh` validates both files and tests the
guard in agy format. Real test: `agy -p "Run exactly: rm -rf ~/x-nonexistent"` must be denied.
