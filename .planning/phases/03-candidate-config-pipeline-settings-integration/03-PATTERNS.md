# Phase 3: Candidate Config & Pipeline Settings Integration - Pattern Map

**Mapped:** 2026-06-15
**Files analyzed:** 4 (2 new, 2 modified)
**Analogs found:** 2 / 4 (new config files have no analog — documented in "No Analog Found")

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `transcribrr.sh` (modify) | orchestrator / config-consumer | request-response + transform | `transcribrr.sh` itself (self-referential) | exact — all patterns are additions within the existing file |
| `config/candidates.conf` (create) | config data file | batch (parse-not-source) | none | no analog — new artifact type |
| `config/settings.conf.example` (create) | config documentation file | flat KEY=value | none | no analog — new artifact type |
| `.gitignore` (modify) | repo config | n/a | `.gitignore` itself (existing entries) | exact — one-line addition following existing pattern |

---

## Pattern Assignments

### `transcribrr.sh` — sentinel init additions to defaults block

**Location of change:** Lines 12–23 (existing defaults block)

**Analog:** The existing defaults block in `transcribrr.sh`. The three model variables already exist; add sentinel and source variables alongside them in the same block.

**Existing defaults pattern** (`transcribrr.sh` lines 12–23):
```bash
# ── Defaults (per D-08) ──────────────────────────────────────────────────────

WHISPER_MODEL="small"
CLEANUP_MODEL="llama3.1-8b-4bit"
SUMMARY_MODEL="Qwen2.5-32B-4bit"
SUMMARY_STYLE="blog"
NO_CLEANUP=false
NO_INSTALL=false
MP3_FILE=""
INPUT_ARG=""
IS_URL=false
URL=""
```

**New sentinel additions — append immediately after `SUMMARY_MODEL="Qwen2.5-32B-4bit"` at line 16:**
```bash
WHISPER_MODEL_EXPLICIT=false
CLEANUP_MODEL_EXPLICIT=false
SUMMARY_MODEL_EXPLICIT=false
WHISPER_MODEL_SOURCE="built-in"
CLEANUP_MODEL_SOURCE="built-in"
SUMMARY_MODEL_SOURCE="built-in"
```

**Pattern notes:**
- Follow the existing `VARNAME=value` idiom (no `export`, no `declare`, no `local` — this is the top-level scope).
- Boolean-style sentinels use unquoted `false` to match `NO_CLEANUP=false` and `NO_INSTALL=false` convention at lines 18–19.
- Source strings use double-quotes to match `SUMMARY_STYLE="blog"` convention at line 17.
- Do NOT put a blank line between the model defaults and their sentinels — they belong together as a logical unit.

---

### `transcribrr.sh` — sentinel wiring in flag-parse loop

**Location of change:** Lines 97–137 (existing flag-parse `while/case` block)

**Analog:** The three existing `--*-model` case branches at lines 99–110.

**Existing flag-parse pattern** (`transcribrr.sh` lines 97–110):
```bash
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
```

**Modified form — add sentinel and source assignments to each branch:**
```bash
        --whisper-model)
            WHISPER_MODEL="$2"
            WHISPER_MODEL_EXPLICIT=true
            WHISPER_MODEL_SOURCE="flag"
            shift 2
            ;;
        --cleanup-model)
            CLEANUP_MODEL="$2"
            CLEANUP_MODEL_EXPLICIT=true
            CLEANUP_MODEL_SOURCE="flag"
            shift 2
            ;;
        --summary-model)
            SUMMARY_MODEL="$2"
            SUMMARY_MODEL_EXPLICIT=true
            SUMMARY_MODEL_SOURCE="flag"
            shift 2
            ;;
```

