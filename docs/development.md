# Development, updates and releases

## Developing on the tool
Client hooks store an absolute path, so they must not point at a clone you develop in; otherwise
uncommitted work would run live in every session. From a dev clone, `install.sh` takes care of that:
```sh
git clone <tool-repo> ~/dev/cairn
~/dev/cairn/tools/install.sh --data ~/cairn-data
```
When there is no installed copy yet, it is created as a detached `git worktree` of the clone (latest
release tag, or `origin/main` before the first one) and `install.sh` re-runs itself from there. That
worktree depends on the clone, so use `bootstrap.sh` on machines where you do not develop. Later runs
reuse the installed copy as it is. `--dev` skips it and wires the clients to the clone as it is, to try
a branch; the single-repo layout (memory inside the clone) always installs this way.

## Updating
```sh
cairn update                   # latest release: checkout the tag, then re-run install.sh
cairn update --check           # only report (doctor.sh does this too)
cairn update --to v0.1.0       # pin or roll back
cairn update --channel main    # follow main instead of releases
```
The first install is `bootstrap.sh` (or `install.sh`), not `update.sh`. Run `update.sh` from the
installed copy or from a dev clone: when the installed copy exists, that is what moves.
`update.sh` refuses to move a clone with uncommitted changes or local commits. Your memory repo is
never committed to: skeleton files added by a new release are listed and copied only if you accept,
and layout migrations (`migrations/NNN-*.sh`, see [migrations/README.md](../migrations/README.md)) run
only after asking. Both leave changes unstaged for you to review with `git status` and commit. The
layout of the memory repo is the integer in `<data>/.cairn-layout` (missing means 1); a tool that is
too old for it stops.

## Releasing
Commits to `main` follow [Conventional Commits](https://www.conventionalcommits.org): `fix:` → patch,
`feat:` → minor, `feat!:` or `BREAKING CHANGE:` → major. The `release` workflow (release-please) keeps
a release PR open; merging it bumps `VERSION`, updates `CHANGELOG.md` and tags `vX.Y.Z`, which is what
`update.sh` installs.
