# ai-memory

Portable AI memory and configuration across machines and across models (Claude Code, Antigravity CLI,
GitHub Copilot CLI, local models), with nothing sensitive travelling along. Everything is Markdown
versioned in Git; clients load it at startup via `@path` imports, so a new chat amounts to reading it.

Two repositories:
- **this one, the tool** (public): scripts, client policies, hooks and the skeleton of a memory repo.
- **your memory repo** (private): `global/`, `projects/`, `skills/`, `prompts/`, `presets/`.
  Created from `templates/data/` by `install.sh --data <path>`; the tools find it through
  `AI_MEMORY_PROJECTS_DATA` or `~/.config/ai-memory/env`. Without either, memory is expected inside this repo
  (single-repo layout, as in early versions).

## Layout
```
templates/data/    skeleton of the memory repo (copied by install.sh --data):
  global/            rules for every session (AGENTS.md ≤ 400 tokens) + private profile (not versioned)
  projects/  <p>/AGENTS.md (conventions) · state.md (≤ 1,500) · architecture.md · decisions.md · memory/ · plans/ · skills/
  skills/            shared global skills (<skill>/SKILL.md) linked into Claude, Agy and Copilot
  prompts/           reusable prompts
  presets/           which model for which task, no keys
  mcp/servers.json   MCP server catalog, rendered into every installed client (no secret values)
  settings/<client>/ your client preferences (defaultMode, statusLine, attribution, extra deny/ask)
  gateway/           LiteLLM config for phase 2 (os.environ/... only)
templates/         templates for local machine files (forbidden-terms.txt, projects.yml)
policy/claude/     Claude Code security floor: deny/ask permissions + guard-bash hook
policy/agy/        Antigravity CLI (agy) security floor: permissions + guard-bash hook
policy/copilot/    GitHub Copilot CLI security floor: guard-bash hook + sandbox
policy/vscode/     VS Code: built-in Copilot off in .env, credentials and other sensitive file types
tools/             install · doctor · projects · new-project · promote · build · ai · sanitize · check-size · guard-bash · merge-settings · render-mcp · lib
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

Client hooks store an absolute path, so they must point at a **release** in a stable place you do
not develop in; otherwise uncommitted work in a dev clone would run live in every session.
`install.sh` takes care of that from any clone:
```sh
git clone <tool-repo> ~/dev/ai-memory                    # your clone: develop here
~/dev/ai-memory/tools/install.sh --data ~/ai-memory-data # creates the memory repo if missing, or clone yours first
~/dev/ai-memory/tools/doctor.sh                          # --module hardening,memory,mcp,projects (all by default)
```
The first run checks out the latest release tag (`origin/main` before the first release) in a detached
worktree at `~/.local/share/ai-memory` (`AI_MEMORY_INSTALL_DIR` overrides it) and re-runs itself from
there. Hooks, the status line and the memory repo's pre-commit hook point at that installed copy, so
switching branches in your clone does not change them. Later runs reuse it as it is; only `update.sh`
moves it. A plain `git clone --branch vX.Y.Z <tool-repo> ~/.local/share/ai-memory` works too.
`--dev` skips the installed copy and wires the clients to the clone as it is, to try a branch; the
single-repo layout (memory inside the clone) always installs this way. `doctor.sh` fails if the
installed copy has local changes.

### Update
```sh
tools/update.sh            # latest release: checkout the tag, then re-run install.sh
tools/update.sh --check    # only report (doctor.sh does this too)
tools/update.sh --to v0.1.0  # pin or roll back
tools/update.sh --channel main  # follow main instead of releases
```
Run from your clone or from the installed copy: when the installed copy exists, that is what moves.
`update.sh` refuses to move a clone with uncommitted changes or local commits. Your memory repo is
never committed to: skeleton files added by a new release are listed and copied only if you accept,
and layout migrations (`migrations/NNN-*.sh`, see `migrations/README.md`) run only after asking. Both
leave changes unstaged for you to review with `git status` and commit. The layout of the memory repo
is the integer in `<data>/.ai-memory-layout` (missing means 1); a tool that is too old for it stops.

### Releasing
Commits to `main` follow [Conventional Commits](https://www.conventionalcommits.org): `fix:` → patch,
`feat:` → minor, `feat!:` or `BREAKING CHANGE:` → major. The `release` workflow (release-please) keeps
a release PR open; merging it bumps `VERSION`, updates `CHANGELOG.md` and tags `vX.Y.Z`, which is what
`update.sh` installs.

`--data` is remembered in `~/.config/ai-memory/env`; later runs do not need it. On a second machine,
clone your private memory repo first and point `--data` at it.

None of the three supported AI clients (**Claude Code**, **Antigravity CLI `agy`**, **GitHub Copilot CLI `copilot`**) is mandatory: `install.sh` and `doctor.sh` auto-detect which ones are installed on the machine and skip the rest without failing. You can also run a single module with `--module hardening`, `--module memory`, `--module mcp`, or `--module projects`.
`install.sh` is idempotent and prints every step. It first checks the tools: `gitleaks` (the hook
blocks commits without it) and `jq` (status line) are offered for install with Homebrew, asking
before each one; without Homebrew it tells you what to install and goes on. Then it writes an import
block into `~/.claude/CLAUDE.md` (and `~/.gemini/GEMINI.md` if you use Gemini), enables the hooks in
both repos, creates `<data>/global/profile.private.md` and `~/.config/ai-memory/forbidden-terms.txt`,
and merges `policy/claude/settings.json` + `<data>/settings/claude/settings.json` into `~/.claude/settings.json` while keeping yours (`theme`,
`model`, `permissions.allow`, your own hooks). In a new session, check with `/context` that the files
appear under *Memory files* and with `/hooks` that `guard-bash` is active.

## Environment variables
All optional. Export them in `~/.zshrc` or similar; no script loads `.env.example`.

| Variable | Read by | Purpose | Default |
|---|---|---|---|
| `AI_MEMORY_PROJECTS_DATA` | every script (via `tools/lib.sh`), `tools/ai` | Path of the memory repo: `global/`, `projects/`, `skills/` | the `AI_MEMORY_PROJECTS_DATA` line in `$AI_MEMORY_LOCAL/env` (written by `install.sh --data`), else this repo |
| `AI_MEMORY_INSTALL_DIR` | `tools/install.sh`, `tools/doctor.sh` (via `tools/lib.sh`) | Installed copy (detached worktree at a release) that client hooks point to | `~/.local/share/ai-memory` |
| `AI_MEMORY_LOCAL` | every script | Per-machine config dir, never versioned: `forbidden-terms.txt`, `env`, `projects.yml` | `~/.config/ai-memory` |
| `AI_MEMORY_PROJECTS` | `projects.sh`, `doctor.sh` | Path of the projects registry | `$AI_MEMORY_LOCAL/projects.yml` |
| `AI_MEMORY_PROJECTS_ENC` | `projects.sh encrypt/decrypt` | Default path of the encrypted registry backup | none (pass it as an argument) |
| `AI_MEMORY_GUARD_NEUTRAL` | `guard-bash.py` (agy only) | Decision returned to agy when the guard has no objection | `ask` |
| `AI_MEMORY_CHARS_PER_TOKEN` | `check-size.sh` | Characters per token for the size estimate | `4` |
| `AI_ENDPOINT` | `tools/ai` | OpenAI-compatible base URL | `$OLLAMA_HOST/v1`, else `http://localhost:11434/v1` |
| `AI_MODEL` | `tools/ai` | Model name on the server | required |
| `AI_API_KEY_VAR` | `tools/ai` | NAME of the variable that holds the key, never the key itself | none |