**Pattern notes:**
- Insert the two new lines (`*_EXPLICIT=true`, `*_SOURCE="flag"`) between the assignment and the `shift 2` — not after `shift 2`. Preserves existing indentation (8-space indent matching the file's convention).
- `true` is unquoted, matching the existing boolean convention (`NO_CLEANUP=true` at line 115).
- All three branches follow an identical structure — copy exactly, substituting `WHISPER`/`CLEANUP`/`SUMMARY`.

---

### `transcribrr.sh` — settings.conf read block + provenance summary

**Location of change:** After line 137 (`done` closing the flag-parse loop), before line 139 (URL detection block header comment). Insert as a new named section with a separator comment matching the file's style.

**Analog for section separator style** (`transcribrr.sh` line 25–28, line 95):
```bash
# ── ERR trap — names the failing stage ───────────────────────────────────────
# ── Flag parsing ─────────────────────────────────────────────────────────────
```

**Analog for `$SCRIPT_DIR`-relative path construction** (`transcribrr.sh` line 10):
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```
All config file references must use `$SCRIPT_DIR/config/...` (never relative `./config/...`).

**Analog for safe `grep`/`cut` parsing idiom:** The existing flag-parse loop already avoids `eval`/`source`. The `_read_setting` helper below follows the same no-eval discipline.

**Full new block to insert after line 137:**
```bash
# ── settings.conf — read model defaults (flag > settings.conf > built-in) ────
# D-07/D-08: read once, after flag parsing, before preflight.
# Parse-not-source: grep extracts the value as a literal string; no eval.

SETTINGS_FILE="$SCRIPT_DIR/config/settings.conf"
if [ -f "$SETTINGS_FILE" ]; then
    _read_setting() {
        # Anchored grep prevents prefix collisions; tail -1 = last-writer-wins;
        # cut -d= -f2- preserves values that contain '=' characters.
        grep "^${1}=" "$SETTINGS_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
    }
    if [ "$WHISPER_MODEL_EXPLICIT" = false ]; then
        _val=$(_read_setting WHISPER_MODEL_DEFAULT)
        if [ -n "$_val" ]; then
            WHISPER_MODEL="$_val"
            WHISPER_MODEL_SOURCE="settings.conf"
        fi
    fi
    if [ "$CLEANUP_MODEL_EXPLICIT" = false ]; then
        _val=$(_read_setting CLEANUP_MODEL_DEFAULT)
        if [ -n "$_val" ]; then
            CLEANUP_MODEL="$_val"
            CLEANUP_MODEL_SOURCE="settings.conf"
        fi
    fi
    if [ "$SUMMARY_MODEL_EXPLICIT" = false ]; then
        _val=$(_read_setting SUMMARY_MODEL_DEFAULT)
        if [ -n "$_val" ]; then
            SUMMARY_MODEL="$_val"
            SUMMARY_MODEL_SOURCE="settings.conf"
        fi
    fi
fi

# ── Provenance summary — print model + source before pipeline starts (D-09) ──

echo "Models:"
printf "  whisper  = %-24s (%s)\n" "$WHISPER_MODEL" "$WHISPER_MODEL_SOURCE"
printf "  cleanup  = %-24s (%s)\n" "$CLEANUP_MODEL" "$CLEANUP_MODEL_SOURCE"
printf "  summary  = %-24s (%s)\n" "$SUMMARY_MODEL" "$SUMMARY_MODEL_SOURCE"
```

**Pattern notes:**
- `_read_setting` is a shell function defined inside the `if [ -f ... ]` block. Using a leading underscore (`_`) matches the existing `_PLAYLIST_PATTERN` naming convention for internal-use variables (line 267).
- `_val` is a throw-away local name — it is intentionally not `local` because this is top-level scope (functions defined at top level can't use `local` for outer scope assignments; the function returns stdout, not sets a variable).
- The `echo "Models:"` + three `printf` lines must appear unconditionally (after the `fi` for the settings block) so provenance is always printed, even when no settings.conf exists (source will read "built-in" for all three).
- `%-24s` left-aligns the model name in a 24-char field for tabular alignment matching the D-09 preview format.

---

### `transcribrr.sh` — CFG-03 catch-and-translate at stage invocations

**Location of change:** Lines 381–432 — the three stage invocation blocks for `transcribe.sh`, `cleanup-transcript.sh`, and `summarize-transcript.sh`.

**Analog — existing stage invocation pattern** (`transcribrr.sh` lines 381–389, 402–410, 427–432):
```bash
STAGE_OUT=$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
    | tee /dev/stderr \
    | { grep "^OUTPUT_FILE=" || true; })
TRANSCRIPT_FILE="${STAGE_OUT#OUTPUT_FILE=}"

if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Error: transcribe stage did not produce a valid output file." >&2
    exit 1
fi
```

**Analog — existing ERR trap** (`transcribrr.sh` lines 27–28):
```bash
CURRENT_STAGE="preflight"
trap 'echo "Error: transcribrr.sh failed during stage: $CURRENT_STAGE" >&2' ERR
```

**Critical constraint — `set -e` + pipeline interaction (RESEARCH.md Pitfall 1):**
The existing `STAGE_OUT=$(cmd | tee /dev/stderr | { grep ... || true; })` pattern relies on the ERR trap firing when `cmd` fails inside the subshell. Adding a `||` after the pipeline suppresses the ERR trap for that line (the shell treats the `||` as "error is handled"). Use a wrapper function approach — safe with `set -e` — so stage failures remain ERR-trappable unless the `||` branch explicitly fires.

**Recommended wrapper pattern for each stage:**

For the transcribe stage (lines ~381–389):
```bash
_run_transcribe() {
    "$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
        | tee /dev/stderr \
        | { grep "^OUTPUT_FILE=" || true; }
}

