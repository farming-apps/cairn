# MCP servers

One catalog, `<data>/mcp/servers.json`, describes the MCP servers you want everywhere; `cairn install
--module mcp` translates it into each installed client and `cairn doctor --module mcp` reports drift.
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

- Only servers cairn created are updated or removed (their names live in
  `~/.config/cairn/mcp-managed.json`); yours are kept, and a catalog name that collides with one
  of them is skipped with a warning. Every write leaves a `.bak.<timestamp>`.
- Secret-looking `env`/`headers` values must be `${VAR}` references and URLs must not carry
  credentials, or the render fails. Values are never resolved: each client expands the reference
  at start-up, so export the variable (or let your secrets resolver do it). Check that your client
  version expands `${VAR}` in that file before relying on it.
- Packages started with `npx`/`uvx`/`bunx`/`pnpm dlx` must be pinned (`pkg@1.2.3`); unpinned ones
  are warned, since an MCP server runs with your user's permissions.
- The agents cannot write these files themselves: they are in the guard's policy list and the
  `deny` rules (`.mcp.json` inside a project still asks).
