#!/bin/bash

set -euo pipefail

# benchmark.sh — Interactive staged benchmark sweep for transcribrr pipeline.
# Usage: ./benchmark.sh [--sample <youtube-url|mp3-path>]
# Dispatched from: transcribrr.sh --benchmark
#
# Runs every hardware-fitting candidate model for each stage (whisper → cleanup →
# summarize), measures speed and peak memory, shows real output excerpts, then
# prompts the user to pick the best result per stage. Per-stage picks chain into
# the next stage. Requires an interactive TTY (D-03).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Path constants (SCRIPT_DIR-relative) ────────────────────────────────────

VENV_DIR="$SCRIPT_DIR/.venv"
PYTHON="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"
HF_CLI="$VENV_DIR/bin/hf"
CANDIDATES_CONF="$SCRIPT_DIR/config/candidates.conf"
RESULTS_DIR="$SCRIPT_DIR/results"
HF_CACHE="${HOME}/.cache/huggingface/hub"

# ── Tuning constants ─────────────────────────────────────────────────────────

# Runtime-overhead buffer added to each candidate's size_gb for the fit gate.
# Covers Python interpreter + tokenizer + MLX allocator baseline (~2-3 GB);
# does NOT cover KV cache (that's per-model; D-07 / RESEARCH Section 1).
BENCH_OVERHEAD_BUFFER_GB=4   # D-07: 4 GB recommended; large transcripts → generous headroom

# Fixed cool-down pause between candidates to allow thermal recovery (D-14).
# 30–60 s range from PITFALLS #4; 45 s is midpoint, conservative.
BENCH_COOLDOWN_SECS=45       # D-14: 45 s default within 30–60 s range

# ── ERR trap (stage-level; per-candidate failures use set +e brackets) ───────
# NOTE: per-candidate failures are handled with set +e / set -e brackets
# (D-16 / continue-on-failure, added in plan 04-03). This trap fires only for
# unexpected framework-level failures, not individual candidate OOMs.

CURRENT_STAGE="init"
trap 'echo "Error: benchmark.sh failed during: $CURRENT_STAGE" >&2' ERR

# ── Argument parsing ─────────────────────────────────────────────────────────

BENCH_SAMPLE_ARG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --sample)
            BENCH_SAMPLE_ARG="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Usage: benchmark.sh [--sample <url|mp3>]" >&2
            exit 1
            ;;
    esac
done

# ── TTY guard (D-03) ─────────────────────────────────────────────────────────
# Must be FIRST: no point proceeding if the user cannot respond to prompts.
# [ -t 0 ] = stdin is a terminal — correct check for interactive input availability.

if [ ! -t 0 ]; then
    echo "Error: --benchmark requires an interactive TTY." >&2
    echo "  Run directly from a terminal, not piped or in cron." >&2
    exit 1
fi

# ── setup_venv (Pitfall B: MUST be called before any .venv/bin/* access) ────
# Ensures .venv exists and mlx-lm is installed (which also provides .venv/bin/hf).
# BENCH-07: auto-install mlx-lm so .venv/bin/hf and .venv/bin/python are available.

setup_venv() {
    if [ ! -d "$VENV_DIR" ]; then
        echo "Creating virtual environment at $VENV_DIR ..."
        python3 -m venv "$VENV_DIR"
    fi

    if ! "$PYTHON" -c "import mlx_lm" 2>/dev/null; then
        echo "Installing mlx-lm (required for benchmark)..."
        "$PIP" install --upgrade pip > /dev/null
        "$PIP" install mlx-lm
        echo ""
        echo "mlx-lm installed successfully."
    fi
}

setup_venv   # MUST be first action after TTY check — .venv/bin/hf needed for pre-fetch

# ── ensure_dep: auto-install or hint for a missing system dependency ──────────
# Usage: ensure_dep <command> <brew-formula>
# Returns 0 if the command is available (after install if needed), 1 on failure.
# Note: benchmark.sh is exec'd as a standalone script and cannot access
# transcribrr.sh's function definitions; this is a verbatim copy.

