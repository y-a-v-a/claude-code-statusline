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
CACHE_FILE="/tmp/statusline-git-cache"
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
if cache_is_stale; then
    if git rev-parse --git-dir > /dev/null 2>&1; then
        BRANCH=$(git branch --show-current 2>/dev/null || echo "")
        STAGED=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
        MODIFIED=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
        echo "$BRANCH|$STAGED|$MODIFIED" > "$CACHE_FILE"
    else
        echo "||" > "$CACHE_FILE"
    fi
fi

if [ -f "$CACHE_FILE" ]; then
    IFS='|' read -r BRANCH STAGED MODIFIED < "$CACHE_FILE"
fi

STAGED=$(as_int "$STAGED")
MODIFIED=$(as_int "$MODIFIED")

if [ -n "$BRANCH" ]; then
    GIT_STATUS=""
    [ "$STAGED" -gt 0 ] && GIT_STATUS="${GREEN}+${STAGED}${RESET}"
    [ "$MODIFIED" -gt 0 ] && GIT_STATUS="${GIT_STATUS}${YELLOW}~${MODIFIED}${RESET}"
    GIT_INFO="  🌿 $BRANCH $GIT_STATUS"
fi

# Sanitize text fields
MODEL_DISPLAY=$(sanitize_text "$MODEL_DISPLAY")
VERSION=$(sanitize_text "$VERSION")
DIR_NAME=$(sanitize_text "$DIR_NAME")

# Current time for display
CURRENT_TIME=$(date "+%Y%m%d%H%M%S")

# Line 1: model, version, directory, git
echo -e "🤖 ${CYAN}${MODEL_DISPLAY}${RESET}  🎲 v${VERSION}  📁 ${DIR_NAME}${GIT_INFO}"
# Line 2: context bar, cost (api only), duration, time
if [ "$IS_SUBSCRIPTION" -eq 1 ]; then
    COST_SEGMENT=""
else
    COST_SEGMENT="  💰 ${COST_FORMATTED}"
fi
echo -e "${BAR_COLOR}${BAR}${RESET} 🧠 ${PCT}% (↓${INPUT_FMT} ↑${OUTPUT_FMT})${COST_SEGMENT}  ⏱️ ${MINS}m${SECS}s  🕐 ${CURRENT_TIME}"
