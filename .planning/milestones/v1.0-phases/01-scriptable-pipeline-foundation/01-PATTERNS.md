# Phase 1: Scriptable Pipeline Foundation - Pattern Map

**Mapped:** 2026-06-14
**Files analyzed:** 4 (1 new, 3 modified)
**Analogs found:** 4 / 4

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `transcribrr.sh` (new) | orchestrator/utility | request-response, batch | `summarize-transcript.sh` | role-match (flag parsing, `set -euo pipefail`, `SCRIPT_DIR` idiom) |
| `transcribe.sh` (modify) | service | batch / file-I/O | itself (self-analog) + `summarize-transcript.sh` flag parser | exact — same file, extend the existing `for arg` loop |
| `cleanup-transcript.sh` (modify) | service | batch / file-I/O | itself (self-analog) + `summarize-transcript.sh` flag parser | exact — same file, replace positional arg with `while` loop |
| `summarize-transcript.sh` (modify) | service | batch / file-I/O | itself (self-analog) | exact — already has `--install` flag; extend same `for arg` loop |

---

## Pattern Assignments

### `transcribrr.sh` (new orchestrator, request-response)

**Primary analog:** `summarize-transcript.sh` (for shebang, `set -euo pipefail`, `SCRIPT_DIR`, flag loop)
**Secondary analog:** `mlx-chat.sh` (for `command -v` dependency check idiom and the `if [[ "$choice" == */* ]]` HF-ID detection pattern)

---

#### Shebang and strict mode

**Source:** `summarize-transcript.sh` lines 1, 9

```bash
#!/bin/bash

set -euo pipefail
```

Note: `transcribe.sh` does NOT use `set -euo pipefail` (verified: no `set -e` anywhere in that file). The new orchestrator MUST use `set -euo pipefail` — sub-script exit codes are still propagated correctly from a child process. The asymmetry is intentional; only the orchestrator needs strict mode.

---

#### `SCRIPT_DIR` resolution

**Source:** `summarize-transcript.sh` line 26 / `cleanup-transcript.sh` line 17 / `transcribe.sh` line 59

All three scripts use the identical idiom:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

The orchestrator must use this same pattern so sub-scripts are located correctly regardless of the user's `$CWD`.

---

#### `while` flag-parsing loop

**Source:** `summarize-transcript.sh` lines 14–23 (existing `--install` flag parser is the template)

```bash
# Current summarize-transcript.sh flag parser (lines 14-23):
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
```

For `transcribrr.sh`, expand this into a `while [[ $# -gt 0 ]]` loop so two-token flags (`--whisper-model small`) can consume `$2`:

```bash
# Pattern for transcribrr.sh (and sub-script refactors that need --flag value):
MP3_FILE=""
WHISPER_MODEL="small"
CLEANUP_MODEL="llama3.1-8b-4bit"
SUMMARY_MODEL="Qwen2.5-32B-4bit"
SUMMARY_STYLE="blog"
NO_CLEANUP=false

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
            exit 1
            ;;
        *)
            MP3_FILE="$1"
            shift
            ;;
    esac
done
```

---

#### HF model ID detection (contains `/`)

**Source:** `mlx-chat.sh` line 314

```bash
# mlx-chat.sh line 314 — detect raw HF ID vs menu choice:
if [[ "$choice" == */* ]]; then
    SELECTED_MODEL="$choice"
```

Use the same glob test in each sub-script refactor. When a flag value contains `/`, treat it as a raw HF model ID and apply label sanitization instead of a friendly-label `case` match.

---

#### `--help` block (heredoc pattern)

**Source:** `cleanup-transcript.sh` lines 10–14 (basic usage echo) and `summarize-transcript.sh` lines 66–75 (multi-line usage). The `mlx-chat.sh` shows a richer `cat << 'EOF'` heredoc is also idiomatic. Prefer a function:

