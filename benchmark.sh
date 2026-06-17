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

# ── verify_model_complete: real shard-completeness check (MA2-01) ─────────────
# is_model_cached() only proves the snapshots dir is non-empty; a model with just
# model.safetensors.index.json (no shard blobs) passes it falsely. This verifies
# every shard listed in the index weight_map exists as a non-zero resolved blob,
# or — for single-file models — that a non-zero weight file is present.
# Returns 0 (complete) / 1 (incomplete). Gates on exit code, not stdout.

verify_model_complete() {
    local model_id="$1"
    local cache_name="models--$(echo "$model_id" | sed 's|/|--|g')"
    local snapshots_dir="$HF_CACHE/$cache_name/snapshots"
    [ -d "$snapshots_dir" ] && [ -n "$(ls -A "$snapshots_dir" 2>/dev/null)" ] || return 1

    local snap
    snap=$(ls -1d "$snapshots_dir"/*/ 2>/dev/null | head -1)
    [ -n "$snap" ] && [ -d "$snap" ] || return 1
    snap="${snap%/}"

    if [ -f "$snap/model.safetensors.index.json" ]; then
        # Index present → every weight_map shard must exist with non-zero resolved size.
        # python3 is guaranteed via .venv ($PYTHON). Continue-on-failure (D-16): any
        # python error defaults to "incomplete".
        local probe rc
        set +e
        probe=$("$PYTHON" - "$snap" <<'PY' 2>/dev/null
import json, os, sys
snap = sys.argv[1]
try:
    with open(os.path.join(snap, "model.safetensors.index.json")) as f:
        idx = json.load(f)
    shards = sorted(set((idx.get("weight_map") or {}).values()))
    if not shards:
        print("incomplete")
        sys.exit(0)
    for s in shards:
        p = os.path.join(snap, s)
        # os.path.getsize follows the symlink into the blobs store.
        if not os.path.exists(p) or os.path.getsize(p) <= 0:
            sys.stderr.write("missing shard: %s\n" % s)
            print("incomplete")
            sys.exit(0)
    print("complete")
except Exception as e:
    sys.stderr.write("verify error: %s\n" % e)
    print("incomplete")
PY
)
        rc=$?
        set -e
        if [ "$rc" -ne 0 ] || [ "$probe" != "complete" ]; then
            return 1
        fi
        return 0
    fi

    # No index → single-file model. Require a non-zero weight file (-s follows symlink).
    local f
    for f in "$snap"/*.safetensors "$snap"/weights.npz "$snap"/*.npz; do
        [ -s "$f" ] && return 0
    done
    return 1
}

# ── params_for_id: block-aware params= lookup from candidates.conf (MA2-04) ────
# Same while-read/case idiom as parse_candidates (parse-not-source). Echoes the
# params value for the matching id, or "?" if unknown. Never trips set -e.

params_for_id() {
    local want_id="$1"
    local current_id="" current_params=""
    local in_block=false line
    while IFS= read -r line; do
        case "$line" in
            "[candidate]")
                if [ "$in_block" = true ] && [ "$current_id" = "$want_id" ]; then
                    echo "$current_params"; return 0
                fi
                in_block=true
                current_id="" current_params=""
                ;;
            id=*)     current_id="${line#id=}" ;;
            params=*) current_params="${line#params=}" ;;
            "#"*|"")  : ;;
        esac
    done < "$CANDIDATES_CONF"
    # Emit-last-block stanza (Pitfall E): the final candidate must not be dropped.
    if [ "$in_block" = true ] && [ "$current_id" = "$want_id" ]; then
        echo "$current_params"; return 0
    fi
    echo "?"
    return 0
}

# ── is_incomplete: membership test for INCOMPLETE_IDS (MA2-02) ────────────────
# Models that stayed incomplete after the pre-fetch (re)download are skipped at
# sweep time rather than attempted and failed at model-load. Bash 3.2: linear
# scan (no associative arrays); set -u safe expansion for the empty-array case.
# INCOMPLETE_IDS is populated by the pre-fetch loop, which runs before any sweep.
is_incomplete() {
    local want="$1" m
    for m in ${INCOMPLETE_IDS[@]+"${INCOMPLETE_IDS[@]}"}; do
        [ "$m" = "$want" ] && return 0
    done
    return 1
}

# ── Resume detection primitives (RESUME-01/02, D-11/D-12/D-13) ───────────────
#
# RESUMING: module-level boolean flipped to true by the 05-03 caller when the
# user accepts a resume prompt. Defined here for 05-03 to toggle; default false.
RESUMING=false

# detect_incomplete_run: returns path to most-recent incomplete run dir, or "".
# A run is "complete" if it has sweep_meta.json (Phase 4 contract); report.md
# is checked additionally for Phase 5-complete runs. During the Phase 5 transition
# a run with sweep_meta.json but no report.md is treated as COMPLETE (Phase-4-
# complete runs are not re-runnable). Gate completeness primarily on sweep_meta.json.
# Returns "" if: no run dirs exist, the most-recent dir is complete, or the most-
# recent dir has no result JSONs (empty/aborted before any work was done).
detect_incomplete_run() {
    local most_recent
    most_recent=$(ls -td "$RESULTS_DIR"/benchmark_*/ 2>/dev/null | head -1)
    most_recent="${most_recent%/}"
    if [ -z "$most_recent" ] || [ ! -d "$most_recent" ]; then
        echo ""; return 0
    fi
    # Complete = has sweep_meta.json (Phase 4 contract).
    # Also treat sweep_meta.json + report.md as complete (Phase 5).
    if [ -f "$most_recent/sweep_meta.json" ]; then
        echo ""; return 0
    fi
    # Incomplete: has at least one result JSON → was started, not just an empty dir.
    if find "$most_recent" -name '*_result.json' -maxdepth 2 | grep -q .; then
        echo "$most_recent"; return 0
    fi
    echo ""; return 0
}

