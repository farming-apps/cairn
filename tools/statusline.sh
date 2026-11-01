#!/usr/bin/env bash
# Claude Code status line. Reads the session JSON from stdin and prints two lines:
#   [Fable] ai-memory  main*  effort:high  agent:x
#   [███████░░░] 70% 140k/200k  $0.42 12m  5h 23% 7d 41%  mem: ai-memory · 2 pending · state 16d
# Context colors: green <70 %, amber >=70 %, red >=85 % (adds "⚠ compact").
# Fields missing from the JSON (cost, limits, agent...) are omitted; it never fails.
# Also serves Antigravity CLI (agy): its JSON is almost the same; only
# cost.total_usd (vs total_cost_usd) and model.effort (vs effort.level) differ, covered by fallbacks.
# Also serves GitHub Copilot CLI: there used_percentage/context_window_size are null and the live
# values are current_context_used_percentage, current_context_tokens and displayed_context_limit;
# total_input/output_tokens are session cumulative (ignored) and cost has no USD, only
# total_premium_requests (shown as "N premium"). No rate_limits, effort or agent fields.
# Configured from <data>/settings/{claude,agy,copilot}/settings.json (statusLine key) via tools/install.sh.
# Manual test:  echo '{}' | tools/statusline.sh
set -u
export LC_ALL=C
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
input="$(cat)"
command -v jq >/dev/null 2>&1 || { echo "statusline: jq missing"; exit 0; }

# A single jq call. Separator \x1f (not whitespace, so read keeps empty fields).
US=$'\x1f'
fields="$(printf '%s' "$input" | jq -r '[
  (.model.display_name // ""),
  (.workspace.current_dir // .cwd // ""),
  (.workspace.project_dir // .workspace.current_dir // .cwd // ""),
  ((.context_window.used_percentage // .context_window.current_context_used_percentage // 0) | floor),
  (.context_window.current_context_tokens
     // ((.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0))),
  (.context_window.context_window_size // .context_window.displayed_context_limit // 0),
  (.cost.total_cost_usd // .cost.total_usd // 0),
  (.cost.total_premium_requests // ""),
  (.cost.total_duration_ms // 0),
  (.effort.level // .model.effort // ""),
  ((.rate_limits.five_hour.used_percentage // null) | if . == null then "" else floor end),
  ((.rate_limits.seven_day.used_percentage // null) | if . == null then "" else floor end),
  (.agent.name // "")
] | map(tostring) | join("\u001f")' 2>/dev/null)"
[ -n "$fields" ] || { echo "statusline: unreadable JSON"; exit 0; }
IFS="$US" read -r model cur proj pct used size cost premium dur effort h5 d7 agent <<<"$fields"

RESET=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'
GREEN=$'\033[32m'; AMBER=$'\033[33m'; RED=$'\033[31m'

abbr() { # 140000 -> 140k ; 1234567 -> 1.2M ; 1000000 -> 1M
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    local d=$(( (n % 1000000) / 100000 ))
    [ "$d" -eq 0 ] && printf '%dM' $((n / 1000000)) || printf '%d.%dM' $((n / 1000000)) "$d"
  elif [ "$n" -ge 1000 ]; then printf '%dk' $(( (n + 500) / 1000 ))
  else printf '%d' "$n"; fi
}

# ---- line 1: model, folder (last component only), branch, effort, agent
l1="${BOLD}[${model:-Claude}]${RESET}"
[ -n "$cur" ] && l1="$l1 ${cur##*/}"
branch=""
if [ -n "$cur" ] && git -C "$cur" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$cur" symbolic-ref --short -q HEAD 2>/dev/null || git -C "$cur" rev-parse --short HEAD 2>/dev/null)"
  [ -n "$(git -C "$cur" status --porcelain 2>/dev/null | head -1)" ] && branch="$branch*"
fi
[ -n "$branch" ] && l1="$l1  ${DIM}$branch${RESET}"
[ -n "$effort" ] && l1="$l1  ${DIM}effort:$effort${RESET}"
[ -n "$agent" ] && l1="$l1  ${DIM}agent:$agent${RESET}"

# ---- line 2: context, cost/duration, limits, project memory
pct=${pct:-0}; [ "$pct" -gt 100 ] && pct=100
color=$GREEN; [ "$pct" -ge 70 ] && color=$AMBER; [ "$pct" -ge 85 ] && color=$RED
filled=$(( (pct + 5) / 10 )); bar=""
for ((i = 0; i < 10; i++)); do if [ "$i" -lt "$filled" ]; then bar="$bar█"; else bar="$bar░"; fi; done
ctx="${color}[$bar] ${pct}%"
[ "${size:-0}" -gt 0 ] && ctx="$ctx $(abbr "${used:-0}")/$(abbr "$size")"
[ "$pct" -ge 85 ] && ctx="$ctx ⚠ compact"
l2="$ctx${RESET}"

sess=""
case "$cost" in 0|0.0|"") ;; *) sess="$(printf '$%.2f' "$cost")" ;; esac
[ -z "$sess" ] && [ -n "$premium" ] && [ "${premium%.*}" -gt 0 ] && sess="${premium%.*} premium"
mins=$(( ${dur%.*} / 60000 ))
if [ "$mins" -ge 60 ]; then sess="$sess $((mins / 60))h$(printf '%02d' $((mins % 60)))m"
elif [ "$mins" -gt 0 ]; then sess="$sess ${mins}m"; fi
[ -n "${sess# }" ] && l2="$l2  ${DIM}${sess# }${RESET}"

lim=""
[ -n "$h5" ] && lim="5h ${h5}%"
[ -n "$d7" ] && lim="${lim:+$lim }7d ${d7}%"
[ -n "$lim" ] && l2="$l2  ${DIM}$lim${RESET}"

# Memory project: autoMemoryDirectory (written by new-project.sh) or project-memories/<repo-name>.
pdir=""
sl="$proj/.claude/settings.local.json"
if [ -n "$proj" ] && [ -f "$sl" ]; then
  amd="$(jq -r '.autoMemoryDirectory // ""' "$sl" 2>/dev/null)"
  amd="${amd/#\~/$HOME}"
  [ -n "$amd" ] && pdir="${amd%/pending}"
fi
if [ -z "$pdir" ] && [ -n "$cur" ]; then
  top="$(git -C "$cur" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$top" ] && [ -d "$PM_DIR/${top##*/}" ] && pdir="$PM_DIR/${top##*/}"
fi
mem="no memory"
if [ -n "$pdir" ] && [ -d "$pdir" ]; then
  mem="mem: ${pdir##*/}"
  set -- "$pdir"/pending/*.md
  [ -e "$1" ] && mem="$mem · $# pending"
  if [ -f "$pdir/state.md" ]; then
    mtime="$(stat -f %m "$pdir/state.md" 2>/dev/null || stat -c %Y "$pdir/state.md" 2>/dev/null || echo 0)"
    age=$(( ($(date +%s) - mtime) / 86400 ))
    [ "$mtime" -gt 0 ] && [ "$age" -gt 14 ] && mem="$mem · ${AMBER}state ${age}d${RESET}${DIM}"
  fi
fi
l2="$l2  ${DIM}$mem${RESET}"

printf '%s\n%s\n' "$l1" "$l2"
