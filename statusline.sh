#!/bin/bash

# Remove control characters and escape backslashes to prevent echo -e interpretation.
sanitize_text() {
    local text
    text=$(LC_ALL=C tr -d '\000-\037\177' <<< "$1")
    printf '%s' "${text//\\/\\\\}"
}

# Format token counts with K suffix if >= 1000
format_tokens() {
    local tokens=$1
    if ! [[ "$tokens" =~ ^[0-9]+$ ]]; then
        echo "0"
        return
    fi
    if [ "$tokens" -ge 1000 ]; then
        echo "$((tokens / 1000))k"
    else
        echo "$tokens"
    fi
}

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "[statusline: jq not found]"
    exit 0
fi

# Read JSON input from stdin
input=$(cat)

# Validate JSON input (reject empty input and invalid JSON)
if [ -z "${input// /}" ] || ! echo "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "[statusline: waiting for data]"
    exit 0
fi

# Helper: ensure a value is a valid integer, default to 0
as_int() {
    local val="${1:-0}"
    # Strip decimal portion and non-numeric chars
    val="${val%%.*}"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
    else
        echo "0"
    fi
}

# Extract values using jq with null fallbacks
MODEL_DISPLAY=$(echo "$input" | jq -r '.model.display_name // "unknown"')
EFFORT_LEVEL=$(echo "$input" | jq -r '.effort.level? | strings' 2>/dev/null)
FIVE_HOUR_PCT=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage? | numbers' 2>/dev/null)
SEVEN_DAY_PCT=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage? | numbers' 2>/dev/null)
VERSION=$(echo "$input" | jq -r '.version // "?"')
CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir // "."')
TOTAL_COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
USED_PERCENT=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
DURATION_MS=$(as_int "$(echo "$input" | jq -r '.cost.total_duration_ms // 0')")

# Use current_usage tokens (actual context state) instead of cumulative totals
# current_usage is null before the first API call in a session
INPUT_TOKENS=$(as_int "$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')")
CACHE_CREATE=$(as_int "$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')")
CACHE_READ=$(as_int "$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')")
OUTPUT_TOKENS=$(as_int "$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0')")

