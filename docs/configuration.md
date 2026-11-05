# Configuration

## Environment variables
All optional. Export them in `~/.zshrc` or similar. The pre-rename `AI_MEMORY_*` names
(`AI_MEMORY_PROJECTS_DATA` for `CAIRN_DATA`, the rest one to one) are still read, with a warning.

| Variable | Read by | Purpose | Default |
|---|---|---|---|
| `CAIRN_DATA` | every script (via `tools/lib.sh`), `tools/ai` | Path of the memory repo: `global/`, `projects/`, `skills/` | the `CAIRN_DATA` line in `$CAIRN_LOCAL/env` (written by `install.sh --data`), else this repo |
| `CAIRN_INSTALL_DIR` | `tools/install.sh`, `tools/doctor.sh` (via `tools/lib.sh`) | Installed copy (detached worktree at a release) that client hooks point to | `~/.local/share/cairn` |
| `CAIRN_BIN_DIR` | `tools/install.sh` | Where the `cairn` command is linked | `~/.local/bin` |
| `CAIRN_LOCAL` | every script | Per-machine config dir, never versioned: `forbidden-terms.txt`, `env`, `projects.yml` | `~/.config/cairn` |
| `CAIRN_PROJECTS` | `projects.sh`, `doctor.sh` | Path of the projects registry | `$CAIRN_LOCAL/projects.yml` |
| `CAIRN_PROJECTS_ENC` | `projects.sh encrypt/decrypt` | Default path of the encrypted registry backup | none (pass it as an argument) |
| `CAIRN_GUARD_NEUTRAL` | `guard-bash.py` (agy only) | Decision returned to agy when the guard has no objection | `ask` |
| `CAIRN_CHARS_PER_TOKEN` | `check-size.sh` | Characters per token for the size estimate | `4` |
| `AI_ENDPOINT` | `tools/ai` | OpenAI-compatible base URL | `$OLLAMA_HOST/v1`, else `http://localhost:11434/v1` |
| `AI_MODEL` | `tools/ai` | Model name on the server | required |
| `AI_API_KEY_VAR` | `tools/ai` | NAME of the variable that holds the key, never the key itself | none |

## Projects registry (`projects.yml`)
```yaml
<section>:
  <project>:
    path: ~/dev/my-app
    status: active        # active is synced; paused/archived are listed only
    agents: true          # also link a flat AGENTS.md (OpenCode/Codex/Aider)
    memory: false         # registered repo with no cairn bridges or project memory
    kind: workspace       # a plain folder holding several repos, one memory for all
    notes: free text
```
Unknown keys such as `remote:` are ignored, so a repo manifest kept in your dotfiles can double as the
registry: set `CAIRN_PROJECTS` to its path.