ensure_dep() {
    local cmd="$1"
    local formula="$2"

    if command -v "$cmd" &>/dev/null; then
        return 0
    fi

    if ! command -v brew &>/dev/null; then
        echo "Error: $cmd not found and Homebrew is not installed." >&2
        return 1
    fi

    echo "Installing missing dependency: $cmd (brew install $formula)..." >&2
    brew install "$formula"

    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: auto-install of $cmd via 'brew install $formula' failed." >&2
        return 1
    fi
    return 0
}

# ── stage_banner: progress header (CLI-03 — verbatim copy from transcribrr.sh) ─
# exec-dispatch gives benchmark.sh no access to transcribrr.sh's functions.

stage_banner() {
    local msg="$1"
    echo ""
    echo "=========================================="
    echo "  $msg"
    echo "=========================================="
    echo ""
}

# ── parse_candidates: parse config/candidates.conf (parse-not-exec, T-04-01) ───
# Returns one pipe-delimited line per matching candidate: id|label|size_gb
#
# Pattern from 04-RESEARCH.md Pattern 5 (verified on live file — correctly
# extracts all 4 whisper + 4 cleanup + 5 summarize candidates).
#
# CRITICAL (Pitfall E): The "emit last block" stanza after the while loop is
# MANDATORY. Without it the last candidate per stage is silently dropped.

parse_candidates() {
    local stage_filter="$1"
    local conf_file="$2"
    local in_block=false
    local current_stage="" current_id="" current_label="" current_size=""

    while IFS= read -r line; do
        case "$line" in
            "[candidate]")
                if [ "$in_block" = true ] && [ "$current_stage" = "$stage_filter" ]; then
                    printf '%s|%s|%s\n' "$current_id" "$current_label" "$current_size"
                fi
                in_block=true
                current_stage="" current_id="" current_label="" current_size=""
                ;;
            stage=*)   current_stage="${line#stage=}" ;;
            id=*)      current_id="${line#id=}" ;;
            label=*)   current_label="${line#label=}" ;;
            size_gb=*) current_size="${line#size_gb=}" ;;
            "#"*|"")   : ;;
        esac
    done < "$conf_file"
    # Emit last block (Pitfall E — without this, last candidate per stage is silently dropped)
    if [ "$in_block" = true ] && [ "$current_stage" = "$stage_filter" ]; then
        printf '%s|%s|%s\n' "$current_id" "$current_label" "$current_size"
    fi
}

# TODO: REMOVE AFTER 04-04 — temporary skeleton smoke check; 04-04 Task 1 strips this block
# This block verifies the skeleton is runnable and the parser returns correct candidate counts.

CURRENT_STAGE="smoke-check"

ensure_dep ffmpeg ffmpeg
ensure_dep yt-dlp yt-dlp

stage_banner "Benchmark skeleton smoke check"

echo "Candidates.conf: $CANDIDATES_CONF"
echo ""

WHISPER_COUNT=0
while IFS='|' read -r model_id label size_gb; do
    WHISPER_COUNT=$((WHISPER_COUNT + 1))
    printf "  whisper [%d] id=%s  label=%s  size_gb=%s\n" \
        "$WHISPER_COUNT" "$model_id" "$label" "$size_gb"
done < <(parse_candidates "whisper" "$CANDIDATES_CONF")

CLEANUP_COUNT=0
while IFS='|' read -r model_id label size_gb; do
    CLEANUP_COUNT=$((CLEANUP_COUNT + 1))
    printf "  cleanup [%d] id=%s  label=%s  size_gb=%s\n" \
        "$CLEANUP_COUNT" "$model_id" "$label" "$size_gb"
done < <(parse_candidates "cleanup" "$CANDIDATES_CONF")

SUMMARIZE_COUNT=0
while IFS='|' read -r model_id label size_gb; do
    SUMMARIZE_COUNT=$((SUMMARIZE_COUNT + 1))
    printf "  summarize [%d] id=%s  label=%s  size_gb=%s\n" \
        "$SUMMARIZE_COUNT" "$model_id" "$label" "$size_gb"
done < <(parse_candidates "summarize" "$CANDIDATES_CONF")

echo ""
printf "Detected candidates: whisper=%d  cleanup=%d  summarize=%d\n" \
    "$WHISPER_COUNT" "$CLEANUP_COUNT" "$SUMMARIZE_COUNT"
echo ""
echo "Skeleton OK. Implement staged sweep in plans 04-02 through 04-04."
# ── END temporary smoke check block ──────────────────────────────────────────
