#!/usr/bin/env bash
# Updates this tool to the latest release (git tag vX.Y.Z) and re-runs install.sh so client hooks,
# settings and skills match the new version. The memory repository is never committed to: pending
# layout migrations (migrations/NNN-*.sh) only run after asking, and their changes stay unstaged.
#
# Usage: update.sh [--check] [--to vX.Y.Z] [--channel release|main] [--yes] [--dry-run]
#   --check            only report whether an update exists (used by doctor.sh); never changes anything
#   --to vX.Y.Z        install that exact release (pin or roll back)
#   --channel main     follow the tip of origin/main instead of releases (for testers)
#   --yes              do not ask before updating, migrating or installing missing tools
#   --dry-run          show what would be done
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CHECK=0; YES=0; DRY=0; TO=""; CHANNEL=release; POST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check)     CHECK=1; shift ;;
    --to)        TO="${2:-}"; shift 2 ;;
    --to=*)      TO="${1#*=}"; shift ;;
    --channel)   CHANNEL="${2:-}"; shift 2 ;;
    --channel=*) CHANNEL="${1#*=}"; shift ;;
    --yes)       YES=1; shift ;;
    --dry-run)   DRY=1; shift ;;
    --post-update) POST=1; shift ;;   # internal: second phase, run by the NEW version of this script
    -h|--help)   awk 'NR>1 && /^set -euo pipefail/{exit} NR>1{print}' "$0"; exit 0 ;;
    *)           echo "update: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$CHANNEL" in release|main) ;; *) echo "update: --channel must be 'release' or 'main'" >&2; exit 2 ;; esac

say() { printf '%s\n' "$*"; }
confirm() { # question -> 0 to proceed
  [ "$YES" -eq 1 ] && return 0
  [ -t 0 ] || { say "  no terminal to ask; re-run with --yes"; return 1; }
  printf '%s [y/N] ' "$1"; read -r reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
g() { git -C "$ROOT" "$@"; }

# --- phase 2: runs from the freshly checked-out version --------------------------------------------
if [ "$POST" -eq 1 ]; then
  say "ai-memory $(tool_version) at $ROOT"
  if data_is_separate && [ -d "$DATA" ]; then
    layout="$(data_layout)"
    if [ "$layout" -gt "$DATA_LAYOUT_SUPPORTED" ]; then
      say "update: memory repo layout $layout is newer than this version supports ($DATA_LAYOUT_SUPPORTED); install a newer release" >&2
      exit 1
    fi
    for m in "$ROOT"/migrations/[0-9][0-9][0-9]-*.sh; do
      [ -f "$m" ] || continue
      n="$(basename "$m" | cut -c1-3)"; n=$((10#$n))
      [ "$n" -gt "$layout" ] && [ "$n" -le "$DATA_LAYOUT_SUPPORTED" ] || continue
      say "migration $(basename "$m") on $DATA (changes stay unstaged; review with git status and commit)"
      if [ "$DRY" -eq 1 ]; then say "  + bash $m $DATA"; continue; fi
      confirm "  run it?" || { say "update: migration declined; the memory repo stays at layout $layout" >&2; exit 1; }
      bash "$m" "$DATA"
    done
  fi
  install_args=()
  [ "$YES" -eq 1 ] && install_args+=(--yes)
  [ "$DRY" -eq 1 ] && install_args+=(--dry-run)
  exec "$ROOT/tools/install.sh" ${install_args[@]+"${install_args[@]}"}
fi

# --- phase 1: pick the target and check it out -----------------------------------------------------
g rev-parse --git-dir >/dev/null 2>&1 || { say "update: $ROOT is not a git clone; reinstall with git clone" >&2; exit 1; }

if ! g fetch --tags --quiet origin 2>/dev/null; then
  if [ "$CHECK" -eq 1 ]; then say "update: could not reach origin (offline?); skipped"; exit 0; fi
  say "update: git fetch failed; check the network and your access to the remote" >&2; exit 1
fi

if [ -n "$TO" ]; then
  g rev-parse -q --verify "refs/tags/$TO" >/dev/null || { say "update: no such release: $TO" >&2; exit 1; }
  target="$TO"
elif [ "$CHANNEL" = main ]; then
  target="origin/main"
else
  target="$(g tag -l 'v[0-9]*' --sort=-v:refname | head -1)"
  [ -n "$target" ] || { say "update: no releases yet (no v* tags); use --channel main" >&2; exit 1; }
fi

current="$(g describe --tags --exact-match HEAD 2>/dev/null || g rev-parse --short HEAD)"
head_sha="$(g rev-parse HEAD)"; target_sha="$(g rev-parse "$target^{commit}")"
if [ "$head_sha" = "$target_sha" ]; then
  say "ai-memory is up to date ($current, version $(tool_version))"
  exit 0
fi
if [ "$CHECK" -eq 1 ]; then
  say "update available: $current -> $target   (run tools/update.sh)"
  exit 0
fi

# Never overwrite work: refuse on a dirty tree or on a branch with commits that are not on origin.
if [ -n "$(g status --porcelain --untracked-files=no)" ]; then
  say "update: $ROOT has uncommitted changes. This looks like a development clone;" >&2
  say "        install releases in a separate clone (see README, 'Install a release')." >&2
  exit 1
fi
branch="$(g symbolic-ref -q --short HEAD || true)"
if [ -n "$branch" ] && [ -n "$(g rev-list "origin/main..HEAD" 2>/dev/null | head -1)" ]; then
  say "update: branch '$branch' has commits that are not on origin/main; refusing to move it" >&2
  exit 1
fi

say "ai-memory: $current -> $target"
if g merge-base --is-ancestor HEAD "$target_sha"; then
  g log --oneline --no-decorate "HEAD..$target_sha" | head -30 | sed 's/^/  /'
else
  say "  (this moves to an older or diverging version)"
fi
if [ "$DRY" -eq 1 ]; then
  say "  + git checkout $target; then tools/update.sh --post-update"
  exec "$ROOT/tools/update.sh" --post-update --dry-run $([ "$YES" -eq 1 ] && echo --yes)
fi
confirm "update now?" || { say "cancelled"; exit 0; }

if [ "$CHANNEL" = main ] && [ -z "$TO" ]; then
  g checkout -q main 2>/dev/null || g checkout -q -b main origin/main
  g merge -q --ff-only origin/main
else
  g checkout -q --detach "$target"
fi

# Hand over to the new version of this script, so its migrations and install.sh are the ones that run.
post_args=(--post-update)
[ "$YES" -eq 1 ] && post_args+=(--yes)
if grep -q -- '--post-update' "$ROOT/tools/update.sh" 2>/dev/null; then
  exec "$ROOT/tools/update.sh" "${post_args[@]}"
fi
exec "$ROOT/tools/install.sh" $([ "$YES" -eq 1 ] && echo --yes)   # target predates update.sh