# should_skip_pair: given a result-JSON path, returns 0 (skip) or 1 (run/re-run).
# Skip logic (D-13, Pitfall 4):
#   - File absent → run (return 1)
#   - fit_status == "skip" → always skip (deterministic fit-gate exclusion, return 0)
#   - error is empty/null (success) → skip (return 0)
#   - error is non-empty → re-run (transient OOM/load failure; return 1)
should_skip_pair() {
    local json_path="$1"
    [ -f "$json_path" ] || return 1  # no JSON → run it
    local fit_status error_val
    fit_status=$("$PYTHON" -c "import json; d=json.load(open('$json_path')); print(d.get('fit_status',''))" 2>/dev/null || echo "")
    error_val=$("$PYTHON" -c "import json; d=json.load(open('$json_path')); print(d.get('error') or '')" 2>/dev/null || echo "")
    # fit-gate skip → always skip (deterministic)
    [ "$fit_status" = "skip" ] && return 0
    # success (error null/empty) → skip
    [ -z "$error_val" ] && return 0
    # error non-empty → re-run (transient failure)
    return 1
}

# ── Stage-pick persistence (D-14, RESUME-01) ─────────────────────────────────
#
# persist_pick(stage, output_file): write/update picks.json in the run dir.
#   - Uses A1 pattern: "$PYTHON" - args << 'PYEOF' (verified on bash 3.2.57)
#     where args are delivered as sys.argv[1:] alongside the heredoc on stdin.
#   - Reads existing picks.json (if present) and merges the new entry.
#   - NEVER sources picks.json (parse-not-source; T-05-03).
#
# load_picks(): populate SELECTED_TRANSCRIPT/SELECTED_CLEANED/SELECTED_SUMMARY
#   from $RUN_DIR/picks.json when resuming a partial run (D-14).
#   - Reads via "$PYTHON" -c json.load (never source).
#   - Values will be empty strings if the key is absent or the file missing.

persist_pick() {
    local stage="$1"
    local output_file="$2"
    local picks_path="$RUN_DIR/picks.json"
    "$PYTHON" - "$picks_path" "$stage" "$output_file" << 'PYEOF'
import json, sys
picks_path, stage, output_file = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(picks_path) as f:
        picks = json.load(f)
except Exception:
    picks = {}
picks[stage] = output_file
with open(picks_path, 'w') as f:
    json.dump(picks, f, indent=2)
PYEOF
}

