#!/bin/bash

# Remove control characters before writing values to terminal output.
sanitize_text() {
    LC_ALL=C tr -d '\000-\037\177' <<< "$1"
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

# Validate JSON input
if ! echo "$input" | jq empty 2>/dev/null; then
    echo "[statusline: invalid JSON]"
    exit 0
fi

# Extract values using jq with null fallbacks
MODEL_DISPLAY=$(echo "$input" | jq -r '.model.display_name // "unknown"')
VERSION=$(echo "$input" | jq -r '.version // "?"')
CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir // "."')
TOTAL_COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
USED_PERCENT=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# Use current_usage tokens (actual context state) instead of cumulative totals
INPUT_TOKENS=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
CACHE_CREATE=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
CACHE_READ=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0')

# Format cost
if [[ "$TOTAL_COST" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    COST_FORMATTED=$(printf '$%.2f' "$TOTAL_COST")
else
    COST_FORMATTED='$0.00'
fi

# Format context percentage
if [[ "$USED_PERCENT" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    PCT=$(echo "$USED_PERCENT" | cut -d. -f1)
else
    PCT=0
fi

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

# Extract directory name safely
if [ -n "$CURRENT_DIR" ] && [ "$CURRENT_DIR" != "/" ]; then
    DIR_NAME="${CURRENT_DIR##*/}"
else
    DIR_NAME="/"
fi

# Git info with caching (refreshes every 5 seconds)
CACHE_FILE="/tmp/statusline-git-cache"
CACHE_MAX_AGE=5

cache_is_stale() {
    [ ! -f "$CACHE_FILE" ] || \
    [ $(($(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0))) -gt $CACHE_MAX_AGE ]
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

IFS='|' read -r BRANCH STAGED MODIFIED < "$CACHE_FILE"

if [ -n "$BRANCH" ]; then
    GIT_STATUS=""
    [ "$STAGED" -gt 0 ] 2>/dev/null && GIT_STATUS="${GREEN}+${STAGED}${RESET}"
    [ "$MODIFIED" -gt 0 ] 2>/dev/null && GIT_STATUS="${GIT_STATUS}${YELLOW}~${MODIFIED}${RESET}"
    GIT_INFO=" | 🌿 $BRANCH $GIT_STATUS"
fi

# Sanitize text fields
MODEL_DISPLAY=$(sanitize_text "$MODEL_DISPLAY")
VERSION=$(sanitize_text "$VERSION")
DIR_NAME=$(sanitize_text "$DIR_NAME")

# Current time for display
CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")

# Line 1: model, version, directory, git
echo -e "🤖 ${CYAN}${MODEL_DISPLAY}${RESET} | 🎲 v${VERSION} | 📁 ${DIR_NAME}${GIT_INFO}"
# Line 2: context bar, cost, duration, time
echo -e "${BAR_COLOR}${BAR}${RESET} 🧠 ${PCT}% (↓${INPUT_FMT} ↑${OUTPUT_FMT}) | 💰 ${COST_FORMATTED} | ⏱️ ${MINS}m ${SECS}s | 🕐 ${CURRENT_TIME}"
