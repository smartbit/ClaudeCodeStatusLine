#!/bin/bash
# Source: https://github.com/daniel3303/ClaudeCodeStatusLine v1.4.4 (MIT), adapted:
#   - all data from Claude Code's stdin JSON; no OAuth token reads, no API or GitHub calls
#   - locale-independent number parsing; decimals and day/month names follow the user's locale
#   - cache in $XDG_RUNTIME_DIR (private) instead of shared /tmp
#   - git: ahead/behind, staged+unstaged line counts vs HEAD, untracked file count
#   - session cost
# Single line: Model | dir@branch↑a↓b (+a -d) ?u | tokens (%used) | $cost | effort | 5h % @reset | 7d % @reset | version

set -f  # disable globbing

# Decimal separator for display, read from the user's locale before forcing C for parsing
decimal_point=$(locale decimal_point 2>/dev/null)
decimal_point=${decimal_point:-.}
export LC_NUMERIC=C  # printf/awk must parse "23.5" regardless of the user's locale

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ANSI colors matching oh-my-posh theme. Real escape characters, so the output is printed
# with %s and backslashes in directory names or other input are never interpreted.
blue=$'\033[38;2;0;153;255m'
orange=$'\033[38;2;255;176;85m'
green=$'\033[38;2;0;160;0m'
cyan=$'\033[38;2;46;149;153m'
red=$'\033[38;2;255;85;85m'
yellow=$'\033[38;2;230;200;0m'
purple=$'\033[38;2;167;139;250m'
white=$'\033[38;2;220;220;220m'
dim=$'\033[2m'
reset=$'\033[0m'

# Format token counts with the locale's decimal separator (e.g., 50k / 200k, 1.5m or 1,5m)
format_tokens() {
    local num=$1 formatted
    if [ "$num" -ge 1000000 ]; then
        formatted=$(awk "BEGIN {v=sprintf(\"%.1f\",$num/1000000)+0; if(v==int(v)) printf \"%dm\",v; else printf \"%.1fm\",v}")
        printf "%s" "${formatted//./$decimal_point}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

# Return color escape based on usage percentage
# Usage: usage_color <pct>
usage_color() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then echo "$red"
    elif [ "$pct" -ge 70 ]; then echo "$orange"
    elif [ "$pct" -ge 50 ]; then echo "$yellow"
    else echo "$green"
    fi
}

# Resolve config directory: CLAUDE_CONFIG_DIR (set by alias) or default ~/.claude
claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# ===== Extract data from JSON =====
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
model_name=$(echo "$model_name" | sed 's/ *(\([0-9.]*[kKmM]*\) context)/ \1/')  # "(1M context)" → "1M"

# Context window
size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

# Token usage
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

# Session cost (client-side estimate at list price): $3.05 / $3 / empty when zero
cost=$(echo "$input" | jq -r --arg dp "$decimal_point" '
    (.cost.total_cost_usd // 0) * 100 | round
    | if . <= 0 then ""
      elif . % 100 == 0 then "$\(. / 100 | floor)"
      else "$\(. / 100 | floor)\($dp)\(. % 100 | tostring | if length < 2 then "0" + . else . end)"
      end')

settings_path="$claude_config_dir/settings.json"
effort_level=""
stdin_effort=$(echo "$input" | jq -r '.effort.level // empty' 2>/dev/null)
if [ -n "$stdin_effort" ]; then
    effort_level="$stdin_effort"
elif [ -n "$CLAUDE_CODE_EFFORT_LEVEL" ]; then
    effort_level="$CLAUDE_CODE_EFFORT_LEVEL"
elif [ -f "$settings_path" ]; then
    effort_val=$(jq -r '.effortLevel // empty' "$settings_path" 2>/dev/null)
    [ -n "$effort_val" ] && effort_level="$effort_val"
fi
[ -z "$effort_level" ] && effort_level="medium"

cli_version=$(echo "$input" | jq -r '.version // empty')

# ===== Build single-line output =====
sep=" ${dim}|${reset} "
out=""
out+="${blue}${model_name}${reset}"

# Current working directory
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
if [ -n "$cwd" ]; then
    out+="${sep}${cyan}${cwd##*/}${reset}"

    # --no-optional-locks: don't take index.lock, avoids races with Claude's own git commands
    if git_status=$(git -C "$cwd" --no-optional-locks status --porcelain=2 --branch 2>/dev/null); then
        branch="" oid="" ahead=0 behind=0 changed=0 untracked=0
        while IFS= read -r line; do
            case $line in
                "# branch.oid "*)  oid=${line#"# branch.oid "} ;;
                "# branch.head "*) branch=${line#"# branch.head "} ;;
                "# branch.ab "*)   read -r _ _ ahead behind <<< "$line"; ahead=${ahead#+}; behind=${behind#-} ;;
                "? "*)             untracked=$(( untracked + 1 )) ;;
                [12u]" "*)         changed=$(( changed + 1 )) ;;
            esac
        done <<< "$git_status"
        [ "$branch" = "(detached)" ] && branch=${oid:0:7}

        out+="${dim}@${reset}${green}${branch}${reset}"
        [ "$ahead" -gt 0 ] && out+="${cyan}↑${ahead}${reset}"
        [ "$behind" -gt 0 ] && out+="${cyan}↓${behind}${reset}"

        if [ "$changed" -gt 0 ]; then
            # Staged + unstaged lines vs HEAD; a repo without commits has no HEAD, so diff the index too
            if [ "$oid" = "(initial)" ]; then
                numstat=$( { git -C "$cwd" --no-optional-locks diff --cached --numstat; git -C "$cwd" --no-optional-locks diff --numstat; } 2>/dev/null)
            else
                numstat=$(git -C "$cwd" --no-optional-locks diff HEAD --numstat 2>/dev/null)
            fi
            git_stat=$(echo "$numstat" | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "+%d -%d", a, d}')
            if [ -n "$git_stat" ]; then
                out+=" ${dim}(${reset}${green}${git_stat%% *}${reset} ${red}${git_stat##* }${reset}${dim})${reset}"
            else
                # Binary, rename or mode changes only: no line counts, show changed file count
                out+=" ${dim}(${reset}${yellow}~${changed}${reset}${dim})${reset}"
            fi
        fi
        [ "$untracked" -gt 0 ] && out+=" ${orange}?${untracked}${reset}"
    fi
