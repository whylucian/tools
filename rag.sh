#!/bin/bash

# RAG System Runner
# Runs rag/rag_system.py with environment variables from rag/.env

# Check if rag directory exists
if [ ! -d "rag" ]; then
    echo "Error: rag directory not found. Please ensure you're running this from the tools directory."
    exit 1
fi

# Check if rag_system.py exists
if [ ! -f "rag/rag_system.py" ]; then
    echo "Error: rag/rag_system.py not found."
    exit 1
fi

# Check if virtual environment exists
if [ ! -d "rag/.env" ]; then
    echo "Error: rag/.env virtual environment not found."
    echo "Please run 'cd rag && ./install.sh' to set up the environment first."
    exit 1
fi

# Activate virtual environment
source rag/.env/bin/activate

# Change to rag directory and run the script with all arguments
cd rag
python3 rag_system.py "$@"