# Prompt cache state as "observed|expires_at|ttl|recache_tokens_if_cold"
# prompt_cache is absent before the first API response (and before Claude Code v2.1.251)
CACHE_STATE=$(echo "$input" | jq -r '.prompt_cache // {}
    | [(.caching_observed // false), (.expires_at // ""), (.ttl // ""), (.recache_tokens_if_cold // "")]
    | map(tostring) | join("|")' 2>/dev/null)
IFS='|' read -r CACHE_OBSERVED CACHE_EXPIRES CACHE_TTL CACHE_RECACHE <<< "$CACHE_STATE"

# Format cost
if [[ "$TOTAL_COST" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    COST_FORMATTED=$(printf '$%.2f' "$TOTAL_COST")
else
    COST_FORMATTED='$0.00'
fi

# Detect auth mode: when logged in on a subscription, the cost number is misleading.
# Read ~/.claude.json oauthAccount.billingType — "stripe_subscription" => hide cost.
IS_SUBSCRIPTION=0
if [ -r "$HOME/.claude.json" ]; then
    BILLING_TYPE=$(jq -r '.oauthAccount.billingType // ""' "$HOME/.claude.json" 2>/dev/null)
    if [[ "$BILLING_TYPE" == *subscription* ]]; then
        IS_SUBSCRIPTION=1
    fi
fi

# Format context percentage (safe integer, clamped to 0-100)
PCT=$(as_int "$USED_PERCENT")
[ "$PCT" -gt 100 ] && PCT=100
[ "$PCT" -lt 0 ] && PCT=0

# Format duration from cost.total_duration_ms
DURATION_SEC=$((DURATION_MS / 1000))
MINS=$((DURATION_SEC / 60))
SECS=$((DURATION_SEC % 60))

# Color thresholds for context usage
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
RESET='\033[0m'

if [ "$PCT" -ge 90 ]; then
    BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then
    BAR_COLOR="$YELLOW"
else
    BAR_COLOR="$GREEN"
fi

# Build progress bar
BAR_WIDTH=10
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
BAR=""
[ "$FILLED" -gt 0 ] && BAR=$(printf "%${FILLED}s" | tr ' ' '█')
[ "$EMPTY" -gt 0 ] && BAR="${BAR}$(printf "%${EMPTY}s" | tr ' ' '░')"

# Format token counts
INPUT_TOTAL=$((INPUT_TOKENS + CACHE_CREATE + CACHE_READ))
INPUT_FMT=$(format_tokens "$INPUT_TOTAL")
OUTPUT_FMT=$(format_tokens "$OUTPUT_TOKENS")

# Display path relative to home directory (~/...)
if [ -n "$CURRENT_DIR" ] && [ "$CURRENT_DIR" != "/" ]; then
    if [ -n "$HOME" ] && [ "$CURRENT_DIR" = "$HOME" ]; then
        DIR_NAME="~"
    elif [ -n "$HOME" ] && [ "${CURRENT_DIR#"$HOME"/}" != "$CURRENT_DIR" ]; then
        DIR_NAME="~/${CURRENT_DIR#"$HOME"/}"
    else
        DIR_NAME="$CURRENT_DIR"
    fi
else
    DIR_NAME="/"
fi

# Git info with caching (refreshes every 5 seconds)
CACHE_MAX_AGE=5

cache_is_stale() {
    [ ! -f "$CACHE_FILE" ] && return 0
    local now file_mtime age
    now=$(date +%s 2>/dev/null) || return 0
    file_mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null) || return 0
    age=$((now - file_mtime)) 2>/dev/null || return 0
    [ "$age" -gt "$CACHE_MAX_AGE" ]
}

GIT_INFO=""
GIT_ROOT=""
if [ -n "$CURRENT_DIR" ] && [ -d "$CURRENT_DIR" ]; then
    GIT_ROOT=$(git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
fi

if [ -n "$GIT_ROOT" ]; then
    CACHE_KEY=$(printf '%s' "$GIT_ROOT" | cksum | cut -d ' ' -f 1)
    CACHE_FILE="${TMPDIR:-/tmp}/statusline-git-cache-${CACHE_KEY}"

    if cache_is_stale; then
        if git -C "$CURRENT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
            BRANCH=$(git -C "$CURRENT_DIR" branch --show-current 2>/dev/null || echo "")
            STAGED=$(git -C "$CURRENT_DIR" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
            MODIFIED=$(git -C "$CURRENT_DIR" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
            # Total line churn (added|removed) across all uncommitted changes vs HEAD.
            # Skip binary files, whose numstat columns are "-".
            DIFFSTAT=$(git -C "$CURRENT_DIR" diff HEAD --numstat 2>/dev/null \
                | awk '{ if ($1 != "-") a += $1; if ($2 != "-") d += $2 } END { print (a+0) "|" (d+0) }')
            ADDED=${DIFFSTAT%%|*}
            REMOVED=${DIFFSTAT##*|}
            echo "$BRANCH|$STAGED|$MODIFIED|$ADDED|$REMOVED" > "$CACHE_FILE"
        else
            echo "||||" > "$CACHE_FILE"
        fi
    fi

    if [ -f "$CACHE_FILE" ]; then
        IFS='|' read -r BRANCH STAGED MODIFIED ADDED REMOVED < "$CACHE_FILE"
    fi

    STAGED=$(as_int "$STAGED")
    MODIFIED=$(as_int "$MODIFIED")
    ADDED=$(as_int "$ADDED")
    REMOVED=$(as_int "$REMOVED")

    if [ -n "$BRANCH" ]; then
        GIT_STATUS=""
        [ "$STAGED" -gt 0 ] && GIT_STATUS="${GREEN}+${STAGED}${RESET}"
        [ "$MODIFIED" -gt 0 ] && GIT_STATUS="${GIT_STATUS}${YELLOW}~${MODIFIED}${RESET}"
        GIT_CHURN=""
        [ "$ADDED" -gt 0 ] && GIT_CHURN="${GREEN}+${ADDED}${RESET}"
        [ "$REMOVED" -gt 0 ] && GIT_CHURN="${GIT_CHURN}${RED}-${REMOVED}${RESET}"
        [ -n "$GIT_CHURN" ] && GIT_STATUS="${GIT_STATUS} ${GIT_CHURN}"
        GIT_INFO="  🌿 $BRANCH $GIT_STATUS"
    fi
fi

# Sanitize text fields
MODEL_DISPLAY=$(sanitize_text "$MODEL_DISPLAY")
EFFORT_LEVEL=$(sanitize_text "$EFFORT_LEVEL")
EFFORT_SEGMENT=""
[ -n "$EFFORT_LEVEL" ] && EFFORT_SEGMENT=" (${EFFORT_LEVEL})"
VERSION=$(sanitize_text "$VERSION")
DIR_NAME=$(sanitize_text "$DIR_NAME")

# Current time for display
CURRENT_TIME=$(date "+%Y%m%d%H%M%S")

# Line 1: model, version, directory, git
echo -e "🤖 ${CYAN}${MODEL_DISPLAY}${EFFORT_SEGMENT}${RESET}  🎲 v${VERSION}  📁 ${DIR_NAME}${GIT_INFO}"
# Line 2: context bar, cost (api only), duration, time
if [ "$IS_SUBSCRIPTION" -eq 1 ]; then
    COST_SEGMENT=""
else
    COST_SEGMENT="  💰 ${COST_FORMATTED}"
fi

limit_segment() {
    local label=$1 pct color
    pct=$(as_int "$(printf '%.0f' "$2" 2>/dev/null)")
    if [ "$pct" -ge 90 ]; then
        color="$RED"
    elif [ "$pct" -ge 70 ]; then
        color="$YELLOW"
    else
        color="$GREEN"
    fi
    printf '%s %b%s%%%b' "$label" "$color" "$pct" "$RESET"
}

LIMITS=""
LIMITS_SEGMENT=""
[ -n "$FIVE_HOUR_PCT" ] && LIMITS="$(limit_segment 5h "$FIVE_HOUR_PCT")"
[ -n "$SEVEN_DAY_PCT" ] && LIMITS="${LIMITS:+$LIMITS }$(limit_segment 7d "$SEVEN_DAY_PCT")"
[ -n "$LIMITS" ] && LIMITS_SEGMENT="  📊 ${LIMITS}"

# Prompt cache countdown: whole minutes until the cached conversation expires.
# Once cold, the next message re-processes the whole context (↻ tokens) at cache-write cost.
# Compares expires_at against the clock, so it needs statusLine.refreshInterval to tick while idle.
CACHE_SEGMENT=""
NOW=$(as_int "$(date +%s 2>/dev/null)")
if [ "$CACHE_OBSERVED" = "true" ] && [ "$NOW" -gt 0 ]; then
    CACHE_EXPIRES=$(as_int "$CACHE_EXPIRES")
    CACHE_LEFT=$((CACHE_EXPIRES - NOW))
    if [ "$CACHE_EXPIRES" -gt 0 ] && [ "$CACHE_LEFT" -gt 0 ]; then
        if [ "$CACHE_TTL" = "5m" ]; then
            CACHE_TTL_SEC=300
        else
            CACHE_TTL_SEC=3600
        fi
        CACHE_LEFT_PCT=$((CACHE_LEFT * 100 / CACHE_TTL_SEC))
        if [ "$CACHE_LEFT_PCT" -le 10 ]; then
            CACHE_COLOR="$RED"
        elif [ "$CACHE_LEFT_PCT" -le 25 ]; then
            CACHE_COLOR="$YELLOW"
        else
            CACHE_COLOR="$GREEN"
        fi
        if [ "$CACHE_LEFT" -ge 60 ]; then
            CACHE_LEFT_FMT="$((CACHE_LEFT / 60))m"
        else
            CACHE_LEFT_FMT="<1m"
        fi
        CACHE_SEGMENT="  🔥 ${CACHE_COLOR}${CACHE_LEFT_FMT}${RESET}"
    else
        CACHE_RECACHE=$(as_int "$CACHE_RECACHE")
        CACHE_SEGMENT="  🧊 ${CYAN}cold${RESET}"
        [ "$CACHE_RECACHE" -gt 0 ] && CACHE_SEGMENT="${CACHE_SEGMENT} ↻$(format_tokens "$CACHE_RECACHE")"
    fi
fi

echo -e "${BAR_COLOR}${BAR}${RESET} 🧠 ${PCT}% (↓${INPUT_FMT} ↑${OUTPUT_FMT})${CACHE_SEGMENT}${COST_SEGMENT}${LIMITS_SEGMENT}  ⏱️ ${MINS}m${SECS}s  🕐 ${CURRENT_TIME}"
