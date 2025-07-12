#!/bin/bash
# llm.sh - CLI for OpenRouter LLMs

if [ $# -lt 1 ]; then
    echo "Usage: $0 [-model model_name] [-out filename] 'prompt' [file1.txt file2.txt ...]"
    echo "       $0 models"
    echo "Example: $0 'What is the capital of France?'"
    echo "Example: $0 -model anthropic/claude-3.5-sonnet 'Summarize these files' file1.txt file2.txt"
    echo "Example: $0 -out summary.txt 'Summarize this' file.txt"
    echo "Example: $0 models"
    exit 1
fi

if [ -z "$openrouter_key" ]; then
    echo "Error: Please set the openrouter_key environment variable"
    echo "Example: export openrouter_key=your-api-key-here"
    exit 1
fi

# Handle models command
if [ "$1" = "models" ]; then
    curl -X GET https://openrouter.ai/api/v1/models \
      -H "Authorization: Bearer $openrouter_key" \
      -H "Content-Type: application/json" | \
    jq -r '.data[] | "\(.id) - \(.name)"' | sort
    exit 0
fi

# Parse parameters
OUTPUT_FILE=""
MODEL="anthropic/claude-3.5-sonnet"  # Default model
ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -out)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -model)
            MODEL="$2"
            shift 2
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

# Check for piped input
if [ ! -t 0 ]; then
    PIPED_INPUT=$(cat)
    if [ -n "$PIPED_INPUT" ]; then
        CONTENT="$CONTENT"$'\n\n'"Piped input:"$'\n'"$PIPED_INPUT"
    fi
fi

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

# Use jq to properly build JSON and make API call
RESPONSE=$(jq -n \
  --arg model "$MODEL" \
  --arg content "$CONTENT" \
  '{
    model: $model,
    max_tokens: 50000,
    messages: [{role: "user", content: $content}]
  }' | \
curl -X POST https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $openrouter_key" \
  -H "Content-Type: application/json" \
  -H "HTTP-Referer: https://github.com/user/repo" \
  -H "X-Title: LLM CLI Tool" \
  -d @- | jq -r '.choices[0].message.content')

# Output handling
if [ -n "$OUTPUT_FILE" ]; then
    echo "$RESPONSE" > "$OUTPUT_FILE"
    echo "Output saved to: $OUTPUT_FILE"
else
    echo "$RESPONSE" | glow - # python -m rich.markdown - | sed 's/• /\n• /g'
fi