fi

out+="${sep}"
out+="${orange}${used_tokens}/${total_tokens}${reset} ${dim}(${reset}${green}${pct_used}%${reset}${dim})${reset}"
[ -n "$cost" ] && out+="${sep}${yellow}${cost}${reset}"
out+="${sep}"
out+="effort: "
case "$effort_level" in
    low)    out+="${dim}${effort_level}${reset}" ;;
    medium) out+="${orange}med${reset}" ;;
    high)   out+="${green}${effort_level}${reset}" ;;
    xhigh)  out+="${purple}${effort_level}${reset}" ;;
    max)    out+="${red}${effort_level}${reset}" ;;
    *)      out+="${green}${effort_level}${reset}" ;;
esac

# ===== Usage limits =====
# rate_limits arrives on stdin for claude.ai Pro/Max subscribers (percent 0–100, resets_at epoch seconds).
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hour_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Last good values, shared across Claude Code instances of the same config dir
cache_dir="${XDG_RUNTIME_DIR:-/tmp/claude-$(id -u)}/claude-statusline"
mkdir -p -m 700 "$cache_dir" 2>/dev/null
cache_file="$cache_dir/usage-$(printf '%s' "$claude_config_dir" | cksum | cut -d' ' -f1).json"

# All-zero values without reset timestamps likely indicate an API failure on Claude's side —
# fall back to the cache instead of displaying a misleading 0%. Genuine zero responses
# (after a billing reset) still include valid resets_at timestamps, so we trust those.
is_set() { [ -n "$1" ] && [ "$1" != "null" ] && [ "$1" != "0" ]; }
trust_stdin=false
if is_set "$(printf '%.0f' "${five_hour_pct:-0}")" || is_set "$(printf '%.0f' "${seven_day_pct:-0}")" || \
   is_set "$five_hour_reset" || is_set "$seven_day_reset"; then
    trust_stdin=true
fi

if $trust_stdin; then
    jq -n --arg fp "$five_hour_pct" --arg fr "$five_hour_reset" --arg sp "$seven_day_pct" --arg sr "$seven_day_reset" \
        '{five_hour: {pct: $fp, reset: $fr}, seven_day: {pct: $sp, reset: $sr}}' > "$cache_file" 2>/dev/null
elif [ -s "$cache_file" ]; then
    five_hour_pct=$(jq -r '.five_hour.pct' "$cache_file")
    five_hour_reset=$(jq -r '.five_hour.reset' "$cache_file")
    seven_day_pct=$(jq -r '.seven_day.pct' "$cache_file")
    seven_day_reset=$(jq -r '.seven_day.reset' "$cache_file")
fi

# Day/month names come from the user's LC_TIME (e.g. "Fri 9 Oct 00:53")
# Usage: render_limit <label> <pct> <reset-epoch> <date format>
render_limit() {
    local label=$1 pct=$2 reset_epoch=$3 fmt=$4
    if [ -z "$pct" ]; then
        out+="${sep}${white}${label}${reset} ${dim}-${reset}"
        return
    fi
    pct=$(printf "%.0f" "$pct")
    out+="${sep}${white}${label}${reset} $(usage_color "$pct")${pct}%${reset}"
    if is_set "$reset_epoch"; then
        local when
        when=$(date -d "@$reset_epoch" +"$fmt" 2>/dev/null || date -j -r "$reset_epoch" +"$fmt" 2>/dev/null)
        [ -n "$when" ] && out+=" ${dim}@${when}${reset}"
    fi
}

render_limit 5h "$five_hour_pct" "$five_hour_reset" "%H:%M"
render_limit 7d "$seven_day_pct" "$seven_day_reset" "%a %-d %b %H:%M"

# Append CLI version as last segment
if [ -n "$cli_version" ]; then
    out+="${sep}${orange}v${cli_version}${reset}"
fi

# Output
printf "%s" "$out"

exit 0
