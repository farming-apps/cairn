# ai-memory

Portable AI memory and configuration across machines and across models (Claude Code, Antigravity CLI,
GitHub Copilot CLI, local models), with nothing sensitive travelling along. Everything is Markdown
versioned in Git; clients load it at startup via `@path` imports, so a new chat amounts to reading it.

Two repositories:
- **this one, the tool** (public): scripts, client policies, hooks and the skeleton of a memory repo.
- **your memory repo** (private): `global/`, `project-memories/`, `skills/`, `prompts/`, `presets/`.
  Created from `templates/data/` by `install.sh --data <path>`; the tools find it through
  `AI_MEMORY_PROJECTS_DATA` or `~/.config/ai-memory/env`. Without either, memory is expected inside this repo
  (single-repo layout, as in early versions).

## Layout
```
templates/data/    skeleton of the memory repo (copied by install.sh --data):
  global/            rules for every session (AGENTS.md ≤ 400 tokens) + private profile (not versioned)
  project-memories/  <p>/AGENTS.md (conventions) · state.md (≤ 1,500) · architecture.md · decisions.md · pending/ · skills/
  skills/            shared global skills (<skill>/SKILL.md) linked into Claude, Agy and Copilot
  prompts/           reusable prompts
  presets/           which model for which task, no keys
templates/         templates for local machine files (forbidden-terms.txt, projects.yml)
gateway/           LiteLLM config for phase 2 (os.environ/... only)
settings/claude/   Claude Code policy: deny/ask permissions + guard-bash hook + statusLine
settings/agy/      Antigravity CLI (agy) policy: permissions + guard-bash hook + statusLine
settings/copilot/  GitHub Copilot CLI policy: guard-bash hook + sandbox + statusLine
settings/vscode/   VS Code: built-in Copilot off in .env, credentials and other sensitive file types
tools/             install · doctor · projects · new-project · promote · build · ai · sanitize · check-size · guard-bash · merge-settings · lib
.githooks/         pre-commit: gitleaks + sanitize + size (shared by both repos)
.github/workflows/ the same scan on the remote
docs/security.md   rules and what to do if something leaks
```
`AGENTS.md` is the single source and is plain Markdown, no imports. The wrappers carry the import in
their client's syntax: `CLAUDE.md` → `@AGENTS.md` (Claude Code); `GEMINI.md` → `@[AGENTS](AGENTS.md)`
(Antigravity CLI, `agy`: its bare `@path` does not insert content).

## Install on a machine
Requirements: `git` and `python3` (3.9+, standard library only). On macOS both come with the Xcode
Command Line Tools (`xcode-select --install`).
```sh
git clone <tool-repo> ~/ai-memory                        # any path works
~/ai-memory/tools/install.sh --data ~/ai-memory-data     # creates the memory repo if missing, or clone yours first
~/ai-memory/tools/doctor.sh                              # --module hardening,memory,projects (all by default)
```
`--data` is remembered in `~/.config/ai-memory/env`; later runs do not need it. On a second machine,
clone your private memory repo first and point `--data` at it.

**Installed copy.** `install.sh` does not wire the clients to your clone. It checks out `origin/main`
(local `main` if there is no remote) in a detached worktree at `~/.local/share/ai-memory`
(`AI_MEMORY_INSTALL_DIR` overrides it) and re-runs itself from there. That way the guard-bash hook,
the status line and the memory repo's pre-commit hook run what was merged, and switching branches in
the clone does not change them. To update after a merge, run `tools/install.sh` again from the clone.
`--dev` skips the worktree and installs from the clone as it is, to try a branch. The single-repo
layout (memory inside the clone) always installs this way. `doctor.sh` warns when the installed copy
is behind `origin/main`, and fails if it has local changes.
None of the three supported AI clients (**Claude Code**, **Antigravity CLI `agy`**, **GitHub Copilot CLI `copilot`**) is mandatory: `install.sh` and `doctor.sh` auto-detect which ones are installed on the machine and skip the rest without failing. You can also run a single module with `--module hardening`, `--module memory`, or `--module projects`.
`install.sh` is idempotent and prints every step. It first checks the tools: `gitleaks` (the hook
blocks commits without it) and `jq` (status line) are offered for install with Homebrew, asking
before each one; without Homebrew it tells you what to install and goes on. Then it writes an import
block into `~/.claude/CLAUDE.md` (and `~/.gemini/GEMINI.md` if you use Gemini), enables the hooks in
both repos, creates `<data>/global/profile.private.md` and `~/.config/ai-memory/forbidden-terms.txt`,
and merges `settings/claude/settings.json` into `~/.claude/settings.json` while keeping yours (`theme`,
`model`, `permissions.allow`, your own hooks). In a new session, check with `/context` that the files
appear under *Memory files* and with `/hooks` that `guard-bash` is active.