if ! STAGE_OUT=$(_run_transcribe); then
    if [ "$WHISPER_MODEL_SOURCE" = "settings.conf" ]; then
        echo "" >&2
        echo "Error: whisper model '$WHISPER_MODEL' from config/settings.conf could not be loaded." >&2
        echo "Fix: run \`transcribrr.sh --benchmark\` to reselect, or pass --whisper-model <label|hf-id>." >&2
    fi
    exit 1
fi
TRANSCRIPT_FILE="${STAGE_OUT#OUTPUT_FILE=}"
```

For the cleanup stage (lines ~402–410), identical structure substituting `CLEANUP`:
```bash
_run_cleanup() {
    "$SCRIPT_DIR/cleanup-transcript.sh" "$TRANSCRIPT_FILE" --model "$CLEANUP_MODEL" \
        | tee /dev/stderr \
        | { grep "^OUTPUT_FILE=" || true; }
}

if ! STAGE_OUT=$(_run_cleanup); then
    if [ "$CLEANUP_MODEL_SOURCE" = "settings.conf" ]; then
        echo "" >&2
        echo "Error: cleanup model '$CLEANUP_MODEL' from config/settings.conf could not be loaded." >&2
        echo "Fix: run \`transcribrr.sh --benchmark\` to reselect, or pass --cleanup-model <label|hf-id>." >&2
    fi
    exit 1
fi
CLEANED_FILE="${STAGE_OUT#OUTPUT_FILE=}"
```

For the summarize stage (lines ~427–432):
```bash
_run_summarize() {
    "$SCRIPT_DIR/summarize-transcript.sh" "$SUMMARIZE_INPUT" \
        --model "$SUMMARY_MODEL" \
        --style "$SUMMARY_STYLE" \
        | tee /dev/stderr \
        | { grep "^OUTPUT_FILE=" || true; }
}

if ! STAGE_OUT=$(_run_summarize); then
    if [ "$SUMMARY_MODEL_SOURCE" = "settings.conf" ]; then
        echo "" >&2
        echo "Error: summary model '$SUMMARY_MODEL' from config/settings.conf could not be loaded." >&2
        echo "Fix: run \`transcribrr.sh --benchmark\` to reselect, or pass --summary-model <label|hf-id>." >&2
    fi
    exit 1
fi
SUMMARY_FILE="${STAGE_OUT#OUTPUT_FILE=}"
```

**Pattern notes:**
- Function names use leading underscore (`_run_*`) — matches existing `_PLAYLIST_PATTERN` and `_read_setting` naming conventions for internal-use identifiers.
- The existing `if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]` guard after each invocation should remain — it catches the case where the stage exits 0 but produces no output file. The wrapper only catches non-zero exits.
- The `if ! STAGE_OUT=$(...)` idiom works correctly under `set -e` because `if` suppresses `set -e` for its condition — this is intentional and correct.
- Stage wrapper functions must be defined just before their call site (not at the top of the file) because they reference `$MP3_FILE`, `$WHISPER_MODEL`, etc., which are set during the run.
- The cleanup stage invocation is inside `if [ "$NO_CLEANUP" = false ]; then` — the wrapper definition and the `if ! STAGE_OUT=...` call must both remain inside that block.

---

### `.gitignore` — add `config/settings.conf`

**Location of change:** End of file, after line 26.

**Existing pattern for gitignore comment + entry** (`.gitignore` lines 20–22):
```gitignore
# Per-video working directories created by URL mode (named <SAFE_TITLE>_<VIDEO_ID>/)
# The pattern *_*/ matches any directory whose name contains an underscore,
# which covers the sanitized-title + underscore + video-id naming convention.
*_*/
```

**New addition to append:**
```gitignore
# Per-user model selection (generated by --benchmark; do not commit)
config/settings.conf
```

**Pattern notes:**
- One-line comment followed immediately by the path, matching the existing style throughout `.gitignore`.
- Use `config/settings.conf` (repo-root-relative path with no leading `./`) — consistent with how `models/` and `.venv/` are listed.

---

## No Analog Found

| File | Role | Data Flow | Reason |
|---|---|---|---|
| `config/candidates.conf` | config data file | batch parse-not-source | No existing INI-like or multi-record config files in this repo. This is the first committed machine-parsed data file. The file format (content) is fully specified in RESEARCH.md `## Code Examples` and CONTEXT.md D-01. |
| `config/settings.conf.example` | config documentation / template | flat KEY=value | No existing `.example` or template files in this repo. The file format (content) is fully specified in RESEARCH.md `## Code Examples`. |

**For both config/ files:** The planner must first ensure the `config/` directory exists via `mkdir -p "$SCRIPT_DIR/config"` (RESEARCH.md Pitfall 5). The `config/` directory itself is new — no prior wave can assume it exists.