load_picks() {
    local picks_path="$RUN_DIR/picks.json"
    if [ -f "$picks_path" ]; then
        SELECTED_TRANSCRIPT=$("$PYTHON" -c "import json; d=json.load(open('$picks_path')); print(d.get('whisper',''))" 2>/dev/null || echo "")
        SELECTED_CLEANED=$("$PYTHON" -c "import json; d=json.load(open('$picks_path')); print(d.get('cleanup',''))" 2>/dev/null || echo "")
        SELECTED_SUMMARY=$("$PYTHON" -c "import json; d=json.load(open('$picks_path')); print(d.get('summarize',''))" 2>/dev/null || echo "")
    fi
}

# ── Atomic settings.conf writer (RPT-03, D-07/D-08/D-10, T-05-01/T-05-02) ────
#
# write_settings_key(key, value): atomically update one key in config/settings.conf.
#
# Security (T-05-02):
#   - Validates key against the 3 allowed keys only.
#   - Validates value against ^[A-Za-z0-9._/-]+$ (no shell metacharacters).
#   - Passes key+value via sys.argv (A1 pattern; NOT heredoc interpolation) to
#     prevent shell injection into the Python heredoc body.
# Atomicity (T-05-01):
#   - mktemp in config/ dir (SAME filesystem as target → mv is atomic rename).
#   - Temp file registered in _BENCH_TMPFILES EXIT trap (cleaned on Ctrl-C).
#   - On successful mv, removed from _BENCH_TMPFILES (no double-remove).
#   - SIGINT during write leaves settings.conf either fully written or absent
#     (criterion #6 / RPT-03).
# Merge: reads all existing lines, replaces matching ^KEY\s*= line or appends.

write_settings_key() {
    local key="$1"
    local value="$2"

    # Validate key — only the 3 established settings.conf keys are allowed (T-05-02).
    case "$key" in
        WHISPER_MODEL_DEFAULT|CLEANUP_MODEL_DEFAULT|SUMMARY_MODEL_DEFAULT) ;;
        *)
            echo "Error: write_settings_key: invalid key '$key' (must be one of WHISPER_MODEL_DEFAULT, CLEANUP_MODEL_DEFAULT, SUMMARY_MODEL_DEFAULT)" >&2
            return 1
            ;;
    esac

    # Validate value — only safe label characters allowed (T-05-02).
    if ! echo "$value" | grep -qE '^[A-Za-z0-9._/-]+$'; then
        echo "Error: write_settings_key: invalid value '$value' (must match ^[A-Za-z0-9._/-]+\$)" >&2
        return 1
    fi

    local conf_path="$SCRIPT_DIR/config/settings.conf"
    mkdir -p "$SCRIPT_DIR/config"

    # mktemp in same dir as target (Pitfall 3: macOS /tmp is a separate filesystem;
    # cross-fs mv is NOT atomic — must use same-dir mktemp for atomic rename).
    local tmp_conf
    tmp_conf=$(mktemp "$SCRIPT_DIR/config/.settings_tmp_XXXXXX")
    _BENCH_TMPFILES+=("$tmp_conf")

    # A1 pattern: pass conf_path, tmp_conf, key, value via sys.argv (not heredoc
    # interpolation) to prevent any shell-injection of a malicious label into the
    # Python heredoc body. Verified working on bash 3.2.57 (Open Question A1 resolved).
    "$PYTHON" - "$conf_path" "$tmp_conf" "$key" "$value" << 'PYEOF'
import sys, re, os
conf_path, tmp_path, key, value = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = []
found = False
if os.path.isfile(conf_path):
    with open(conf_path) as f:
        for line in f:
            stripped = line.rstrip('\n')
            if re.match(r'^' + re.escape(key) + r'\s*=', stripped):
                lines.append(f"{key}={value}")
                found = True
            else:
                lines.append(stripped)
if not found:
    lines.append(f"{key}={value}")
