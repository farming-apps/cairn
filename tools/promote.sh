#!/usr/bin/env bash
# Promotes what the model left in project-memories/<p>/pending/ into state.md or decisions.md.
# It is the only checkpoint for that folder: pending/ is ignored by git and the hook
# never sees it. Runs sanitize.py and checks that the destination stays within its limit.
#
# Usage: promote.sh <project> [state|decisions] [--clear] [--yes]
#   --clear  delete the .md files in pending/ after promoting them
#   --yes    do not ask for confirmation
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
project="${1:-}"; [ -n "$project" ] || { sed -n '2,9p' "$0"; exit 2; }
shift
dest_kind="state"; clear=0; yes=0
for a in "$@"; do
  case "$a" in
    state|decisions) dest_kind="$a" ;;
    --clear) clear=1 ;;
    --yes) yes=1 ;;
    *) echo "promote: unknown argument: $a" >&2; exit 2 ;;
  esac
done

pdir="$PM_DIR/$project"
pending="$pdir/pending"
dest_rel="project-memories/$project/$dest_kind.md"
dest="$DATA/$dest_rel"
[ -d "$pdir" ] || { echo "promote: $pdir does not exist" >&2; exit 1; }
[ -f "$dest" ] || { echo "promote: $dest_rel does not exist" >&2; exit 1; }

files=()
while IFS= read -r -d '' f; do files+=("$f"); done \
  < <(find "$pending" -maxdepth 2 -type f -name '*.md' -print0 2>/dev/null | sort -z)
[ ${#files[@]} -gt 0 ] || { echo "promote: pending/ is empty"; exit 0; }

echo "== 1/3 sanitize"
python3 "$ROOT/tools/sanitize.py" "${files[@]}"

echo "== 2/3 resulting size"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
{
  cat "$dest"
  printf '\n## Promoted %s\n\n' "$(date +%F)"
  for f in "${files[@]}"; do
    printf '<!-- %s -->\n' "${f#"$pending"/}"
    cat "$f"; printf '\n'
  done
} >"$tmp"
"$ROOT/tools/check-size.sh" --as "$dest_rel" "$tmp" || {
  echo "promote: the destination would exceed its limit. Summarize or archive into architecture.md/decisions.md first." >&2
  exit 1
}

echo "== 3/3 content to append to $dest_rel"
echo "--------------------------------------------------"
for f in "${files[@]}"; do printf '<!-- %s -->\n' "${f#"$pending"/}"; cat "$f"; echo; done
echo "--------------------------------------------------"
if [ "$yes" -ne 1 ]; then
  read -r -p "Append to $dest_rel? [y/N] " ans
  case "$ans" in s|S|y|Y) ;; *) echo "promote: cancelled"; exit 0 ;; esac
fi

cp "$tmp" "$dest"
if [ -d "$BUILD_DIR/$project" ]; then
  "$ROOT/tools/build.sh" "$project" >/dev/null
fi
git -C "$DATA" --no-pager diff --stat -- "$dest_rel" || true
echo "promote: appended. Edit $dest_rel if needed and commit."

if [ "$clear" -eq 1 ]; then
  rm -f "${files[@]}"
  echo "promote: pending/ cleared"
else
  echo "promote: pending/ kept (use --clear to delete it)"
fi
