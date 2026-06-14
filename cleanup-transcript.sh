#!/bin/bash

# Clean up a whisper transcript using a local LLM via MLX
# Usage: ./cleanup-transcript.sh <transcript_file>

set -euo pipefail

TRANSCRIPT_FILE="${1:-}"

if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Usage: $0 <transcript_file>"
    echo "Example: $0 recording_transcript.txt"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python"

if [ ! -f "$PYTHON" ]; then
    echo "Error: Python not found at $PYTHON"
    exit 1
fi

BASENAME="${TRANSCRIPT_FILE%.*}"
OUTPUT_FILE="${BASENAME}_cleaned.txt"

# Model selection
echo ""
echo "Select LLM for transcript cleanup:"
echo "  1) Llama 3.2 1B   - Fastest, ~1 GB RAM"
echo "  2) Llama 3.2 3B   - Fast, ~2 GB RAM"
echo "  3) Llama 3.1 8B   - Best balance (recommended) ⭐ ~5 GB RAM"
echo "  4) Llama 3.1 8B 8-bit - Higher quality, ~8 GB RAM"
echo "  5) custom          - Enter a custom model name"
echo ""
read -p "Enter choice [1-5] (default: 3): " llm_choice

case "$llm_choice" in
    1) MODEL="mlx-community/Llama-3.2-1B-Instruct-4bit" ; MODEL_LABEL="llama3.2-1b-4bit" ;;
    2) MODEL="mlx-community/Llama-3.2-3B-Instruct-4bit" ; MODEL_LABEL="llama3.2-3b-4bit" ;;
    3|"") MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-4bit" ; MODEL_LABEL="llama3.1-8b-4bit" ;;
    4) MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-8bit" ; MODEL_LABEL="llama3.1-8b-8bit" ;;
    5)
        read -p "Enter model name: " MODEL
        if [ -z "$MODEL" ]; then
            MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"
            MODEL_LABEL="llama3.1-8b-4bit"
        else
            MODEL_LABEL=$(echo "$MODEL" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
        fi
        ;;
    *) MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-4bit" ; MODEL_LABEL="llama3.1-8b-4bit" ;;
esac

# Set model label for filename if not already set
if [ -z "${MODEL_LABEL:-}" ]; then
    MODEL_LABEL=$(echo "$MODEL" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
fi

OUTPUT_FILE="${BASENAME}_cleaned_${MODEL_LABEL}.txt"

echo ""
echo "Using model: $MODEL"
echo "Input:  $TRANSCRIPT_FILE"
echo "Output: $OUTPUT_FILE"
echo ""

# Strip metadata header (Model:, Source:, Date: lines) from transcript
TRANSCRIPT_BODY=$(sed '/^Model:/d; /^Source:/d; /^Date:/d; /^$/d' "$TRANSCRIPT_FILE" | head -1 > /dev/null && sed '1,/^$/d' "$TRANSCRIPT_FILE" 2>/dev/null || cat "$TRANSCRIPT_FILE")

# Count words
WORD_COUNT=$(echo "$TRANSCRIPT_BODY" | wc -w | tr -d ' ')
echo "Transcript: $WORD_COUNT words"

# Chunk size in words (~1500 words per chunk to stay well within context window)
CHUNK_SIZE=1500

# Run the cleanup via Python for proper chunking and MLX integration
TRANSCRIPT_FILE="$TRANSCRIPT_FILE" OUTPUT_FILE="$OUTPUT_FILE" MODEL="$MODEL" CHUNK_SIZE="$CHUNK_SIZE" "$PYTHON" << 'PYTHON_SCRIPT'
import sys
import os
import textwrap

transcript_file = os.environ['TRANSCRIPT_FILE']
output_file = os.environ['OUTPUT_FILE']
model_name = os.environ['MODEL']
chunk_size = int(os.environ['CHUNK_SIZE'])

# Read transcript, skip metadata header
with open(transcript_file, 'r') as f:
    lines = f.readlines()

# Strip metadata lines at the top (Model:, Source:, Date:, blank)
content_lines = []
header_done = False
for line in lines:
    if not header_done:
        if line.startswith(('Model:', 'Source:', 'Date:')) or line.strip() == '':
            continue
        header_done = True
    content_lines.append(line)

transcript = ''.join(content_lines).strip()
if not transcript:
    # No header found, use everything
    transcript = ''.join(lines).strip()

words = transcript.split()
total_words = len(words)
print(f"Processing {total_words} words in chunks of {chunk_size}...")

# Split into chunks at sentence boundaries
chunks = []
current_chunk = []
current_count = 0

for word in words:
    current_chunk.append(word)
    current_count += 1
    if current_count >= chunk_size and word.endswith(('.', '!', '?')):
        chunks.append(' '.join(current_chunk))
        current_chunk = []
        current_count = 0

if current_chunk:
    chunks.append(' '.join(current_chunk))

print(f"Split into {len(chunks)} chunks")
print()

# Load model
print(f"Loading model: {model_name}")
from mlx_lm import load, generate

model, tokenizer = load(model_name)
print("Model loaded!")
print()

SYSTEM_PROMPT = """You are a transcript editor. Your job is to clean up speech-to-text transcripts.

Rules:
- Fix spelling and grammar errors
- Fix punctuation
- Remove filler words (um, uh, you know, like, sort of, kind of) ONLY when they are clearly filler
- Fix obvious word substitution errors from speech recognition
- Add paragraph breaks at natural topic transitions
- Do NOT change the meaning or rephrase sentences
- Do NOT add information that isn't in the original
- Do NOT summarize or shorten the text
- Preserve the speaker's voice and style
- Output ONLY the cleaned text, NO preambles like "Here's the cleaned transcript:" or any commentary
- Start directly with the cleaned content"""

cleaned_chunks = []

for i, chunk in enumerate(chunks):
    print(f"Processing chunk {i+1}/{len(chunks)} ({len(chunk.split())} words)...")

    prompt = f"Clean up this transcript segment:\n\n{chunk}"

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": prompt}
    ]

    formatted = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)

    response = generate(
        model,
        tokenizer,
        prompt=formatted,
        max_tokens=chunk_size * 2,
        verbose=False,
    )

    # Strip common LLM preambles
    cleaned = response.strip()
    preambles = [
        "Here's the cleaned-up transcript:",
        "Here's the cleaned up transcript:",
        "Here is the cleaned-up transcript:",
        "Here is the cleaned up transcript:",
        "Here's the cleaned transcript:",
        "Here is the cleaned transcript:",
        "Cleaned transcript:",
        "Here you go:",
        "Sure, here's",
        "Sure! Here's",
    ]
    for preamble in preambles:
        if cleaned.startswith(preamble):
            cleaned = cleaned[len(preamble):].strip()
            break

    cleaned_chunks.append(cleaned)
    print(f"  Done ({len(response.split())} words out)")

# Write output
with open(output_file, 'w') as f:
    f.write('\n\n'.join(cleaned_chunks))
    f.write('\n')

print()
print(f"Cleaned transcript saved to: {output_file}")
print(f"Original: {total_words} words -> Cleaned: {sum(len(c.split()) for c in cleaned_chunks)} words")
PYTHON_SCRIPT

echo ""
echo "Done!"
echo "Cleaned transcript: $OUTPUT_FILE"