```bash
print_help() {
    cat << 'EOF'
Usage: transcribrr.sh <audio.mp3> [options]

  Transcribes, cleans, and summarizes an audio file using local MLX models.

Arguments:
  <audio.mp3>             Path to an MP3 (or any ffmpeg-readable audio) file

Options:
  --whisper-model <label|hf-id>
                          Whisper model: tiny, base, small, medium, large-v3, turbo
                          or a raw Hugging Face model ID (contains '/')
                          Default: small

  --cleanup-model <label|hf-id>
                          Cleanup LLM: llama3.2-1b-4bit, llama3.2-3b-4bit,
                          llama3.1-8b-4bit, llama3.1-8b-8bit
                          or a raw Hugging Face model ID
                          Default: llama3.1-8b-4bit

  --no-cleanup            Skip the transcript cleanup stage

  --summary-model <label|hf-id>
                          Summary LLM: Qwen2.5-7B-4bit, Qwen2.5-14B-4bit,
                          Qwen2.5-32B-4bit, Qwen2.5-32B-8bit
                          or a raw Hugging Face model ID
                          Default: Qwen2.5-32B-4bit

  --summary-style <style>
                          Summary style: executive, detailed, bullets, chapters, blog
                          Default: blog

  --help, -h              Show this help message and exit

Examples:
  transcribrr.sh talk.mp3
  transcribrr.sh talk.mp3 --whisper-model turbo --summary-style detailed
  transcribrr.sh talk.mp3 --no-cleanup --summary-model Qwen2.5-7B-4bit
  transcribrr.sh talk.mp3 --whisper-model mlx-community/whisper-large-v3-turbo
EOF
}
```

---

#### Preflight dependency check

**Source:** `transcribe.sh` lines 47–56 and 62–68 (file-existence + binary-existence checks). Pattern extends the same idioms into a function:

```bash
# transcribe.sh lines 47-56 (input validation):
if [ -z "$AUDIO_FILE" ]; then
    echo "Usage: $0 <audio_file>"
    exit 1
fi
if [ ! -f "$AUDIO_FILE" ]; then
    echo "Error: File '$AUDIO_FILE' not found"
    exit 1
fi

# transcribe.sh lines 62-68 (binary check):
if [ ! -f "$WHISPER_CMD" ]; then
    echo "Error: mlx_whisper not found at $WHISPER_CMD"
    echo "Please install it first with: pip install mlx-whisper"
    exit 1
fi
```

For `transcribrr.sh`, consolidate into a single preflight function that accumulates all errors before aborting (fail with a full list, not just the first missing item):

```bash
preflight_check() {
    local errors=0

    if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
        echo "Error: Input file not found: ${MP3_FILE:-<not specified>}" >&2
        errors=$((errors + 1))
    fi

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

    if ! command -v ffmpeg &>/dev/null; then
        echo "Error: ffmpeg not found on PATH. Install with: brew install ffmpeg" >&2
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        echo "Aborting: $errors preflight check(s) failed." >&2
        exit 1
    fi
}
```

---

#### Stage invocation and OUTPUT_FILE capture

**Source:** `transcribe.sh` line 275 (current echo to be changed), `cleanup-transcript.sh` line 211, `summarize-transcript.sh` lines 453–457.

The current echo in each script is NOT machine-parseable:
- `transcribe.sh` line 275: `echo "Transcript: $OUTPUT_FILE"`
- `cleanup-transcript.sh` line 211: `echo "Cleaned transcript: $OUTPUT_FILE"`
- `summarize-transcript.sh` line 453–457: `echo "Blog post: $OUTPUT_FILE"` / `echo "Summary: $OUTPUT_FILE"`

Each must be followed by (or replaced with) the machine-parseable line: `echo "OUTPUT_FILE=$OUTPUT_FILE"`

The orchestrator captures it using `tee /dev/stderr` (to pass all progress output through to the terminal) + `grep`:

```bash
# In transcribrr.sh — invoke a stage, show all output to user, capture OUTPUT_FILE= line
STAGE_OUT=$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
    | tee /dev/stderr \
    | grep "^OUTPUT_FILE=")
TRANSCRIPT_FILE="${STAGE_OUT#OUTPUT_FILE=}"

if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Error: transcribe stage did not produce a valid output file." >&2
    exit 1
fi
```

Repeat the same pattern for cleanup and summarize stages, binding `CLEANED_FILE` and `SUMMARY_FILE` respectively.

---

#### ERR trap for stage-context error messages

**Source:** `transcribe.sh` lines 33–34 (signal trap idiom):

```bash
# transcribe.sh signal trap pattern (lines 33-34):
trap cleanup SIGINT SIGTERM
```

Extend to an ERR trap in the orchestrator so failures name the failing stage:

```bash
CURRENT_STAGE="preflight"
trap 'echo "Error: transcribrr.sh failed during stage: $CURRENT_STAGE" >&2' ERR

CURRENT_STAGE="transcribe"
# ... invoke transcribe.sh ...

CURRENT_STAGE="cleanup"
# ... invoke cleanup-transcript.sh ...

CURRENT_STAGE="summarize"
# ... invoke summarize-transcript.sh ...
```

