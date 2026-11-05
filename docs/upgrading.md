# Upgrading from ai-memory

The tool was called ai-memory before v1.0.0. On a machine installed with the old name, run the old
copy's `update.sh` once (`~/.local/share/ai-memory/tools/update.sh`); the new `install.sh` then:
- moves `~/.config/ai-memory/` to `~/.config/cairn/` (the `AI_MEMORY_PROJECTS_DATA` line in its `env`
  is still read and is rewritten as `CAIRN_DATA` on the next `--data`);
- creates the installed copy in `~/.local/share/cairn` and points every client hook there; delete
  `~/.local/share/ai-memory` once `cairn doctor` passes;
- replaces the hooks and the `CLAUDE.md`/`GEMINI.md` blocks marked `ai-memory` instead of adding new ones;
- offers migration `003-rename-cairn.sh` for the memory repo (`.ai-memory-layout` → `.cairn-layout`,
  `{{AI_MEMORY_*}}` placeholders and `# ai-memory` markers in `settings/`); commit it afterwards.

Then run `cairn project sync` (or `cairn project add` per repo) to rename the bridges in your work repos
(`.agents/rules/cairn.md`, `.github/instructions/cairn.instructions.md`), and rename `AI_MEMORY_*`
variables in your shell profile to `CAIRN_*` (the old names still work for now, with a warning).