with open(tmp_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PYEOF

    mv "$tmp_conf" "$conf_path"
    # Remove from tmpfiles list (mv succeeded; no EXIT-trap cleanup needed for this file).
    # Bash 3.2 safe: parameter expansion replacement (no associative arrays).
    _BENCH_TMPFILES=("${_BENCH_TMPFILES[@]/$tmp_conf/}")
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
    if ! verify_model_complete "$model_id"; then
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

# ── Model pre-fetch — verify completeness, (re)download incomplete (D-08, MA2-01/02) ─
# Use .venv/bin/hf (the current hf CLI — NOT the deprecated legacy tool — Pitfall D / RESEARCH Decision #4).
# Gate on verify_model_complete() (real shard check) — NOT is_model_cached (presence-only,
# which falsely passes index-only snapshots). Incomplete models are (re)downloaded then
# re-verified; persistent failures are recorded and SKIPPED (continue-on-failure, D-16) —
# never abort the sweep. All complete fitting models must be present before timing starts.

CURRENT_STAGE="pre-fetch"

INCOMPLETE_IDS=()

for i in "${!FITTING_IDS[@]}"; do
    model_id="${FITTING_IDS[$i]}"
    label="${FITTING_LABELS[$i]}"
    if verify_model_complete "$model_id"; then
        echo "  Verified complete: $label"
    else
        echo "  Downloading $label ($model_id) ..."
        # D-16 continue-on-failure: a download error must not abort the sweep.
        set +e
        "$HF_CLI" download "$model_id"
        dl_rc=$?
        set -e
        if [ "$dl_rc" -ne 0 ]; then
            echo "  WARNING: download of $label ($model_id) exited non-zero ($dl_rc)" >&2
        fi
        if verify_model_complete "$model_id"; then
            echo "  Verified complete: $label"
        else
            echo "  ERROR: $label ($model_id) still incomplete after download — will skip during sweep" >&2
            INCOMPLETE_IDS+=("$model_id")
        fi
    fi
done

# ── Model inventory — per-stage detail table (MA2-03) ─────────────────────────
# Columns: full HF repo id | params | quantization | on-disk size | approx memory.
# Bash 3.2: indexed arrays only; all float math via awk; quant lowercase via tr (no ${var,,}).

stage_banner "Model inventory"

INV_FMT='  %-46s %-7s %-7s %8s %10s\n'
for inv_stage in whisper cleanup summarize; do
    # Skip stages with no fitting candidates.
    inv_any=false
    for i in "${!FITTING_IDS[@]}"; do
        if [ "${FITTING_STAGES[$i]}" = "$inv_stage" ]; then inv_any=true; break; fi
    done
    [ "$inv_any" = true ] || continue

    echo "  [$inv_stage]"
    # shellcheck disable=SC2059
    printf "$INV_FMT" "HF repo id" "params" "quant" "on-disk" "approx mem"
    for i in "${!FITTING_IDS[@]}"; do
        [ "${FITTING_STAGES[$i]}" = "$inv_stage" ] || continue
        model_id="${FITTING_IDS[$i]}"
        size_gb="${FITTING_SIZES[$i]}"

        inv_params=$(params_for_id "$model_id")

        # Quantization — lowercase via tr (bash 3.2 has no ${var,,}).
        inv_id_lc=$(echo "$model_id" | tr 'A-Z' 'a-z')
        case "$inv_id_lc" in
            *4bit*|*q4*) inv_quant="4-bit" ;;
            *8bit*|*q8*) inv_quant="8-bit" ;;
            *)           inv_quant="fp16"  ;;
        esac

        # On-disk size — du of the model cache dir; "—" if missing/empty.
        inv_cache="$HF_CACHE/models--$(echo "$model_id" | sed 's|/|--|g')"
        inv_disk=$(du -sh "$inv_cache" 2>/dev/null | awk '{print $1}')
        [ -n "$inv_disk" ] || inv_disk="—"

        # Approx memory — size_gb + overhead buffer (awk float math, mirrors fit gate).
        inv_mem=$(awk "BEGIN{printf \"%.1f GB\", $size_gb + $BENCH_OVERHEAD_BUFFER_GB}")

        # shellcheck disable=SC2059
        printf "$INV_FMT" "$model_id" "$inv_params" "$inv_quant" "$inv_disk" "$inv_mem"
    done
    echo ""
done

