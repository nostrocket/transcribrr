# Phase 4: Benchmark Engine Core - Pattern Map

**Mapped:** 2026-06-15
**Files analyzed:** 3 (benchmark.sh NEW, transcribrr.sh MODIFIED, .gitignore MODIFIED)
**Analogs found:** 3 / 3

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `benchmark.sh` | orchestrator / harness | batch + event-driven (subprocess-per-candidate) | `transcribrr.sh` (orchestrator pattern) + `transcribe.sh` (setup_venv) | role-match + pattern-match |
| `transcribrr.sh` | orchestrator | request-response | `transcribrr.sh` itself (flag-parse + dispatch extension) | exact (self-extension) |
| `.gitignore` | config | — | `.gitignore` itself (append entry) | exact (self-extension) |

---

## Pattern Assignments

### `benchmark.sh` (NEW — orchestrator/harness, batch, subprocess-per-candidate)

**Primary analog:** `transcribrr.sh`
**Secondary analog:** `transcribe.sh` (for `setup_venv`) and `summarize-transcript.sh` (for `setup_venv` + tok/s)

---

#### Script header and SCRIPT_DIR pattern

**Analog:** `transcribrr.sh` lines 1–10

```bash
#!/bin/bash

set -euo pipefail

# benchmark.sh — Interactive staged benchmark sweep for transcribrr pipeline.
# Usage: ./benchmark.sh [--sample <youtube-url|mp3-path>]
# Dispatched from: transcribrr.sh --benchmark

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

**Note:** Use `SCRIPT_DIR`-relative paths for all references to `config/candidates.conf`, `results/`, and `.venv`. Do NOT use relative paths — `benchmark.sh` may be exec'd from a different cwd.

---

#### ERR trap + CURRENT_STAGE pattern

**Analog:** `transcribrr.sh` lines 31–34

```bash
CURRENT_STAGE="init"
trap 'echo "Error: benchmark.sh failed during: $CURRENT_STAGE" >&2' ERR
```

**Critical difference from transcribrr.sh:** The ERR trap must NOT fire for individual candidate failures. Use `set +e` / `set -e` brackets around per-candidate subprocess calls (or use explicit `if !` guards), so a single candidate OOM does not trigger the global ERR trap and abort the sweep. See D-16 / continue-on-failure pattern below.

---

#### `setup_venv()` — copy from `transcribe.sh` lines 76–90

**Analog:** `transcribe.sh` lines 76–92

```bash
VENV_DIR="$SCRIPT_DIR/.venv"
PYTHON="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

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
```

**LANDMINE (Pitfall B):** Call `setup_venv` before ANY `.venv/bin/*` access (`.venv/bin/hf`, `.venv/bin/python`). On a fresh system this path does not exist yet. Call order: TTY check → `setup_venv()` → everything else.

---

#### TTY guard — abort if not interactive

**Analog:** No existing analog. Use verified pattern from RESEARCH.md Pattern 6.

```bash
if [ ! -t 0 ]; then
    echo "Error: --benchmark requires an interactive TTY." >&2
    echo "  Run directly from a terminal, not piped or in cron." >&2
    exit 1
fi
```

**Why `[ -t 0 ]` (stdin):** stdin is the correct check for interactive input availability. `[ -t 1 ]` tests stdout, which could be redirected to a log while stdin remains interactive.

---

#### `candidates.conf` parser — parse-not-source rule

**Analog:** `transcribrr.sh` lines 151–185 (the `_read_setting` pattern — parse-not-source, `grep | cut`). The candidates parser is more complex but follows the same principle: never `source` config files.

**Pattern from RESEARCH.md Pattern 5 (verified on live file):**

```bash
CANDIDATES_CONF="$SCRIPT_DIR/config/candidates.conf"

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
    # Emit last block (CRITICAL — without this, last candidate per stage is silently dropped)
    if [ "$in_block" = true ] && [ "$current_stage" = "$stage_filter" ]; then
        printf '%s|%s|%s\n' "$current_id" "$current_label" "$current_size"
    fi
}

# Usage:
while IFS='|' read -r model_id label size_gb; do
    # process each candidate
    :
done < <(parse_candidates "whisper" "$CANDIDATES_CONF")
```

**LANDMINE (Pitfall E):** The "emit last block" section after the `while read` loop is mandatory. Without it, the last candidate in each stage group is silently dropped.

**Pitfall G — label vs id:** `candidates.conf` contains `Qwen/Qwen3-14B-MLX-4bit` (org=`Qwen`, not `mlx-community`). The stage scripts' `MODEL_LABEL` sanitizer (`sed 's/mlx-community\///'`) does NOT strip the `Qwen/` prefix. In `benchmark.sh`, always use the `label` field from `candidates.conf` for display and result file naming, and `model_id` (the HF ID) as the `--model` argument to stage scripts.

---

#### Hardware memory detection and fit gate

**Analog:** No existing analog. Use verified pattern from RESEARCH.md Pattern 2.

```bash
# Constants (top of benchmark.sh)
BENCH_OVERHEAD_BUFFER_GB=4    # covers Python + tokenizer + MLX allocator baseline
BENCH_COOLDOWN_SECS=45        # thermal recovery between candidates (30-60s range)

# Detection:
MEMSIZE_BYTES=$(sysctl -n hw.memsize)
TOTAL_GB=$(echo "$MEMSIZE_BYTES" | awk '{printf "%d", $1/1024/1024/1024}')
USABLE_GB=$(echo "$TOTAL_GB" | awk '{printf "%d", $1 * 0.75}')
echo "Detected RAM: ${TOTAL_GB} GB  |  Usable ceiling: ${USABLE_GB} GB (75%)"

# Per-candidate fit gate (use awk — bash 3.2 has no float arithmetic in (( ))):
FIT=$(awk "BEGIN {
    estimate = $size_gb + $BENCH_OVERHEAD_BUFFER_GB
    if (estimate <= $USABLE_GB) print \"fit\"
    else print \"skip\"
}")
if [ "$FIT" = "skip" ]; then
    echo "  SKIP $label: ${size_gb} + ${BENCH_OVERHEAD_BUFFER_GB} (overhead) = $(awk "BEGIN{printf \"%.1f\", $size_gb + $BENCH_OVERHEAD_BUFFER_GB}") GB > ${USABLE_GB} GB usable"
    # Write skip JSON and continue
fi
```

**Anti-pattern:** Never use `$(( ))` or `(( ))` for float comparison in bash 3.2. Always delegate to `awk`.

---

#### Disk-space gate

**Analog:** No existing analog. Use `df -g` + `awk`.

```bash
# Sum size_gb of all fitting-but-uncached candidates, then check available space:
HF_CACHE="${HOME}/.cache/huggingface/hub"
AVAIL_GB=$(df -g "$HF_CACHE" 2>/dev/null | awk 'NR==2 {print $4}')
# Hard-abort before ANY download begins:
ENOUGH=$(awk "BEGIN { if ($NEEDED_GB <= $AVAIL_GB) print \"yes\"; else print \"no\" }")
if [ "$ENOUGH" = "no" ]; then
    echo "Error: Insufficient disk space for model pre-fetch." >&2
    printf "  Need: %.1f GB  |  Available: %d GB (on %s)\n" "$NEEDED_GB" "$AVAIL_GB" "$HF_CACHE" >&2
    exit 1
fi
```

---

#### HF model cache detection and pre-fetch

**Analog:** No existing analog. Use verified pattern from RESEARCH.md Pattern 3.

```bash
HF_CACHE="${HOME}/.cache/huggingface/hub"
HF_CLI="$VENV_DIR/bin/hf"   # NOT huggingface-cli (deprecated, warns on stderr)

is_model_cached() {
    local model_id="$1"
    local cache_name="models--$(echo "$model_id" | sed 's|/|--|g')"
    local snapshots_dir="$HF_CACHE/$cache_name/snapshots"
    [ -d "$snapshots_dir" ] && [ -n "$(ls -A "$snapshots_dir" 2>/dev/null)" ]
}

# Pre-fetch loop — only call hf download for models NOT in cache:
if ! is_model_cached "$model_id"; then
    echo "  Downloading $label ($model_id) ..."
    "$HF_CLI" download "$model_id"
else
    echo "  Cached: $label"
fi
```

**LANDMINE (Pitfall D):** Even for a cached model, `hf download` makes a network request to check for updates. Use `is_model_cached()` guard first and only call `hf download` when the model is NOT cached.

---

#### Stage banner — reuse existing function verbatim

**Analog:** `transcribrr.sh` lines 301–308

```bash
stage_banner() {
    local msg="$1"
    echo ""
    echo "=========================================="
    echo "  $msg"
    echo "=========================================="
    echo ""
}
```

**Usage in benchmark.sh:** Copy this function into `benchmark.sh` (it is defined in `transcribrr.sh`, not a library — exec-dispatch gives `benchmark.sh` no access to the parent's functions). Call it as:

```bash
stage_banner "Benchmark: whisper (1/3) — ${total_candidates} candidates to run"
```

---

#### Per-candidate subprocess with `/usr/bin/time -l` + capture idiom

**Analog:** `transcribrr.sh` `_run_transcribe` idiom (lines 436–450) — extended with `/usr/bin/time -l` and `$TIME_OUT` temp file.

**Analog lines 436–450:**
```bash
_run_transcribe() {
    "$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
        | tee /dev/stderr \
        | { grep "^OUTPUT_FILE=" || true; }
}
if ! STAGE_OUT=$(_run_transcribe); then
    ...
fi
TRANSCRIPT_FILE="${STAGE_OUT#OUTPUT_FILE=}"
```

**benchmark.sh adaptation (verified, RESEARCH.md Pattern 1):**

```bash
# For each fitting candidate — wrap in set +e for continue-on-failure (D-16):
TIME_OUT=$(mktemp)
t_start=$(date +%s)

set +e
STAGE_OUT=$( /usr/bin/time -l "$SCRIPT_DIR/transcribe.sh" "$SAMPLE_MP3" \
               --model "$model_id" \
               2>"$TIME_OUT" \
             | tee /dev/stderr \
             | { grep "^OUTPUT_FILE=" || true; } )
candidate_exit=$?
set -e

t_end=$(date +%s)
wall_time=$((t_end - t_start))

if [ "$candidate_exit" -ne 0 ]; then
    # Write error JSON (D-16 — continue, not abort)
    write_error_json "$model_id" "$label" "$stage" "$candidate_exit" "$result_json_path"
    rm -f "$TIME_OUT"
    continue
fi

output_file="${STAGE_OUT#OUTPUT_FILE=}"
peak_bytes=$(grep "maximum resident set size" "$TIME_OUT" | awk '{print $1}')
peak_gb=$(echo "$peak_bytes" | awk '{printf "%.2f", $1/1024/1024/1024}')
rm -f "$TIME_OUT"
```

**CRITICAL ANTI-PATTERN:** Never `{ /usr/bin/time -l ... } 2>&1` — this merges time metrics into stdout and corrupts the `grep "^OUTPUT_FILE="` capture. Always `2>"$TIME_OUT"`.

**Why `set +e` / `set -e` around the subprocess call:** `set -euo pipefail` is active globally; a nonzero exit from the stage subprocess would trigger the ERR trap and abort the sweep. The `set +e` bracket + explicit `$candidate_exit` check implements D-16 (continue-on-failure).

---

#### Warm-up pass pattern

**Analog:** Same `_run_*` idiom but with a short synthetic audio and discarded output (no capture needed).

```bash
# Warm-up: separate subprocess invocation before timed pass (Pitfall C — NEVER same subprocess)
# Generate a 5-second silence wav for warm-up (populates Metal kernel disk cache):
WARMUP_WAV=$(mktemp /tmp/benchmark_warmup_XXXXXX.wav)
ffmpeg -f lavfi -i "sine=frequency=440:duration=5" -ar 16000 "$WARMUP_WAV" -y -loglevel quiet

warmup_start=$(date +%s)
set +e
"$SCRIPT_DIR/transcribe.sh" "$WARMUP_WAV" --model "$model_id" \
    > /dev/null 2>&1
warmup_exit=$?
set -e
warmup_end=$(date +%s)
warmup_wall=$((warmup_end - warmup_start))
rm -f "$WARMUP_WAV"
# Note: warmup_exit nonzero on short audio is acceptable (some models error on <1s input)
# The timed pass uses the full SAMPLE_MP3 and is what matters.

# Brief cool-down after warm-up before timed pass:
sleep 5
```

**Architecture note (RESEARCH.md Pitfall C):** Warm-up IS a full subprocess invocation of the stage script. Timed pass IS a separate subprocess. Two subprocess calls per candidate. Never combine them — MLX Metal memory accumulates within a process and skews timing.

---

#### Speed metric computation

**Analog:** `transcribe.sh` lines 103–113 (audio duration via ffmpeg — RTF denominator).

**Whisper RTF (reuse transcribe.sh's ffmpeg duration pattern):**
```bash
# Compute audio duration ONCE before the sweep (not per-candidate):
DURATION_STR=$(ffmpeg -i "$SAMPLE_MP3" 2>&1 | grep "Duration" | awk '{print $2}' | tr -d ,)
IFS=: read h m s <<< "$DURATION_STR"
AUDIO_DURATION_S=$(echo "$h * 3600 + $m * 60 + $s" | LC_NUMERIC=C bc)

# After timed pass:
RTF=$(awk "BEGIN {printf \"%.3f\", $wall_time / $AUDIO_DURATION_S}")
```

**Summarize tok/s (from stage stdout — verified on live system):**

`summarize-transcript.sh` line 387 emits:
```
  Generated ~4096 tokens in 12.5s (327.7 tok/s)
```

```bash
TOK_PER_S=$(echo "$stage_stdout" | grep -oE '[0-9]+\.[0-9]+ tok/s' | tail -1 | awk '{print $1}')
```

**Cleanup tok/s (derived — no self-report from cleanup-transcript.sh):**
```bash
WORD_COUNT=$(wc -w < "$output_file" | tr -d ' ')
TOK_PER_S=$(awk "BEGIN {printf \"%.1f\", ($WORD_COUNT * 1.3) / $wall_time}")
```

---

#### JSON result file writing — Python for safe escaping

**Analog:** No existing analog. Use Python-generated JSON (RESEARCH.md Pattern 7). Never use shell string concatenation for JSON with model output (newlines, backslashes, quotes are all present in transcripts).

```bash
# Success JSON:
"$PYTHON" - << PYEOF
import json, datetime
data = {
    "format_version":      1,
    "candidate_id":        "$model_id",
    "label":               "$label",
    "stage":               "$stage",
    "run_ts":              datetime.datetime.now().isoformat(timespec='seconds'),
    "fit_status":          "fit",
    "error":               None,
    "speed_metric":        "$speed_metric",
    "speed_value":         $speed_value,
    "peak_mem_bytes":      $peak_bytes,
    "peak_mem_gb":         $peak_gb,
    "wall_time_sec":       $wall_time,
    "audio_duration_sec":  $audio_duration_sec,
    "output_file":         "$output_file",
    "warmup_wall_sec":     $warmup_wall,
}
with open("$result_json_path", "w") as f:
    json.dump(data, f, indent=2)
PYEOF

# Error JSON (OOM / nonzero exit):
"$PYTHON" -c "
import json
data = {'format_version': 1, 'candidate_id': '$model_id', 'label': '$label',
        'stage': '$stage', 'fit_status': 'fit',
        'error': 'subprocess_nonzero', 'exit_code': $candidate_exit}
open('$result_json_path', 'w').write(json.dumps(data, indent=2))
"

# Skip JSON (fit gate):
"$PYTHON" -c "
import json
data = {'format_version': 1, 'candidate_id': '$model_id', 'label': '$label',
        'stage': '$stage', 'fit_status': 'skip',
        'skip_reason': '${size_gb}(size) + ${BENCH_OVERHEAD_BUFFER_GB}(overhead) = $(awk "BEGIN{printf \"%.1f\",$size_gb+$BENCH_OVERHEAD_BUFFER_GB}") > ${USABLE_GB}(usable)'}
open('$result_json_path', 'w').write(json.dumps(data, indent=2))
"
```

---

#### Live progress

**Analog:** `transcribrr.sh` `stage_banner()` for headers (see above). Per-candidate in-line progress follows `transcribe.sh`'s `\r` printf pattern (line 236).

```bash
# Per-candidate running line (overwrite same terminal line with \r):
printf "  [%s %d/%d]  %-35s  elapsed: %ds\r" \
    "$stage" "$current_num" "$total_candidates" "$label" "$elapsed"

# After candidate completes — advance line + summary:
echo ""
printf "  %-35s  RTF/tok-s: %-8s  Mem: %s GB\n" \
    "$label" "$speed_value" "$peak_gb"
```

---

#### Per-stage interactive selection

**Analog:** No existing analog. Standard bash `read -r` with TTY already guaranteed.

```bash
# Display results table for stage, then prompt:
echo ""
echo "  Stage complete. Select the best output:"
echo ""
i=0
while IFS='|' read -r cand_label cand_output; do
    i=$((i + 1))
    printf "  [%d] %s\n" "$i" "$cand_label"
    echo "      --- excerpt (first 10 lines) ---"
    head -10 "$cand_output" | sed 's/^/      /'
    echo ""
done < "$STAGE_RESULTS_LIST"

printf "Enter number (1-%d): " "$i"
read -r selection
# Validate: must be integer in [1..i]
if ! echo "$selection" | grep -qE '^[0-9]+$' || \
   [ "$selection" -lt 1 ] || [ "$selection" -gt "$i" ]; then
    echo "Error: invalid selection '$selection'" >&2
    exit 1
fi
# Extract selected output file and pass to next stage
SELECTED_OUTPUT=$(sed -n "${selection}p" "$STAGE_RESULTS_LIST" | cut -d'|' -f2)
```

---

#### Sample audio cache

**Analog:** `transcribrr.sh` URL download logic (lines 403–424) — same `yt-dlp` dependency.

```bash
BENCH_SAMPLE_URL="${BENCH_SAMPLE_URL:-https://www.youtube.com/watch?v=EWo7-azGHic}"
VIDEO_ID=$(echo "$BENCH_SAMPLE_URL" | grep -oE '[?&]v=[^&]+' | sed 's/[?&]v=//')
RESULTS_DIR="$SCRIPT_DIR/results"
SAMPLE_CACHE="$RESULTS_DIR/sample_${VIDEO_ID}.mp3"

mkdir -p "$RESULTS_DIR"

if [ ! -f "$SAMPLE_CACHE" ]; then
    stage_banner "Downloading benchmark sample audio (first run only)..."
    ensure_dep yt-dlp yt-dlp  # reuse transcribrr.sh's ensure_dep pattern
    yt-dlp -x --audio-format mp3 \
           --no-playlist \
           -o "$RESULTS_DIR/sample_${VIDEO_ID}.%(ext)s" \
           "$BENCH_SAMPLE_URL"
    SAMPLE_MP3="$SAMPLE_CACHE"
else
    echo "Sample audio cached: $SAMPLE_CACHE"
    SAMPLE_MP3="$SAMPLE_CACHE"
fi
```

**Note:** `ensure_dep` is defined in `transcribrr.sh` (lines 223–252). Copy the function into `benchmark.sh` or inline the brew-install logic. `benchmark.sh` is exec'd as a standalone script and cannot access `transcribrr.sh`'s function definitions.

---

#### Result directory structure

```bash
RUN_TS=$(date '+%Y%m%dT%H%M%S')
RUN_DIR="$SCRIPT_DIR/results/benchmark_${RUN_TS}"
mkdir -p "$RUN_DIR/whisper" "$RUN_DIR/cleanup" "$RUN_DIR/summarize"

# Per-candidate result file path:
result_json_path="$RUN_DIR/$stage/${label}_result.json"

# Sweep metadata (written at end of sweep):
"$PYTHON" -c "
import json, datetime
data = {
    'run_ts': '${RUN_TS}',
    'total_ram_gb': $TOTAL_GB,
    'usable_gb': $USABLE_GB,
    'audio_duration_s': $AUDIO_DURATION_S,
    'sample_url': '$BENCH_SAMPLE_URL',
    'overhead_buffer_gb': $BENCH_OVERHEAD_BUFFER_GB,
    'cooldown_secs': $BENCH_COOLDOWN_SECS,
}
open('$RUN_DIR/sweep_meta.json', 'w').write(json.dumps(data, indent=2))
"
```

---

### `transcribrr.sh` (MODIFIED — flag-parse extension + exec-dispatch + help update)

**Analog:** `transcribrr.sh` itself — extend the existing flag-parse loop and help text.

---

#### Flag-parse loop extension

**Analog:** `transcribrr.sh` lines 103–149 (the `while [[ $# -gt 0 ]]; do case $1 in ...` block).

Add two new cases inside the existing `case` block, before the `-*)` catch-all:

```bash
        --benchmark)
            BENCHMARK_MODE=true
            shift
            ;;
        --sample)
            BENCH_SAMPLE_ARG="$2"
            shift 2
            ;;
```

Declare defaults at the top of the script (alongside the existing defaults block, lines 12–29):

```bash
BENCHMARK_MODE=false
BENCH_SAMPLE_ARG=""
```

---

#### Exec-dispatch block

**Analog:** `transcribrr.sh` lines 310–425 (the `if [ "$IS_URL" = true ]` dispatch pattern). The benchmark dispatch goes AFTER settings.conf read (line 185) and BEFORE the URL/local input validation block.

Place this block immediately after the settings.conf read section (after line 185):

```bash
# ── Benchmark dispatch (D-17) ─────────────────────────────────────────────────
# exec replaces this process — no code after this block runs in benchmark mode.

if [ "$BENCHMARK_MODE" = true ]; then
    BENCHMARK_SCRIPT="$SCRIPT_DIR/benchmark.sh"
    if [ ! -f "$BENCHMARK_SCRIPT" ] || [ ! -x "$BENCHMARK_SCRIPT" ]; then
        echo "Error: benchmark.sh not found or not executable: $BENCHMARK_SCRIPT" >&2
        exit 1
    fi
    if [ -n "$BENCH_SAMPLE_ARG" ]; then
        exec "$BENCHMARK_SCRIPT" --sample "$BENCH_SAMPLE_ARG"
    else
        exec "$BENCHMARK_SCRIPT"
    fi
fi
```

**Why `exec` (not fork):** `exec` replaces the shell process rather than spawning a child. This means `benchmark.sh` inherits the terminal's TTY, which is necessary for the `[ -t 0 ]` interactive guard to work correctly. If `transcribrr.sh` forked `benchmark.sh` as a subshell, stdin redirection behaviour could differ.

---

#### `print_help()` extension

**Analog:** `transcribrr.sh` lines 38–99 (the `print_help()` heredoc).

Add to the Options section (before `--no-install`):

```
  --benchmark             Run the interactive benchmark sweep. Requires an
                          interactive TTY. For each pipeline stage (whisper,
                          cleanup, summarize), runs all hardware-fitting model
                          candidates, measures speed and memory, shows a real
                          output excerpt, then prompts you to select the best
                          result. Per-stage picks chain into the next stage.

  --sample <url|mp3>      Override the default benchmark audio sample.
                          Accepts a YouTube URL or path to a local MP3.
                          Default: https://www.youtube.com/watch?v=EWo7-azGHic
```

---

### `.gitignore` (MODIFIED — add `results/` entry)

**Analog:** `.gitignore` itself (lines 19–23 explain the `*_*/` pattern context).

**Add after the `config/settings.conf` entry (line 28):**

```gitignore
# Benchmark results directory (per-run dirs already caught by *_*/ above,
# but results/ parent must be explicit to suppress git status noise)
results/
```

**Note from RESEARCH.md (Pitfall F):** The existing `*_*/` pattern already catches `benchmark_<ts>/` subdirs. The `results/` parent directory itself needs an explicit entry so `git status` does not show it as an untracked directory.

---

## Shared Patterns

### Bash 3.2 compatibility (applies to all of `benchmark.sh`)

**Source:** `transcribrr.sh` throughout; `RESEARCH.md` PITFALLS #12

**Rules enforced everywhere in `benchmark.sh`:**

- No `mapfile` / `readarray` — use `while IFS= read -r line; do ... done < <(...)` 
- No `declare -A` associative arrays — use flat files for candidate→result mapping
- No float in `$(( ))` or `(( ))` — always delegate to `awk 'BEGIN {printf...}'`
- `LC_NUMERIC=C bc` if `bc` is used at all (awk preferred)
- All variables double-quoted in subprocess calls: `"$model_id"`, `"$label"`, `"$output_file"`

**Reference — portable array build from transcribrr.sh lines 343–355:**
```bash
MY_ARRAY=()
while IFS= read -r line; do
    MY_ARRAY+=("$line")
