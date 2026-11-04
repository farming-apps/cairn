#!/usr/bin/env bash
# First install without cloning by hand. Clones the tool into the installed-copy location
# ($CAIRN_INSTALL_DIR or ~/.local/share/cairn), checks out the latest release (origin/main
# before the first one) and runs install.sh from there. Afterwards, tools/update.sh moves that copy.
#
#   curl -fsSL https://raw.githubusercontent.com/farming-apps/cairn/main/tools/bootstrap.sh | bash -s -- --data ~/cairn-data
#
# Every argument is passed to install.sh. Without --data (and with no ~/.config/cairn/env from a
# previous install) the memory repo defaults to ~/cairn-data.
#   CAIRN_REPO         tool repository to clone (default: the public GitHub repo)
#   CAIRN_INSTALL_DIR  where to install (default: ~/.local/share/cairn)
set -euo pipefail

REPO="${CAIRN_REPO:-https://github.com/farming-apps/cairn.git}"
DIR="${CAIRN_INSTALL_DIR:-$HOME/.local/share/cairn}"
DIR="${DIR/#\~/$HOME}"

say() { printf '%s\n' "$*"; }
die() { printf 'bootstrap: %s\n' "$*" >&2; exit 1; }

for t in git python3; do
  command -v "$t" >/dev/null 2>&1 \
    || die "$t is required (macOS: xcode-select --install; Debian/Ubuntu: apt install git python3)"
done

if [ -e "$DIR" ]; then
  if [ -f "$DIR/tools/install.sh" ]; then
    die "already installed at $DIR; update with: $DIR/tools/update.sh (or re-run $DIR/tools/install.sh)"
  fi
  die "$DIR exists and is not a cairn install; move it or set CAIRN_INSTALL_DIR"
fi

args=("$@")
has_data=0
for a in ${args[@]+"${args[@]}"}; do
  case "$a" in --data|--data=*) has_data=1 ;; esac
done
if [ "$has_data" -eq 0 ] && [ ! -f "$HOME/.config/cairn/env" ]; then
  args+=(--data "$HOME/cairn-data")
fi

say "bootstrap: cloning $REPO into $DIR"
mkdir -p "$(dirname "$DIR")"
git clone --quiet "$REPO" "$DIR" || die "git clone failed; check the network and the URL ($REPO)"

ref="$(git -C "$DIR" tag -l 'v[0-9]*' --sort=-v:refname | head -1)"
[ -n "$ref" ] || ref="origin/main"
git -C "$DIR" checkout --quiet --detach "$ref"
say "bootstrap: $DIR at $ref ($(git -C "$DIR" rev-parse --short HEAD))"

exec bash "$DIR/tools/install.sh" ${args[@]+"${args[@]}"}
