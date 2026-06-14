#!/bin/bash

# Summarize a video transcript using Qwen 2.5 with MLX (Apple Silicon GPU)
# Usage: ./summarize-transcript.sh <transcript_file>
#
# Requires: Apple Silicon Mac, ~20 GB RAM for 32B 4-bit model
# Dependencies are installed automatically into .venv on first run.

set -euo pipefail

TRANSCRIPT_FILE=""
INSTALL_ONLY=false

for arg in "$@"; do
    case $arg in
        --install)
            INSTALL_ONLY=true
            ;;
        *)
            TRANSCRIPT_FILE="$arg"
            ;;
    esac
done

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
PYTHON="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

# ── Ensure virtual environment and dependencies ──────────────────────────────

setup_venv() {
    if [ ! -d "$VENV_DIR" ]; then
        echo "Creating virtual environment at $VENV_DIR ..."
        python3 -m venv "$VENV_DIR"
    fi

    # Check if mlx-lm is installed
    if ! "$PYTHON" -c "import mlx_lm" 2>/dev/null; then
        echo "Installing mlx-lm (MLX language model framework)..."
        "$PIP" install --upgrade pip > /dev/null
        "$PIP" install mlx-lm
        echo ""
        echo "mlx-lm installed successfully."
    fi
}

setup_venv

if $INSTALL_ONLY; then
    echo ""
    echo "Dependencies installed. Pre-downloading default model..."
    "$PYTHON" -c "
from mlx_lm import load
print('Downloading Qwen2.5-32B-Instruct-4bit...')
model, tokenizer = load('mlx-community/Qwen2.5-32B-Instruct-4bit')
print('Model downloaded and ready.')
"
    echo "Done! Run: $0 <transcript_file>"
    exit 0
fi

# ── Validate input ───────────────────────────────────────────────────────────

if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Usage: $0 <transcript_file>"
    echo "       $0 --install            # Install deps and download model"
    echo ""
    echo "Example: $0 recording_transcript.txt"
    echo ""
    echo "Summarizes a video/audio transcript using Qwen 2.5 on Apple Silicon."
    echo "Supports transcripts of any length via intelligent chunking."
    exit 1
fi

# ── Model selection ──────────────────────────────────────────────────────────

echo ""
echo "Select Qwen model for summarization:"
echo "  1) Qwen 2.5  7B  4-bit  - Fast, ~5 GB RAM"
echo "  2) Qwen 2.5 14B  4-bit  - Good balance, ~9 GB RAM"
echo "  3) Qwen 2.5 32B  4-bit  - Best quality ⭐ ~20 GB RAM"
echo "  4) Qwen 2.5 32B  8-bit  - Highest quality, ~34 GB RAM"
echo "  5) custom                - Enter a custom model name"
echo ""
read -p "Enter choice [1-5] (default: 3): " model_choice

case "$model_choice" in
    1) MODEL="mlx-community/Qwen2.5-7B-Instruct-4bit"   ; MODEL_LABEL="Qwen2.5-7B-4bit" ;;
    2) MODEL="mlx-community/Qwen2.5-14B-Instruct-4bit"  ; MODEL_LABEL="Qwen2.5-14B-4bit" ;;
    3|"") MODEL="mlx-community/Qwen2.5-32B-Instruct-4bit" ; MODEL_LABEL="Qwen2.5-32B-4bit" ;;
    4) MODEL="mlx-community/Qwen2.5-32B-Instruct-8bit"  ; MODEL_LABEL="Qwen2.5-32B-8bit" ;;
    5)
        read -p "Enter model name: " MODEL
        MODEL_LABEL="$MODEL"
        if [ -z "$MODEL" ]; then
            MODEL="mlx-community/Qwen2.5-32B-Instruct-4bit"
            MODEL_LABEL="Qwen2.5-32B-4bit"
        fi
        ;;
    *)
        MODEL="mlx-community/Qwen2.5-32B-Instruct-4bit"
        MODEL_LABEL="Qwen2.5-32B-4bit"
        ;;
esac

# ── Summary style selection ──────────────────────────────────────────────────

echo ""
echo "Select summary style:"
echo "  1) Executive    - 1-2 paragraph overview with key takeaways"
echo "  2) Detailed     - Structured summary with sections and bullet points"
echo "  3) Bullet-only  - Concise bullet-point list of main topics"
echo "  4) Chapter      - Chapter-by-chapter breakdown with timestamps"
echo "  5) Blog Post    - Compelling narrative optimized for engagement ⭐"
echo ""
read -p "Enter choice [1-5] (default: 5): " style_choice