done < <(some_command)
```

---

### `ensure_dep` — auto-install or hint

**Source:** `transcribrr.sh` lines 223–252

Copy verbatim into `benchmark.sh` (exec-dispatch gives no access to parent script functions):

```bash
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
```

---

### `SCRIPT_DIR`-relative paths

**Source:** `transcribrr.sh` line 10; `transcribe.sh` line 69; `summarize-transcript.sh` line 42

All three existing scripts use the same idiom:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

All paths from `benchmark.sh` must be constructed from `$SCRIPT_DIR`:
- `"$SCRIPT_DIR/config/candidates.conf"`
- `"$SCRIPT_DIR/results/"`
- `"$SCRIPT_DIR/.venv"`
- `"$SCRIPT_DIR/transcribe.sh"` (never bare `./transcribe.sh`)

---

### Parse-not-source for config files

**Source:** `transcribrr.sh` lines 151–185 (`_read_setting` pattern)

```bash
# CORRECT: parse with grep/cut — no shell evaluation
_read_setting() {
    grep "^${1}=" "$SETTINGS_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# WRONG (never do this):
source "$SETTINGS_FILE"   # executes arbitrary shell code
. "$SETTINGS_FILE"        # same
```

The same principle applies to `candidates.conf` — use the `parse_candidates()` function above, never `source config/candidates.conf`.

---

### Atomic temp+mv write for files

**Source:** `transcribrr.sh` lines 567–604

Not needed for Phase 4's append-only JSON results (each result file is written once and never re-written). However, Phase 5's `settings.conf` write WILL use this pattern. Reference for continuity:

```bash
TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT
# ... write to TEMP_FILE ...
mv "$TEMP_FILE" "$TARGET_FILE"
trap - EXIT
```

---

## No Analog Found

Files with no close existing codebase match (use RESEARCH.md patterns instead):

| File / Feature | Role | Data Flow | Reason |
|----------------|------|-----------|--------|
| `benchmark.sh` — TTY guard | guard | — | No interactive-only guard exists anywhere in codebase |
| `benchmark.sh` — HW memory detection | utility | — | No `sysctl` usage exists in codebase |
| `benchmark.sh` — disk-space gate | utility | — | No `df` usage exists in codebase |
| `benchmark.sh` — HF cache detection / pre-fetch | utility | — | No HF cache interaction in codebase |
| `benchmark.sh` — `/usr/bin/time -l` peak RSS | metrics | — | No process-wrapping timing in codebase |
| `benchmark.sh` — per-stage interactive selection | UI | event-driven | No `read` prompts exist in codebase |
| `benchmark.sh` — JSON result writing | output | — | No JSON output in codebase (all output is plaintext) |

All of the above have verified patterns in `04-RESEARCH.md` (Patterns 1–8) and should be implemented from those patterns.

---

## Metadata

**Analog search scope:** repo root (`transcribrr.sh`, `transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh`, `config/candidates.conf`, `.gitignore`)
**Files read:** 7
**Pattern extraction date:** 2026-06-15
