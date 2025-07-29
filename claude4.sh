#!/bin/bash
# claude4.sh - Simple CLI for Claude 4 Sonnet

if [ $# -lt 1 ]; then
    echo "Usage: $0 [-out filename] [-s] 'prompt' [file1.txt file2.txt ...]"
    echo "Example: $0 'What is the capital of France?'"
    echo "Example: $0 'Summarize these files' file1.txt file2.txt"
    echo "Example: $0 -out summary.txt 'Summarize this' file.txt"
    echo "Example: $0 -s 'Quick question' (uses 3.5 Haiku model)"
    exit 1
fi

if [ -z "$anthropic_key" ]; then
    echo "Error: Please set the anthropic_key environment variable"
    echo "Example: export anthropic_key=your-api-key-here"
    exit 1
fi

# Parse parameters
OUTPUT_FILE=""
USE_HAIKU=false
ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -out)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -s)
            USE_HAIKU=true
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Set the arguments back
set -- "${ARGS[@]}"

if [ $# -lt 1 ]; then
    echo "Error: No prompt provided"
    exit 1
fi

PROMPT="$1"
shift  # Remove the first argument (prompt), rest are files

# Build the content string with file contents
CONTENT="$PROMPT"

# Process each file (if any)
if [ $# -gt 0 ]; then
    for FILE in "$@"; do
        if [ ! -f "$FILE" ]; then
            echo "Error: File '$FILE' not found"
            exit 1
        fi
        
        CONTENT="$CONTENT"$'\n\n'"File: $FILE"$'\n'"$(cat "$FILE")"
    done
fi

# Set model based on flag
if [ "$USE_HAIKU" = true ]; then
    MODEL="claude-3-5-haiku-latest"
else
    MODEL="claude-sonnet-4-20250514"
fi

# Use jq to properly build JSON and make API call
RESPONSE=$(jq -n \
  --arg model "$MODEL" \
  --arg content "$CONTENT" \
  '{
    model: $model,
    max_tokens: 50000,
    messages: [{role: "user", content: $content}]
  }' | \
curl -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $anthropic_key" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d @- | jq -r '.content[0].text')

# Output handling
if [ -n "$OUTPUT_FILE" ]; then
    echo "$RESPONSE" > "$OUTPUT_FILE"
    echo "Output saved to: $OUTPUT_FILE"
else
    echo "$RESPONSE" | glow - # python -m rich.markdown - | sed 's/• /\n• /g'
fi
