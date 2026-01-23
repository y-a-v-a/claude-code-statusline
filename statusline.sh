#!/bin/bash
# Read JSON input from stdin
input=$(cat)

# Extract values using jq
MODEL_DISPLAY=$(echo "$input" | jq -r '.model.display_name')
VERSION=$(echo "$input" | jq -r '.version')
CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir')
TOTAL_COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
USED_PERCENT=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
INPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')

# Format cost (show 4 decimal places)
COST_FORMATTED=$(printf "%.4f" "$TOTAL_COST")

# Format token usage percentage
PERCENT_FORMATTED=$(printf "%.1f" "$USED_PERCENT")

# Get git branch if in a git repo
GIT_INFO=""
if git rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git branch --show-current 2>/dev/null)
    if [ -n "$BRANCH" ]; then
        GIT_INFO=" 🌿 $BRANCH"
    fi
fi

# Format token counts with K suffix if > 1000
format_tokens() {
    local tokens=$1
    if [ "$tokens" -ge 1000 ]; then
        echo "$((tokens / 1000))k"
    else
        echo "$tokens"
    fi
}

INPUT_FMT=$(format_tokens "$INPUT_TOKENS")
OUTPUT_FMT=$(format_tokens "$OUTPUT_TOKENS")

# Get current time
CURRENT_TIME=$(date +%H:%M:%S)

# Build status line
echo "🤖 $MODEL_DISPLAY | 🎲 v$VERSION | 📁 ${CURRENT_DIR##*/}${GIT_INFO} | 💰 \$${COST_FORMATTED} | 🧠 ${PERCENT_FORMATTED}% (↓${INPUT_FMT} ↑${OUTPUT_FMT}) | $CURRENT_TIME"