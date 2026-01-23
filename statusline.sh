#!/bin/bash
# Read JSON input from stdin
input=$(cat)

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
        # Format session start time as YYYY-MM-DD HH:MM
        SESSION_START=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$(echo $FIRST_TIMESTAMP | cut -d'.' -f1)" "+%Y-%m-%d %H:%M" 2>/dev/null)

        # Calculate session duration
        START_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$(echo $FIRST_TIMESTAMP | cut -d'.' -f1)" "+%s" 2>/dev/null)
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

    # Count messages (user + assistant)
    MESSAGE_COUNT=$(grep -c '"type":"user"\|"type":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
fi

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

# Build session info section
SESSION_INFO=""
if [ -n "$SESSION_START" ]; then
    SESSION_INFO=" | ⏰ Started: $SESSION_START | ⏱️ Duration: $SESSION_DURATION | 💬 $MESSAGE_COUNT msgs"
fi

# Build status line
echo "🤖 $MODEL_DISPLAY | 🎲 v$VERSION | 📁 ${CURRENT_DIR##*/}${GIT_INFO} | 💰 \$${COST_FORMATTED} | 🧠 ${PERCENT_FORMATTED}% (↓${INPUT_FMT} ↑${OUTPUT_FMT})${SESSION_INFO} | $CURRENT_TIME"