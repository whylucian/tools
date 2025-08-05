#!/bin/bash
# llm.sh - CLI for OpenRouter LLMs

if [ $# -lt 1 ]; then
    echo "Usage: $0 [-model model_name] [-out filename] [--rag rag_db] [--rag-top-k N] [--llm-rag-prompt] [-v|--verbose] 'prompt' [file1.txt file2.txt ...]"
    echo "       $0 models"
    echo "Example: $0 'What is the capital of France?'"
    echo "Example: $0 -model anthropic/claude-3.5-sonnet 'Summarize these files' file1.txt file2.txt"
    echo "Example: $0 -out summary.txt 'Summarize this' file.txt"
    echo "Example: $0 --rag rag_db 'What do my documents say about AI?'"
    echo "Example: $0 --rag rag_db --rag-top-k 10 'Query with more results'"
    echo "Example: $0 --rag rag_db --llm-rag-prompt 'What do my documents say about machine learning?'"
    echo "Example: $0 -v --rag rag_db 'Query with debug info'"
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
RAG_DB=""
RAG_TOP_K=5
LLM_RAG_PROMPT=false
VERBOSE=false
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
        --rag)
            RAG_DB="$2"
            shift 2
            ;;
        --rag-top-k)
            RAG_TOP_K="$2"
            shift 2
            ;;
        --llm-rag-prompt)
            LLM_RAG_PROMPT=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
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

# Debug info function
debug() {
    if [ "$VERBOSE" = true ]; then
        echo "[DEBUG] $1" >&2
    fi
}

# Extract key terms for better RAG querying
extract_key_terms() {
    local prompt="$1"
    local use_llm="$2"
    
    if [ "$use_llm" = true ]; then
        # Use LLM to reformulate the query for better RAG search
        debug "Using LLM to reformulate RAG query"
        
        local reformulation_prompt="Extract 3-5 key search terms or phrases from this user question that would be most effective for searching a document database. Focus on the core concepts, technical terms, and specific topics. Return only the search terms separated by spaces, no explanations:

User question: $prompt"
        
        # Call LLM with Haiku model for fast reformulation
        local llm_result=$(jq -n \
            --arg model "anthropic/claude-3.5-haiku" \
            --arg content "$reformulation_prompt" \
            '{
                model: $model,
                max_tokens: 100,
                messages: [{role: "user", content: $content}]
            }' | \
        curl -s -X POST https://openrouter.ai/api/v1/chat/completions \
            -H "Authorization: Bearer $openrouter_key" \
            -H "Content-Type: application/json" \
            -H "HTTP-Referer: https://github.com/user/repo" \
            -H "X-Title: LLM CLI Tool" \
            -d @- | jq -r '.choices[0].message.content' 2>/dev/null)
        
        if [ -n "$llm_result" ] && [ "$llm_result" != "null" ]; then
            debug "LLM reformulated query: '$llm_result'"
            echo "$llm_result"
        else
            debug "LLM reformulation failed, using simple extraction"
            # Fallback to simple method
            echo "$prompt" | \
                sed 's/\b\(please\|can you\|could you\|I need\|help me\|tell me\|what is\|what are\|how do\|how can\)\b//gi' | \
                sed 's/[[:punct:]]/ /g' | tr -s ' ' | sed 's/^ *//; s/ *$//' | head -c 200
        fi
    else
        # Simple extraction method (fallback)
        echo "$prompt" | \
            sed 's/\b\(please\|can you\|could you\|I need\|help me\|tell me\|what is\|what are\|how do\|how can\)\b//gi' | \
            sed 's/[[:punct:]]/ /g' | tr -s ' ' | sed 's/^ *//; s/ *$//' | head -c 200
    fi
}

debug "Model: $MODEL"
debug "RAG DB: ${RAG_DB:-none}"
debug "RAG top-k: $RAG_TOP_K"
debug "LLM RAG prompt: $LLM_RAG_PROMPT"
debug "Output file: ${OUTPUT_FILE:-stdout}"

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

# RAG Integration
if [ -n "$RAG_DB" ]; then
    debug "RAG DB specified: $RAG_DB"
    
    # Check if RAG database exists
    if [ -d "$RAG_DB" ]; then
        debug "RAG DB directory found, querying..."
        
        # Extract key terms for better search
        SEARCH_QUERY=$(extract_key_terms "$PROMPT" "$LLM_RAG_PROMPT")
        debug "Extracted search query: '$SEARCH_QUERY'"
        
        # Create temporary file for RAG results
        RAG_TEMP=$(mktemp)
        debug "RAG temp file: $RAG_TEMP"
        
        # Query RAG system with JSON output and configurable top-k
        if ./rag.sh search --top-k "$RAG_TOP_K" --format json "$SEARCH_QUERY" > "$RAG_TEMP" 2>/dev/null; then
            if [ -s "$RAG_TEMP" ]; then
                RAG_RESULTS=$(cat "$RAG_TEMP")
                debug "RAG query successful, adding results to prompt"
                
                # Structured prompt integration
                CONTENT="$CONTENT"$'\n\n'"## Context from Knowledge Base"$'\n'"The following information may be relevant to your question:"$'\n'"$RAG_RESULTS"$'\n\n'"Please use this context to inform your response, but feel free to go beyond it if helpful."
            else
                debug "RAG query returned no results"
            fi
        else
            debug "RAG query failed"
        fi
        
        # Clean up temp file
        rm -f "$RAG_TEMP"
    else
        debug "RAG DB directory not found: $RAG_DB"
        echo "Warning: RAG database '$RAG_DB' not found, proceeding without RAG" >&2
    fi
fi

debug "Final content length: ${#CONTENT} characters"

# Use jq to properly build JSON and make API call
API_RESPONSE=$(echo "$CONTENT" | jq -Rs \
  --arg model "$MODEL" \
  '{
    model: $model,
    max_tokens: 50000,
    messages: [{role: "user", content: .}]
  }' | \
curl -X POST https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $openrouter_key" \
  -H "Content-Type: application/json" \
  -H "HTTP-Referer: https://github.com/user/repo" \
  -H "X-Title: LLM CLI Tool" \
  -d @-)

# Extract the message content
RESPONSE=$(echo "$API_RESPONSE" | jq -r '.choices[0].message.content')

# Extract usage information
PROMPT_TOKENS=$(echo "$API_RESPONSE" | jq -r '.usage.prompt_tokens // 0')
COMPLETION_TOKENS=$(echo "$API_RESPONSE" | jq -r '.usage.completion_tokens // 0')
TOTAL_TOKENS=$(echo "$API_RESPONSE" | jq -r '.usage.total_tokens // 0')

debug "API call completed, response length: ${#RESPONSE} characters"
debug "Token usage - Prompt: $PROMPT_TOKENS, Completion: $COMPLETION_TOKENS, Total: $TOTAL_TOKENS"

# Display token usage information
if [ "$PROMPT_TOKENS" != "0" ] || [ "$COMPLETION_TOKENS" != "0" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "📊 Token Usage: ${PROMPT_TOKENS} in + ${COMPLETION_TOKENS} out = ${TOTAL_TOKENS} total" >&2
    echo "🤖 Model: ${MODEL}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
fi

# Output handling
if [ -n "$OUTPUT_FILE" ]; then
    echo "$RESPONSE" > "$OUTPUT_FILE"
    echo "Output saved to: $OUTPUT_FILE"
else
    echo "$RESPONSE" | glow - # python -m rich.markdown - | sed 's/• /\n• /g'
fi
