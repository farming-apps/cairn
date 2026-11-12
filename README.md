# cairn

Portable AI memory and configuration across machines and across models (Claude Code, Antigravity CLI,
GitHub Copilot CLI, local models), with nothing sensitive travelling along. Everything is Markdown
versioned in Git; clients load it at startup via `@path` imports, so a new chat amounts to reading it.

Two repositories:
- **this one, the tool** (public): scripts, client policies, hooks and the skeleton of a memory repo.
- **your memory repo** (private): `global/`, `projects/`, `skills/`, `prompts/`, `presets/`, `mcp/`,
  `settings/`. Created from `templates/data/` by `install.sh --data <path>` and found through
  `CAIRN_DATA` or `~/.config/cairn/env`.

## Layout
```
templates/data/   skeleton of the memory repo (global/, projects/<p>/, skills/, mcp/, settings/ …)
templates/        per-machine files (forbidden-terms.txt, projects.yml)
policy/<client>/  security floor per client: permissions + guard-bash hook
tools/            the scripts behind `cairn`
.githooks/        pre-commit: gitleaks + sanitize + size (shared by both repos)
docs/             details linked at the end of this file
```
`AGENTS.md` is the single source, plain Markdown; `CLAUDE.md` (`@AGENTS.md`) and `GEMINI.md`
(`@[AGENTS](AGENTS.md)`) only import it.

## Install
Requirements: `git` and `python3` (3.9+). On macOS both come with `xcode-select --install`.
```sh
curl -fsSL https://raw.githubusercontent.com/farming-apps/cairn/main/tools/bootstrap.sh | bash -s -- --data ~/cairn-data
cairn doctor
```
`bootstrap.sh` clones the tool into `~/.local/share/cairn` at the latest release and runs `install.sh`,
which links `cairn` into `~/.local/bin`. `--data` creates the memory repo if missing (on a second
machine, clone yours there first) and is remembered for later runs. To review the script first,
download it, read it and run it with `bash bootstrap.sh --data ~/cairn-data`.

To update, run `cairn update`; running the same one-liner again does the same. The installed copy
is generated: if something changed it by hand, the update restores it and saves the diff to
`~/.config/cairn/`.

`install.sh` is idempotent and asks before installing anything. It detects which clients are present
(none is mandatory), writes the import block into each client's global instructions, enables the
pre-commit hooks, and merges the security floor into each client's settings while keeping yours.
`--module hardening|memory|mcp|projects` runs a single part. In Claude Code, check with `/context`
and `/hooks` that the memory files and `guard-bash` are active.

| Command | Does |
|---|---|
| `cairn install` · `cairn doctor` · `cairn update` | prepare, check, update this machine |
| `cairn project add <name> [repo]` | create a project memory and connect a work repo |
| `cairn project list\|sync\|encrypt\|decrypt` | the projects registry (`~/.config/cairn/projects.yml`) |
| `cairn promote <project> state\|decisions` | promote proposals from `memory/` |
| `cairn build <project>` · `cairn ask "question"` | flat bundles · ask a local model |

## Connect a project
```sh
cairn project add my-app ~/dev/my-app     # one repo
cairn project sync                        # every active project in projects.yml
cairn project list
```
Prepares the work repo for Claude Code, Antigravity CLI and Copilot CLI at once (`CLAUDE.local.md`,
`GEMINI.md`, `.github/instructions/cairn.instructions.md`, shared skills), all excluded through
`.git/info/exclude` so `git status` stays clean. `--agents` also links a flat `AGENTS.md` for
OpenCode/Codex/Aider. Re-running it after moving the memory repo repairs the bridges.

For a plain folder that holds several repos, use `--workspace` (or `kind: workspace` in
`projects.yml`) to give the whole folder one memory, and `memory: false` on the inner repos.

## Daily flow
- The model reads `state.md` at start. Keep it short; stable content goes to `architecture.md`,
  closed items to `decisions.md`.
- The model **does not write** to those files. Its proposals land in `memory/` (git-ignored); you
  review them and run `cairn promote my-app state` (sanitizes and checks size; `--clear` empties `memory/`).
- Plans stay in the client; only a pending one is saved to `projects/<p>/plans/` so it travels.
- Commit in the memory repo → the hook runs `gitleaks`, `sanitize.py` and `check-size.sh`.
- On another machine: `git pull` the memory repo; the next session already sees it.

Token limits: `global/AGENTS.md` 400 · `projects/*/AGENTS.md` 800 · `state.md` 1,500 · rest 3,000.

## Other clients
- **OpenCode / Codex / Aider** do not resolve `@path`: `cairn build <p>` generates a flat `AGENTS.md`.
- **Ollama / LM Studio / OpenAI-compatible**: `cairn ask "question"` uses the project bundle as system
  prompt (`AI_ENDPOINT`, `AI_MODEL`, `AI_API_KEY_VAR`).
- **Claude app (web/desktop)**: does not read these files; paste `global/AGENTS.md` into a Project.

## Security
A portable floor in `policy/` blocks what no model should do anywhere (`rm -rf` outside the project,
reading `~/.ssh` or `.env`, editing its own settings) and makes `sudo`, force-push and hard resets ask;
the `guard-bash` hook analyses each command. Your `settings/` adds rules and removes floor rules only
through an explicit `floorRemove`. The repos name secret variables, never their values.

## More
- [docs/configuration.md](docs/configuration.md): environment variables and `projects.yml` fields
- [docs/mcp.md](docs/mcp.md): one MCP catalog rendered into every client
- [docs/security.md](docs/security.md): rules and what to do if something leaks
- [policy/README.md](policy/README.md): the permission floor per client
- [docs/development.md](docs/development.md): dev clones, updates and releases
- [docs/upgrading.md](docs/upgrading.md): upgrading from ai-memory (pre-1.0)

Not implemented yet: per-project MCP, a minimal `propose_memory`/`search_memory` MCP, a LiteLLM
gateway and a local-embeddings index.