To run the tools from any directory, point a variable of your own at this repo and call the scripts
by full path (or alias them). The scripts find `lib.sh` next to themselves, so do not symlink single
scripts into another `PATH` directory:
```sh
export AI_MEMORY_HOME=~/ai-memory          # read by no script; only for your shell
alias ai-install="$AI_MEMORY_HOME/tools/install.sh"
alias ai-doctor="$AI_MEMORY_HOME/tools/doctor.sh"
```
If you move this repo, update that variable and re-run `install.sh`: client hooks store its absolute path.

## Portable permission policy
`policy/claude/settings.json` holds what you never want any model to do on any machine:
`rm -rf` on `/`, `~` or outside the project, reading `~/.ssh`, `~/.aws` or `.env`, editing its own
`settings.json`; and what must always ask: `sudo`, `git push --force`, `git reset --hard`,
`git clean`. The prefix rules are reinforced by the `tools/guard-bash.py` hook, which analyses each
command (`rm -fr`, `rm -r -f`, `sh -c "rm -rf …"`, empty variables, `find -delete`, `curl | sh`).
Your memory repo's `settings/` can add rules and preferences but never remove floor rules, and
models cannot edit either directory. Details, rationale and how to change it in [policy/README.md](policy/README.md).

## MCP servers
One catalog, `<data>/mcp/servers.json`, describes the MCP servers you want everywhere; `install.sh
--module mcp` translates it into each installed client and `doctor.sh --module mcp` reports drift.
```json
{"servers": {
  "github": {"url": "https://host/mcp", "headers": {"Authorization": "Bearer ${GITHUB_MCP_TOKEN}"}},
  "fs": {"command": "npx", "args": ["-y", "@scope/pkg@1.2.3", "/path"], "clients": ["claude", "vscode"]}
}}
```
| Client | Written to |
|---|---|
| Claude Code | user scope, via `claude mcp add-json -s user` / `claude mcp remove` |
| Antigravity CLI | `~/.gemini/config/mcp_config.json` (`mcpServers`, remote as `serverUrl`) |
| Copilot CLI | `~/.copilot/mcp-config.json` (`mcpServers`, `type: local\|http`, `tools: ["*"]`) |
| VS Code | `<user dir>/mcp.json` (`servers`; references become `${env:VAR}`) |

- Only servers ai-memory created are updated or removed (their names live in
  `~/.config/ai-memory/mcp-managed.json`); yours are kept, and a catalog name that collides with one
  of them is skipped with a warning. Every write leaves a `.bak.<timestamp>`.