---

#### Per-stage progress banners

**Source:** `transcribe.sh` lines 168–169 (separator echo):

```bash
# transcribe.sh line 168-169:
echo "========================================"
echo ""
```

Use a consistent banner function in `transcribrr.sh`:

```bash
stage_banner() {
    local msg="$1"
    echo ""
    echo "=========================================="
    echo "  $msg"
    echo "=========================================="
    echo ""
}

stage_banner "Stage 1/3: Transcribing  (whisper model: $WHISPER_MODEL)"
stage_banner "Stage 2/3: Cleaning transcript  (model: $CLEANUP_MODEL)"
stage_banner "Stage 3/3: Summarizing  (model: $SUMMARY_MODEL, style: $SUMMARY_STYLE)"
```

---

### `transcribe.sh` (modify — add `--model` flag, emit `OUTPUT_FILE=`)

**Self-analog:** `transcribe.sh` itself. The existing `for arg` loop (lines 39–45) is the starting point.

---

#### Current arg-parsing loop to replace

**Source:** `transcribe.sh` lines 37–45:

```bash
# CURRENT (lines 37-45) — only accepts positional, no flags:
AUDIO_FILE=""

for arg in "$@"; do
    case $arg in
        *)
            AUDIO_FILE="$arg"
            ;;
    esac
done
```

Replace with a `while [[ $# -gt 0 ]]` loop (same pattern as `summarize-transcript.sh` lines 14–23, extended for a two-token flag):

```bash
# REPLACEMENT:
AUDIO_FILE=""
MODEL_FLAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL_FLAG="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            AUDIO_FILE="$1"
            shift
            ;;
    esac
done
```

---

#### Current model `case` block to replace (lines 91–143)

**Source:** `transcribe.sh` lines 91–143 (the interactive `read -p` + `case` block).

Replace the entire block (lines 91–143, from `echo "Select Whisper model:"` through the closing `esac`) with flag-driven selection. The `case` labels map directly from the existing menu choices:

```bash
# REPLACEMENT for transcribe.sh lines 91-143:
if [ -n "$MODEL_FLAG" ]; then
    if [[ "$MODEL_FLAG" == */* ]]; then
        # Raw HF model ID — apply same sanitization as cleanup-transcript.sh line 50
        MODEL_SIZE="$MODEL_FLAG"
        MODEL_LABEL=$(echo "$MODEL_FLAG" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
    else
        case "$MODEL_FLAG" in
            tiny)     MODEL_SIZE="mlx-community/whisper-tiny"           ; MODEL_LABEL="tiny" ;;
            base)     MODEL_SIZE="mlx-community/whisper-base-mlx"       ; MODEL_LABEL="base" ;;
            small)    MODEL_SIZE="mlx-community/whisper-small-mlx"      ; MODEL_LABEL="small" ;;
            medium)   MODEL_SIZE="mlx-community/whisper-medium-mlx"     ; MODEL_LABEL="medium" ;;
            large-v3) MODEL_SIZE="mlx-community/whisper-large-v3-mlx"   ; MODEL_LABEL="large-v3" ;;
            turbo)    MODEL_SIZE="mlx-community/whisper-large-v3-turbo" ; MODEL_LABEL="turbo" ;;
            *)
                echo "Error: Unknown whisper model '$MODEL_FLAG'. Valid labels: tiny base small medium large-v3 turbo" >&2
                exit 1
                ;;
        esac
    fi
else
    # Default: small (README-recommended, matches current menu default of choice 3/"")
    MODEL_SIZE="mlx-community/whisper-small-mlx"
    MODEL_LABEL="small"
fi
```

---

#### OUTPUT_FILE echo to change

**Source:** `transcribe.sh` line 275:

```bash
# CURRENT (line 275):
echo "Transcript: $OUTPUT_FILE"

# ADD immediately after (do not remove the existing echo — keep it for human readers):
echo "OUTPUT_FILE=$OUTPUT_FILE"
```

The `OUTPUT_FILE` variable is set at line 149: `OUTPUT_FILE="${BASENAME}_transcript_${MODEL_LABEL}.txt"` — this naming must be preserved so `.gitignore` pattern `*_transcript_*.txt` continues to match.

---

### `cleanup-transcript.sh` (modify — add `--model` flag, emit `OUTPUT_FILE=`)

**Self-analog:** `cleanup-transcript.sh` itself.

---

#### Current positional arg assignment to replace

**Source:** `cleanup-transcript.sh` line 8:

