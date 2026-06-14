# Phase 1: Scriptable Pipeline Foundation - Research

**Researched:** 2026-06-14
**Domain:** Bash orchestration of existing MLX Whisper / MLX-LM pipeline scripts
**Confidence:** HIGH (all findings sourced from direct script-source reads and environment probes)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Refactor each of the three existing scripts to parse its own flags (`--model`, and `--style` for summarize). Chosen over stdin-piping or env-var guards.
- **D-02:** When a model/style flag is not supplied, the script uses the README-recommended default silently — no `read -p` prompt. Interactive menus are replaced by flag-or-default behavior.
- **D-03:** `transcribrr.sh` always passes explicit flags to each sub-script, so it never triggers a prompt and never depends on prompt order/count.
- **D-04:** Each sub-script emits its produced output path on a stable, machine-parseable final line (e.g. `OUTPUT_FILE=<path>`). `transcribrr.sh` captures that line to feed the next stage.
- **D-05:** The new orchestrator is named `transcribrr.sh`, placed at repo root.
- **D-06:** Intermediate artifacts written next to the input MP3 — existing scripts' current behavior.
- **D-07:** Model/style flags accept friendly labels matching the existing menus. If a flag value contains `/`, it is treated as a raw Hugging Face model ID.
- **D-08:** Defaults: whisper `small`, cleanup `llama3.1-8b-4bit`, summary model `Qwen2.5-32B-4bit`, summary style `blog`.
- **D-09:** `--no-cleanup` skips the cleanup stage; raw transcript feeds directly into summarize.
- **D-10:** Preflight check before stage 1, fail-fast with named cause: verify three sub-scripts exist and are executable, `ffmpeg` is on PATH, input MP3 exists.
- **D-11:** `--help` prints usage covering the input-file argument and all flags. Per-stage progress announces which stage is running.

### Claude's Discretion

- Exact wording/format of `--help` output and the per-stage progress banners.
- Exact name of the machine-parseable output line key (`OUTPUT_FILE=` is a suggestion).
- Exact flag long-names where not specified above, and whether to add short aliases.
- How the three sub-scripts are refactored internally to map a flag value to existing model/label/style variables (must preserve current output-filename conventions so `.gitignore` keeps matching).

### Deferred Ideas (OUT OF SCOPE)

- Browser-cookie auth passthrough (`--cookies-from-browser`) — v2.
- Playlist / batch URL support — v2.
- Configurable output directory / keep-vs-discard intermediates toggle — v2.
- Optional `--interactive` flag to restore the old `read -p` menus — roadmap backlog.
- YouTube download + MP3 extraction + metadata capture + single-markdown assembly — Phase 2.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DL-01 | User can run one command with a YouTube URL to start the full pipeline | Phase 1 scope is MP3 input only; URL input is Phase 2. DL-01 is assigned to Phase 1 in REQUIREMENTS.md but CONTEXT.md clarifies Phase 1 takes a local MP3. Planner should note this scoping in plans and ensure DL-01 is partially addressed (single-command invocation with MP3). |
| CLI-01 | Script runs fully unattended when flags are supplied | Achieved by refactoring sub-scripts to accept flags (D-01/D-02/D-03); confirmed no other blocking prompts exist in the three scripts. |
| CLI-02 | Script prints usage/help describing the URL argument and all flags | `--help` pattern in bash; all flags enumerated from D-07/D-08/D-09. |
| CLI-03 | Script reports clear progress per stage | `echo` banners before invoking each sub-script. |
| ROB-01 | Script checks for required dependencies and fails with a clear message if missing | `command -v` checks + file existence checks in preflight block. |
| TR-01 | Script transcribes the MP3 by invoking `transcribe.sh` non-interactively | `transcribe.sh` refactor adds `--model` flag; removes `read -p`. |
| TR-02 | Whisper model size is selectable via flag, defaulting to README-recommended model | Default `small` → `mlx-community/whisper-small-mlx`. |
| TR-03 | Script locates the transcript output file to feed the next stage | Sub-script emits `OUTPUT_FILE=<path>` line; orchestrator captures it. |
| CL-01 | Script cleans the raw transcript by invoking `cleanup-transcript.sh` non-interactively | `cleanup-transcript.sh` refactor adds `--model` flag; removes `read -p`. |
| CL-02 | Cleanup model is selectable via flag with a sensible default | Default `llama3.1-8b-4bit` → `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit`. |
| CL-03 | Cleanup stage can be disabled via flag (`--no-cleanup`) | Orchestrator skips cleanup invocation; passes raw transcript to summarize. |
| SUM-01 | Script summarizes the cleaned transcript by invoking `summarize-transcript.sh` non-interactively | `summarize-transcript.sh` refactor adds `--model` and `--style` flags; removes both `read -p` prompts. |
| SUM-02 | Summary model and style are selectable via flags with sensible defaults | Default model `Qwen2.5-32B-4bit`; default style `blog`. |
| SUM-03 | Script locates the summary output to assemble the final file | Sub-script emits `OUTPUT_FILE=<path>` line; orchestrator captures it. |
</phase_requirements>

---

## Summary

Phase 1 requires writing one new orchestrator script (`transcribrr.sh`) and making targeted refactor edits to the three existing pipeline scripts (`transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh`). All three existing scripts use interactive `read -p` model/style prompts that block unattended execution. The refactor strategy (D-01) replaces those prompts with flag-or-default logic, which is straightforward because each script already contains a `case` statement that maps the prompt input to `MODEL`/`MODEL_LABEL`/`STYLE` variables — the refactor simply moves the input source from `read -p` to a parsed flag.