- Secret-looking `env`/`headers` values must be `${VAR}` references and URLs must not carry
  credentials, or the render fails. Values are never resolved: each client expands the reference
  at start-up, so export the variable (or let your secrets resolver do it). Check that your client
  version expands `${VAR}` in that file before relying on it.
- Packages started with `npx`/`uvx`/`bunx`/`pnpm dlx` must be pinned (`pkg@1.2.3`); unpinned ones
  are warned, since an MCP server runs with your user's permissions.
- The agents cannot write these files themselves: they are in the guard's policy list and the
  `deny` rules (`.mcp.json` inside a project still asks).

## Connect a project
```sh
tools/new-project.sh my-app ~/dev/my-app
# or track & sync multiple projects across sections from ~/.config/ai-memory/projects.yml:
tools/projects.sh list
tools/projects.sh sync
```
Creates `<data>/projects/my-app/` from the template and prepares the work repo for **Claude Code**, **Antigravity CLI (`agy`)** and **GitHub Copilot CLI (`copilot`)** at the same time — all excluded via `.git/info/exclude` so `git status` stays clean:
- `CLAUDE.local.md` and `.claude/settings.local.json` (`autoMemoryDirectory` → `projects/my-app/memory/`)
- `GEMINI.md` (or `.agents/rules/ai-memory.md` if the repo already tracks `GEMINI.md`)
- `.github/instructions/ai-memory.instructions.md` → `<data>/build/my-app/copilot.instructions.md`
- `.claude/skills/*` and `.agents/skills/*` → shared skills from `skills/` and `projects/my-app/skills/`
With `--agents` it also links a flat `AGENTS.md` for OpenCode/Codex/Aider. Re-running it (or
`projects.sh sync`) after moving the memory repo repairs the bridges: imports to the old path are dropped.
`projects.yml` fields: `path`, `status` (`active` is synced; `paused`/`archived` are listed only), `agents`,
`memory: false` (registered repo with no ai-memory bridges or project memory) and `notes`. Unknown keys such
as `remote:` are ignored, so a repo manifest kept in your dotfiles can double as the registry: set
`AI_MEMORY_PROJECTS` to its path.

**Workspaces.** When you open the client in a plain folder that holds several repos, the client reads
the bridges and `autoMemoryDirectory` of that folder, not of the repos inside it. Connect the folder
itself with one memory for all of them:
```sh
tools/new-project.sh my-course ~/dev/my-course --workspace
```
or in `projects.yml` add `kind: workspace` to its entry, and `memory: false` to the inner repos you only
use from there. The bridges are the same; step 8 is skipped because a folder outside git has nothing to
exclude. If you later work inside one of those repos directly, drop its `memory: false` and sync.

## Daily flow
- The model reads `state.md` at start. You keep it short; stable content goes to `architecture.md`,
  closed items to `decisions.md`.
- The model **does not write** to those files. What it proposes lands in `memory/` (git-ignored).
- You review and promote: `tools/promote.sh my-app state` (or `decisions`), which runs `sanitize.py`
  and checks the token limit before appending anything. `--clear` empties `memory/`.
- Commit in the memory repo → the hook runs `gitleaks`, `sanitize.py` and `check-size.sh` on what is *staged*.
- On another machine: `git pull` the memory repo; the next session already sees it.

## Other clients
- **Antigravity CLI (`agy`)**: `install.sh` detects it and writes `~/.gemini/GEMINI.md` (includes
  `@[…](…)`), the permissions in `~/.gemini/antigravity-cli/settings.json` and the hook in
  `~/.gemini/config/hooks.json`. `new-project.sh` leaves a `GEMINI.md` (or `.agents/rules/ai-memory.md`
  if the team already has one) in the work repo, excluded from git. Details in `policy/README.md`.
- **OpenCode / Codex / Aider** do not resolve `@path`: use `tools/build.sh <p>` to generate a flat
  `<data>/build/<p>/AGENTS.md` (or `new-project.sh --agents`).
- **Ollama / LM Studio / any OpenAI-compatible endpoint**: `tools/ai "question"` loads the current
  project's bundle as the system prompt. Variables: `AI_ENDPOINT`, `AI_MODEL`, `AI_API_KEY_VAR`.
- **Claude app (web/desktop)**: does not read these files. Paste `global/AGENTS.md` into a Project's
  instructions if you want it there.

## Token limits
`global/AGENTS.md` 400 · `projects/*/AGENTS.md` 800 · `state.md` 1,500 · everything else 3,000.
With 8K-context local models these limits matter more than with Claude or Gemini.

## Security
Three layers: what is versioned (rules, architecture with aliases, in the private memory repo), what is
local per machine (`~/.config/ai-memory/`, `profile.private.md`) and secrets (Keychain, environment
variables). The repos name variables, never their values. Details and the leak procedure in
[docs/security.md](docs/security.md).

## Next phases (not implemented)
Per-project MCP (`projects/<p>/mcp.json` → `.mcp.json`), minimal MCP `propose_memory`/`search_memory`, real LiteLLM gateway, local-embeddings index
regenerated from the Markdown.