## Portable permission policy
`settings/claude/settings.json` holds what you never want any model to do on any machine:
`rm -rf` on `/`, `~` or outside the project, reading `~/.ssh`, `~/.aws` or `.env`, editing its own
`settings.json`; and what must always ask: `sudo`, `git push --force`, `git reset --hard`,
`git clean`. The prefix rules are reinforced by the `tools/guard-bash.py` hook, which analyses each
command (`rm -fr`, `rm -r -f`, `sh -c "rm -rf …"`, empty variables, `find -delete`, `curl | sh`).
Details, rationale and how to change it in [settings/README.md](settings/README.md).

## Connect a project
```sh
tools/new-project.sh my-app ~/dev/my-app
# or track & sync multiple projects across sections from ~/.config/ai-memory/projects.yml:
tools/projects.sh list
tools/projects.sh sync
```
Creates `<data>/project-memories/my-app/` from the template and prepares the work repo for **Claude Code**, **Antigravity CLI (`agy`)** and **GitHub Copilot CLI (`copilot`)** at the same time — all excluded via `.git/info/exclude` so `git status` stays clean:
- `CLAUDE.local.md` and `.claude/settings.local.json` (`autoMemoryDirectory` → `project-memories/my-app/pending/`)
- `GEMINI.md` (or `.agents/rules/ai-memory.md` if the repo already tracks `GEMINI.md`)
- `.github/instructions/ai-memory.instructions.md` → `<data>/build/my-app/copilot.instructions.md`
- `.claude/skills/*` and `.agents/skills/*` → shared skills from `skills/` and `project-memories/my-app/skills/`
With `--agents` it also links a flat `AGENTS.md` for OpenCode/Codex/Aider. Re-running it (or
`projects.sh sync`) after moving the memory repo repairs the bridges: imports to the old path are dropped.
`projects.yml` fields: `path`, `status` (`active` is synced; `paused`/`archived` are listed only), `agents`,
`memory: false` (registered repo with no ai-memory bridges or project memory) and `notes`. Unknown keys such
as `remote:` are ignored, so a repo manifest kept in your dotfiles can double as the registry: set
`AI_MEMORY_PROJECTS` to its path.

## Daily flow
- The model reads `state.md` at start. You keep it short; stable content goes to `architecture.md`,
  closed items to `decisions.md`.
- The model **does not write** to those files. What it proposes lands in `pending/` (git-ignored).
- You review and promote: `tools/promote.sh my-app state` (or `decisions`), which runs `sanitize.py`
  and checks the token limit before appending anything. `--clear` empties `pending/`.
- Commit in the memory repo → the hook runs `gitleaks`, `sanitize.py` and `check-size.sh` on what is *staged*.
- On another machine: `git pull` the memory repo; the next session already sees it.

## Other clients
- **Antigravity CLI (`agy`)**: `install.sh` detects it and writes `~/.gemini/GEMINI.md` (includes
  `@[…](…)`), the permissions in `~/.gemini/antigravity-cli/settings.json` and the hook in
  `~/.gemini/config/hooks.json`. `new-project.sh` leaves a `GEMINI.md` (or `.agents/rules/ai-memory.md`
  if the team already has one) in the work repo, excluded from git. Details in `settings/README.md`.
- **OpenCode / Codex / Aider** do not resolve `@path`: use `tools/build.sh <p>` to generate a flat
  `<data>/build/<p>/AGENTS.md` (or `new-project.sh --agents`).
- **Ollama / LM Studio / any OpenAI-compatible endpoint**: `tools/ai "question"` loads the current
  project's bundle as the system prompt. Variables: `AI_ENDPOINT`, `AI_MODEL`, `AI_API_KEY_VAR`.
- **Claude app (web/desktop)**: does not read these files. Paste `global/AGENTS.md` into a Project's
  instructions if you want it there.

## Token limits
`global/AGENTS.md` 400 · `project-memories/*/AGENTS.md` 800 · `state.md` 1,500 · everything else 3,000.
With 8K-context local models these limits matter more than with Claude or Gemini.

## Security
Three layers: what is versioned (rules, architecture with aliases, in the private memory repo), what is
local per machine (`~/.config/ai-memory/`, `profile.private.md`) and secrets (Keychain, environment
variables). The repos name variables, never their values. Details and the leak procedure in
[docs/security.md](docs/security.md).

## Next phases (not implemented)
Minimal MCP `propose_memory`/`search_memory`, real LiteLLM gateway, local-embeddings index
regenerated from the Markdown.