case "$style_choice" in
    1) STYLE="executive" ;;
    2) STYLE="detailed" ;;
    3) STYLE="bullets" ;;
    4) STYLE="chapters" ;;
    5|"") STYLE="blog" ;;
    *) STYLE="blog" ;;
esac

BASENAME="${TRANSCRIPT_FILE%.*}"
OUTPUT_FILE="${BASENAME}_summary_${MODEL_LABEL}_${STYLE}.md"

echo ""
echo "Model:   $MODEL"
echo "Style:   $STYLE"
echo "Input:   $TRANSCRIPT_FILE"
echo "Output:  $OUTPUT_FILE"
echo ""

# ── Run summarization via Python ─────────────────────────────────────────────

TRANSCRIPT_FILE="$TRANSCRIPT_FILE" OUTPUT_FILE="$OUTPUT_FILE" MODEL="$MODEL" MODEL_LABEL="$MODEL_LABEL" STYLE="$STYLE" "$PYTHON" << 'PYTHON_SCRIPT'
import sys
import os
import time

transcript_file = os.environ['TRANSCRIPT_FILE']
output_file = os.environ['OUTPUT_FILE']
model_name = os.environ['MODEL']
model_label = os.environ['MODEL_LABEL']
style = os.environ['STYLE']

# ── Read transcript ──────────────────────────────────────────────────────────

with open(transcript_file, 'r') as f:
    lines = f.readlines()

# Strip metadata header (Model:, Source:, Date: lines from transcribe.sh)
content_lines = []
header_done = False
metadata = {}
for line in lines:
    if not header_done:
        if line.startswith('Model:'):
            metadata['transcription_model'] = line.split(':', 1)[1].strip()
            continue
        if line.startswith('Source:'):
            metadata['source'] = line.split(':', 1)[1].strip()
            continue
        if line.startswith('Date:'):
            metadata['date'] = line.split(':', 1)[1].strip()
            continue
        if line.strip() == '':
            continue
        header_done = True
    content_lines.append(line)

transcript = ''.join(content_lines).strip()
if not transcript:
    transcript = ''.join(lines).strip()

words = transcript.split()
total_words = len(words)
print(f"Transcript: {total_words:,} words")

# ── Build prompts per style ──────────────────────────────────────────────────

