#!/bin/bash

set -euo pipefail

# transcribrr.sh — End-to-end audio pipeline orchestrator
# Drives transcribe.sh -> cleanup-transcript.sh -> summarize-transcript.sh unattended.
# Usage: ./transcribrr.sh <audio.mp3> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults (per D-08) ──────────────────────────────────────────────────────

WHISPER_MODEL="small"
CLEANUP_MODEL="llama3.1-8b-4bit"
SUMMARY_MODEL="Qwen2.5-32B-4bit"
SUMMARY_STYLE="blog"
NO_CLEANUP=false
MP3_FILE=""

# ── ERR trap — names the failing stage ───────────────────────────────────────

CURRENT_STAGE="preflight"
trap 'echo "Error: transcribrr.sh failed during stage: $CURRENT_STAGE" >&2' ERR

# ── Help ─────────────────────────────────────────────────────────────────────

print_help() {
    cat << 'EOF'
Usage: transcribrr.sh <audio.mp3> [options]

  Transcribes, cleans, and summarizes an audio file using local MLX models.
  Runs transcribe.sh -> cleanup-transcript.sh -> summarize-transcript.sh
  fully unattended with zero interactive prompts.

Arguments:
  <audio.mp3>             Path to an MP3 (or any ffmpeg-readable audio) file

Options:
  --whisper-model <label|hf-id>
                          Whisper model for transcription.
                          Labels: tiny, base, small, medium, large-v3, turbo
                          Or a raw Hugging Face model ID (must contain '/')
                          Default: small

  --cleanup-model <label|hf-id>
                          LLM for transcript cleanup.
                          Labels: llama3.2-1b-4bit, llama3.2-3b-4bit,
                                  llama3.1-8b-4bit, llama3.1-8b-8bit
                          Or a raw Hugging Face model ID
                          Default: llama3.1-8b-4bit

  --no-cleanup            Skip the transcript cleanup stage and feed the raw
                          transcript directly into summarization.

  --summary-model <label|hf-id>
                          LLM for summarization.
                          Labels: Qwen2.5-7B-4bit, Qwen2.5-14B-4bit,
                                  Qwen2.5-32B-4bit, Qwen2.5-32B-8bit
                          Or a raw Hugging Face model ID
                          Default: Qwen2.5-32B-4bit

  --summary-style <style>
                          Summary output style.
                          Styles: executive, detailed, bullets, chapters, blog
                          Default: blog

  --help, -h              Show this help message and exit

Examples:
  transcribrr.sh talk.mp3
  transcribrr.sh talk.mp3 --whisper-model turbo --summary-style detailed
  transcribrr.sh talk.mp3 --no-cleanup --summary-model Qwen2.5-7B-4bit
  transcribrr.sh talk.mp3 --whisper-model mlx-community/whisper-large-v3-turbo
  transcribrr.sh talk.mp3 --cleanup-model llama3.2-3b-4bit --summary-style bullets
EOF
}

# ── Flag parsing ─────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --whisper-model)
            WHISPER_MODEL="$2"
            shift 2
            ;;
        --cleanup-model)
            CLEANUP_MODEL="$2"
            shift 2
            ;;
        --summary-model)
            SUMMARY_MODEL="$2"
            shift 2
            ;;
        --summary-style)
            SUMMARY_STYLE="$2"
            shift 2
            ;;
        --no-cleanup)
            NO_CLEANUP=true
            shift
            ;;
        --help|-h)
            print_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
        *)
            MP3_FILE="$1"
            shift
            ;;
    esac
done

# ── Preflight check (D-10, ROB-01) ───────────────────────────────────────────
# Accumulates ALL failures before aborting so the user can fix everything at once.

preflight_check() {
    local errors=0

    # Validate input file
    if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
        echo "Error: Input file not found: ${MP3_FILE:-<not specified>}" >&2
        errors=$((errors + 1))
    fi

    # Validate each required sub-script exists and is executable
    for script in transcribe.sh cleanup-transcript.sh summarize-transcript.sh; do
        local path="$SCRIPT_DIR/$script"
        if [ ! -f "$path" ]; then
            echo "Error: Required script not found: $path" >&2
            errors=$((errors + 1))
        elif [ ! -x "$path" ]; then
            echo "Error: Script is not executable: $path" >&2
            errors=$((errors + 1))
        fi
    done

    # Validate ffmpeg is available (transcribe.sh uses it for duration)
    if ! command -v ffmpeg &>/dev/null; then
        echo "Error: ffmpeg not found on PATH. Install with: brew install ffmpeg" >&2
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        echo "Aborting: $errors preflight check(s) failed." >&2
        exit 1
    fi
}

# ── Stage progress banner (CLI-03) ───────────────────────────────────────────

stage_banner() {
    local msg="$1"
    echo ""
    echo "=========================================="
    echo "  $msg"
    echo "=========================================="
    echo ""
}

preflight_check

# ── Stage 1: Transcribe (TR-03) ──────────────────────────────────────────────

CURRENT_STAGE="transcribe"
stage_banner "Stage 1/3: Transcribing (whisper model: $WHISPER_MODEL)"

STAGE_OUT=$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
    | tee /dev/stderr \
    | grep "^OUTPUT_FILE=")
TRANSCRIPT_FILE="${STAGE_OUT#OUTPUT_FILE=}"

if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Error: transcribe stage did not produce a valid output file." >&2
    exit 1
fi

# ── Stage 2: Cleanup (CL-03, D-09) ──────────────────────────────────────────

if [ "$NO_CLEANUP" = false ]; then
    CURRENT_STAGE="cleanup"
    stage_banner "Stage 2/3: Cleaning transcript (model: $CLEANUP_MODEL)"

    STAGE_OUT=$("$SCRIPT_DIR/cleanup-transcript.sh" "$TRANSCRIPT_FILE" --model "$CLEANUP_MODEL" \
        | tee /dev/stderr \
        | grep "^OUTPUT_FILE=")
    CLEANED_FILE="${STAGE_OUT#OUTPUT_FILE=}"

    if [ -z "$CLEANED_FILE" ] || [ ! -f "$CLEANED_FILE" ]; then
        echo "Error: cleanup stage did not produce a valid output file." >&2
        exit 1
    fi

    SUMMARIZE_INPUT="$CLEANED_FILE"
else
    echo "Skipping cleanup stage (--no-cleanup specified)."
    SUMMARIZE_INPUT="$TRANSCRIPT_FILE"
fi

# ── Stage 3: Summarize (SUM-03) ──────────────────────────────────────────────

CURRENT_STAGE="summarize"
stage_banner "Stage 3/3: Summarizing (model: $SUMMARY_MODEL, style: $SUMMARY_STYLE)"

STAGE_OUT=$("$SCRIPT_DIR/summarize-transcript.sh" "$SUMMARIZE_INPUT" \
    --model "$SUMMARY_MODEL" \
    --style "$SUMMARY_STYLE" \
    | tee /dev/stderr \
    | grep "^OUTPUT_FILE=")
SUMMARY_FILE="${STAGE_OUT#OUTPUT_FILE=}"

if [ -z "$SUMMARY_FILE" ] || [ ! -f "$SUMMARY_FILE" ]; then
    echo "Error: summarize stage did not produce a valid output file." >&2
    exit 1
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "  Pipeline complete!"
echo "=========================================="
echo "Summary written to: $SUMMARY_FILE"