The output-chaining mechanism (D-04) requires each sub-script to print a machine-parseable `OUTPUT_FILE=<path>` line at the end of successful execution. The orchestrator captures this with `grep` or `tail` and passes the path to the next sub-script. This is safer than filename prediction because `cleanup-transcript.sh` derives its label from a sanitize expression that the orchestrator would need to duplicate.

The most important finding from reading the actual scripts: `transcribe.sh` does NOT use `set -euo pipefail`, while both `cleanup-transcript.sh` and `summarize-transcript.sh` do. This asymmetry has implications for the orchestrator's error-handling strategy and for how each sub-script is invoked.

**Primary recommendation:** Implement the three sub-script refactors as Wave 1 (they are prerequisites for the orchestrator), then implement `transcribrr.sh` as Wave 2. The refactors are small and localized — primarily replacing `read -p` blocks with `case` on a flag variable, then adding `echo "OUTPUT_FILE=$OUTPUT_FILE"` at the end of each script.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| MP3 input validation | Orchestrator (`transcribrr.sh`) | — | Entry point owns preflight. |
| Whisper transcription | `transcribe.sh` (unchanged logic) | — | Existing script owns GPU invocation. |
| Transcript cleanup | `cleanup-transcript.sh` (unchanged logic) | — | Existing script owns chunked LLM cleanup. |
| Summarization | `summarize-transcript.sh` (unchanged logic) | — | Existing script owns multi-pass summarization. |
| Model/flag parsing | Each sub-script (refactored) | Orchestrator (passes flags through) | Sub-scripts own their own flag parsing per D-01. |
| Output file discovery | Each sub-script emits `OUTPUT_FILE=` | Orchestrator captures it | Avoids duplicating sanitize logic in orchestrator. |
| Stage chaining | Orchestrator | — | Orchestrator is the sole coordinator. |
| Dependency preflight | Orchestrator | — | Single place to fail fast before any heavy work starts. |
| Per-stage progress | Orchestrator | — | Progress banners belong to the coordinator layer. |

---

## Existing Script Interface Contracts

This section documents the **current** interface of each script (as read from source), then defines the **required change** for Phase 1.

### `transcribe.sh` — Current Interface

**[VERIFIED: direct source read]**

**Input:**
- Positional arg 1: `<audio_file>` (required, any audio format ffmpeg can read)
- No other flags parsed — the `for arg` loop assigns every argument to `AUDIO_FILE` (last one wins)

**Interactive prompts (MUST be eliminated):**
- Line 101: `read -p "Enter choice [1-7] (default: 3): " model_choice`
  - If `model_choice` is empty string, case `""` selects `small` (the default).
  - If `model_choice` is `7`, a second `read -p` asks for a raw HF model name.
- **No other interactive prompts.**

**Model-to-label mapping (current `case` statement):**

| Choice | `MODEL_SIZE` | `MODEL_LABEL` |
|--------|-------------|---------------|
| 1 | `mlx-community/whisper-tiny` | `tiny` |
| 2 | `mlx-community/whisper-base-mlx` | `base` |
| 3 / `""` | `mlx-community/whisper-small-mlx` | `small` |
| 4 | `mlx-community/whisper-medium-mlx` | `medium` |
| 5 | `mlx-community/whisper-large-v3-mlx` | `large-v3` |
| 6 | `mlx-community/whisper-large-v3-turbo` | `turbo` |
| 7 | (custom `read -p`) | (the full model ID as label) |
| `*` | `mlx-community/whisper-small-mlx` | `small` |

**Output file naming:**
```
<audio_basename>_transcript_<MODEL_LABEL>.txt
```
Where `BASENAME="${AUDIO_FILE%.*}"` — the full path with extension stripped, so output goes to the same directory as the input file. [VERIFIED: source line 149]

**Progress/log files:**
```
<audio_basename>_transcription_<MODEL_LABEL>.log
<audio_basename>_whisper_<MODEL_LABEL>.pid  (deleted on completion)
```

**Existing output echo (line 275):**
```bash
echo "Transcript: $OUTPUT_FILE"
```
This is NOT machine-parseable in the current form. Must be changed to `echo "OUTPUT_FILE=$OUTPUT_FILE"` per D-04.

**Error handling:**
- Does NOT use `set -euo pipefail`. [VERIFIED: source, no `set -e` present]
- On whisper failure, prints error and exits with `$EXIT_CODE`.
- On signal (SIGINT/SIGTERM), runs `cleanup()` and exits 130.

**`.venv` dependency:**
- Checks for `.venv/bin/mlx_whisper` at script startup. Aborts if missing. Does NOT auto-install (unlike `summarize-transcript.sh`).
- `ffmpeg` is called at line 79 to get duration; if missing, outputs warning but continues.

**README recommended model:** `small` [VERIFIED: README "Recommended" column and `⭐` marker]

---

### `cleanup-transcript.sh` — Current Interface

**[VERIFIED: direct source read]**

**Input:**
- Positional arg 1: `$1` — transcript file path (required)
- No other flags

**Interactive prompts (MUST be eliminated):**
- Line 37: `read -p "Enter choice [1-5] (default: 3): " llm_choice`
  - If `llm_choice` is empty, case `""` selects `llama3.1-8b-4bit`.
  - If choice is `5`, a second `read -p "Enter model name: "` asks for a raw HF model.
