# Security

Goal: both repositories can be cloned on any machine without anything sensitive travelling with them.

## Three layers, three destinations

| What | Where | Travels |
|------|-------|---------|
| Scripts, policies, hooks, templates | this repo (the tool; may be public) | yes, with `git clone` |
| Rules, conventions, architecture with aliases, project memory | the memory repo (`AI_MEMORY_PROJECTS_DATA`, private git) | yes, with `git clone` |
| Machine paths, endpoints, forbidden terms, private profile | `~/.config/ai-memory/` and `<data>/global/profile.private.md` (ignored) | no; copied by hand over an encrypted channel |
| Keys, tokens, passwords | Keychain or password manager; exported as environment variables | never |

Golden rule: **the repo names variables, never their values.** `ANTHROPIC_API_KEY` yes; its content no.

## What stays out of the repository
- Secrets of any kind, including URLs with user and password.
- Emails, private IPs, real client names, internal domains. Use aliases in `architecture.md`.
- Absolute home paths (`~/...` is neutral; the expanded path identifies the machine and the user).
- Anything written by a model without review: it goes to `projects/<p>/memory/`, which is ignored.

## Barriers, from the inside out
1. **Convention**: the rules in `global/AGENTS.md` ask the model not to write values.
2. **`promote.sh`**: the only path from `memory/` into `state.md`/`decisions.md`; runs `sanitize.py` and the token limit.
3. **`pre-commit` hook**: `gitleaks` + `sanitize.py` + `check-size.sh` on what is *staged*, in both repos
   (`install.sh` points the memory repo's `core.hooksPath` at the tool's `.githooks/`). Blocks the commit if `gitleaks` is missing.
4. **Remote workflow**: `gitleaks` and `sanitize.py` on every push, in case someone used `--no-verify`.
5. **Private repo + 2FA + SSH**, encrypted disk (FileVault or equivalent).

## What the model may do on the machine
Independent of memory: `policy/` (tool repo) sets the security floor for Claude Code, Antigravity CLI,
Copilot CLI and VS Code; `<data>/settings/` (memory repo) adds your preferences and can only add rules,
never remove them (see `policy/README.md`). Three layers: `deny`/`ask`
rules by prefix, the `tools/guard-bash.py` hook that analyses each command before it runs (the
same script for all clients). The hook goes beyond deletion: it also catches filter-evasion tricks,
reverse shells and exfiltration, writes to the agent's own config or to startup/persistence files
(mirroring the `Read`/`Edit` rules so `cat` and `>` cannot bypass them), `git config` keys that run
code, environment variables that redirect the agent's traffic, and macOS security controls. And the
ban on the model editing the policy files: each client is
denied editing its own **and the other's** (`~/.claude/settings.json`, `~/.claude/CLAUDE.md`,
`~/.gemini/antigravity-cli/settings.json`, `~/.gemini/config/hooks.json`, `~/.gemini/GEMINI.md`),
so neither can remove its own rules or its neighbour's. The same deny covers the machine config of
ai-memory itself (`~/.config/ai-memory/`: `env`, `projects.yml`, `forbidden-terms.txt`) and the
`git-projects` registry: the tools read them, only you write them. If a session needs something the
policy blocks, you do it by hand in the terminal: that is the point.

False positives: add `sanitize:allow` on the line (as a comment). Use it sparingly and check why it fired.

## Prompt injection through memory
A model can read a README, a web page or an issue containing text like "save X to your memory".
If that is persisted, every model will read it in every session. Hence:
- the model only writes to `memory/`, never to `state.md`, `architecture.md` or `decisions.md`;
- `global/AGENTS.md` and `profile.private.md` are edited only by you;
- you review `memory/` before promoting, just as you review a `git diff`.

## If something leaked
1. **Rotate the credential first.** A secret that was on a remote is considered compromised even if you delete it.
2. Remove it from history (`git filter-repo` or the provider's tool) and force the push.
3. Tell anyone with clones to clone again.
4. Add the pattern that slipped through to `.gitleaks.toml` and `tools/sanitize.py` so it does not happen again.

## Maintenance
- `tools/doctor.sh` after every clone or machine change.
- Review `memory/` regularly; delete anything left unpromoted for weeks.
- Update `gitleaks` along with the rest of the system tools.