STYLE_PROMPTS = {
    "executive": """Write a concise executive summary of this video transcript.

Format:
- Start with a 1-2 sentence overview of what the video is about
- Write 1-2 paragraphs covering the main arguments and conclusions
- End with a "Key Takeaways" section listing 3-5 bullet points
- Keep the total summary under 500 words""",

    "detailed": """Write a detailed, structured summary of this video transcript.

Format:
- Start with a brief overview paragraph
- Create logical sections with clear headings (use ## for headings)
- Under each section, use bullet points for key arguments and details
- Include important quotes or statistics mentioned (use > blockquotes)
- End with a "Key Takeaways" section
- Aim for a thorough but readable summary""",

    "bullets": """Summarize this video transcript as a concise bullet-point list.

Format:
- Group related points under topic headings (use ## for headings)
- Use clear, complete sentences for each bullet
- Include specific claims, numbers, or examples mentioned
- Aim for 15-30 bullet points total
- No prose paragraphs, bullets only""",

    "chapters": """Create a chapter-by-chapter breakdown of this video transcript.

Format:
- Identify natural topic transitions and create chapters
- For each chapter, provide:
  - A descriptive chapter title (## heading)
  - 2-3 sentence summary of that section
  - Key points as bullet list
- Number the chapters sequentially
- Note when the speaker transitions between topics""",

    "blog": """Transform this video transcript into a compelling, engaging blog post that readers can't put down.

CRITICAL — ENGAGEMENT RULES (DocFlow framework):

1. OPENING HOOK (mandatory, first 150 words):
   - Start with a specific, intriguing question that the video answers
   - OR a "you" + problem statement ("Ever struggled with X?", "Tired of Y?")
   - OR a surprising statistic/claim from the video
   - OR an explicit outcome promise ("By the end, you'll understand...")
   - NEVER start with generic introductions like "In this video..." or "The speaker discusses..."

2. CURIOSITY & INFORMATION GAPS:
   - Use question-based headings (## Why Does X Happen? ## How Can You Avoid Y?)
   - Create micro-cliffhangers at section transitions ("But here's where it gets interesting...")
   - Pose each problem/question BEFORE giving the answer
   - Use concrete specifics, not abstractions

3. READER-CENTERED VOICE:
   - Use "you" and "your" frequently — address the reader directly
   - Active voice only (NEVER "it was explained that..." — use "the speaker explains...")
   - Conversational tone: contractions (you'll, here's, let's), questions, informal phrasing
   - High "you" to "the video/speaker" ratio (aim for 3:1)

4. CLARITY & SCANNABILITY:
   - Short sentences (max 25 words average)
   - Descriptive, keyword-rich headings (not "Overview" or "Details")
   - Break dense sections into subsections with ## or #### headings
   - Frontload key points in each paragraph (topic sentence first)

5. CONCRETE EXAMPLES:
   - Every major concept needs a concrete example with specific details
   - NEVER use placeholder names (foo, bar, example, test, sample)
   - Use domain-specific, real-world examples from the transcript
   - Include quotes from the speaker when they're vivid or specific

6. FLOW & MOMENTUM:
   - Use transition phrases between sections ("Now that you understand X...", "Let's see how...", "Here's where it gets interesting...")
   - End with "What's Next" or "Key Takeaways" section
   - Create narrative arc: setup problem → explore solutions → resolution/insights

7. FORBIDDEN LLM VOCABULARY (use natural alternatives):
   - NEVER: delve, tapestry, landscape, realm, embark, cornerstone, underpinning, pivotal, paramount, robust, meticulous
   - NEVER: "It's worth noting that", "It's important to understand", "At the end of the day"
   - AVOID excessive em dashes (—), use regular dashes (-) or commas
   - Write like a human expert, NOT a language model

8. STRUCTURE:
   - Opening hook paragraph (150 words)
   - Problem/context section with question-based heading
   - 3-5 main insight sections, each with:
     * Clear, specific heading
     * Topic sentence stating main point
     * Supporting details with examples/quotes
     * Transition to next section
   - "Key Takeaways" section (3-5 bullets, action-oriented)
   - "What's Next" or final thought

OUTPUT REQUIREMENTS:
- Clean Markdown with ## headings for major sections, #### for subsections
- No meta-commentary ("This blog post...", "The video covers...")
- Preserve all factual claims and insights from the transcript
- 800-1500 words (comprehensive but focused)
- Include 2-3 direct quotes from the speaker (use > blockquotes)
- Suggest where images/diagrams would enhance understanding [IMAGE: description]

Remember: Your goal is to make this content so engaging that readers can't stop reading. Use all the psychological triggers — curiosity gaps, reader focus, momentum, concrete examples — to create addictive documentation."""
}

SYSTEM_PROMPT = """You are an expert content writer specializing in transforming video transcripts into compelling written content.

Core Principles:
- Capture ALL major points and arguments — comprehensive coverage required
- Preserve specific claims, statistics, names, examples, and quotes exactly as stated
- Maintain the logical flow and structure of the original discussion
- Use clear, precise, human language (never robotic or formulaic)
- NEVER add opinions, interpretations, or information not in the transcript
- NEVER use LLM telltale words: delve, tapestry, landscape, realm, embark, cornerstone, robust, meticulous, pivotal, paramount
- NEVER use filler phrases: "It's worth noting", "At the end of the day", "It's important to understand"
- Write like a skilled human writer, not an AI assistant

Output Format:
- Clean, well-structured Markdown
- For blog posts: apply DocFlow engagement framework (see style instructions)
- For summaries: focus on clarity and comprehensiveness
- Always preserve the speaker's voice and key insights"""

style_instruction = STYLE_PROMPTS[style]

# ── Chunking strategy ────────────────────────────────────────────────────────
# Qwen 2.5 32B: 32k token context window
# Budget: ~4k output + ~2k prompt = 6k overhead → 26k tokens available for input
# At ~1.3 tokens/word, safely handle up to 20k words in single pass

MAX_SINGLE_PASS_WORDS = 20000
CHUNK_SIZE = 18000  # If chunking needed, use large chunks
MAX_SUMMARY_TOKENS = 4096

# Only chunk if transcript exceeds single-pass capacity
if total_words <= MAX_SINGLE_PASS_WORDS:
    chunks = [transcript]
    print(f"Transcript fits in single pass ({total_words:,} ≤ {MAX_SINGLE_PASS_WORDS:,} words)")