- **No other interactive prompts.**

**Model-to-label mapping (current `case` statement):**

| Choice | `MODEL` | `MODEL_LABEL` |
|--------|---------|---------------|
| 1 | `mlx-community/Llama-3.2-1B-Instruct-4bit` | `llama3.2-1b-4bit` |
| 2 | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `llama3.2-3b-4bit` |
| 3 / `""` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `llama3.1-8b-4bit` |
| 4 | `mlx-community/Meta-Llama-3.1-8B-Instruct-8bit` | `llama3.1-8b-8bit` |
| 5 | (custom `read -p`) | `$(echo "$MODEL" \| sed …)` — lowercased, non-alnum replaced with `_` |
| `*` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `llama3.1-8b-4bit` |

**Custom label sanitization (line 50):**
```bash
MODEL_LABEL=$(echo "$MODEL" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
```
The orchestrator must apply this same expression when a raw HF ID is passed via `--cleanup-model some/custom-id`.

**Output file naming:**
```
<transcript_basename>_cleaned_<MODEL_LABEL>.txt
```
Where `BASENAME="${TRANSCRIPT_FILE%.*}"` — same directory as input. [VERIFIED: source lines 25, 61]

**Note on `OUTPUT_FILE` pre-assignment:** Line 26 sets `OUTPUT_FILE="${BASENAME}_cleaned.txt"` before the model selection, but line 61 reassigns it to `"${BASENAME}_cleaned_${MODEL_LABEL}.txt"` after the case statement. The actual written file is the second value.

**Existing output echo (line 211):**
```bash
echo "Cleaned transcript: $OUTPUT_FILE"
```
Must be changed to `echo "OUTPUT_FILE=$OUTPUT_FILE"` per D-04.

**Error handling:**
- Uses `set -euo pipefail`. [VERIFIED: source line 6]
- Any failure in the Python heredoc will cause immediate exit.

**`.venv` dependency:**
- Checks for `.venv/bin/python` at script startup. Aborts if missing.
- The README notes that cleanup's Python dependency (`mlx-lm`) is installed by `summarize-transcript.sh`'s `setup_venv`. Cleanup does NOT auto-install.

**README recommended model:** `Llama 3.1 8B 4-bit` (`llama3.1-8b-4bit`) [VERIFIED: README "Recommended" and `⭐` marker]

---

### `summarize-transcript.sh` — Current Interface

**[VERIFIED: direct source read]**

**Input:**
- Positional arg: transcript file path
- Flag: `--install` — installs dependencies and pre-downloads default model, then exits

**Interactive prompts (MUST be eliminated):**
- Line 87: `read -p "Enter choice [1-5] (default: 3): " model_choice` — model selection
- Line 118: `read -p "Enter choice [1-5] (default: 5): " style_choice` — style selection
- If model choice is `5`, a third `read -p "Enter model name: "` asks for a raw HF model.
- **Two required prompts** (model and style) — both must be eliminated.

**Model-to-label mapping:**

| Choice | `MODEL` | `MODEL_LABEL` |
|--------|---------|---------------|
| 1 | `mlx-community/Qwen2.5-7B-Instruct-4bit` | `Qwen2.5-7B-4bit` |
| 2 | `mlx-community/Qwen2.5-14B-Instruct-4bit` | `Qwen2.5-14B-4bit` |
| 3 / `""` | `mlx-community/Qwen2.5-32B-Instruct-4bit` | `Qwen2.5-32B-4bit` |
| 4 | `mlx-community/Qwen2.5-32B-Instruct-8bit` | `Qwen2.5-32B-8bit` |
| 5 | (custom) | `$MODEL` (the full HF id, unmodified) |
| `*` | `mlx-community/Qwen2.5-32B-Instruct-4bit` | `Qwen2.5-32B-4bit` |

**Note:** For the custom model case, `MODEL_LABEL="$MODEL"` (the full HF ID, NOT sanitized). This differs from cleanup-transcript.sh's sanitization. If `/` is in the label, the output filename will contain a `/` — which is a path separator on macOS. The orchestrator should sanitize the label the same way cleanup does when a raw HF ID is passed.

**Style-to-value mapping:**

| Choice | `STYLE` |
|--------|---------|
| 1 | `executive` |
| 2 | `detailed` |
| 3 | `bullets` |
| 4 | `chapters` |
| 5 / `""` | `blog` |
| `*` | `blog` |

**Valid style values:** `executive`, `detailed`, `bullets`, `chapters`, `blog`

**Output file naming:**
```
<transcript_basename>_summary_<MODEL_LABEL>_<STYLE>.md
```
Where `BASENAME="${TRANSCRIPT_FILE%.*}"` — same directory as input. [VERIFIED: source line 130]

**Existing output echo (line 453-456):**
```bash
echo "Done!"
if [ "$STYLE" = "blog" ]; then
    echo "Blog post: $OUTPUT_FILE"
else
    echo "Summary: $OUTPUT_FILE"
fi
```
Must be changed to also emit `echo "OUTPUT_FILE=$OUTPUT_FILE"` per D-04.

**Error handling:**
- Uses `set -euo pipefail`. [VERIFIED: source line 9]
- `setup_venv()` runs unconditionally before input validation, creating `.venv` if absent and auto-installing `mlx-lm` if needed.

