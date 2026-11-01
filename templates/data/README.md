# ai-memory data

Private memory read by the AI clients on every machine. Managed with the `ai-memory` tool
(`tools/install.sh --data <this path>`), which links it into Claude Code, Antigravity CLI and
GitHub Copilot CLI and installs the pre-commit barrier (gitleaks + sanitize + size).

```
global/            rules for every session (AGENTS.md ≤ 400 tokens) + private profile (not versioned)
projects/  one folder per work repo: AGENTS.md · state.md · architecture.md · decisions.md · memory/
skills/            shared skills (<skill>/SKILL.md) linked into every client
prompts/           reusable prompts
presets/           which model for which task, no keys
mcp/servers.json   MCP servers for every client (install.sh --module mcp); ${VAR} references, no values
settings/          client preferences (defaultMode, statusLine, attribution, extra deny/ask); added to the
                   tool's policy/ floor, never replacing it. Edit by hand: models are denied writing here
gateway/           LiteLLM config for phase 2 (os.environ/... only)
build/             generated bundles (ignored)
```
The repo names variables, never their values. Nothing written by a model lands outside `memory/`.
