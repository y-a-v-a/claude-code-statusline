#!/bin/bash
set -euo pipefail

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

# Read JSON input from stdin
input=$(cat)

# Validate JSON input
if ! echo "$input" | jq empty 2>/dev/null; then
    echo "Error: Invalid JSON input" >&2
    exit 1
fi

# Extract values using jq
MODEL_DISPLAY=$(echo "$input" | jq -r '.model.display_name')
VERSION=$(echo "$input" | jq -r '.version')
CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir')
TRANSCRIPT_PATH=$(echo "$input" | jq -r '.transcript_path')
TOTAL_COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
USED_PERCENT=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
INPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')

# Extract session info from transcript
SESSION_START=""
SESSION_DURATION=""
MESSAGE_COUNT=""

if [ -f "$TRANSCRIPT_PATH" ]; then
    # Get first message timestamp
    FIRST_TIMESTAMP=$(head -n 10 "$TRANSCRIPT_PATH" | jq -r 'select(.type == "user") | .timestamp' 2>/dev/null | head -n 1)

    if [ -n "$FIRST_TIMESTAMP" ]; then
        # Extract timestamp without milliseconds
        TIMESTAMP_CLEAN=$(echo "$FIRST_TIMESTAMP" | cut -d'.' -f1)

        # Format session start time as YYYY-MM-DD HH:MM (portable for both macOS and Linux)
        if date --version &>/dev/null 2>&1; then
            # GNU date (Linux)
            SESSION_START=$(date -d "$TIMESTAMP_CLEAN" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "")
            START_EPOCH=$(date -d "$TIMESTAMP_CLEAN" "+%s" 2>/dev/null || echo "")
        else
            # BSD date (macOS)
            SESSION_START=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$TIMESTAMP_CLEAN" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "")
            START_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$TIMESTAMP_CLEAN" "+%s" 2>/dev/null || echo "")
        fi

        # Calculate session duration if we successfully got the start epoch
        if [ -n "$START_EPOCH" ] && [[ "$START_EPOCH" =~ ^[0-9]+$ ]]; then
            CURRENT_EPOCH=$(date +%s)
            DURATION_SECS=$((CURRENT_EPOCH - START_EPOCH))

            HOURS=$((DURATION_SECS / 3600))
            MINS=$(((DURATION_SECS % 3600) / 60))

            if [ $HOURS -gt 0 ]; then
                SESSION_DURATION="${HOURS}h ${MINS}m"
            else
                SESSION_DURATION="${MINS}m"
            fi
        fi
    fi

    # Count messages (user + assistant) using jq for reliability
    MESSAGE_COUNT=$(jq -s '[.[] | select(.type == "user" or .type == "assistant")] | length' "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
fi

# Format cost (show 4 decimal places) with validation
if [[ "$TOTAL_COST" =~ ^[0-9]+\.?[0-9]*$ ]] || [[ "$TOTAL_COST" =~ ^[0-9]*\.[0-9]+$ ]]; then
    COST_FORMATTED=$(printf "%.4f" "$TOTAL_COST")
else
    COST_FORMATTED="0.0000"
fi

# Format token usage percentage with validation
if [[ "$USED_PERCENT" =~ ^[0-9]+\.?[0-9]*$ ]] || [[ "$USED_PERCENT" =~ ^[0-9]*\.[0-9]+$ ]]; then
    PERCENT_FORMATTED=$(printf "%.1f" "$USED_PERCENT")
else
    PERCENT_FORMATTED="0.0"
fi

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
    # Validate that tokens is a number
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

INPUT_FMT=$(format_tokens "$INPUT_TOKENS")
OUTPUT_FMT=$(format_tokens "$OUTPUT_TOKENS")

# Get current time
CURRENT_TIME=$(date +%H:%M:%S)

# Build session info section
SESSION_INFO=""
if [ -n "$SESSION_START" ]; then
    SESSION_INFO=" | ⏰ Started: $SESSION_START | ⏱️ Duration: $SESSION_DURATION | 💬 $MESSAGE_COUNT msgs"
fi

# Extract directory name safely
if [ -n "$CURRENT_DIR" ] && [ "$CURRENT_DIR" != "/" ]; then
    DIR_NAME="${CURRENT_DIR##*/}"
else
    DIR_NAME="/"
fi

# Build status line
echo "🤖 $MODEL_DISPLAY | 🎲 v$VERSION | 📁 ${DIR_NAME}${GIT_INFO} | 💰 \$${COST_FORMATTED} | 🧠 ${PERCENT_FORMATTED}% (↓${INPUT_FMT} ↑${OUTPUT_FMT})${SESSION_INFO} | $CURRENT_TIME"