```bash
# CURRENT (line 8):
TRANSCRIPT_FILE="${1:-}"
```

Replace with a `while` loop matching the pattern from `summarize-transcript.sh` lines 14–23:

```bash
# REPLACEMENT:
TRANSCRIPT_FILE=""
MODEL_FLAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL_FLAG="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            TRANSCRIPT_FILE="$1"
            shift
            ;;
    esac
done
```

---

#### Current model `case` block to replace (lines 28–54)

**Source:** `cleanup-transcript.sh` lines 28–54 (the `echo "Select LLM..."` through closing `esac`).

Replace the entire block with flag-driven selection. The label sanitization on line 50 is the canonical expression — reuse it verbatim for raw HF IDs:

```bash
# REPLACEMENT for cleanup-transcript.sh lines 28-54:
if [ -n "$MODEL_FLAG" ]; then
    if [[ "$MODEL_FLAG" == */* ]]; then
        MODEL="$MODEL_FLAG"
        # Canonical sanitizer — line 50 of the original script:
        MODEL_LABEL=$(echo "$MODEL" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
    else
        case "$MODEL_FLAG" in
            llama3.2-1b-4bit) MODEL="mlx-community/Llama-3.2-1B-Instruct-4bit"       ; MODEL_LABEL="llama3.2-1b-4bit" ;;
            llama3.2-3b-4bit) MODEL="mlx-community/Llama-3.2-3B-Instruct-4bit"       ; MODEL_LABEL="llama3.2-3b-4bit" ;;
            llama3.1-8b-4bit) MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"  ; MODEL_LABEL="llama3.1-8b-4bit" ;;
            llama3.1-8b-8bit) MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-8bit"  ; MODEL_LABEL="llama3.1-8b-8bit" ;;
            *)
                echo "Error: Unknown cleanup model '$MODEL_FLAG'. Valid labels: llama3.2-1b-4bit llama3.2-3b-4bit llama3.1-8b-4bit llama3.1-8b-8bit" >&2
                exit 1
                ;;
        esac
    fi
else
    # Default: llama3.1-8b-4bit (README-recommended, matches current menu default of choice 3/"")
    MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"
    MODEL_LABEL="llama3.1-8b-4bit"
fi
```

---

#### `OUTPUT_FILE` pre-assignment bug — critical positioning note

**Source:** `cleanup-transcript.sh` lines 26 and 61.

Line 26 sets `OUTPUT_FILE="${BASENAME}_cleaned.txt"` (wrong, no label).
Line 61 REASSIGNS `OUTPUT_FILE="${BASENAME}_cleaned_${MODEL_LABEL}.txt"` (correct).

After the refactor the flag-driven selection block (above) already sets `MODEL_LABEL` before any `OUTPUT_FILE` assignment, so the pre-assignment on line 26 can simply be removed, and line 61's assignment stands as the sole definition:

```bash
# Keep only this assignment (line 61 equivalent) — remove line 26's version:
OUTPUT_FILE="${BASENAME}_cleaned_${MODEL_LABEL}.txt"
```

---

#### OUTPUT_FILE echo to add

**Source:** `cleanup-transcript.sh` line 211:

```bash
# CURRENT (line 211):
echo "Cleaned transcript: $OUTPUT_FILE"

# ADD immediately after:
echo "OUTPUT_FILE=$OUTPUT_FILE"
```

The `OUTPUT_FILE` naming `*_cleaned_<MODEL_LABEL>.txt` must be preserved so `.gitignore` pattern `*_cleaned_*.txt` continues to match.

---

### `summarize-transcript.sh` (modify — add `--model` and `--style` flags, emit `OUTPUT_FILE=`)

**Self-analog:** `summarize-transcript.sh` itself. Already has `--install` in a `for arg` loop (lines 14–23). This is the template for adding `--model` and `--style`.

---

#### Current flag loop to extend (lines 13–23)

**Source:** `summarize-transcript.sh` lines 11–23:

```bash
# CURRENT (lines 11-23):
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
```

Replace `for arg` with a `while [[ $# -gt 0 ]]` loop, adding `--model` and `--style` (two-token flags) alongside the existing `--install`:

```bash
# REPLACEMENT:
TRANSCRIPT_FILE=""
INSTALL_ONLY=false
MODEL_FLAG=""
STYLE_FLAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --install)
            INSTALL_ONLY=true
            shift
            ;;
        --model)
            MODEL_FLAG="$2"
            shift 2
            ;;
        --style)
            STYLE_FLAG="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            TRANSCRIPT_FILE="$1"
            shift
            ;;
    esac
done
```