**`.venv` dependency:**
- Auto-installs via `setup_venv()`. This is the ONLY script that auto-installs. [VERIFIED: source lines 33-47, 49]

**README recommended model:** `Qwen 2.5 32B 4-bit` [VERIFIED: README `⭐` marker]
**README recommended style:** `Blog Post` (`blog`) [VERIFIED: README `⭐` marker in summarize-transcript.sh source, line 124]

---

## Standard Stack

This phase is pure bash — no new libraries or packages are installed by the orchestrator. All Python dependencies are managed by the existing sub-scripts.

### Core

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| bash | 3.2+ (macOS system) | Orchestrator shell | Project idiom; all existing scripts use bash |
| ffmpeg | N-102648 (installed, PATH verified) | Audio duration extraction in `transcribe.sh`; required by orchestrator preflight | Already required by existing workflow |
| mlx-whisper | via `.venv` | Whisper inference | Already used by `transcribe.sh` |
| mlx-lm | via `.venv` | LLM inference for cleanup + summarize | Already used by both LLM scripts |

**No new packages are introduced in Phase 1.** `yt-dlp` is a Phase 2 dependency.

### No Package Legitimacy Audit Required

Phase 1 installs zero new external packages. All runtime dependencies are already present in the repo (Python scripts invoke `.venv` managed by `summarize-transcript.sh`'s `setup_venv`). [VERIFIED: direct script source reads]

---

## Architecture Patterns

### System Architecture Diagram

```
[User invokes transcribrr.sh <mp3> --flags]
          |
          v
  [Preflight check]
  - transcribe.sh exists + executable
  - cleanup-transcript.sh exists + executable
  - summarize-transcript.sh exists + executable
  - ffmpeg on PATH
  - <mp3> file exists
          |
          v (fail fast with named message if any check fails)
          |
  [Stage 1: Transcribe]
  transcribe.sh <mp3> --model <label|hf-id>
          |
          v (capture OUTPUT_FILE=... from stdout)
          |
  [Stage 2: Cleanup]  <-- skipped if --no-cleanup
  cleanup-transcript.sh <transcript.txt> --model <label|hf-id>
          |
          v (capture OUTPUT_FILE=... from stdout)
          |
  [Stage 3: Summarize]
  summarize-transcript.sh <cleaned.txt or transcript.txt> --model <label|hf-id> --style <style>
          |
          v (capture OUTPUT_FILE=... from stdout)
          |
  [Done — print summary file path]
```

### Recommended Project Structure

```
/                          # repo root
├── transcribrr.sh         # NEW: orchestrator (Phase 1 deliverable)
├── transcribe.sh          # REFACTORED: add --model flag, emit OUTPUT_FILE=
├── cleanup-transcript.sh  # REFACTORED: add --model flag, emit OUTPUT_FILE=
├── summarize-transcript.sh# REFACTORED: add --model, --style flags, emit OUTPUT_FILE=
├── mlx-chat.sh            # unchanged
├── .venv/                 # Python venv, managed by summarize-transcript.sh
└── .planning/             # GSD planning artifacts
```

### Pattern 1: Flag-or-Default Model Selection (for sub-script refactors)

**What:** Replace each `read -p` block with a `--flag` parser that feeds the existing `case` statement.

**When to use:** In each of the three sub-scripts being refactored.

**Example (transcribe.sh refactor skeleton):**

```bash
# Source: direct analysis of transcribe.sh model selection block (lines 100-143)

# --- NEW flag parsing (replace the existing `for arg` loop) ---
AUDIO_FILE=""
MODEL_FLAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL_FLAG="$2"
            shift 2
            ;;
        *)
            AUDIO_FILE="$1"
            shift
            ;;
    esac
done

# --- REPLACE `read -p` block with flag-driven selection ---
if [ -n "$MODEL_FLAG" ]; then
    # Handle friendly label OR raw HF ID (contains /)
    if [[ "$MODEL_FLAG" == */* ]]; then
        MODEL_SIZE="$MODEL_FLAG"
        MODEL_LABEL=$(echo "$MODEL_FLAG" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
    else
        case "$MODEL_FLAG" in
            tiny)      MODEL_SIZE="mlx-community/whisper-tiny" ; MODEL_LABEL="tiny" ;;
            base)      MODEL_SIZE="mlx-community/whisper-base-mlx" ; MODEL_LABEL="base" ;;
            small)     MODEL_SIZE="mlx-community/whisper-small-mlx" ; MODEL_LABEL="small" ;;
            medium)    MODEL_SIZE="mlx-community/whisper-medium-mlx" ; MODEL_LABEL="medium" ;;
            large-v3)  MODEL_SIZE="mlx-community/whisper-large-v3-mlx" ; MODEL_LABEL="large-v3" ;;
            turbo)     MODEL_SIZE="mlx-community/whisper-large-v3-turbo" ; MODEL_LABEL="turbo" ;;
            *)
                echo "Error: Unknown whisper model '$MODEL_FLAG'" >&2
                exit 1
                ;;
        esac
    fi
else
    # Default: small (README-recommended)
    MODEL_SIZE="mlx-community/whisper-small-mlx"
    MODEL_LABEL="small"
fi
```

### Pattern 2: Capturing OUTPUT_FILE from sub-script stdout

**What:** Each sub-script prints `OUTPUT_FILE=<path>` as its final meaningful stdout line. The orchestrator captures it.

**When to use:** In `transcribrr.sh` after each stage invocation.

```bash
# Capture OUTPUT_FILE= line from sub-script output
# Sub-script streams all progress to stdout; orchestrator tees or greps final line.

STAGE_OUTPUT=$(./transcribe.sh "$MP3_FILE" --model "$WHISPER_MODEL" 2>&1 | tee /dev/stderr | grep "^OUTPUT_FILE=" | tail -1)
TRANSCRIPT_FILE="${STAGE_OUTPUT#OUTPUT_FILE=}"

if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Error: transcribe stage did not produce a valid output file." >&2
    exit 1
fi
```

**Key insight:** Using `tee /dev/stderr` lets the sub-script's progress output reach the user's terminal while the orchestrator captures the parseable line. Alternatively, redirect sub-script stderr to stderr and stdout to a capture variable — but since all three scripts mix progress messages and the final OUTPUT_FILE= line on stdout, the `grep "^OUTPUT_FILE="` approach on the full stdout is more robust.

**Alternative (simpler, if sub-scripts print OUTPUT_FILE= as their absolute last stdout line):**

```bash
TRANSCRIPT_FILE=$(./transcribe.sh "$MP3_FILE" --model "$WHISPER_MODEL" | tee /dev/fd/2 | tail -1)
TRANSCRIPT_FILE="${TRANSCRIPT_FILE#OUTPUT_FILE=}"
```

This only works reliably if `OUTPUT_FILE=` is guaranteed to be the last line. The `grep` approach is safer.

### Pattern 3: Preflight Dependency Check

**What:** Check all prerequisites before starting any heavy work.

```bash
# Source: bash idiomatic dependency check pattern

preflight_check() {
    local errors=0

    # Check input file
    if [ ! -f "$MP3_FILE" ]; then
        echo "Error: Input file not found: $MP3_FILE" >&2
        errors=$((errors + 1))
    fi

    # Check sub-scripts exist and are executable
    for script in transcribe.sh cleanup-transcript.sh summarize-transcript.sh; do
        local script_path="$SCRIPT_DIR/$script"
        if [ ! -f "$script_path" ]; then
            echo "Error: Required script not found: $script_path" >&2
            errors=$((errors + 1))
        elif [ ! -x "$script_path" ]; then
            echo "Error: Script not executable: $script_path" >&2
            errors=$((errors + 1))
        fi
    done

    # Check ffmpeg
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

### Pattern 4: `set -euo pipefail` Asymmetry Handling

**What:** `transcribe.sh` does NOT use `set -euo pipefail`. When the orchestrator is written with `set -euo pipefail`, invoking `transcribe.sh` as a subprocess is safe — the sub-script's exit code is still propagated. However, if `transcribe.sh` exits non-zero, `set -e` in the orchestrator will cause immediate abort, which is the correct behavior.

**Risk:** If `transcribe.sh` itself calls a tool that fails internally but doesn't propagate the error (because it lacks `set -e`), the exit code returned to the orchestrator may still be 0. This is unlikely given the script's explicit `exit $EXIT_CODE` on whisper failure, but is worth noting.

**Recommendation:** The orchestrator should use `set -euo pipefail`. After each stage, also explicitly check that the captured output file exists and is non-empty as a belt-and-suspenders check.

### Pattern 5: Per-Stage Progress Banners

```bash
# Simple, consistent banner format
stage_banner() {
    local stage="$1"
    echo ""
    echo "=========================================="
    echo "  Stage: $stage"
    echo "=========================================="
    echo ""
}

stage_banner "Transcribing (Whisper $WHISPER_MODEL)"
stage_banner "Cleaning transcript (model: $CLEANUP_MODEL)"
stage_banner "Summarizing (model: $SUMMARY_MODEL, style: $SUMMARY_STYLE)"
```

### Anti-Patterns to Avoid

- **Stdin piping to satisfy `read -p`:** The original `read -p` blocks can be satisfied by piping choices via stdin (e.g., `echo "3" | ./transcribe.sh ...`), but this is brittle — prompt order must match, and any change to the scripts breaks the orchestrator silently. D-01 (flag refactor) is the correct approach.
- **Filename prediction in the orchestrator:** The orchestrator must NOT reconstruct the output filename by replicating each sub-script's `BASENAME` + label logic. The `OUTPUT_FILE=` emission pattern (D-04) is the correct approach.
- **Hardcoding `SCRIPT_DIR` as `$(pwd)`:** The orchestrator should use `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` — same pattern all existing scripts use — so it works correctly regardless of where the user invokes it from.
- **Swallowing sub-script output:** Sub-scripts produce valuable progress output. The orchestrator should pass it through to the user's terminal rather than capturing all of it silently.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Transcription | Custom Whisper invocation | `transcribe.sh` (existing, refactored) | GPU scheduling, log management, PID tracking, progress monitoring already implemented |
| LLM cleanup | Custom Python chunking loop | `cleanup-transcript.sh` (existing) | Sentence-boundary chunking, chunk-size tuning, preamble stripping already correct |
| LLM summarization | Custom Qwen invocation | `summarize-transcript.sh` (existing) | Multi-pass synthesis for >20k-word transcripts, all 5 style prompts, DocFlow blog framework already implemented |
| `.venv` management | Custom pip install logic | `summarize-transcript.sh`'s `setup_venv()` (called automatically) | Auto-installs `mlx-lm` if absent; cleanup depends on same venv |
| Model label sanitization | Custom sanitizer | The exact `sed` expression already in `cleanup-transcript.sh` line 50 | Must produce identical labels so `.gitignore` patterns match |

**Key insight:** The value of Phase 1 is entirely in the orchestration layer. Any logic that reimplements what the existing scripts already do correctly will drift over time and create two sources of truth.

---

## Common Pitfalls

### Pitfall 1: `OUTPUT_FILE` Line Not Found After Stage Completion

**What goes wrong:** The orchestrator captures an empty string for `TRANSCRIPT_FILE` even though `transcribe.sh` completed successfully.

**Why it happens:** The `grep "^OUTPUT_FILE="` pattern requires the sub-script to emit the line on stdout. If the sub-script's Python heredoc crashes or the whisper process fails silently (possible without `set -e`), the final `OUTPUT_FILE=` line is never printed.

**How to avoid:** After capturing the line, verify both that the variable is non-empty AND that the file at that path exists. Emit a clear error if either check fails.

**Warning signs:** `TRANSCRIPT_FILE` is an empty string, or it contains text like `"Done!"` instead of a file path (indicating `tail -1` was used but the last line was not the `OUTPUT_FILE=` line).

---

### Pitfall 2: `cleanup-transcript.sh` `OUTPUT_FILE` Pre-assignment Bug

**What goes wrong:** If the refactor of `cleanup-transcript.sh` adds `echo "OUTPUT_FILE=$OUTPUT_FILE"` at the wrong position (before line 61), it will emit the wrong path (`_cleaned.txt` without the model label) instead of the correct path (`_cleaned_<MODEL_LABEL>.txt`).

**Why it happens:** Line 26 pre-assigns `OUTPUT_FILE="${BASENAME}_cleaned.txt"`. Line 61 reassigns it to `"${BASENAME}_cleaned_${MODEL_LABEL}.txt"`. The correct path is the second assignment.

**How to avoid:** Ensure `echo "OUTPUT_FILE=$OUTPUT_FILE"` is added AFTER line 61 (after the case statement), and AFTER the Python heredoc completes successfully.

**Warning signs:** The captured output path ends in `_cleaned.txt` (no model label) — the resulting file won't exist because the Python script wrote to the label-suffixed path.

---

### Pitfall 3: `summarize-transcript.sh` Custom Model Label Contains `/`

**What goes wrong:** If a raw HF model ID like `myorg/MyModel-7B` is passed as `--summary-model`, the `MODEL_LABEL` becomes `myorg/MyModel-7B`, and `OUTPUT_FILE` becomes `transcript_summary_myorg/MyModel-7B_blog.md` — which is a path into a non-existent directory, causing the Python `open()` to fail.

**Why it happens:** The current custom model case (line 96-99) sets `MODEL_LABEL="$MODEL"` without sanitization. This is a pre-existing bug that the refactor must fix for the HF-ID path (D-07).

**How to avoid:** When a `--model` flag value contains `/`, apply the same sanitization as `cleanup-transcript.sh` line 50:
```bash
MODEL_LABEL=$(echo "$MODEL" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
```

**Warning signs:** Python error `FileNotFoundError: [Errno 2] No such file or directory` pointing to the output path containing a `/` in the filename component.

---

### Pitfall 4: `set -euo pipefail` in Orchestrator Conflicts with Sub-script Behavior

**What goes wrong:** With `set -euo pipefail` in the orchestrator, any non-zero exit from a sub-script causes immediate silent abort, which is correct — but the error message may be cryptic if the sub-script already printed its own error to stderr and then the orchestrator silently exits.

**Why it happens:** `set -e` exits on error without printing a message itself.

**How to avoid:** Use a `trap` in the orchestrator to print a stage-context message on exit:

```bash
CURRENT_STAGE="preflight"
trap 'echo "Error: transcribrr.sh failed at stage: $CURRENT_STAGE" >&2' ERR
CURRENT_STAGE="transcribe"
```

---

### Pitfall 5: `--no-cleanup` Feeds Raw Transcript (With Model Header) to Summarize

**What goes wrong:** When `--no-cleanup` is set, the orchestrator passes `transcribe.sh`'s raw output directly to `summarize-transcript.sh`. The raw transcript file includes a three-line header (`Model:`, `Source:`, `Date:`). This is fine — `summarize-transcript.sh`'s Python code explicitly strips this header (lines 162-175). No special handling needed in the orchestrator.

**Why it matters:** This is a potential confusion point. The header stripping is already handled correctly in both downstream scripts. Document this so implementers don't add redundant stripping logic in the orchestrator.

---

### Pitfall 6: Orchestrator `SCRIPT_DIR` vs Sub-script `SCRIPT_DIR`

**What goes wrong:** Each sub-script computes its own `SCRIPT_DIR` using `"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`. This always resolves to the directory containing THAT script. Since `transcribrr.sh` will live in the same directory as the sub-scripts (repo root), `$SCRIPT_DIR/transcribe.sh` from the orchestrator will correctly locate the sub-scripts.

**Caution:** If the orchestrator uses `"$SCRIPT_DIR/transcribe.sh"` to invoke the sub-scripts (preferred over relying on PATH), the sub-scripts will in turn compute their own `SCRIPT_DIR` correctly and locate `.venv` correctly. This pattern is safe.

---

## Code Examples

### `--help` Output Pattern (Claude's Discretion)

```bash
# Source: bash idiomatic --help block

print_help() {
    cat << 'EOF'
Usage: transcribrr.sh <audio.mp3> [options]

  Transcribes, cleans, and summarizes an audio file using local MLX models.

Arguments:
  <audio.mp3>           Path to an MP3 (or any ffmpeg-readable audio) file

Options:
  --whisper-model <label|hf-id>
                        Whisper model size: tiny, base, small, medium, large-v3, turbo
                        or a raw Hugging Face model ID (contains '/')
                        Default: small  (mlx-community/whisper-small-mlx)

  --cleanup-model <label|hf-id>
                        Cleanup LLM: llama3.2-1b-4bit, llama3.2-3b-4bit,
                        llama3.1-8b-4bit, llama3.1-8b-8bit
                        or a raw Hugging Face model ID
                        Default: llama3.1-8b-4bit

  --no-cleanup          Skip the transcript cleanup stage

  --summary-model <label|hf-id>
                        Summary LLM: Qwen2.5-7B-4bit, Qwen2.5-14B-4bit,
                        Qwen2.5-32B-4bit, Qwen2.5-32B-8bit
                        or a raw Hugging Face model ID
                        Default: Qwen2.5-32B-4bit

  --summary-style <style>
                        Summary style: executive, detailed, bullets, chapters, blog
                        Default: blog

  --help, -h            Show this help message and exit

Examples:
  transcribrr.sh talk.mp3
  transcribrr.sh talk.mp3 --whisper-model turbo --summary-style detailed
  transcribrr.sh talk.mp3 --no-cleanup --summary-model Qwen2.5-7B-4bit
  transcribrr.sh talk.mp3 --whisper-model mlx-community/whisper-large-v3-turbo
EOF
}
```

### Sub-script Refactor: Adding `--model` Flag to `cleanup-transcript.sh`

```bash
# Source: based on cleanup-transcript.sh source lines 8 and 37-54

# REPLACE the positional arg assignment and read -p block:

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

# Then replace the read -p case block:
if [ -n "$MODEL_FLAG" ]; then
    if [[ "$MODEL_FLAG" == */* ]]; then
        MODEL="$MODEL_FLAG"
        MODEL_LABEL=$(echo "$MODEL" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
    else
        case "$MODEL_FLAG" in
            llama3.2-1b-4bit)  MODEL="mlx-community/Llama-3.2-1B-Instruct-4bit" ; MODEL_LABEL="llama3.2-1b-4bit" ;;
            llama3.2-3b-4bit)  MODEL="mlx-community/Llama-3.2-3B-Instruct-4bit" ; MODEL_LABEL="llama3.2-3b-4bit" ;;
            llama3.1-8b-4bit)  MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-4bit" ; MODEL_LABEL="llama3.1-8b-4bit" ;;
            llama3.1-8b-8bit)  MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-8bit" ; MODEL_LABEL="llama3.1-8b-8bit" ;;
            *)
                echo "Error: Unknown cleanup model '$MODEL_FLAG'" >&2
                exit 1
                ;;
        esac
    fi
else
    MODEL="mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"
    MODEL_LABEL="llama3.1-8b-4bit"
fi

OUTPUT_FILE="${BASENAME}_cleaned_${MODEL_LABEL}.txt"  # now correct first time
```

### Emitting Machine-Parseable Output Path

```bash
# Add this as the final echo in each sub-script (after confirming successful write):

echo "OUTPUT_FILE=$OUTPUT_FILE"
```

The orchestrator captures it:

```bash
# In transcribrr.sh — capture OUTPUT_FILE= line while showing all other output to user
STAGE_OUT=$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" | tee /dev/stderr | grep "^OUTPUT_FILE=")
TRANSCRIPT_FILE="${STAGE_OUT#OUTPUT_FILE=}"
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Interactive `read -p` menus | Flag-or-default (to be implemented) | Phase 1 (this phase) | Scripts become automation-friendly |
| Manual four-step workflow | Single `transcribrr.sh` command (to be implemented) | Phase 1 (this phase) | Core project value delivered |
| Filename prediction for chaining | `OUTPUT_FILE=` line emission (to be implemented) | Phase 1 (this phase) | Robust stage chaining without duplicating label-sanitization logic |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `yt-dlp` is not needed in Phase 1 (Phase 2 only) | User Constraints / CONTEXT.md scope | Low — CONTEXT.md is explicit that Phase 1 takes a local MP3, Phase 2 adds download. |
| A2 | `mlx-whisper` and `mlx-lm` are already installed in `.venv` on the target machine (or will be bootstrapped on first sub-script run) | Environment Availability | Medium — `.venv` was not present in the repo at research time. First run of `summarize-transcript.sh` will auto-create it; `transcribe.sh` will fail if `.venv` absent since it does NOT auto-install. Planner should note that `summarize-transcript.sh --install` should be run first. |
| A3 | The `tee /dev/stderr` approach for sub-script output passthrough works on macOS bash | Code Examples | Low — standard POSIX; works on macOS. Alternative: use a named pipe or process substitution. |

**If this table is empty:** N/A — 3 assumptions logged above.

---

## Open Questions (RESOLVED)

1. **`transcribe.sh` `.venv` bootstrap** — RESOLVED
   - What we know: `transcribe.sh` checks for `.venv/bin/mlx_whisper` and aborts if absent. `summarize-transcript.sh` auto-installs `mlx-lm` (which includes `mlx-whisper` CLI? — not confirmed) via `setup_venv`.
   - What's unclear: Does `mlx-lm`'s pip install also install the `mlx_whisper` CLI, or are they separate packages? The README says `transcribe.sh` dependencies are auto-installed into `.venv/` (mlx-whisper), but the script itself does NOT auto-install.
   - **Resolution:** Out of scope for Phase 1 to auto-bootstrap `.venv`. Documented as Assumption A2. The orchestrator's preflight (Plan 01-02 Task 1, D-10) checks sub-script executability and `ffmpeg`; `.venv` bootstrap remains the user's responsibility per the README (`./summarize-transcript.sh --install` first). The end-to-end human check (Plan 01-02 Task 2) lists the bootstrap in its `read_first` so the executor runs `--install` before the smoke test. Plans do not duplicate the bootstrap logic.

2. **`summarize-transcript.sh` custom model label containing `/`** — RESOLVED
   - What we know: The existing bug (unsanitized label when custom HF ID is passed) will cause `open()` failure in the Python block.
   - What's unclear: Whether any existing users rely on the current (broken) behavior for custom models.
   - **Resolution:** Fixed silently as part of the flag refactor in Plan 01-01 Task 3 — apply the canonical sanitizer from `cleanup-transcript.sh` line 50 when a `/`-containing `--model` value is passed. This is a bug fix, not a behavior change for existing users.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| ffmpeg | `transcribe.sh` (duration), orchestrator preflight | Yes | N-102648 (evermeet.cx) | None — required for Whisper duration tracking |
| python3 | All three sub-scripts via `.venv` | Yes | 3.11.6 | None |
| .venv/bin/mlx_whisper | `transcribe.sh` | Not present (no .venv) | — | Run `./summarize-transcript.sh --install` first to create venv, then install mlx-whisper separately |
| .venv/bin/python (mlx-lm) | `cleanup-transcript.sh`, `summarize-transcript.sh` | Not present (no .venv) | — | `summarize-transcript.sh --install` auto-creates on first run |
| yt-dlp | Phase 2 only | Not found on PATH | — | Phase 2 concern — not needed for Phase 1 |
| bash | Orchestrator + all sub-scripts | Yes (macOS system bash) | 3.2.57 (system) or newer via Homebrew | — |

**Missing dependencies with no fallback:**
- `.venv` is absent on this machine — but the `summarize-transcript.sh` auto-install handles it on first run. `transcribe.sh`'s `mlx_whisper` binary requires a separate install step; the planner should document this clearly in the acceptance criteria.

**Missing dependencies with fallback:**
- `yt-dlp` — missing, but Phase 1 does not require it.

---

## Validation Architecture

> `nyquist_validation` is explicitly `false` in `.planning/config.json`. This section is omitted.

---

## Security Domain

> `security_enforcement: true` and `security_asvs_level: 1` in config.

### Applicable ASVS Categories (ASVS Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No auth in a local bash script |
| V3 Session Management | No | No sessions |
| V4 Access Control | No | Local file access only |
| V5 Input Validation | Yes | Validate that the input MP3 path exists and is a regular file before passing to sub-scripts; validate flag values against known-good lists before embedding in shell commands |
| V6 Cryptography | No | No cryptographic operations |

### Known Threat Patterns for Bash Scripts

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Shell injection via unsanitized filename | Tampering | Always quote `"$AUDIO_FILE"` in all invocations; validate it exists before passing |
| Path traversal | Elevation of Privilege | Input validation: confirm file exists and is a regular file (`[ -f "$MP3_FILE" ]`). Do not `eval` any user input. |
| Malicious model ID passed to `--model` | Tampering | Validate flag values against known-good labels list when not a raw HF ID; for raw HF IDs, sanitize label before embedding in filename but pass the model ID directly to the Python process (mlx-lm handles model download from HF) |

**Key note:** This is a local-only, single-user tool with no network-facing surface. ASVS Level 1 for V5 (input validation) is met by quoting all variables and checking file existence before use. No elevated privilege concerns.

---

## Sources

### Primary (HIGH confidence)

- `transcribe.sh` — full source read, lines 1-290. All interface contract findings are VERIFIED.
- `cleanup-transcript.sh` — full source read, lines 1-212. All interface contract findings are VERIFIED.
- `summarize-transcript.sh` — full source read, lines 1-458. All interface contract findings are VERIFIED.
- `README.md` — full read; used for recommended defaults and output filename conventions. VERIFIED.
- `.gitignore` — full read; output file patterns confirmed. VERIFIED.
- `.planning/phases/01-scriptable-pipeline-foundation/01-CONTEXT.md` — all locked decisions. VERIFIED.
- `environment probe` — `command -v` and `--version` checks for ffmpeg, python3, yt-dlp. VERIFIED.

### Secondary (MEDIUM confidence)

- Bash `set -euo pipefail` interaction with sub-processes: standard POSIX shell behavior. ASSUMED (well-established).
- `tee /dev/stderr` passthrough pattern: standard on macOS/Linux. ASSUMED.

### Tertiary (LOW confidence)

- None.

---

## Metadata

**Confidence breakdown:**
- Script interface contracts: HIGH — read directly from source
- Architecture: HIGH — derived from locked decisions (CONTEXT.md) + source analysis
- Pitfalls: HIGH — derived from actual code paths identified in source
- Environment: HIGH — probed directly

**Research date:** 2026-06-14
**Valid until:** Stable — until any of the three existing scripts are modified. Re-read source before implementing if >30 days elapsed.
