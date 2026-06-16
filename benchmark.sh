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

# WR-04 fix: EXIT trap cleans up known temp files on any exit.
# Files are registered into _BENCH_TMPFILES as they are allocated.
# Signal handlers (INT/TERM) must EXIT — not just clean up — otherwise bash runs
# the handler and RESUMES the script, swallowing Ctrl+C. `exit` then fires the EXIT
# trap, so cleanup still runs exactly once. Exit codes follow 128+signal convention.
_BENCH_TMPFILES=()
_bench_cleanup() { [ ${#_BENCH_TMPFILES[@]} -gt 0 ] && rm -f "${_BENCH_TMPFILES[@]}" 2>/dev/null; return 0; }
trap '_bench_cleanup' EXIT
trap 'exit 130' INT     # Ctrl+C  → 128 + SIGINT(2)
trap 'exit 143' TERM    # SIGTERM → 128 + SIGTERM(15)

# ── Argument parsing ─────────────────────────────────────────────────────────

BENCH_SAMPLE_ARG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --sample)
            # WR-03 fix: guard against bare --sample with no following value (set -u crash)
            if [ $# -lt 2 ]; then
                echo "Error: --sample requires an argument (URL or MP3 path)." >&2
                echo "Usage: benchmark.sh [--sample <url|mp3>]" >&2
                exit 1
            fi
            BENCH_SAMPLE_ARG="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Usage: benchmark.sh [--sample <url|mp3>]" >&2
            exit 1
            ;;
        *)
            # WR-03 fix: add default case so positional args don't cause an infinite loop
            # (no shift occurred previously, so $# never decremented).
            echo "Error: unexpected argument: $1" >&2
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

# ── Hugging Face token resolution — higher rate limits + faster downloads ─────
# Prefer an already-exported HF_TOKEN; otherwise read it from ~/.zshrc so the
# token is always used even when benchmark.sh runs from a shell that never
# sourced the profile (cron, `sh -c ...`, a fresh non-interactive shell). The hf
# CLI reads HF_TOKEN from the environment, so exporting it here is all it needs.
CURRENT_STAGE="hf-auth"
if [ -z "${HF_TOKEN:-}" ] && [ -f "$HOME/.zshrc" ]; then
    _tok=$(grep -E '^[[:space:]]*export[[:space:]]+HF_TOKEN=' "$HOME/.zshrc" | tail -1 || true)  # no match must not trip set -e/pipefail
    _tok=${_tok#*=}            # drop up to the first '='
    _tok=${_tok%\"}; _tok=${_tok#\"}   # strip surrounding double quotes
    _tok=${_tok%\'}; _tok=${_tok#\'}   # strip surrounding single quotes
    if [ -n "$_tok" ]; then HF_TOKEN=$_tok; export HF_TOKEN; fi
    unset _tok
fi
if [ -n "${HF_TOKEN:-}" ]; then
    echo "Hugging Face: HF_TOKEN detected — authenticated downloads (higher rate limits)."
else
    echo "Please set a HF_TOKEN to enable higher rate limits and faster downloads" >&2
fi

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

# ── Hardware memory detection (HW-01, D-05/D-06) ────────────────────────────
# Detect total unified memory via sysctl, compute 75% usable ceiling.
# Bash 3.2: no float in (( )) — all arithmetic via awk.

CURRENT_STAGE="hardware-detection"

MEMSIZE_BYTES=$(sysctl -n hw.memsize)
TOTAL_GB=$(echo "$MEMSIZE_BYTES" | awk '{printf "%d", $1/1024/1024/1024}')
USABLE_GB=$(echo "$TOTAL_GB" | awk '{printf "%d", $1 * 0.75}')
echo "Detected RAM: ${TOTAL_GB} GB | Usable ceiling: ${USABLE_GB} GB (75%)"

# ── HF cache detection helper (Pattern 3, Pitfall D) ────────────────────────
# Checks local dir structure — no network access.
# Returns 0 (cached) or 1 (not cached).

is_model_cached() {
    local model_id="$1"
    local cache_name="models--$(echo "$model_id" | sed 's|/|--|g')"
    local snapshots_dir="$HF_CACHE/$cache_name/snapshots"
    [ -d "$snapshots_dir" ] && [ -n "$(ls -A "$snapshots_dir" 2>/dev/null)" ]
}

# ── Fit gate — classify each candidate as fit/skip (HW-02/03, D-07) ─────────
# estimate = size_gb + BENCH_OVERHEAD_BUFFER_GB; compare <= USABLE_GB via awk.
# NEVER use (( )) for float comparison — bash 3.2 integer-only.
# Fitting candidates are accumulated for the disk-space gate and pre-fetch.

CURRENT_STAGE="fit-gate"

# Arrays for fitting candidates (bash 3.2 safe: append to indexed array)
FITTING_IDS=()
FITTING_LABELS=()
FITTING_SIZES=()
FITTING_STAGES=()

for stage_filter in whisper cleanup summarize; do
    while IFS='|' read -r model_id label size_gb; do
        FIT=$(awk "BEGIN {
            estimate = $size_gb + $BENCH_OVERHEAD_BUFFER_GB
            if (estimate <= $USABLE_GB) print \"fit\"
            else print \"skip\"
        }")
        if [ "$FIT" = "skip" ]; then
            ESTIMATE=$(awk "BEGIN{printf \"%.1f\", $size_gb + $BENCH_OVERHEAD_BUFFER_GB}")
            echo "  SKIP $label: ${size_gb}+${BENCH_OVERHEAD_BUFFER_GB}=${ESTIMATE} GB > ${USABLE_GB} GB usable"
        else
            FITTING_IDS+=("$model_id")
            FITTING_LABELS+=("$label")
            FITTING_SIZES+=("$size_gb")
            FITTING_STAGES+=("$stage_filter")
        fi
    done < <(parse_candidates "$stage_filter" "$CANDIDATES_CONF")
done

# ── Disk-space gate — guard before any download (D-09) ───────────────────────
# Sum size_gb of fitting-but-uncached candidates; hard-abort if insufficient.
# The disk gate MUST run before any hf download invocation.

CURRENT_STAGE="disk-gate"

# WR-05 fix: accumulate as float (NEEDED_GB_F), then ceiling to nearest integer.
# The original "%d" truncation caused sub-0.5 GB models to contribute 0 each,
# so an all-tiny uncached set could total NEEDED_GB=0 and skip the gate entirely.
NEEDED_GB_F="0"
for i in "${!FITTING_IDS[@]}"; do
    model_id="${FITTING_IDS[$i]}"
    size_gb="${FITTING_SIZES[$i]}"
    if ! is_model_cached "$model_id"; then
        NEEDED_GB_F=$(awk "BEGIN{printf \"%.3f\", $NEEDED_GB_F + $size_gb}")
    fi
done
# Ceiling: if the float has a fractional part, round up; otherwise use exact value.
NEEDED_GB=$(awk "BEGIN{ v=$NEEDED_GB_F; printf \"%d\", (v == int(v)) ? v : int(v)+1 }")

if [ "$NEEDED_GB" -gt 0 ]; then
    mkdir -p "$HF_CACHE"
    AVAIL_GB=$(df -g "$HF_CACHE" 2>/dev/null | awk 'NR==2 {print $4}')
    # CR-02 fix: guard against empty AVAIL_GB (unexpected df output → awk syntax error
    # with set -e aborts the entire script before any model is tested).
    if [ -z "$AVAIL_GB" ] || ! echo "$AVAIL_GB" | grep -qE '^[0-9]+$'; then
        echo "Warning: cannot determine available disk space for $HF_CACHE — skipping disk-space gate." >&2
        AVAIL_GB="$NEEDED_GB"   # treat as exactly sufficient; gate passes, but warns
    fi
    ENOUGH=$(awk "BEGIN { if ($NEEDED_GB <= $AVAIL_GB) print \"yes\"; else print \"no\" }")
    if [ "$ENOUGH" = "no" ]; then
        echo "Error: Insufficient disk space for model pre-fetch. Need: ${NEEDED_GB} GB | Available: ${AVAIL_GB} GB" >&2
        exit 1
    fi
fi

# ── Model pre-fetch — download uncached fitting candidates (D-08) ─────────────
# Use .venv/bin/hf (the current hf CLI — NOT the deprecated legacy tool — Pitfall D / RESEARCH Decision #4).
# Guard with is_model_cached() before every hf download call.
# All fitting models must be cached locally before timing starts.

CURRENT_STAGE="pre-fetch"

for i in "${!FITTING_IDS[@]}"; do
    model_id="${FITTING_IDS[$i]}"
    label="${FITTING_LABELS[$i]}"
    if is_model_cached "$model_id"; then
        echo "  Cached: $label"
    else
        echo "  Downloading $label ($model_id) ..."
        "$HF_CLI" download "$model_id"
    fi
done

# ── Sample audio cache (BENCH-06, D-13) ─────────────────────────────────────
# Branch 1 — LOCAL FILE: --sample <existing-path> → use directly, no download.
# Branch 2 — URL / default: download via yt-dlp and cache under results/.
# DEFAULT sample: https://www.youtube.com/watch?v=EWo7-azGHic (full video, D-13).

CURRENT_STAGE="sample-audio"

BENCH_SAMPLE_URL="https://www.youtube.com/watch?v=EWo7-azGHic"

if [ -n "$BENCH_SAMPLE_ARG" ] && [ -f "$BENCH_SAMPLE_ARG" ]; then
    # Branch 1: caller supplied an existing local file — use directly, no download.
    SAMPLE_MP3="$BENCH_SAMPLE_ARG"
    echo "Using local sample file: $SAMPLE_MP3"
else
    # Branch 2: URL (or default). Override default if a URL was supplied.
    if [ -n "$BENCH_SAMPLE_ARG" ]; then
        BENCH_SAMPLE_URL="$BENCH_SAMPLE_ARG"
    fi

    # WR-01 fix: extract VIDEO_ID from ?v=, &v= (watch URLs), and youtu.be/<id> path.
    # If neither pattern matches (unknown URL shape), fall back to a hash of the URL
    # so two distinct URLs never collide on the same sample_.mp3 cache file.
    VIDEO_ID=$(echo "$BENCH_SAMPLE_URL" | grep -oE '[?&]v=[^&]+' | sed 's/[?&]v=//')
    if [ -z "$VIDEO_ID" ]; then
        VIDEO_ID=$(echo "$BENCH_SAMPLE_URL" | grep -oE 'youtu\.be/([^?&]+)' | sed 's|youtu\.be/||')
    fi
    if [ -z "$VIDEO_ID" ]; then
        # Last-resort: hash the URL so distinct URLs do not collide
        VIDEO_ID=$(echo "$BENCH_SAMPLE_URL" | cksum | awk '{print $1}')
    fi
    SAMPLE_MP3="$RESULTS_DIR/sample_${VIDEO_ID}.mp3"
    mkdir -p "$RESULTS_DIR"

    if [ ! -f "$SAMPLE_MP3" ]; then
        stage_banner "Downloading benchmark sample audio (first run only)"
        ensure_dep yt-dlp yt-dlp
        yt-dlp -x --audio-format mp3 \
               --no-playlist \
               -o "$RESULTS_DIR/sample_${VIDEO_ID}.%(ext)s" \
               "$BENCH_SAMPLE_URL"
    else
        echo "Sample audio cached: $SAMPLE_MP3"
    fi
fi

# ── Audio duration (RTF denominator — compute once, D-11) ────────────────────
# Reuse transcribe.sh ffmpeg idiom (lines 103-113).
# LC_NUMERIC=C bc is mandatory to avoid locale decimal-separator issues.

CURRENT_STAGE="audio-duration"

ensure_dep ffmpeg ffmpeg
DURATION_STR=$(ffmpeg -i "$SAMPLE_MP3" 3>&1 1>/dev/null 2>&3 3>&- | grep "Duration" | awk '{print $2}' | tr -d ,)
IFS=: read h m s <<< "$DURATION_STR"
AUDIO_DURATION_S=$(echo "$h * 3600 + $m * 60 + $s" | LC_NUMERIC=C bc)
echo "Audio duration: $DURATION_STR (${AUDIO_DURATION_S%.*} seconds)"

# ── JSON result writers (D-15, T-04-09 — Python for safe escaping) ───────────
# Three writers: write_success_json, write_error_json, write_skip_json.
# ALL JSON is generated via "$PYTHON" json module — NEVER shell string concatenation.
# Model output (transcript text, file paths) may contain quotes/newlines/backslashes.

write_success_json() {
    local model_id="$1"
    local label="$2"
    local stage="$3"
    local speed_metric="$4"      # "rtf" or "tok_per_s"
    local speed_value="$5"       # numeric (no quotes in JSON)
    local peak_bytes="$6"        # numeric
    local peak_gb="$7"           # numeric
    local wall_time="$8"         # integer seconds
    local audio_duration_sec="$9" # numeric or "None" (whisper only; others pass None)
    local output_file="${10}"
    local result_json_path="${11}"
    local warmup_wall="${12}"     # integer seconds

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
}

write_error_json() {
    local model_id="$1"
    local label="$2"
    local stage="$3"
    local candidate_exit="$4"
    local result_json_path="$5"

    "$PYTHON" - << PYEOF
import json, datetime
data = {
    "format_version":      1,
    "candidate_id":        "$model_id",
    "label":               "$label",
    "stage":               "$stage",
    "run_ts":              datetime.datetime.now().isoformat(timespec='seconds'),
    "fit_status":          "fit",
    "error":               "subprocess_nonzero",
    "exit_code":           $candidate_exit,
    "speed_metric":        None,
    "speed_value":         None,
    "peak_mem_bytes":      None,
    "peak_mem_gb":         None,
    "wall_time_sec":       None,
    "audio_duration_sec":  None,
    "output_file":         None,
    "warmup_wall_sec":     None,
}
with open("$result_json_path", "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

write_skip_json() {
    local model_id="$1"
    local label="$2"
    local stage="$3"
    local skip_reason="$4"
    local result_json_path="$5"

    "$PYTHON" - << PYEOF
import json
data = {
    "format_version":  1,
    "candidate_id":    "$model_id",
    "label":           "$label",
    "stage":           "$stage",
    "fit_status":      "skip",
    "skip_reason":     "$skip_reason",
}
with open("$result_json_path", "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# ── run_candidate: per-candidate execution engine (BENCH-02/03/04/05/08, D-10..D-16) ──
#
# Usage: run_candidate <stage> <model_id> <label> <input_file>
#                       <result_json_path> <output_dir> [extra_args]
#
# stage:            whisper | cleanup | summarize
# model_id:         HF model id passed to --model (Pitfall G: use id, not label)
# label:            human-readable label used for display and result file naming
# input_file:       audio file (whisper) or transcript file (cleanup/summarize)
# result_json_path: path to write the per-candidate JSON result
# output_dir:       directory where stage script writes its output (passed as OUTPUT_DIR=)
# extra_args:       optional trailing args forwarded verbatim to both warm-up and
#                   timed subprocesses (e.g. "--style blog" for summarize — plan 04-04)
#
# Architecture (locked by research):
#   BENCH-03 / Pitfall C: warm-up IS a separate full subprocess invocation;
#             timed pass IS a separate subprocess — MLX Metal memory not released in-process.
#   D-10 / Pitfall A: /usr/bin/time -l + 2>"$TIME_OUT" — NEVER merge stderr to
#             stdout (that corrupts the OUTPUT_FILE= grep with time metrics).
#   D-16: set +e / set -e bracket + return (not exit) on nonzero → sweep continues.
#   T-04-09: all JSON written via Python json module.
#   T-04-10: TIME_OUT and STDOUT_TMP both via mktemp; rm -f on both paths.

run_candidate() {
    local stage="$1"
    local model_id="$2"
    local label="$3"
    local input_file="$4"
    local result_json_path="$5"
    local output_dir="$6"
    local extra_args="${7:-}"   # optional; word-split when expanded (intentional — $STAGE_EXTRA)

    # Resolve stage script path (SCRIPT_DIR-relative — never bare ./script.sh)
    local stage_script
    case "$stage" in
        whisper)   stage_script="$SCRIPT_DIR/transcribe.sh" ;;
        cleanup)   stage_script="$SCRIPT_DIR/cleanup-transcript.sh" ;;
        summarize) stage_script="$SCRIPT_DIR/summarize-transcript.sh" ;;
        *)
            echo "  ERROR: unknown stage '$stage'" >&2
            return 1
            ;;
    esac

    # STAGE_EXTRA: intentionally NOT double-quoted in subprocess calls below.
    # An empty value contributes zero args; "--style blog" expands to two args.
    # shellcheck disable=SC2206
    local STAGE_EXTRA
    STAGE_EXTRA=$extra_args

    # ── Step 1: WARM-UP (BENCH-03, Pitfall C) ────────────────────────────────
    # A SEPARATE full subprocess to populate the Metal kernel disk cache.
    # Warm-up exit is tolerated — short input may error on some models; that is OK.

    local warmup_input warmup_start warmup_end warmup_wall
    warmup_input=""

    if [ "$stage" = "whisper" ]; then
        # Generate a 5-second sine wave for warm-up (populates Metal kernel cache)
        warmup_input=$(mktemp /tmp/benchmark_warmup_XXXXXX.wav)
        # WR-04 fix: ensure warmup file is removed even if ffmpeg fails under set -e
        # (local trap inside the function; does not interfere with global ERR/EXIT traps).
        trap 'rm -f "$warmup_input" 2>/dev/null' RETURN
        ffmpeg -f lavfi -i "sine=frequency=440:duration=5" -ar 16000 \
               "$warmup_input" -y -loglevel quiet
    else
        # Cleanup/summarize: warm up on a tiny temp text file
        warmup_input=$(mktemp /tmp/benchmark_warmup_XXXXXX.txt)
        trap 'rm -f "$warmup_input" 2>/dev/null' RETURN
        printf "This is a short warm-up text for the %s model.\n" "$stage" > "$warmup_input"
    fi

    warmup_start=$(date +%s)
    set +e
    "$stage_script" "$warmup_input" --model "$model_id" $STAGE_EXTRA \
        >/dev/null 2>/dev/null
    set -e
    warmup_end=$(date +%s)
    warmup_wall=$((warmup_end - warmup_start))
    rm -f "$warmup_input"
    warmup_input=""   # prevent RETURN trap double-removing a re-used name

    # Brief cool-down after warm-up before timed pass
    sleep 5

    # ── Step 2: TIMED PASS (BENCH-02/04, D-10) ───────────────────────────────
    # /usr/bin/time -l wraps the stage subprocess.
    # TIME_OUT  — receives time metrics on stderr (2>"$TIME_OUT"; never merge stderr to stdout)
    # STDOUT_TMP — receives full stage stdout (for tok/s grep)
    # Both are mktemp'd (T-04-10); both are rm -f'd on success AND failure paths.

    local TIME_OUT STDOUT_TMP TIME_EXIT_FILE
    TIME_OUT=$(mktemp)
    STDOUT_TMP=$(mktemp)
    TIME_EXIT_FILE=$(mktemp)

    local t_start t_end wall_time candidate_exit STAGE_OUT
    t_start=$(date +%s)

    # Live progress (BENCH-08) — background ticker so elapsed time is real, not frozen at 0s.
    # Kills cleanly before metrics; any output after kill goes to /dev/null.
    local TIMER_PID
    (
        while true; do
            _now=$(date +%s)
            _elapsed=$((_now - t_start))
            printf "  [%s]  %-35s  elapsed: %ds\r" "$stage" "$label" "$_elapsed" 2>/dev/null || true
            sleep 5
        done
    ) &
    TIMER_PID=$!

    # CR-01 fix: capture stage script's real exit code in a temp file from inside the
    # subshell, BEFORE the pipeline's || true can mask it.  The inner group writes the
    # /usr/bin/time exit to TIME_EXIT_FILE; the outer grep || true only suppresses
    # grep's own "no OUTPUT_FILE= line" exit — it no longer masks the stage exit.
    set +e
    STAGE_OUT=$(
        (
            /usr/bin/time -l "$stage_script" "$input_file" \
                --model "$model_id" $STAGE_EXTRA
            printf '%s' "$?" > "$TIME_EXIT_FILE"
        ) 2>"$TIME_OUT" \
        | tee "$STDOUT_TMP" /dev/stderr \
        | { grep "^OUTPUT_FILE=" || true; }
    )
    set -e
    candidate_exit=$(cat "$TIME_EXIT_FILE" 2>/dev/null || echo 1)
    rm -f "$TIME_EXIT_FILE"

    # Stop the progress ticker; print a final completion line with actual elapsed time.
    kill "$TIMER_PID" 2>/dev/null
    wait "$TIMER_PID" 2>/dev/null || true

    t_end=$(date +%s)
    wall_time=$((t_end - t_start))

    # Final elapsed line — clears the \r progress line with the actual elapsed time.
    printf "  [%s]  %-35s  elapsed: %ds\n" "$stage" "$label" "$wall_time"

    # ── Step 3: FAILURE (D-16) — write error JSON, clean up, cool down, return ─
    if [ "$candidate_exit" -ne 0 ]; then
        printf "  %-35s  ERROR (exit %d)\n" "$label" "$candidate_exit"
        mkdir -p "$(dirname "$result_json_path")"
        write_error_json "$model_id" "$label" "$stage" "$candidate_exit" "$result_json_path"
        rm -f "$TIME_OUT" "$STDOUT_TMP"
        sleep "$BENCH_COOLDOWN_SECS"
        return   # NEVER exit — sweep continues to next candidate (D-16)
    fi

    # ── Step 4: METRICS ───────────────────────────────────────────────────────

    # Output file from OUTPUT_FILE= contract
    local output_file
    output_file="${STAGE_OUT#OUTPUT_FILE=}"

    # Peak memory from /usr/bin/time -l temp file (bytes — verified)
    local peak_bytes peak_gb
    peak_bytes=$(grep "maximum resident set size" "$TIME_OUT" | awk '{print $1}')
    peak_gb=$(echo "$peak_bytes" | awk '{printf "%.2f", $1/1024/1024/1024}')

    # Speed metric (D-11): stage-specific
    local speed_metric speed_value audio_duration_sec
    audio_duration_sec="None"

    case "$stage" in
        whisper)
            # RTF = wall_time / AUDIO_DURATION_S (awk — no (( )) float, bash 3.2)
            speed_metric="rtf"
            speed_value=$(awk "BEGIN{printf \"%.3f\", $wall_time / $AUDIO_DURATION_S}")
            audio_duration_sec="$AUDIO_DURATION_S"
            ;;
        cleanup)
            # tok/s derived: output word count * 1.3 / wall_time (cleanup has no self-report)
            speed_metric="tok_per_s"
            local word_count
            word_count=$(wc -w < "$output_file" | tr -d ' ')
            speed_value=$(awk "BEGIN{printf \"%.1f\", ($word_count * 1.3) / $wall_time}")
            ;;
        summarize)
            # tok/s from stage stdout: grep STDOUT_TMP (NOT the OUTPUT_FILE line)
            speed_metric="tok_per_s"
            speed_value=$(grep -oE '[0-9]+\.[0-9]+ tok/s' "$STDOUT_TMP" | tail -1 | awk '{print $1}')
            if [ -z "$speed_value" ]; then
                speed_value="0"
            fi
            ;;
    esac

    # Clean up both temp files (T-04-10)
    rm -f "$TIME_OUT" "$STDOUT_TMP"

    # ── Step 5: Write success JSON ────────────────────────────────────────────
    mkdir -p "$(dirname "$result_json_path")"
    write_success_json \
        "$model_id" "$label" "$stage" \
        "$speed_metric" "$speed_value" \
        "$peak_bytes" "$peak_gb" \
        "$wall_time" "$audio_duration_sec" \
        "$output_file" "$result_json_path" \
        "$warmup_wall"

    # Result summary line
    printf "  %-35s  %s: %-8s  Mem: %s GB\n" \
        "$label" "$speed_metric" "$speed_value" "$peak_gb"

    # ── Step 6: COOL-DOWN (D-14) ─────────────────────────────────────────────
    sleep "$BENCH_COOLDOWN_SECS"
}

# ── Per-run results directory (D-15, one dir per sweep invocation) ────────────

CURRENT_STAGE="run-dir-setup"

RUN_TS=$(date '+%Y%m%dT%H%M%S')
RUN_DIR="$RESULTS_DIR/benchmark_${RUN_TS}"
mkdir -p "$RUN_DIR/whisper" "$RUN_DIR/cleanup" "$RUN_DIR/summarize"
echo "Results directory: $RUN_DIR"

# ── select_best: interactive per-stage candidate selection (D-01, T-04-13) ────
#
# Usage: select_best <stage> <list_file>
#   stage:     whisper | cleanup | summarize (used for display only)
#   list_file: flat temp file, one "label|output_file" line per successful candidate
#
# Prints the selected output_file to stdout.
# Exits non-zero if zero successful candidates (chain cannot continue).
#
# Selection validation (T-04-13 mitigations):
#   - Strict integer-format regex: grep -qE '^[0-9]+$' (no minus, no spaces, digits only)
#   - Bounds check: selection -ge 1 AND selection -le N
#   - Invalid input: re-prompt (loop) — never silently pick or crash
#
# Bash 3.2 compatible: per-stage mapping uses a flat temp file (no associative arrays).

select_best() {
    local stage="$1"
    local list_file="$2"

    # Count successful candidates
    local count
    count=$(wc -l < "$list_file" | tr -d ' ')

    if [ "$count" -eq 0 ]; then
        echo "" >&2
        echo "Error: No successful candidates in stage '$stage' — cannot continue." >&2
        echo "  All candidates were either skipped (fit gate) or failed to run." >&2
        exit 1
    fi

    echo ""
    echo "  Stage '$stage' complete. ${count} candidate(s) available. Select the best output:"

    # Display numbered menu with metrics + excerpt (BENCH-05 — real output shown to human)
    local i=0
    while IFS='|' read -r cand_label cand_output cand_speed cand_peak; do
        i=$((i + 1))
        printf "\n  [%d] %s\n" "$i" "$cand_label"
        printf "      Speed: %s   Peak memory: %s GB\n" "$cand_speed" "$cand_peak"
        echo "      --- excerpt (first 10 lines) ---"
        if [ -f "$cand_output" ]; then
            head -10 "$cand_output" | sed 's/^/      /'
        else
            echo "      (output file not found: $cand_output)"
        fi
    done < "$list_file"

    echo ""

    # Validation loop — re-prompt on invalid input (T-04-13)
    local selection
    while true; do
        printf "  Enter number (1-%d): " "$count"
        read -r selection

        # Format check: must be one or more digits, nothing else
        if ! echo "$selection" | grep -qE '^[0-9]+$'; then
            echo "  Invalid input: '$selection' is not an integer. Please enter a number between 1 and ${count}." >&2
            continue
        fi

        # Bounds check: [1..count] — reject if below 1 or above count
        if [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ]; then
            echo "  Out of range: '$selection' must be between 1 and ${count}." >&2
            continue
        fi

        break
    done

    # Extract selected output_file (field 2) from the Nth line of the list file
    sed -n "${selection}p" "$list_file" | cut -d'|' -f2
}

# ── fit_check: classify a single candidate as fit or skip (HW-02/03, D-07) ──
# Usage: fit_check <size_gb>
# Prints "fit" or "skip".

fit_check() {
    local size_gb="$1"
    awk "BEGIN {
        estimate = $size_gb + $BENCH_OVERHEAD_BUFFER_GB
        if (estimate <= $USABLE_GB) print \"fit\"
        else print \"skip\"
    }"
}

# ── Staged sweep: whisper → cleanup → summarize (D-01, BENCH-01, D-02) ───────
#
# For each stage, in order:
#   1. Print stage banner (BENCH-08)
#   2. Iterate ALL fitting candidates (D-02 — no cap)
#   3. fit_check each: skip → write_skip_json + SKIP log; fit → run_candidate
#   4. After stage completes, call select_best to pick the best output
#   5. Carry selected output forward as input to the next stage (D-01 chaining)
#
# Stage temp files (bash 3.2 compatible — flat files mapping, no associative arrays):
#   label|output_file|speed_display|peak_gb  (one line per successful candidate)

CURRENT_STAGE="staged-sweep"

# Initialise chaining variables (populated by select_best after each stage)
SELECTED_TRANSCRIPT=""
SELECTED_CLEANED=""
SELECTED_SUMMARY=""

# ────────────────────────────────────────────────────────────────────────────
# STAGE 1: whisper
# ────────────────────────────────────────────────────────────────────────────

CURRENT_STAGE="sweep-whisper"

WHISPER_RESULTS_LIST=$(mktemp /tmp/benchmark_whisper_list_XXXXXX)
_BENCH_TMPFILES+=("$WHISPER_RESULTS_LIST")

# Count fitting whisper candidates for the banner
WHISPER_CANDIDATE_COUNT=0
while IFS='|' read -r _id _label _size; do
    FIT_TMP=$(fit_check "$_size")
    if [ "$FIT_TMP" = "fit" ]; then
        WHISPER_CANDIDATE_COUNT=$((WHISPER_CANDIDATE_COUNT + 1))
    fi
done < <(parse_candidates "whisper" "$CANDIDATES_CONF")

stage_banner "Benchmark: whisper (1 of 3) — ${WHISPER_CANDIDATE_COUNT} fitting candidates"

while IFS='|' read -r model_id label size_gb; do
    CANDIDATE_FIT=$(fit_check "$size_gb")

    if [ "$CANDIDATE_FIT" = "skip" ]; then
        ESTIMATE=$(awk "BEGIN{printf \"%.1f\", $size_gb + $BENCH_OVERHEAD_BUFFER_GB}")
        SKIP_REASON="${size_gb}(size) + ${BENCH_OVERHEAD_BUFFER_GB}(overhead) = ${ESTIMATE} > ${USABLE_GB}(usable)"
        echo "  SKIP $label: $SKIP_REASON"
        write_skip_json "$model_id" "$label" "whisper" "$SKIP_REASON" \
            "$RUN_DIR/whisper/${label}_result.json"
    else
        run_candidate "whisper" "$model_id" "$label" \
            "$SAMPLE_MP3" \
            "$RUN_DIR/whisper/${label}_result.json" \
            "$RUN_DIR/whisper" \
            ""

        # Record successful candidate in list file for select_best
        # Extract output_file and metrics from the written JSON via Python
        if [ -f "$RUN_DIR/whisper/${label}_result.json" ]; then
            CAND_ERROR=$("$PYTHON" -c "
import json
with open('$RUN_DIR/whisper/${label}_result.json') as f:
    d = json.load(f)
print(d.get('error') or '')
" 2>/dev/null || echo "read_error")
            if [ -z "$CAND_ERROR" ]; then
                CAND_OUTPUT=$("$PYTHON" -c "
import json
with open('$RUN_DIR/whisper/${label}_result.json') as f:
    d = json.load(f)
print(d.get('output_file',''))
" 2>/dev/null || echo "")
                CAND_SPEED=$("$PYTHON" -c "
import json
with open('$RUN_DIR/whisper/${label}_result.json') as f:
    d = json.load(f)
print('RTF=' + str(d.get('speed_value','')))
" 2>/dev/null || echo "RTF=?")
                CAND_PEAK=$("$PYTHON" -c "
import json
with open('$RUN_DIR/whisper/${label}_result.json') as f:
    d = json.load(f)
print(str(d.get('peak_mem_gb','')))
" 2>/dev/null || echo "?")
                if [ -n "$CAND_OUTPUT" ] && [ -f "$CAND_OUTPUT" ]; then
                    printf '%s|%s|%s|%s\n' "$label" "$CAND_OUTPUT" "$CAND_SPEED" "$CAND_PEAK" \
                        >> "$WHISPER_RESULTS_LIST"
                fi
            fi
        fi
    fi
done < <(parse_candidates "whisper" "$CANDIDATES_CONF")

SELECTED_TRANSCRIPT=$(select_best "whisper" "$WHISPER_RESULTS_LIST")
rm -f "$WHISPER_RESULTS_LIST"

echo ""
echo "  Selected transcript: $SELECTED_TRANSCRIPT"

# ────────────────────────────────────────────────────────────────────────────
# STAGE 2: cleanup (input = SELECTED_TRANSCRIPT)
# ────────────────────────────────────────────────────────────────────────────

CURRENT_STAGE="sweep-cleanup"

CLEANUP_RESULTS_LIST=$(mktemp /tmp/benchmark_cleanup_list_XXXXXX)
_BENCH_TMPFILES+=("$CLEANUP_RESULTS_LIST")

CLEANUP_CANDIDATE_COUNT=0
while IFS='|' read -r _id _label _size; do
    FIT_TMP=$(fit_check "$_size")
    if [ "$FIT_TMP" = "fit" ]; then
        CLEANUP_CANDIDATE_COUNT=$((CLEANUP_CANDIDATE_COUNT + 1))
    fi
done < <(parse_candidates "cleanup" "$CANDIDATES_CONF")

stage_banner "Benchmark: cleanup (2 of 3) — ${CLEANUP_CANDIDATE_COUNT} fitting candidates"

while IFS='|' read -r model_id label size_gb; do
    CANDIDATE_FIT=$(fit_check "$size_gb")

    if [ "$CANDIDATE_FIT" = "skip" ]; then
        ESTIMATE=$(awk "BEGIN{printf \"%.1f\", $size_gb + $BENCH_OVERHEAD_BUFFER_GB}")
        SKIP_REASON="${size_gb}(size) + ${BENCH_OVERHEAD_BUFFER_GB}(overhead) = ${ESTIMATE} > ${USABLE_GB}(usable)"
        echo "  SKIP $label: $SKIP_REASON"
        write_skip_json "$model_id" "$label" "cleanup" "$SKIP_REASON" \
            "$RUN_DIR/cleanup/${label}_result.json"
    else
        run_candidate "cleanup" "$model_id" "$label" \
            "$SELECTED_TRANSCRIPT" \
            "$RUN_DIR/cleanup/${label}_result.json" \
            "$RUN_DIR/cleanup" \
            ""

        if [ -f "$RUN_DIR/cleanup/${label}_result.json" ]; then
            CAND_ERROR=$("$PYTHON" -c "
import json
with open('$RUN_DIR/cleanup/${label}_result.json') as f:
    d = json.load(f)
print(d.get('error') or '')
" 2>/dev/null || echo "read_error")
            if [ -z "$CAND_ERROR" ]; then
                CAND_OUTPUT=$("$PYTHON" -c "
import json
with open('$RUN_DIR/cleanup/${label}_result.json') as f:
    d = json.load(f)
print(d.get('output_file',''))
" 2>/dev/null || echo "")
                CAND_SPEED=$("$PYTHON" -c "
import json
with open('$RUN_DIR/cleanup/${label}_result.json') as f:
    d = json.load(f)
print(str(d.get('speed_value','')) + ' tok/s')
" 2>/dev/null || echo "? tok/s")
                CAND_PEAK=$("$PYTHON" -c "
import json
with open('$RUN_DIR/cleanup/${label}_result.json') as f:
    d = json.load(f)
print(str(d.get('peak_mem_gb','')))
" 2>/dev/null || echo "?")
                if [ -n "$CAND_OUTPUT" ] && [ -f "$CAND_OUTPUT" ]; then
                    printf '%s|%s|%s|%s\n' "$label" "$CAND_OUTPUT" "$CAND_SPEED" "$CAND_PEAK" \
                        >> "$CLEANUP_RESULTS_LIST"
                fi
            fi
        fi
    fi
done < <(parse_candidates "cleanup" "$CANDIDATES_CONF")

SELECTED_CLEANED=$(select_best "cleanup" "$CLEANUP_RESULTS_LIST")
rm -f "$CLEANUP_RESULTS_LIST"

echo ""
echo "  Selected cleaned transcript: $SELECTED_CLEANED"

# ────────────────────────────────────────────────────────────────────────────
# STAGE 3: summarize (input = SELECTED_CLEANED; extra_args = "--style blog")
# ────────────────────────────────────────────────────────────────────────────

CURRENT_STAGE="sweep-summarize"

SUMMARIZE_RESULTS_LIST=$(mktemp /tmp/benchmark_summarize_list_XXXXXX)
_BENCH_TMPFILES+=("$SUMMARIZE_RESULTS_LIST")

SUMMARIZE_CANDIDATE_COUNT=0
while IFS='|' read -r _id _label _size; do
    FIT_TMP=$(fit_check "$_size")
    if [ "$FIT_TMP" = "fit" ]; then
        SUMMARIZE_CANDIDATE_COUNT=$((SUMMARIZE_CANDIDATE_COUNT + 1))
    fi
done < <(parse_candidates "summarize" "$CANDIDATES_CONF")

stage_banner "Benchmark: summarize (3 of 3) — ${SUMMARIZE_CANDIDATE_COUNT} fitting candidates"

while IFS='|' read -r model_id label size_gb; do
    CANDIDATE_FIT=$(fit_check "$size_gb")

    if [ "$CANDIDATE_FIT" = "skip" ]; then
        ESTIMATE=$(awk "BEGIN{printf \"%.1f\", $size_gb + $BENCH_OVERHEAD_BUFFER_GB}")
        SKIP_REASON="${size_gb}(size) + ${BENCH_OVERHEAD_BUFFER_GB}(overhead) = ${ESTIMATE} > ${USABLE_GB}(usable)"
        echo "  SKIP $label: $SKIP_REASON"
        write_skip_json "$model_id" "$label" "summarize" "$SKIP_REASON" \
            "$RUN_DIR/summarize/${label}_result.json"
    else
        # Pass --style blog via extra_args (D-01, plan 04-04 requirement)
        run_candidate "summarize" "$model_id" "$label" \
            "$SELECTED_CLEANED" \
            "$RUN_DIR/summarize/${label}_result.json" \
            "$RUN_DIR/summarize" \
            "--style blog"

        if [ -f "$RUN_DIR/summarize/${label}_result.json" ]; then
            CAND_ERROR=$("$PYTHON" -c "
import json
with open('$RUN_DIR/summarize/${label}_result.json') as f:
    d = json.load(f)
print(d.get('error') or '')
" 2>/dev/null || echo "read_error")
            if [ -z "$CAND_ERROR" ]; then
                CAND_OUTPUT=$("$PYTHON" -c "
import json
with open('$RUN_DIR/summarize/${label}_result.json') as f:
    d = json.load(f)
print(d.get('output_file',''))
" 2>/dev/null || echo "")
                CAND_SPEED=$("$PYTHON" -c "
import json
with open('$RUN_DIR/summarize/${label}_result.json') as f:
    d = json.load(f)
print(str(d.get('speed_value','')) + ' tok/s')
" 2>/dev/null || echo "? tok/s")
                CAND_PEAK=$("$PYTHON" -c "
import json
with open('$RUN_DIR/summarize/${label}_result.json') as f:
    d = json.load(f)
print(str(d.get('peak_mem_gb','')))
" 2>/dev/null || echo "?")
                if [ -n "$CAND_OUTPUT" ] && [ -f "$CAND_OUTPUT" ]; then
                    printf '%s|%s|%s|%s\n' "$label" "$CAND_OUTPUT" "$CAND_SPEED" "$CAND_PEAK" \
                        >> "$SUMMARIZE_RESULTS_LIST"
                fi
            fi
        fi
    fi
done < <(parse_candidates "summarize" "$CANDIDATES_CONF")

SELECTED_SUMMARY=$(select_best "summarize" "$SUMMARIZE_RESULTS_LIST")
rm -f "$SUMMARIZE_RESULTS_LIST"

echo ""
echo "  Selected summary: $SELECTED_SUMMARY"

# ── sweep_meta.json — run-level metadata (D-15, Phase 5 contract) ─────────────
# Written via "$PYTHON" json module for safe serialization (T-04-09).
# Does NOT write config/settings.conf — that is Phase 5's responsibility (D-04).

CURRENT_STAGE="sweep-meta"

"$PYTHON" - << PYEOF
import json
data = {
    "run_ts":              "$RUN_TS",
    "total_ram_gb":        $TOTAL_GB,
    "usable_gb":           $USABLE_GB,
    "audio_duration_s":    $AUDIO_DURATION_S,
    "sample_url":          "$BENCH_SAMPLE_URL",
    "overhead_buffer_gb":  $BENCH_OVERHEAD_BUFFER_GB,
    "cooldown_secs":       $BENCH_COOLDOWN_SECS,
    "selected_transcript": "$SELECTED_TRANSCRIPT",
    "selected_cleaned":    "$SELECTED_CLEANED",
    "selected_summary":    "$SELECTED_SUMMARY",
}
with open("$RUN_DIR/sweep_meta.json", "w") as f:
    json.dump(data, f, indent=2)
print("sweep_meta.json written.")
PYEOF

echo ""
echo "Benchmark sweep complete."
echo "Phase 5 will read $RUN_DIR to write config/settings.conf"
