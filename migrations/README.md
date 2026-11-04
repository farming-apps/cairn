# Memory-repo migrations

Only needed when a release changes the layout of the memory repo in a way old data cannot be read.
Name them `NNN-short-name.sh`, where `NNN` is the layout they upgrade **to** (e.g. `002-move-presets.sh`).
Each script receives the memory repo path as `$1`, must be idempotent, must not `git add` or commit,
and must write the new number into `$1/.cairn-layout`. `tools/update.sh` runs pending ones after
asking; the user reviews `git status` in the memory repo and commits.
Bump `DATA_LAYOUT_SUPPORTED` in `tools/lib.sh` in the same commit.