---

#### Current model `case` block to replace (lines 79–106)

**Source:** `summarize-transcript.sh` lines 79–106 (the `echo "Select Qwen model..."` through closing `esac`).

Replace with flag-driven selection. Note: the existing custom model case (line 96) sets `MODEL_LABEL="$MODEL"` without sanitization — this is a pre-existing bug that MUST be fixed here (Pitfall 3 in RESEARCH.md):

```bash
# REPLACEMENT for summarize-transcript.sh lines 79-106:
if [ -n "$MODEL_FLAG" ]; then
    if [[ "$MODEL_FLAG" == */* ]]; then
        MODEL="$MODEL_FLAG"
        # Apply same sanitization as cleanup-transcript.sh line 50 (fixes the unsanitized label bug):
        MODEL_LABEL=$(echo "$MODEL" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
    else
        case "$MODEL_FLAG" in
            Qwen2.5-7B-4bit)  MODEL="mlx-community/Qwen2.5-7B-Instruct-4bit"  ; MODEL_LABEL="Qwen2.5-7B-4bit" ;;
            Qwen2.5-14B-4bit) MODEL="mlx-community/Qwen2.5-14B-Instruct-4bit" ; MODEL_LABEL="Qwen2.5-14B-4bit" ;;
            Qwen2.5-32B-4bit) MODEL="mlx-community/Qwen2.5-32B-Instruct-4bit" ; MODEL_LABEL="Qwen2.5-32B-4bit" ;;
            Qwen2.5-32B-8bit) MODEL="mlx-community/Qwen2.5-32B-Instruct-8bit" ; MODEL_LABEL="Qwen2.5-32B-8bit" ;;
            *)
                echo "Error: Unknown summary model '$MODEL_FLAG'. Valid labels: Qwen2.5-7B-4bit Qwen2.5-14B-4bit Qwen2.5-32B-4bit Qwen2.5-32B-8bit" >&2
                exit 1
                ;;
        esac
    fi
else
    # Default: Qwen2.5-32B-4bit (README-recommended, matches current menu default of choice 3/"")
    MODEL="mlx-community/Qwen2.5-32B-Instruct-4bit"
    MODEL_LABEL="Qwen2.5-32B-4bit"
fi
```

---

#### Current style `case` block to replace (lines 110–127)

**Source:** `summarize-transcript.sh` lines 110–127 (the `echo "Select summary style..."` through closing `esac`).

```bash
# REPLACEMENT for summarize-transcript.sh lines 110-127:
if [ -n "$STYLE_FLAG" ]; then
    case "$STYLE_FLAG" in
        executive|detailed|bullets|chapters|blog)
            STYLE="$STYLE_FLAG"
            ;;
        *)
            echo "Error: Unknown style '$STYLE_FLAG'. Valid styles: executive detailed bullets chapters blog" >&2
            exit 1
            ;;
    esac
else
    # Default: blog (README-recommended, matches current menu default of choice 5/"")
    STYLE="blog"
fi
```

---

#### OUTPUT_FILE echo to change (lines 453–457)

**Source:** `summarize-transcript.sh` lines 451–457:

```bash
# CURRENT (lines 451-457):
echo ""
echo "Done!"
if [ "$STYLE" = "blog" ]; then
    echo "Blog post: $OUTPUT_FILE"
else
    echo "Summary: $OUTPUT_FILE"
fi

# ADD the machine-parseable line after the existing echoes (preserve human-readable output):
echo "OUTPUT_FILE=$OUTPUT_FILE"
```

The `OUTPUT_FILE` naming `*_summary_<MODEL_LABEL>_<STYLE>.md` must be preserved so `.gitignore` pattern `*_summary_*.md` continues to match. The `OUTPUT_FILE` assignment is at line 130: `OUTPUT_FILE="${BASENAME}_summary_${MODEL_LABEL}_${STYLE}.md"` — this line is unchanged; only the final echo is added.

---

## Shared Patterns

### `set -euo pipefail` usage

**Source:** `cleanup-transcript.sh` line 6, `summarize-transcript.sh` line 9 (both use it); `transcribe.sh` (does NOT use it).

- `cleanup-transcript.sh` and `summarize-transcript.sh` already have `set -euo pipefail`. Do not remove it.
- `transcribe.sh` does not have it. Do not add it — the existing background-process + `wait` pattern and the progress monitor loop are likely written to tolerate non-zero sub-commands, and adding strict mode risks breaking the monitoring loop.
- `transcribrr.sh` (new) MUST have `set -euo pipefail` at line 3, after the shebang.