---

## Shared Patterns

### `$SCRIPT_DIR`-relative path construction
**Source:** `transcribrr.sh` line 10
**Apply to:** All references to `config/candidates.conf`, `config/settings.conf`, `config/settings.conf.example` throughout `transcribrr.sh` and any future scripts.
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Usage:
SETTINGS_FILE="$SCRIPT_DIR/config/settings.conf"
```

### Bash 3.2 portability constraint
**Source:** `transcribrr.sh` lines 287–292 (explicitly uses `while IFS= read -r line; do META+=("$line"); done < <(...)` instead of `mapfile`)
**Apply to:** All new parsing code — candidates.conf parse loop, settings.conf read helper.

Forbidden constructs (bash 3.2 lacks them):
- `mapfile` / `readarray`
- Associative arrays (`declare -A`)
- `<<<` with arrays

Permitted constructs (confirmed in existing code):
- `while IFS= read -r line; do ... done < <(cmd)` — array population
- `IFS='|' read -r a b c <<< "$line"` — string splitting (herestring is 3.2-compatible)
- `case "$var" in pattern)` — pattern matching
- `printf '%s|%s|%s|%s\n'` — record emission
- Parameter expansion: `${var#prefix}`, `${var%suffix}`, `${var:-default}`

### ERR trap + `CURRENT_STAGE` naming convention
**Source:** `transcribrr.sh` lines 27–28 and 263, 274, 349, 374, 395, 420, 441
**Apply to:** All new stage-invocation code. Set `CURRENT_STAGE` before each stage call so the ERR trap names the failing stage correctly.
```bash
CURRENT_STAGE="preflight"
trap 'echo "Error: transcribrr.sh failed during stage: $CURRENT_STAGE" >&2' ERR
# Before each stage:
CURRENT_STAGE="transcribe"
CURRENT_STAGE="cleanup"
CURRENT_STAGE="summarize"
```
The CFG-03 wrapper functions fire `exit 1` explicitly — the ERR trap still fires on the `exit 1` and will print the stage name. The CFG-03 message prints to stderr before `exit 1` so it appears above the ERR trap message.

### Section separator comment style
**Source:** `transcribrr.sh` lines 25, 95, 139, 163, 199, 244
**Apply to:** All new sections added to `transcribrr.sh`.
```bash
# ── Section name — brief note ────────────────────────────────────────────────
```
Use `──` (em-dash pairs) and trailing `─` fill characters to column 80. Match exactly — the file is visually consistent.

### Boolean variable convention
**Source:** `transcribrr.sh` lines 18–19 (`NO_CLEANUP=false`, `NO_INSTALL=false`) and line 115 (`NO_CLEANUP=true`)
**Apply to:** `*_EXPLICIT=false` / `*_EXPLICIT=true` sentinel variables.
```bash
# Unquoted false/true (not "false"/"true"), compared as:
if [ "$WHISPER_MODEL_EXPLICIT" = false ]; then ...
```

### Stage invocation output capture pattern
**Source:** `transcribrr.sh` lines 381–384, 402–405, 427–431
**Apply to:** The new `_run_*` wrapper functions — they must preserve the existing `| tee /dev/stderr | { grep "^OUTPUT_FILE=" || true; }` pipeline so progress output still streams to the user's terminal.
```bash
STAGE_OUT=$("$SCRIPT_DIR/stage.sh" "$INPUT" --model "$MODEL" \
    | tee /dev/stderr \
    | { grep "^OUTPUT_FILE=" || true; })
```

### Stage script `--model */*` HF ID passthrough (MODEL-03 — already satisfied)
**Source:** `transcribe.sh` lines 101–105, `cleanup-transcript.sh` lines 47–50, `summarize-transcript.sh` lines 96–99

All three stage scripts share the identical guard:
```bash
if [[ "$MODEL_FLAG" == */* ]]; then
    MODEL="$MODEL_FLAG"
    MODEL_LABEL=$(echo "$MODEL" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
```

**Implication for Phase 3:** Any HF ID from `candidates.conf` (e.g. `mlx-community/Qwen3-8B-4bit`, `Qwen/Qwen3-14B-MLX-4bit`) passed through `--model "$CLEANUP_MODEL"` will be accepted as-is. No stage-script edits required. The sanitizer strips `mlx-community/` for the label but leaves other org prefixes in place (so `Qwen/Qwen3-14B-MLX-4bit` gets label `qwen3-14b-mlx-4bit` — acceptable).

---

## Metadata

**Analog search scope:** Repo root — `transcribrr.sh`, `transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh`, `.gitignore`
**Files scanned:** 5
**Pattern extraction date:** 2026-06-15
