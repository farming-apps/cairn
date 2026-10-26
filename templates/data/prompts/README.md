# Reusable prompts

One `.md` file per prompt. No project-specific data or secrets: they go through the same
hook as the rest of the repository.

Naming convention: `<scope>-<action>.md`, e.g. `code-review.md`, `adr-write.md`.
Suggested header: what it is for, which variables it expects (`{{file}}`, `{{goal}}`) and an example.
