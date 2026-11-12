#!/usr/bin/env bash
# Install or update without cloning by hand. On a first run it clones the tool into the installed-copy location
# ($CAIRN_INSTALL_DIR or ~/.local/share/cairn), checks out the latest release (origin/main
# before the first one) and runs install.sh from there. When it is already installed, the same
# command updates it (tools/update.sh), so the one-liner below is both install and update.
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

# Piped from curl, stdin is the script itself, so install.sh/update.sh could not ask anything:
# hand the scripts it starts the terminal when there is one (never this one: bash is still reading it).
IN=/dev/stdin
if [ ! -t 0 ] && (exec </dev/tty) 2>/dev/null; then IN=/dev/tty; fi

if [ -e "$DIR" ]; then
  if [ -f "$DIR/tools/install.sh" ]; then
    say "bootstrap: already installed at $DIR; updating it"
    upd=()   # update.sh takes --yes/--dry-run; the rest (e.g. --data) is remembered from the install
    for a in "$@"; do case "$a" in --yes|--dry-run) upd+=("$a") ;; esac; done
    exec bash "$DIR/tools/update.sh" ${upd[@]+"${upd[@]}"} <"$IN"
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

exec bash "$DIR/tools/install.sh" ${args[@]+"${args[@]}"} <"$IN"