else:
    # Split at sentence boundaries for very long transcripts
    chunks = []
    current_chunk = []
    current_count = 0

    for word in words:
        current_chunk.append(word)
        current_count += 1
        if current_count >= CHUNK_SIZE and word.endswith(('.', '!', '?', '."', '?"', '!"')):
            chunks.append(' '.join(current_chunk))
            current_chunk = []
            current_count = 0

    if current_chunk:
        chunks.append(' '.join(current_chunk))
    
    print(f"Transcript exceeds single-pass limit, using {len(chunks)} chunks")

print()

# ── Load model ───────────────────────────────────────────────────────────────

print(f"Loading model: {model_name}")
t0 = time.time()
from mlx_lm import load, generate

model, tokenizer = load(model_name)
load_time = time.time() - t0
print(f"Model loaded in {load_time:.1f}s")
print()

# ── Generate summaries ───────────────────────────────────────────────────────

def run_llm(system, user, max_tokens=MAX_SUMMARY_TOKENS):
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]
    formatted = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )
    t0 = time.time()
    response = generate(
        model,
        tokenizer,
        prompt=formatted,
        max_tokens=max_tokens,
        verbose=False,
    )
    elapsed = time.time() - t0
    # Rough token count for speed reporting
    out_tokens = len(response.split()) * 1.3  # approximate
    speed = out_tokens / elapsed if elapsed > 0 else 0
    print(f"  Generated ~{int(out_tokens)} tokens in {elapsed:.1f}s ({speed:.1f} tok/s)")
    return response.strip()


if len(chunks) == 1:
    # Single-pass summarization (optimal path)
    print("Generating summary in single pass...")
    user_prompt = f"{style_instruction}\n\nTranscript:\n\n{chunks[0]}"
    summary = run_llm(SYSTEM_PROMPT, user_prompt)

else:
    # Multi-pass: summarize each chunk, then synthesize (only for very long transcripts)
    print(f"Multi-pass summarization ({len(chunks)} chunks)...")
    print(f"Pass 1: Summarizing chunks individually...")
    chunk_summaries = []

    for i, chunk in enumerate(chunks):
        print(f"  Chunk {i+1}/{len(chunks)} ({len(chunk.split()):,} words)...")
        user_prompt = (
            f"Summarize this section of a longer video transcript. "
            f"This is part {i+1} of {len(chunks)}.\n\n"
            f"Capture all key points, arguments, names, and specific claims.\n\n"
            f"Transcript section:\n\n{chunk}"
        )
        chunk_summary = run_llm(SYSTEM_PROMPT, user_prompt, max_tokens=2048)
        chunk_summaries.append(chunk_summary)

    print()
    print("Pass 2: Synthesizing final summary from chunk summaries...")

    combined = "\n\n---\n\n".join(
        f"## Section {i+1}\n{s}" for i, s in enumerate(chunk_summaries)
    )
    synthesis_prompt = (
        f"{style_instruction}\n\n"
        f"Below are summaries of consecutive sections of a video transcript. "
        f"Synthesize them into a single, coherent summary that flows naturally "
        f"and eliminates redundancy.\n\n{combined}"
    )
    summary = run_llm(SYSTEM_PROMPT, synthesis_prompt)

# ── Write output ─────────────────────────────────────────────────────────────

source_name = metadata.get('source', transcript_file.rsplit('/', 1)[-1])
output_words = len(summary.split())

# Different front matter for blog posts vs summaries
if style == 'blog':
    header = f"# {source_name.replace('_transcript.txt', '').replace('_', ' ')}\n\n"
    header += f"*Originally from: {source_name}*\n\n"
    header += f"---\n\n"
else:
    header = f"# Summary: {source_name}\n\n"
    header += f"| | |\n|---|---|\n"
    header += f"| **Source** | {source_name} |\n"
    header += f"| **Words** | {total_words:,} |\n"
    header += f"| **Model** | {model_label} |\n"
    header += f"| **Style** | {style} |\n"
    header += f"\n---\n\n"

with open(output_file, 'w') as f:
    f.write(header)
    f.write(summary)
    f.write('\n')

print()
print(f"{'Blog post' if style == 'blog' else 'Summary'} saved to: {output_file}")
print(f"Transcript: {total_words:,} words → Output: {output_words:,} words")
PYTHON_SCRIPT

echo ""
echo "Done!"
if [ "$STYLE" = "blog" ]; then
    echo "Blog post: $OUTPUT_FILE"
else
    echo "Summary: $OUTPUT_FILE"
fi
