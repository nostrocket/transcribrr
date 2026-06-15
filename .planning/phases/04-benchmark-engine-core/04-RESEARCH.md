# Phase 4: Benchmark Engine Core - Research

**Researched:** 2026-06-15
**Domain:** Bash benchmark harness — Apple Silicon macOS, MLX inference, subprocess-per-candidate, interactive staged pipeline
**Confidence:** HIGH (all mechanisms verified against live system: Darwin 25.x, arm64, bash 3.2.57, mlx-lm 0.31.3)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Staged interactive pipeline — whisper → cleanup → summarize. Human picks best output per stage; that pick is input to next stage.
- **D-02:** Run ALL hardware-fitting candidates per stage (no cap).
- **D-03:** `--benchmark` requires an interactive TTY. Abort cleanly with clear message if no TTY (no hanging at selection prompt). Cross-phase implication: Phase 6 success criterion #3 must be reworded (skill-refresh subprocess exits, not interactive sweep).
- **D-04:** Phase 4 makes per-stage picks and persists per-candidate JSON results. Phase 5 writes `settings.conf`.
- **D-05:** Detect total unified memory at runtime via `sysctl hw.memsize`.
- **D-06:** Usable memory ceiling = 75% of detected RAM.
- **D-07:** Fit estimate = `size_gb` + fixed runtime-overhead buffer. No per-model HF-config introspection. Skip unfit candidates before execution, log reason. Buffer value: Claude's discretion (see Section 4 below).
- **D-08:** Pre-fetch step before timing. Download uncached fitting candidates with progress. Timing starts only after all needed models are locally cached. No mid-sweep downloads.
- **D-09:** Disk-space gate before pre-fetch. Sum `size_gb` of uncached fitting candidates, compare against available space on HF-cache volume + buffer. Hard-abort with "need X GB, have Y GB" message if insufficient.
- **D-10:** Peak memory via `/usr/bin/time -l` wrapping each candidate subprocess. Parse "maximum resident set size" field.
- **D-11:** Speed metric: RTF = wall_time ÷ audio_duration for whisper; tokens/sec from stage script output for cleanup/summarize.
- **D-12:** Real output excerpt captured per model via `OUTPUT_FILE=` contract. Stage scripts unchanged.
- **D-13:** Default sample = `https://www.youtube.com/watch?v=EWo7-azGHic`, full video. Cached locally on first run.
- **D-14:** Fixed cool-down pause between candidates (~45s default, Claude's discretion within 30–60s range).
- **D-15:** One JSON result file per candidate. Fields: Claude's discretion (see Section 8).
- **D-16:** Continue-on-failure: candidate OOM/load-fail → error JSON, sweep continues.
- **D-17:** `--benchmark` exec-dispatches to new `benchmark.sh` at repo root. Stage scripts unmodified. Results in `results/benchmark_<ts>/`. `candidates.conf` parsed, never sourced.

### Claude's Discretion

- Exact runtime-overhead buffer GB (D-07)
- Cool-down duration within 30–60s range (D-14)
- JSON result schema fields (D-15)
- Live-progress line format (follow existing `stage_banner` idiom plus per-candidate current-model/stage/elapsed line)
- Pre-fetch mechanism (`hf download` CLI vs Python `snapshot_download`)
- No-TTY detection method (`[ -t 0 ]` vs `[ -t 1 ]`)
- Optional memory-pressure pre-flight warning (PITFALLS #3)

### Deferred Ideas (OUT OF SCOPE)

- Phase 5: saved `report.md`, resumable sweeps, atomic `settings.conf` write (RPT-01/02/03, RESUME-01/02)
- Phase 6: Claude refresh skill, `--benchmark` auto-launch of it (SKILL-01..04)
- Multi-pass timing averaging (FUT-05)
- `--max-candidates N` cap
- `--cooldown SECONDS` flag
- Configurable usable-memory fraction
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| HW-01 | Detect total unified memory at runtime | `sysctl -n hw.memsize` → bytes; `awk '{printf "%d", $1/1024/1024/1024}'` → integer GB. Verified on Darwin 25 arm64. |
| HW-02 | Check each candidate against available memory before execution; skip with reason | Fit gate: `size_gb + OVERHEAD_BUFFER_GB <= usable_gb`. awk float compare. Verified. |
| HW-03 | Only fit models are ever loaded | Fit gate runs before any subprocess launch. Continue-on-failure (D-16) handles OOM edge cases. |
| BENCH-01 | `--benchmark` mode runs each fitting candidate through its real stage on sample input | exec-dispatch to `benchmark.sh` from `transcribrr.sh` flag-parse loop. Stage scripts called via existing `--model` + `OUTPUT_FILE=` contract. |
| BENCH-02 | Each candidate runs in its own subprocess | One subprocess per candidate call. MLX Metal memory released on process exit (confirmed by Pitfall #6 prior research). |
| BENCH-03 | Discarded warm-up pass per model before timed pass | Warm-up subprocess on short audio/text eliminates Metal JIT compile latency from timing (Metal kernel cache is disk-persistent). Timed subprocess starts after warm-up exits. |
| BENCH-04 | Wall-clock time + derived speed metric; peak memory per model | RTF via `date +%s` wall timing; tok/s from grep on stage stdout; peak RSS from `/usr/bin/time -l` parsed from temp file. All verified. |
| BENCH-05 | Real output excerpt captured per model | `OUTPUT_FILE=` contract + per-candidate result file. Stage scripts unchanged. |
| BENCH-06 | Default audio sample downloaded on first run, cached locally | yt-dlp download via existing pipeline; cached at `results/sample_<VIDEO_ID>.mp3`; subsequent runs skip download. |
| BENCH-07 | Auto-install `mlx-whisper` and `mlx-lm` as part of `--benchmark` setup | `benchmark.sh` runs its own `setup_venv()` mirroring stage scripts. `.venv/bin/hf` (huggingface_hub CLI) available after mlx-lm install. |
| BENCH-08 | Live progress during sweep | `stage_banner()` for stage headers + per-candidate `printf "\r  [%s] %d/%d  model=%-30s  elapsed=%ds"` line. |
</phase_requirements>

---

## Summary

Phase 4 builds a single new script (`benchmark.sh`) and minimal additions to `transcribrr.sh`, reusing all existing stage scripts unchanged. Every mechanism needed was verified on the target platform (Darwin 25.3.0, arm64, bash 3.2.57, mlx-lm 0.31.3).

The most important verified findings are: `/usr/bin/time -l` reports "maximum resident set size" in **bytes** (not pages), captures grandchild process RSS through bash subprocess wrappers, and cleanly separates from stage script stdout when directed to a temp file. The `hf` CLI (from `huggingface_hub` 1.19.0 already in `.venv`) replaces the deprecated `huggingface-cli`. The `summarize-transcript.sh` already emits a parseable `tok/s` line on stdout; `cleanup-transcript.sh` does not (wall time + output word count required). The 4 GB fixed overhead buffer passes all current candidates on a 64 GB machine while correctly gating candidates on a 16 GB machine.

Two landmines for the planner: (1) `benchmark.sh` needs its own `setup_venv()` call before pre-fetch can use `.venv/bin/hf` — the `.venv` may not exist if this is the user's first benchmark run; (2) the warm-up subprocess eliminates Metal JIT compile latency (disk-cached) but does NOT eliminate model weight loading from disk — this is intentional and honest, but must be documented in the plan so timing expectations are correct.

**Primary recommendation:** Build `benchmark.sh` with the verified patterns below; the standard stack is the existing `.venv` + `awk` + `/usr/bin/time -l` + `.venv/bin/hf` — no new dependencies needed.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Hardware memory detection | `benchmark.sh` (shell) | — | `sysctl` is a system call; no Python needed |
| Memory fit gate | `benchmark.sh` (shell) | — | Pure arithmetic on `size_gb` from `candidates.conf` |
| Disk space gate | `benchmark.sh` (shell) | — | `df` command, awk arithmetic |
| Model pre-fetch | `benchmark.sh` → `.venv/bin/hf` | Python `snapshot_download` fallback | `hf download` handles cache-miss and cache-hit efficiently |
| Warm-up pass | `benchmark.sh` → stage script subprocess | — | Stage script own `setup_venv()` handles Metal JIT |
| Timed inference | `benchmark.sh` → stage script subprocess (wrapped in `/usr/bin/time -l`) | — | Only correct way to measure whole-process RSS |
| RTF computation | `benchmark.sh` (awk) | — | `wall_time / audio_duration` in floating point |
| tok/s extraction (summarize) | `benchmark.sh` grep on stage stdout | — | Stage script already emits `(N.N tok/s)` line |
| tok/s approximation (cleanup) | `benchmark.sh` (awk) | — | Wall time + wc -w on output file |
| Peak memory parsing | `benchmark.sh` (awk + grep) | — | From `/usr/bin/time -l` temp file |
| Output excerpt capture | `benchmark.sh` via `OUTPUT_FILE=` contract | — | Existing pattern, stage scripts unchanged |
| JSON result writing | `benchmark.sh` → `.venv/bin/python` | — | Safe escaping of arbitrary text excerpts |
| Interactive selection | `benchmark.sh` (read -r) | — | Requires TTY (D-03) |
| Live progress | `benchmark.sh` (printf \r) | — | In-band, no ncurses dependency |
| Audio sample cache | `benchmark.sh` → `yt-dlp` (existing path) | — | Reuses Phase 1-2 download infrastructure |

---

## Standard Stack

### Core (all already in `.venv` or system, no new installs)

| Library / Tool | Version (verified) | Purpose | Notes |
|---------------|---------------------|---------|-------|
| bash 3.2.57 | system `/bin/bash` | Script interpreter | Mandatory constraint |
| `/usr/bin/time -l` | system (Darwin 25) | Peak RSS measurement | Outputs bytes, includes grandchild RSS |
| `sysctl` | system | Total RAM detection | `sysctl -n hw.memsize` → bytes |
| `awk` | system | All float arithmetic | Locale-independent, bash 3.2 safe |
| `df -g` | system | Disk space gate | `awk 'NR==2 {print $4}'` → available GB |
| `mlx-lm` | 0.31.3 | LLM inference (via stage scripts) | Already in `.venv` |
| `mlx_whisper` | current | ASR inference (via stage scripts) | Already in `.venv` |
| `huggingface_hub` | 1.19.0 | Pre-fetch + cache detection | Installed transitively by `mlx-lm` |
| `.venv/bin/hf` | 1.19.0 | CLI for model pre-fetch | Replaces deprecated `huggingface-cli` |
| `yt-dlp` | system (Homebrew) | Sample audio download | Existing dependency, auto-installed |
| `ffmpeg` | system (Homebrew) | Audio duration computation + warm-up audio | Existing dependency |
| `date +%s` | system | Wall-clock timing (integer seconds) | Bash 3.2 safe |

### Packages Required

No new packages. All tooling is already in `.venv` or system PATH.

**Version verification (run at planning time):**
```bash
/Users/gareth/git/transcribrr/.venv/bin/python -c "import mlx_lm; print(mlx_lm.__version__)"
/Users/gareth/git/transcribrr/.venv/bin/hf --version
```

---

## Package Legitimacy Audit

No new packages are installed in this phase. All tooling is from existing `.venv` dependencies or macOS system tools. The `hf` CLI is `huggingface_hub` 1.19.0, installed as a transitive dependency of `mlx-lm` from Hugging Face Inc. (authoritative source). No audit required.

---

## Architecture Patterns

### System Architecture Diagram

```
transcribrr.sh --benchmark
        │
        │ (flag parsed, BENCHMARK_MODE=true)
        │
        └─► exec benchmark.sh
                    │
                    ├─[0] TTY check: [ -t 0 ] || abort
                    │
                    ├─[1] setup_venv() — ensure .venv + mlx-lm + hf CLI
                    │
                    ├─[2] read config/candidates.conf
                    │     parse [candidate] blocks → id|label|size_gb per stage
                    │
                    ├─[3] sysctl hw.memsize → total_gb
                    │     usable_gb = total_gb * 0.75 (awk)
                    │     fit gate: size_gb + OVERHEAD_BUFFER <= usable_gb
                    │     → fitting[], skipped[]
                    │
                    ├─[4] disk-space gate (before ANY download)
                    │     sum size_gb of uncached fitting candidates (df -g HF cache)
                    │     hard-abort if insufficient
                    │
                    ├─[5] sample audio: check cache → download via yt-dlp if missing
                    │     cache: results/sample_<VIDEO_ID>.mp3
                    │
                    ├─[6] pre-fetch: for each fitting candidate not in HF cache
                    │     .venv/bin/hf download <model_id>
                    │     (skips network if already cached)
                    │
                    ├─[7] WHISPER STAGE SWEEP
                    │     for each fitting whisper candidate:
                    │       ┌─ warm-up subprocess (short sine wav, discard output)
                    │       │    /usr/bin/time -l transcribe.sh warmup.wav --model id
                    │       │    (populates Metal kernel disk cache)
                    │       │    sleep 5  (brief cool-down after warm-up)
                    │       └─ timed subprocess
                    │            TIME_OUT=$(mktemp)
                    │            t_start=$(date +%s)
                    │            STAGE_STDOUT=$( /usr/bin/time -l transcribe.sh sample.mp3 \
                    │                              --model id 2>"$TIME_OUT" \
                    │                            | tee /dev/stderr \
                    │                            | { grep "^OUTPUT_FILE=" || true; } )
                    │            t_end=$(date +%s)
                    │            wall_time=$((t_end - t_start))
                    │            peak_bytes=$(grep "maximum resident" "$TIME_OUT" | awk '{print $1}')
                    │            rtf=$(awk "BEGIN {printf \"%.3f\", $wall_time/$audio_duration}")
                    │            write result JSON
                    │       cool-down sleep 45
                    │     display results table (model, RTF, peak_mem, excerpt)
                    │     prompt user to select best transcript
                    │     → SELECTED_TRANSCRIPT (input to next stage)
                    │
                    ├─[8] CLEANUP STAGE SWEEP
                    │     (same pattern; input = SELECTED_TRANSCRIPT from [7])
                    │     tok/s = output_word_count * 1.3 / wall_time  (awk)
                    │     prompt user → SELECTED_CLEANED
                    │
                    ├─[9] SUMMARIZE STAGE SWEEP
                    │     (same pattern; input = SELECTED_CLEANED from [8])
                    │     tok/s = grep "tok/s" from stage stdout
                    │     prompt user → SELECTED_SUMMARY
                    │
                    └─[10] persist per-candidate JSON results + sweep metadata
                           print: "Phase 5 will read results/benchmark_<ts>/ to write settings.conf"
```

### Recommended Project Structure

```
transcribrr/
├── transcribrr.sh          # MODIFIED: add --benchmark / --sample flag cases + exec-dispatch
├── benchmark.sh            # NEW: the entire benchmark engine (this phase)
├── transcribe.sh           # UNCHANGED
├── cleanup-transcript.sh   # UNCHANGED
├── summarize-transcript.sh # UNCHANGED
├── config/
│   ├── candidates.conf     # UNCHANGED (Phase 3 artifact)
│   └── settings.conf       # NOT WRITTEN yet (Phase 5)
└── results/                # NEW dir; add to .gitignore
    ├── sample_EWo7-azGHic.mp3  # cached benchmark audio (gitignored via results/)
    └── benchmark_20260615T120000/   # per-run dir (gitignored via *_*/ pattern)
        ├── whisper/
        │   ├── small_result.json
        │   ├── small_transcript_small.txt
        │   ├── turbo_result.json
        │   └── ...
        ├── cleanup/
        │   └── ...
        ├── summarize/
        │   └── ...
        └── sweep_meta.json  # run-level metadata (ts, total_ram_gb, usable_gb, audio_duration_s)
```

**Note on `.gitignore`:** The existing `*_*/` pattern already catches `benchmark_20260615T120000/` (verified via `git check-ignore`). The `results/` directory itself must be added to `.gitignore` as a new entry.

---

### Pattern 1: `/usr/bin/time -l` peak RSS capture

**What:** Wrap each stage-script subprocess in `/usr/bin/time -l`. Redirect time output to a temp file (via `2>`), while stage stdout flows through `tee /dev/stderr | grep "^OUTPUT_FILE="` as in the existing `transcribrr.sh` capture idiom.

**Verified facts:**
- "maximum resident set size" is in **bytes** (not pages). Confirmed: 300 MB bytearray → 327,630,848 bytes reported.
- Page size on Apple Silicon is 16,384 bytes; 327,630,848 / 16,384 = 19,995 — clearly not pages.
- `/usr/bin/time -l` **does** capture grandchild process RSS through a bash wrapper (`/bin/bash -c 'python3 ...'` → 327 MB reported for a 300 MB python3 grandchild). This uses `getrusage(RUSAGE_CHILDREN)`.
- Time metrics go to stderr; stage script progress goes to stdout. With `2>"$TIME_OUT"`, they stay cleanly separated.

**Example (bash 3.2 safe):**
```bash
# [VERIFIED: live system test, Darwin 25.3.0]
TIME_OUT=$(mktemp)
t_start=$(date +%s)
STAGE_OUT=$( /usr/bin/time -l "$stage_script" "$input" --model "$model_id" \
               2>"$TIME_OUT" \
             | tee /dev/stderr \
             | { grep "^OUTPUT_FILE=" || true; } )
t_end=$(date +%s)
wall_time=$((t_end - t_start))

output_file="${STAGE_OUT#OUTPUT_FILE=}"
peak_bytes=$(grep "maximum resident set size" "$TIME_OUT" | awk '{print $1}')
peak_gb=$(echo "$peak_bytes" | awk '{printf "%.2f", $1/1024/1024/1024}')
rm -f "$TIME_OUT"
```

**Anti-pattern to avoid:** `{ /usr/bin/time -l script ... } 2>&1` merges stderr into stdout. This corrupts the `tee | grep OUTPUT_FILE=` capture with time output. Always use a temp file for time output.

---

### Pattern 2: Memory detection and fit gate

**What:** Detect total RAM via `sysctl`, compute 75% usable ceiling, apply per-candidate fit check via awk.

**Verified facts:**
- `sysctl -n hw.memsize` → `68719476736` (64 GB M2 Max, bytes). [VERIFIED: live system]
- Bytes → integer GB: `awk '{printf "%d", $1/1024/1024/1024}'` → `64`. [VERIFIED]
- 75% usable: `awk '{printf "%d", $1 * 0.75}'` → `48`. [VERIFIED]
- Float fit comparison via awk (bash 3.2 safe — no `(( ))` with floats). [VERIFIED]

**Example:**
```bash
# [VERIFIED: live system test, bash 3.2.57]
MEMSIZE_BYTES=$(sysctl -n hw.memsize)
TOTAL_GB=$(echo "$MEMSIZE_BYTES" | awk '{printf "%d", $1/1024/1024/1024}')
USABLE_GB=$(echo "$TOTAL_GB" | awk '{printf "%d", $1 * 0.75}')
echo "Detected RAM: ${TOTAL_GB} GB  Usable ceiling: ${USABLE_GB} GB"

# Per-candidate fit check:
FIT=$(awk "BEGIN {
    estimate = $size_gb + $OVERHEAD_BUFFER_GB
    if (estimate <= $USABLE_GB) print \"fit\"
    else print \"skip\"
}")
```

---

### Pattern 3: HF model cache detection and pre-fetch

**What:** Check HF cache directory for model presence before download; use `.venv/bin/hf download` for pre-fetch.

**Verified facts:**
- `huggingface-cli` is **deprecated** (warns "use `hf` instead"). Use `.venv/bin/hf`. [VERIFIED: live system]
- `huggingface_hub` 1.19.0 is installed transitively via `mlx-lm` → `transformers`. [VERIFIED]
- `.venv/bin/hf` exists and works. [VERIFIED]
- `hf download <model_id>` on an already-cached model: **fast** (just prints the cached path, no network download). [VERIFIED]
- `hf download` on an uncached model: downloads with progress bars to `~/.cache/huggingface/hub/`.
- Cache directory naming: `models--<org>--<name>` (slashes become double-dashes). [VERIFIED]
- Works for non-mlx-community orgs: `Qwen/Qwen3-14B-MLX-4bit` → `models--Qwen--Qwen3-14B-MLX-4bit`. [VERIFIED]

**Shell cache detection (bash 3.2):**
```bash
# [VERIFIED: live system test]
HF_CACHE="${HOME}/.cache/huggingface/hub"

is_model_cached() {
    local model_id="$1"
    local cache_name="models--$(echo "$model_id" | sed 's|/|--|g')"
    local snapshots_dir="$HF_CACHE/$cache_name/snapshots"
    [ -d "$snapshots_dir" ] && [ -n "$(ls -A "$snapshots_dir" 2>/dev/null)" ]
}

# Pre-fetch (shows progress on terminal):
if ! is_model_cached "$model_id"; then
    echo "Downloading $model_id ..."
    "$VENV_DIR/bin/hf" download "$model_id"
fi
```

**LANDMINE:** `huggingface-cli download` still works but prints a deprecation warning. Filter or suppress with `2>/dev/null` if used for scripting. Better: use `.venv/bin/hf` directly.

---

### Pattern 4: Speed metrics per stage

**Whisper stage — RTF:**
```bash
# [VERIFIED: live system test]
# audio_duration from ffmpeg (reuse transcribe.sh pattern):
DURATION_STR=$(ffmpeg -i "$AUDIO_FILE" 2>&1 | grep "Duration" | awk '{print $2}' | tr -d ,)
IFS=: read h m s <<< "$DURATION_STR"
AUDIO_DURATION_S=$(echo "$h * 3600 + $m * 60 + $s" | LC_NUMERIC=C bc)
# Then after timed subprocess:
RTF=$(awk "BEGIN {printf \"%.3f\", $wall_time / $AUDIO_DURATION_S}")
```

**Summarize stage — tok/s (from stage stdout):**

`summarize-transcript.sh` emits on stdout (Python `print()`):
```
  Generated ~4096 tokens in 12.5s (327.7 tok/s)
```
This line appears once per `run_llm()` call (may be multiple for chunked transcripts).

```bash
# [VERIFIED: live grep test]
TOK_PER_S=$(echo "$stage_stdout" | grep -oE '[0-9]+\.[0-9]+ tok/s' | tail -1 | awk '{print $1}')
```

**Cleanup stage — tok/s (no self-report, derive from wall time):**

`cleanup-transcript.sh` does NOT emit a `tok/s` line. Compute from wall time and output:
```bash
# [VERIFIED: awk test]
WORD_COUNT=$(wc -w < "$output_file" | tr -d ' ')
TOK_PER_S=$(awk "BEGIN {printf \"%.1f\", ($WORD_COUNT * 1.3) / $wall_time}")
```

**Note:** The `summarize-transcript.sh` script's own tok/s calculation uses `len(response.split()) * 1.3` (word-count approximation, not true token count). This is consistent with what the benchmark extracts. [VERIFIED: source code read]

---

### Pattern 5: Candidates.conf parser

**Actual format (Phase 3 artifact):** `[candidate]` blocks with `stage=`, `id=`, `label=`, `size_gb=` fields. [VERIFIED: live file read]

```bash
# [VERIFIED: live parser test — correctly extracts all 4 whisper + 5 summarize candidates]
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
    # Emit last block
    if [ "$in_block" = true ] && [ "$current_stage" = "$stage_filter" ]; then
        printf '%s|%s|%s\n' "$current_id" "$current_label" "$current_size"
    fi
}
# Usage:
while IFS='|' read -r id label size_gb; do
    ...
done < <(parse_candidates "whisper" "$CANDIDATES_CONF")
```

**IMPORTANT:** The parser above misses the last candidate when the file ends without a blank line or new `[candidate]` block. The "emit last block" section at the bottom handles this correctly. Test with the actual file.

---

### Pattern 6: TTY detection for interactive guard

```bash
# [VERIFIED: live system test]
# [ -t 0 ] = stdin is a terminal (best signal for interactive intent)
if [ ! -t 0 ]; then
    echo "Error: --benchmark requires an interactive TTY." >&2
    echo "  Run directly from a terminal, not piped or in cron." >&2
    exit 1
fi
```

**Why `[ -t 0 ]` (stdin) not `[ -t 1 ]` (stdout):** Stdin is the correct check for whether the *user* can provide interactive input. `transcribrr.sh --benchmark < /dev/null` correctly fails (stdin not a TTY). Stdout could be redirected to a log while stdin remains interactive — `[ -t 0 ]` handles this correctly.

---

### Pattern 7: JSON result file (Python-generated)

Safe JSON emission for arbitrary text excerpts (quotes, newlines, backslashes all handled):

```bash
# [VERIFIED: live Python test]
"$VENV_DIR/bin/python" - << PYEOF
import json
data = {
    "candidate_id":  "$candidate_id",
    "label":         "$label",
    "stage":         "$stage",
    "speed_metric":  "$speed_metric",  # "rtf" or "tok_per_s"
    "speed_value":   $speed_value,
    "peak_mem_bytes": $peak_bytes,
    "peak_mem_gb":   $peak_gb,
    "wall_time_sec": $wall_time,
    "audio_duration_sec": $audio_duration,  # whisper only; null for others
    "output_file":   "$output_file",
    "fit_status":    "fit",
    "error":         None
}
with open("$result_json_path", "w") as f:
    json.dump(data, f, indent=2)
PYEOF
```

For error cases (OOM, load failure):
```bash
"$VENV_DIR/bin/python" -c "
import json
data = {'candidate_id': '$candidate_id', 'label': '$label', 'stage': '$stage',
        'fit_status': 'fit', 'error': 'oom_or_load_failure', 'exit_code': $exit_code}
open('$result_json_path', 'w').write(json.dumps(data, indent=2))
"
```

**Alternative — pure bash JSON for non-text fields:** For cases where the output_file path and error fields have no special characters, a `printf` heredoc works. But any field from stage script output must use Python to avoid injection.

---

### Pattern 8: Live progress

Follow the existing `stage_banner()` idiom (transcribrr.sh line 301-308) for stage headers; add a per-candidate progress line:

```bash
# Stage header (reuse existing function):
stage_banner "Benchmark: whisper (stage 1 of 3) — ${#fitting_candidates[@]} candidates"

# Per-candidate running status (overwrite same line with \r):
printf "  [whisper %d/%d]  %-35s  elapsed: %ds\r" \
    "$current_num" "$total_candidates" "$label" "$elapsed"

# After candidate completes: advance to new line + result summary:
echo ""  # finalize the \r line
printf "  %-35s  RTF: %s  Mem: %s GB  %s\n" "$label" "$rtf" "$peak_gb" "[done]"
```

---

### Anti-Patterns to Avoid

- **Merging `/usr/bin/time` stderr into stdout:** `{ /usr/bin/time -l ... } 2>&1` breaks the `grep OUTPUT_FILE=` capture. Always `2>"$TIME_OUT"`.
- **Using `huggingface-cli`:** Deprecated (prints warning to stderr, confuses log parsing). Use `.venv/bin/hf`.
- **Using `declare -A` for candidate→result mapping:** Unavailable in bash 3.2. Use flat files (`<label>_result.json`).
- **Float arithmetic in `(( ))`:** Bash 3.2 integer-only. Always use `awk`.
- **`bc` without `LC_NUMERIC=C`:** Locale can use `,` as decimal separator. Always `LC_NUMERIC=C bc`.
- **Running the warm-up and timed passes in the same subprocess:** MLX Metal memory is not released within a process. Each must be a separate subprocess invocation.
- **Calling `.venv/bin/hf` before `setup_venv()` runs:** `.venv` may not exist on first benchmark. `benchmark.sh` must call its own `setup_venv()` before any `.venv/bin/*` access.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Peak process RSS | Custom `/proc` parsing or `ps` polling | `/usr/bin/time -l` | Captures grandchild RSS; atomic at process exit; no polling race |
| JSON with arbitrary text | `echo '{"key": "'"$val"'"}'` string concatenation | `python3 -c "import json; ..."` via `.venv/bin/python` | Shell quoting cannot safely escape newlines, backslashes, or quotes in model output |
| Float arithmetic | `expr`, `$(( ))`, `let` | `awk 'BEGIN {printf...}'` | Bash arithmetic is integer-only; awk is locale-independent floating point |
| HF model download with progress | `wget`/`curl` of individual safetensor files | `.venv/bin/hf download` | Handles multi-file repos, checksums, partial download resume, cache structure |
| HF cache detection | Manually parsing `~/.cache/huggingface/hub/` structure | Shell dir-existence check on `models--<org>--<name>/snapshots/` OR Python `try_to_load_from_cache` | The dir structure IS the contract; works without network |

---

## Common Pitfalls

### Pitfall A: `/usr/bin/time -l` stderr merged with stage script output

**What goes wrong:** If you do `{ /usr/bin/time -l script ... ; } 2>&1 | grep "^OUTPUT_FILE="`, the time metrics become part of the pipe and the grep extracts nothing because `OUTPUT_FILE=` is on stdout while time metrics are on stderr — both now on the same stream, in unpredictable order.

**How to avoid:** `2>"$TIME_OUT"` on the subprocess. The `OUTPUT_FILE=` grep runs on the stdout-only pipe. [VERIFIED]

**Warning signs:** `STAGE_OUT` is empty after capture; `cat "$TIME_OUT"` shows both time output AND "OUTPUT_FILE=..." mixed together.

---

### Pitfall B: `setup_venv()` not called before pre-fetch in benchmark.sh

**What goes wrong:** On a fresh system (or after `rm -rf .venv`), `benchmark.sh` attempts to call `.venv/bin/hf download ...` before the venv exists. The path doesn't exist; the script fails with a confusing "not found" error.

**How to avoid:** `benchmark.sh` must call its own `setup_venv()` as its FIRST action after TTY check. Mirror the pattern from any stage script:

```bash
setup_venv() {
    if [ ! -d "$VENV_DIR" ]; then
        echo "Creating virtual environment..."
        python3 -m venv "$VENV_DIR"
    fi
    if ! "$PYTHON" -c "import mlx_lm" 2>/dev/null; then
        echo "Installing mlx-lm (required for benchmark)..."
        "$PIP" install --upgrade pip > /dev/null
        "$PIP" install mlx-lm
    fi
}
```

After this, `.venv/bin/hf`, `.venv/bin/python`, and `mlx-lm` are all available. [VERIFIED]

---

### Pitfall C: Warm-up and timed passes in the SAME subprocess

**What goes wrong:** If you try to warm up and time in one Python process (e.g., a thin Python wrapper that calls the stage script logic), MLX Metal memory accumulates between calls; the warm-up state persists into the timing window; and the process cannot be accurately timed with `/usr/bin/time -l` (which only reports at process exit).

**How to avoid:** Warm-up IS a full subprocess invocation of the stage script. Timed pass IS a separate full subprocess invocation. Two subprocess calls per candidate per stage. [VERIFIED architecture]

---

### Pitfall D: `hf download` network latency on already-cached models

**What goes wrong:** Even for a cached model, `hf download` makes a network request to check for updates (as shown by the "unauthenticated requests" warning). In a slow or no-network environment, this adds latency to the pre-fetch step.

**How to avoid:** Use the shell `is_model_cached()` function (dir existence check) BEFORE calling `hf download`. Only call `hf download` for models that are NOT in cache. The dir check is instant and offline. [VERIFIED]

---

### Pitfall E: `candidates.conf` parser misses last candidate block

**What goes wrong:** The parse loop emits a candidate when it sees the next `[candidate]` header (flush-on-next-block). The last block is only flushed if there's a trailing `[candidate]` or blank line. Without an explicit "emit last block" section, the last candidate in each stage is silently dropped.

**How to avoid:** Always include the "emit last block" code after the `while read` loop ends. [VERIFIED: tested against actual candidates.conf]

---

### Pitfall F: Disk space gate missing from results/ gitignore

**What goes wrong:** The `results/` directory is never tracked by git even with no explicit gitignore entry (subdirectories with `*_*/` names are caught), but the `results/` parent directory itself shows as an untracked directory in `git status`. This is cosmetically wrong and may confuse users running `git status`.

**How to avoid:** Add `results/` to `.gitignore` explicitly. [VERIFIED: existing `*_*/` pattern already catches `benchmark_<ts>/` subdirs via recursive gitignore matching]

---

### Pitfall G: MODEL_LABEL sanitization for non-mlx-community orgs

**What goes wrong:** `candidates.conf` contains `Qwen/Qwen3-14B-MLX-4bit` (org=`Qwen`, not `mlx-community`). The stage scripts' MODEL_LABEL sanitizer `sed 's/mlx-community\///'` does NOT strip the `Qwen/` prefix. The resulting label is `qwen_qwen3-14b-mlx-4bit` (the `/` becomes `_`). This is valid for filenames but unexpected as a display label.

**Impact:** Result JSON files will be named `qwen_qwen3-14b-mlx-4bit_result.json` not `Qwen3-14B-4bit_result.json`. Phase 5's report generation must handle this.

**How to avoid:** In `benchmark.sh`, use the `label` field from `candidates.conf` (already set to `Qwen3-14B-4bit`) as the display name and for result file naming. Use `model_id` (the HF ID) as the `--model` argument to stage scripts. The stage script's internal MODEL_LABEL is only for the stage script's own output filename, not for benchmark result naming.

---

## Decisions Requiring Concrete Recommendations

### 1. Runtime-Overhead Buffer (D-07): RECOMMEND 4 GB

**Analysis:**
- All current candidates on a 64 GB machine (48 GB usable): 4 GB buffer includes all candidates including Llama-3.3-70B (39.7 + 4 = 43.7 GB < 48 GB). [VERIFIED: fit gate test]
- On a 16 GB machine (12 GB usable): 4 GB buffer correctly excludes Qwen2.5-14B (8.31 + 4 = 12.31 GB > 12 GB). [VERIFIED]
- KV cache for large models: The `summarize-transcript.sh` already chunks long transcripts at 20k words (~15.4k tokens), limiting single-call KV cache to ~3.7 GB for 32B models and ~5.0 GB for 70B models. These are NOT included in the buffer because the buffer is meant to cover Python overhead + tokenizer + MLX allocator baseline (~2-3 GB), NOT KV cache.
- **70B edge case:** Llama-3.3-70B at 39.7 + 4 = 43.7 GB passes the fit gate but may OOM during generation (KV cache + overhead pushes it toward 48-50 GB on a 64 GB machine). D-16's continue-on-failure + error JSON is the safety net. The OOM IS informative data (user sees "70B OOM on your hardware").
- **Why not 6+ GB:** Increasing buffer to 9+ GB would exclude the 70B model from the candidate list entirely, which the user explicitly added. 4 GB correctly allows it to attempt to run with graceful OOM handling.

**Recommendation: 4 GB. Define as `BENCH_OVERHEAD_BUFFER_GB=4` constant at top of `benchmark.sh`.**

---

### 2. Cool-down Duration (D-14): RECOMMEND 45 s

The 30–60 s range from PITFALLS #4 is based on M-series thermal recovery time. 45 s is the midpoint, conservative enough to allow meaningful cool-down without excessive total benchmark time. A 13-candidate full sweep (4 whisper + 4 cleanup + 5 summarize) with 45 s between each adds 12 × 45 s = 9 minutes to total sweep time — acceptable. [ASSUMED: no live thermal measurement available; range from prior research]

**Recommendation: `BENCH_COOLDOWN_SECS=45`. Expose as a comment but not a flag (deferred per CONTEXT.md).**

---

### 3. JSON Result Schema (D-15)

**Recommended schema (per-candidate result file):**

```json
{
  "format_version": 1,
  "candidate_id":    "mlx-community/whisper-large-v3-turbo",
  "label":           "turbo",
  "stage":           "whisper",
  "run_ts":          "2026-06-15T12:00:00",
  "fit_status":      "fit",
  "error":           null,
  "speed_metric":    "rtf",
  "speed_value":     0.089,
  "peak_mem_bytes":  1823000000,
  "peak_mem_gb":     1.70,
  "wall_time_sec":   318,
  "audio_duration_sec": 3580,
  "output_file":     "results/benchmark_20260615T120000/whisper/turbo_transcript_turbo.txt",
  "warmup_wall_sec": 42
}
```

For error cases:
```json
{
  "format_version": 1,
  "candidate_id":   "mlx-community/Llama-3.3-70B-Instruct-4bit",
  "label":          "Llama3.3-70B-4bit",
  "stage":          "summarize",
  "run_ts":         "2026-06-15T14:32:00",
  "fit_status":     "fit",
  "error":          "subprocess_nonzero",
  "exit_code":      1,
  "speed_metric":   null,
  "speed_value":    null,
  "peak_mem_bytes": null,
  "peak_mem_gb":    null,
  "wall_time_sec":  null,
  "audio_duration_sec": null,
  "output_file":    null,
  "warmup_wall_sec": null
}
```

**Skipped (fit gate):**
```json
{
  "format_version": 1,
  "candidate_id":   "mlx-community/Llama-3.3-70B-Instruct-4bit",
  "label":          "Llama3.3-70B-4bit",
  "stage":          "whisper",
  "fit_status":     "skip",
  "skip_reason":    "size_gb(39.7) + overhead(4) = 43.7 > usable(12.0)"
}
```

**Rationale for field choices:**
- `format_version`: Phase 5 can detect old-format files if schema changes.
- `speed_metric`/`speed_value`: Single pair handles both RTF and tok/s without schema divergence.
- `audio_duration_sec`: In whisper JSON only; null elsewhere (not meaningful for LLM stages).
- `warmup_wall_sec`: Diagnostic; Phase 5 report can surface "warm-up overhead".
- `output_file`: Absolute path to the stage output file; Phase 5 needs this for report excerpts.

---

### 4. Pre-fetch Mechanism

**Recommendation: `.venv/bin/hf download <model_id>`** over Python `snapshot_download`.

- Already installed, no new dependency [VERIFIED].
- Shows download progress bars automatically (user sees what's happening).
- Fast no-op for already-cached models [VERIFIED].
- Works for non-mlx-community orgs [VERIFIED].
- The one caveat: makes a network request even for cached models (checking for updates). Mitigate with the shell `is_model_cached()` guard: only call `hf download` when the model is NOT in cache.

---

### 5. No-TTY Detection

**Recommendation: `[ ! -t 0 ]` (stdin not a terminal)**

- `[ -t 0 ]` tests whether stdin is a TTY. This is the canonical check for interactive invocation. [VERIFIED: live system test]
- `transcribrr.sh --benchmark < /dev/null` → `[ ! -t 0 ]` → abort correctly.
- Cron, CI, piped invocations → abort correctly.
- Works in bash 3.2 without any feature detection. [VERIFIED]

---

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| `huggingface-cli download` | `.venv/bin/hf download` (huggingface_hub 1.19.0) | `huggingface-cli` still works but deprecated; `hf` is the replacement |
| `mlx.metal.clear_cache()` between model loads | Subprocess-per-candidate (process exit releases memory) | `clear_cache()` is insufficient; confirmed pattern in MLX community |
| `mlx_lm.generate(verbose=True)` for timing | Script-internal Python timing + grep on stdout | Stage scripts already use their own timing; don't need verbose mode |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | 45 s cool-down is sufficient for M-series thermal recovery | Section "Decisions" #2 | Later candidates may still be thermally disadvantaged; user can increase constant |
| A2 | Llama-3.3-70B will attempt to run (fit gate passes at 4 GB buffer) and may OOM | Section "Decisions" #1 | If 64 GB machine has enough headroom, 70B may run fine and OOM assumption is wrong — no harm |
| A3 | Sample video `EWo7-azGHic` is still available on YouTube at execution time | BENCH-06 | yt-dlp download fails; user supplies `--sample` override or different video is needed |
| A4 | `summarize-transcript.sh`'s tok/s approximation (words × 1.3 / time) is acceptable precision for benchmark comparison | Pattern 4 | Displayed speed numbers are approximate; ranking validity not affected |

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `/usr/bin/time -l` | Peak RSS (D-10) | ✓ | system (Darwin 25) | No fallback — macOS system tool |
| `sysctl hw.memsize` | RAM detection (HW-01) | ✓ | system | No fallback — macOS system tool |
| `df -g` | Disk space gate (D-09) | ✓ | system | `df -k` + awk conversion |
| `.venv/bin/hf` | Pre-fetch (D-08) | ✓ | 1.19.0 (via mlx-lm deps) | Python `snapshot_download` from same package |
| `.venv/bin/python` | JSON writing (D-15) | ✓ | 3.11 | No fallback — required |
| `yt-dlp` | Sample audio download (BENCH-06) | ✓ | system (Homebrew, auto-installed) | No fallback; existing `ensure_dep` handles |
| `ffmpeg` | Audio duration + warm-up audio | ✓ | system (Homebrew, auto-installed) | No fallback; existing `ensure_dep` handles |
| `awk` | Float arithmetic | ✓ | system | No fallback — system tool |
| `LC_NUMERIC=C bc` | (optional; use awk instead) | ✓ | system | Use awk exclusively |

**Missing dependencies with no fallback:** None. All required tools are system tools or already in `.venv`.

---

## Security Domain

`security_enforcement: true`, `security_asvs_level: 1`.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No user auth in local CLI tool |
| V3 Session Management | No | Stateless CLI invocations |
| V4 Access Control | No | Single-user local tool |
| V5 Input Validation | Yes | `candidates.conf` parsed, never sourced; model IDs validated as `[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+` before passing to stage scripts |
| V6 Cryptography | No | No secrets or encryption in this phase |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Shell injection via `candidates.conf` model ID | Tampering | Parse-not-source; validate model ID format before use; `"$model_id"` always double-quoted in subprocess calls |
| Output file path traversal | Tampering | All result paths constructed from `$RESULT_DIR` (fixed, under `results/`) + sanitized label; never from user input |
| Symlink attack on temp file for `/usr/bin/time` output | Tampering | Use `mktemp` (creates a unique temp file with no predictable name); remove after reading |
| `hf download` executing untrusted code | Elevation of Privilege | `hf download` only downloads files; it does NOT execute them. The `.venv/bin/` binary is from the controlled virtual environment |

**Key enforcement:** The `candidates.conf` parse-not-source rule (existing from Phase 3) is the primary injection prevention. `benchmark.sh` must NEVER use `source` or `.` on any config file.

---

## Sources

### Primary (HIGH confidence — verified against live system)
- Live system tests on Darwin 25.3.0 arm64, bash 3.2.57, mlx-lm 0.31.3 — all patterns in "Code Examples" verified with actual output
- `/Users/gareth/git/transcribrr/transcribrr.sh` — flag-parse idiom (lines 103–149), `stage_banner` (301–308), `_run_*` capture idiom (436–520)
- `/Users/gareth/git/transcribrr/transcribe.sh` — `setup_venv`, audio duration computation, `OUTPUT_FILE=` emission
- `/Users/gareth/git/transcribrr/cleanup-transcript.sh` — no tok/s output (confirmed by source read)
- `/Users/gareth/git/transcribrr/summarize-transcript.sh` — tok/s line format (line 387), `verbose=False` in generate call
- `/Users/gareth/git/transcribrr/config/candidates.conf` — actual block format, all candidate entries
- `mlx_lm.generate` source inspection — `verbose=True` output format, `response.peak_memory` attribute
- `/usr/bin/time -l` output format — bytes confirmed (not pages), grandchild RSS capture confirmed

### Secondary (MEDIUM confidence — verified indirectly)
- `.planning/research/PITFALLS.md` — PITFALL #7 (memory overhead 4 GB starting point), PITFALL #4 (30–60 s thermal range)
- `.planning/research/ARCHITECTURE.md` — Pattern 1 dispatch, Pattern 2 OUTPUT_FILE reuse, Anti-Pattern 2/3/4
- huggingface_hub 1.19.0 CLI (`hf --version` verified; deprecation warning for `huggingface-cli` verified)

### Tertiary (LOW confidence — from training / not live-verified)
- Thermal recovery 30–60 s range [ASSUMED from PITFALLS #4, not measured live]
- Llama-3.3-70B KV cache arithmetic estimates [ASSUMED model architecture from training knowledge]

---

## Metadata

**Confidence breakdown:**
- `/usr/bin/time -l` behavior: HIGH — live system verified (byte units, grandchild RSS, temp file separation)
- Memory detection: HIGH — live system verified
- tok/s extraction: HIGH — source code confirmed, grep pattern verified
- candidates.conf parser: HIGH — live parser test on actual file
- HF pre-fetch via `hf` CLI: HIGH — live test (cached + uncached behavior)
- Overhead buffer recommendation: MEDIUM — logic sound, KV cache estimates are [ASSUMED]
- Cool-down recommendation: MEDIUM — based on prior research range, not live thermal measurement

**Research date:** 2026-06-15
**Valid until:** 2026-09-15 (mlx-lm API stable; `hf` CLI from huggingface_hub is stable)