### `SCRIPT_DIR` resolution

**Source:** All three existing scripts (lines 59/17/26 in transcribe/cleanup/summarize respectively).

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

Every bash script in this repo uses this exact form. Copy verbatim.

### Label sanitization (canonical expression)

**Source:** `cleanup-transcript.sh` line 50.

```bash
MODEL_LABEL=$(echo "$MODEL" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
```

This expression is used in two places today (cleanup line 50, and the fallback at line 58). It must be applied in all three script refactors when a raw HF ID is passed via `--model`, and in `transcribrr.sh` nowhere (the orchestrator passes the flag through; label sanitization lives in each sub-script).

### Input file validation pattern

**Source:** `transcribe.sh` lines 47–56, `cleanup-transcript.sh` lines 10–14, `summarize-transcript.sh` lines 66–75.

```bash
# Pattern used across all three scripts:
if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
    echo "Usage: $0 <input_file>"
    exit 1
fi
```

The refactors do not change this validation — it moves to after the flag-parsing loop but the content is identical.

### `command -v` dependency check

**Source:** `transcribe.sh` lines 62–68 (checks for `.venv/bin/mlx_whisper`). For binary-on-PATH checks, `command -v` is the idiomatic bash form.

```bash
if ! command -v ffmpeg &>/dev/null; then
    echo "Error: ffmpeg not found on PATH. Install with: brew install ffmpeg" >&2
    exit 1
fi
```

### `.venv` binary check pattern

**Source:** `transcribe.sh` lines 62–68, `cleanup-transcript.sh` lines 20–23.

```bash
# transcribe.sh lines 62-68:
WHISPER_CMD="$SCRIPT_DIR/.venv/bin/mlx_whisper"
if [ ! -f "$WHISPER_CMD" ]; then
    echo "Error: mlx_whisper not found at $WHISPER_CMD"
    echo "Please install it first with: pip install mlx-whisper"
    exit 1
fi

# cleanup-transcript.sh lines 18-23:
PYTHON="$SCRIPT_DIR/.venv/bin/python"
if [ ! -f "$PYTHON" ]; then
    echo "Error: Python not found at $PYTHON"
    exit 1
fi
```

In `transcribrr.sh`, the orchestrator's preflight does NOT duplicate these checks — each sub-script still handles its own `.venv` validation. The orchestrator only checks that the sub-script files exist and are executable.

---

## No Analog Found

All four files (the three sub-scripts and the new orchestrator) have strong codebase analogs. No file is without a match.

---

## Key Pitfalls to Flag for Planner

These are derived from RESEARCH.md and the actual source reads:

1. **`cleanup-transcript.sh` pre-assignment bug (lines 26 vs 61):** After the refactor, `OUTPUT_FILE` must be set ONLY after `MODEL_LABEL` is known (i.e., only the line-61 equivalent assignment survives). Adding `echo "OUTPUT_FILE=$OUTPUT_FILE"` before the final Python heredoc exits would emit the wrong path.

2. **`summarize-transcript.sh` unsanitized custom label (line 96):** The existing `MODEL_LABEL="$MODEL"` for custom HF IDs (no sanitization) causes a path-separator bug in the output filename. The refactor fixes this by applying the canonical `sed` sanitizer from `cleanup-transcript.sh` line 50.

3. **`transcribe.sh` no `set -euo pipefail`:** Do not add it. The orchestrator's `set -euo pipefail` is sufficient — `transcribe.sh`'s exit code is propagated correctly as a child process.

4. **`OUTPUT_FILE=` line placement in `summarize-transcript.sh`:** The `OUTPUT_FILE` assignment is at line 130 (before the Python heredoc). The `echo "OUTPUT_FILE=$OUTPUT_FILE"` must be added AFTER the Python heredoc block (after line 449), not before — otherwise it fires before the summary is written.

5. **`tee /dev/stderr` vs full capture in orchestrator:** Because sub-scripts mix progress output and the `OUTPUT_FILE=` line on stdout, the orchestrator must use `tee /dev/stderr | grep "^OUTPUT_FILE="` to show progress to the user while capturing the parseable line. Using only `$()` capture would hide all sub-script output.

---

## Metadata

**Analog search scope:** repo root (all 4 `.sh` files read in full)
**Files scanned:** 4 (`transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh`, `mlx-chat.sh`)
**Lines read:** ~830 total across all scripts
**Pattern extraction date:** 2026-06-14