if [ ${#INCOMPLETE_IDS[@]} -gt 0 ]; then
    echo "  WARNING: the following models stayed incomplete after download and will be SKIPPED during the sweep:" >&2
    for inc in "${INCOMPLETE_IDS[@]}"; do
        echo "    - $inc" >&2
    done
fi

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
DURATION_STR=$(ffmpeg -i "$SAMPLE_MP3" 3>&1 1>/dev/null 2>&3 3>&- | grep "Duration" | awk '{print $2}' | tr -d , || true)  # ffmpeg -i with no output exits non-zero by design — don't let pipefail/set -e abort
if [ -z "$DURATION_STR" ]; then
    echo "Error: could not read audio duration from $SAMPLE_MP3" >&2
    exit 1
fi
IFS=: read -r h m s <<< "$DURATION_STR"
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
        | tee "$STDOUT_TMP" \
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
# Usage: select_best <stage> <list_file> [current_default_label]
#   stage:                 whisper | cleanup | summarize (used for display)
#   list_file:             flat temp file, one "label|output_file" line per
#                          successful candidate
#   current_default_label: optional. If provided AND the label matches a candidate,
#                          a "[k] Keep current (<label>)" entry is shown (D-09).
#                          If not provided or not among candidates, [k] is NOT shown
#                          (Pitfall 8 — never chain an undefined output file).
#
# Prints the selected output_file to stdout (ONLY; menu/prompts go to stderr).
# Exits non-zero if zero successful candidates (chain cannot continue).
#
# Keep-current sentinel (D-09, TIME_EXIT_FILE analog — benchmark.sh lines 779-786):
#   select_best runs inside $(...) command substitution → it executes in a SUBSHELL.
#   Any variable set inside (e.g. LAST_PICK_WAS_KEEP_CURRENT=true) is LOST when the
#   subshell exits — the parent never sees it, silently breaking D-08 (keep-current
#   must write nothing). Instead we use the codebase's existing subshell-to-parent
#   FILE-SIGNAL pattern: the subshell WRITES a sentinel file; the parent READS it
#   AFTER the subshell exits, then rm -f's it.
#
#   Sentinel contract:
#     Path:     $RUN_DIR/.keep_current_<stage>   (${RUN_DIR:-/tmp} so robust if unset)
#     Creator:  select_best (this function), inside the subshell
#     Reader:   the 05-03 caller, immediately after capturing stdout path, via:
#                 if [ -f "$RUN_DIR/.keep_current_${stage}" ]; then
#                   # skip write_settings_key for this stage
#                 fi
#                 rm -f "$RUN_DIR/.keep_current_${stage}"
#     Lifetime: created on keep-current pick; removed by caller immediately after check.
#               On a numbered (new) pick, rm -f any stale sentinel for this stage first.
#
# Selection validation (T-04-13 mitigations):
#   - Strict integer-format regex: grep -qE '^[0-9]+$' (no minus, no spaces, digits only)
#   - Bounds check: selection -ge 1 AND selection -le N (or 'k'/'K' if offered)
#   - Invalid input: re-prompt (loop) — never silently pick or crash
#
# Bash 3.2 compatible: per-stage mapping uses a flat temp file (no associative arrays).

select_best() {
    local stage="$1"
    local list_file="$2"
    local current_default_label="${3:-}"   # optional 3rd parameter (D-09)

    # Count successful candidates
    local count
    count=$(wc -l < "$list_file" | tr -d ' ')

    if [ "$count" -eq 0 ]; then
        echo "" >&2
        echo "Error: No successful candidates in stage '$stage' — cannot continue." >&2
        echo "  All candidates were either skipped (fit gate) or failed to run." >&2
        exit 1
    fi

    # Check if keep-current is available: current_default_label must be non-empty
    # AND must match at least one candidate label in the list file (Pitfall 8).
    local keep_current_line=""
    if [ -n "$current_default_label" ]; then
        # grep -m1 for the first matching label|… line
        keep_current_line=$(grep -m1 "^${current_default_label}|" "$list_file" 2>/dev/null || true)
    fi
    local keep_current_offered=false
    [ -n "$keep_current_line" ] && keep_current_offered=true

    # Menu + prompt go to STDERR so they reach the terminal — this function's STDOUT
    # is captured by the caller's $(...) and must contain ONLY the selected file path.
    echo "" >&2
    echo "  ── ${stage} stage: ${count} transcript(s) ──────────────────────────────" >&2
    echo "  Open the files below to compare, then choose the best:" >&2
    echo "" >&2

    # Numbered menu: number, label + metrics, and the transcript LOCATION (one per line)
    local i=0
    while IFS='|' read -r cand_label cand_output cand_speed cand_peak; do
        i=$((i + 1))
        printf "  [%d] %-22s  %s   peak %s GB\n" "$i" "$cand_label" "$cand_speed" "$cand_peak" >&2
        printf "      %s\n" "$cand_output" >&2
    done < "$list_file"

    # Keep-current entry (D-09): only when current default is among candidates.
    if [ "$keep_current_offered" = true ]; then
        printf "  [k] Keep current (%s)\n" "$current_default_label" >&2
    fi

    echo "" >&2

    # Sentinel dir for keep-current signal (${RUN_DIR:-/tmp} so robust if RUN_DIR unset)
    local sentinel_dir="${RUN_DIR:-/tmp}"
    local sentinel_file="${sentinel_dir}/.keep_current_${stage}"

    # Validation loop — re-prompt on invalid input (T-04-13)
    local selection
    while true; do
        if [ "$keep_current_offered" = true ]; then
            printf "  Select the best [1-%d/k]: " "$count" >&2
        else
            printf "  Select the best [1-%d]: " "$count" >&2
        fi
        read -r selection

        # Keep-current: accept 'k' or 'K' only when the entry was offered.
        if [ "$keep_current_offered" = true ] && { [ "$selection" = "k" ] || [ "$selection" = "K" ]; }; then
            # Remove any stale sentinel from a prior keep for this stage, then create fresh.
            rm -f "$sentinel_file"
            touch "$sentinel_file"
            # Return the matched candidate's output_file on stdout so chaining works.
            echo "$keep_current_line" | cut -d'|' -f2
            return 0
        fi

        # Format check: must be one or more digits, nothing else
        if ! echo "$selection" | grep -qE '^[0-9]+$'; then
            echo "  Invalid input: '$selection' is not an integer. Please enter a number between 1 and ${count}${keep_current_offered:+ (or k to keep current)}." >&2
            continue
        fi

        # Bounds check: [1..count] — reject if below 1 or above count
        if [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ]; then
            echo "  Out of range: '$selection' must be between 1 and ${count}." >&2
            continue
        fi

        break
    done

    # Numbered pick: remove any stale keep-current sentinel for this stage.
    rm -f "$sentinel_file"

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
    # MA2-02: a model left incomplete after the pre-fetch (re)download cannot load
    # — skip here rather than waste a run slot + thermal cooldown on a guaranteed
    # failure. Matches the pre-fetch warning that incomplete models are skipped.
    if is_incomplete "$model_id"; then
        echo "  SKIP $label: incomplete (failed shard verification, not downloadable)"
        write_skip_json "$model_id" "$label" "whisper" "incomplete: failed shard verification" \
            "$RUN_DIR/whisper/${label}_result.json"
        continue
    fi

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
            "" </dev/null   # sever subprocess stdin from the candidate pipe (ffmpeg/MLX must not eat the next line)

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
    # MA2-02: skip models left incomplete after pre-fetch (see whisper loop note).
    if is_incomplete "$model_id"; then
        echo "  SKIP $label: incomplete (failed shard verification, not downloadable)"
        write_skip_json "$model_id" "$label" "cleanup" "incomplete: failed shard verification" \
            "$RUN_DIR/cleanup/${label}_result.json"
        continue
    fi

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
            "" </dev/null   # sever subprocess stdin from the candidate pipe

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
    # MA2-02: skip models left incomplete after pre-fetch (see whisper loop note).
    if is_incomplete "$model_id"; then
        echo "  SKIP $label: incomplete (failed shard verification, not downloadable)"
        write_skip_json "$model_id" "$label" "summarize" "incomplete: failed shard verification" \
            "$RUN_DIR/summarize/${label}_result.json"
        continue
    fi

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
            "--style blog" </dev/null   # sever subprocess stdin from the candidate pipe

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
