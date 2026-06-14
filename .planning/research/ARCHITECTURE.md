# Architecture Research

**Domain:** Bash pipeline extension — benchmarking + model auto-selection for MLX audio pipeline
**Researched:** 2026-06-14
**Confidence:** HIGH (all conclusions grounded in the existing source code read directly)

## Standard Architecture

### System Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                      NORMAL PIPELINE (existing)                       │
│  transcribrr.sh <url|mp3> [--whisper-model X] [--cleanup-model X]   │
│                             [--summary-model X]                       │
│                                    │                                  │
│           ┌────────────────────────┼────────────────────┐            │
│           ▼                        ▼                    ▼            │
│     transcribe.sh          cleanup-transcript.sh  summarize-          │
│     --model $WHISPER_MODEL  --model $CLEANUP_MODEL  transcript.sh    │
│     → OUTPUT_FILE=          → OUTPUT_FILE=          --model $SUMMARY │
│                                                     → OUTPUT_FILE=   │
└──────────────────────────────────────────────────────────────────────┘
                │
                │  default-resolution layer (NEW v2.0)
                ▼
┌──────────────────────────────────────────────────────────────────────┐
│              settings.conf  (selected model defaults)                 │
│   WHISPER_MODEL_DEFAULT=...  CLEANUP_MODEL_DEFAULT=...               │
│   SUMMARY_MODEL_DEFAULT=...                                          │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                    BENCHMARK MODE (NEW v2.0)                          │
│  transcribrr.sh --benchmark [--sample <mp3>] [--skip-research]       │
│          │                                                            │
│          ▼                                                            │
│    benchmark.sh  ◄── candidates.conf (candidate model list)          │
│          │            (input; refreshed by skill or manually)        │
│          │                                                            │
│   ┌──────┴──────────────────────────────────┐                        │
│   │  For each stage × each candidate model: │                        │
│   │    run stage script → capture output    │                        │
│   │    record wall_time, tok_s, output path │                        │
│   └──────┬──────────────────────────────────┘                        │
│          │                                                            │
│          ▼                                                            │
│    results/benchmark_<timestamp>/                                     │
│      whisper/  cleanup/  summarize/  report.md                       │
│          │                                                            │
│          ▼                                                            │
│    Human reads report.md → selects winner per stage                  │
│          │                                                            │
│          ▼                                                            │
│    settings.conf  (written by selection step)                        │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                  SKILL REFRESH LOOP (NEW v2.0)                        │
│  benchmark.sh detects stale/missing candidates.conf                  │
│          │                                                            │
│          ▼  (unless --skip-research flag given)                       │
│    claude -p "run refresh-mlx-candidates skill" \                    │
│           --output-format stream-json                                 │
│          │                                                            │
│          ▼                                                            │
│  .claude/skills/refresh-mlx-candidates/SKILL.md                     │
│  → researches mlx-community HF, writes candidates.conf               │
└──────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | File Location |
|-----------|----------------|---------------|
| `transcribrr.sh` | Orchestration entry point; default-resolution; `--benchmark` dispatch | repo root (modify existing) |
| `benchmark.sh` | Benchmark loop; skill-refresh trigger; report generation | repo root (new) |
| `candidates.conf` | Vetted candidate model list per stage; input to benchmark | `config/candidates.conf` (new) |
| `settings.conf` | Selected winner per stage; read by pipeline default-resolution | `config/settings.conf` (new) |
| `results/benchmark_<ts>/` | Per-run outputs, timings, report | `results/` dir (generated, gitignored) |
| `refresh-mlx-candidates` skill | Claude skill that researches current mlx-community models and writes `candidates.conf` | `.claude/skills/refresh-mlx-candidates/SKILL.md` (new) |

## Recommended Project Structure

```
transcribrr/
├── transcribrr.sh           # MODIFIED: adds --benchmark dispatch + settings.conf default-resolution
├── transcribe.sh            # unchanged
├── cleanup-transcript.sh    # unchanged
├── summarize-transcript.sh  # unchanged
├── mlx-chat.sh              # unchanged
├── benchmark.sh             # NEW: benchmark loop, report, selection
├── config/
│   ├── candidates.conf      # NEW: candidate models per stage (refreshed by skill)
│   └── settings.conf        # NEW: selected defaults (written by benchmark selection step)
├── results/                 # gitignored
│   └── benchmark_<ts>/      # NEW: per-run outputs
│       ├── whisper/
│       ├── cleanup/
│       ├── summarize/
│       └── report.md
└── .claude/
    └── skills/
        └── refresh-mlx-candidates/
            └── SKILL.md     # NEW: Claude skill for candidate model research
```

### Structure Rationale

- **`benchmark.sh` at repo root:** Matches the existing idiom. All stage scripts live at root; `benchmark.sh` is a peer, not buried in a subdirectory.
- **`config/` subdirectory:** Keeps the two config files (`candidates.conf`, `settings.conf`) out of root clutter and makes their purpose visually distinct from executable scripts.
- **`results/` gitignored:** Benchmark outputs can be many MB (audio samples + model outputs). No value in tracking per-run artifacts; the pipeline itself is the asset.
- **`.claude/skills/` for the skill:** Matches the standard Claude Code skill convention already referenced in CLAUDE.md (`skills/`, `SKILL.md` index file).

## Architectural Patterns

### Pattern 1: `--benchmark` as a dispatch flag in `transcribrr.sh`, delegating immediately to `benchmark.sh`

**What:** `transcribrr.sh` adds `--benchmark` to its flag-parsing block. When detected, it validates that a sample audio file is available (flag `--sample <mp3>` or a built-in default sample path), then execs `"$SCRIPT_DIR/benchmark.sh"` with any forwarded flags. `benchmark.sh` owns all benchmark logic.

**When to use:** Keeps `transcribrr.sh` as the single user-facing entry point (one script to document, one script in PATH), while separating benchmark complexity into its own file. The dispatch pattern — parse just enough to know what mode you're in, then delegate — is already how the existing script works (metadata stage, download stage, etc. are sequential logical blocks).

**Trade-offs:** One extra subprocess fork, negligible. The alternative (inlining all benchmark logic in `transcribrr.sh`) would make that file significantly harder to maintain and test.

**Example:**
```bash
# In transcribrr.sh flag-parsing block:
--benchmark)
    BENCHMARK_MODE=true
    shift
    ;;
--sample)
    BENCHMARK_SAMPLE="$2"
    shift 2
    ;;
--skip-research)
    BENCHMARK_SKIP_RESEARCH=true
    shift
    ;;

# After flag parsing:
if [ "$BENCHMARK_MODE" = true ]; then
    exec "$SCRIPT_DIR/benchmark.sh" \
        ${BENCHMARK_SAMPLE:+--sample "$BENCHMARK_SAMPLE"} \
        ${BENCHMARK_SKIP_RESEARCH:+--skip-research}
fi
```

### Pattern 2: Reuse the `OUTPUT_FILE=` contract for benchmark per-model capture

**What:** Each stage script already prints `OUTPUT_FILE=<path>` on success. `benchmark.sh` calls each stage script for each candidate model using the identical capture idiom from `transcribrr.sh` (process substitution + `grep "^OUTPUT_FILE="`). The output files land in the per-run results directory, making them available for the report and for human inspection.

**When to use:** Always — reusing the contract means stage scripts need zero modification. The contract is: call the script with `--model <id>`, capture stdout, grep for `OUTPUT_FILE=`, strip prefix. Timing wraps outside the subprocess.

**Trade-offs:** The stage scripts write their output files relative to the input file's directory (e.g. `transcribe.sh` writes `${BASENAME}_transcript_${MODEL_LABEL}.txt` alongside the input). For benchmark runs, the sample file should live in a temporary working directory under `results/benchmark_<ts>/` so all model outputs for that stage cluster together without polluting the repo root. This means `benchmark.sh` copies the sample to that working dir before each stage sweep.

**Example:**
```bash
# In benchmark.sh — per-model timing loop (bash 3.2 compatible):
run_stage() {
    local stage_script="$1"   # e.g. "$SCRIPT_DIR/transcribe.sh"
    local input_file="$2"
    local model_id="$3"
    local result_dir="$4"

    local t_start t_end elapsed
    t_start=$(date +%s)

    local stage_out
    stage_out=$("$stage_script" "$input_file" --model "$model_id" \
        | tee /dev/stderr \
        | { grep "^OUTPUT_FILE=" || true; })

    t_end=$(date +%s)
    elapsed=$((t_end - t_start))

    local output_file="${stage_out#OUTPUT_FILE=}"
    # Record to TSV results store
    printf "%s\t%s\t%s\t%s\n" "$model_id" "$elapsed" "$output_file" \
        >> "$result_dir/timings.tsv"
}
```

### Pattern 3: Three-tier default resolution in `transcribrr.sh`

**What:** For each model variable (`WHISPER_MODEL`, `CLEANUP_MODEL`, `SUMMARY_MODEL`), resolution follows: flag value > `settings.conf` value > built-in code default. The settings file is read once at startup, after flag parsing, before preflight. A flag always wins; the settings file is a persistent user-level override; the built-in literal string in the script is the last resort.

**When to use:** This is the only correct design. Any other order (e.g. settings file read before flag parsing) would prevent flags from overriding settings, breaking unattended scripting.

**Trade-offs:** None meaningful. This is standard Unix config precedence (env/flag > config file > compiled default). The settings file uses simple `KEY=value` format that bash can source directly.

**Example:**
```bash
# In transcribrr.sh, after flag parsing block and before preflight_check:
SETTINGS_FILE="$SCRIPT_DIR/config/settings.conf"
if [ -f "$SETTINGS_FILE" ]; then
    # Source only known keys to avoid arbitrary code execution.
    # Parse manually rather than 'source' to stay safe with untrusted files.
    _read_setting() {
        local key="$1"
        grep "^${key}=" "$SETTINGS_FILE" | tail -1 | cut -d= -f2-
    }
    # Apply settings file value only when the flag was NOT supplied.
    # Flag-supplied values are already in WHISPER_MODEL / CLEANUP_MODEL /
    # SUMMARY_MODEL (they were parsed above); we detect "not supplied" by
    # comparing against the hard-coded built-in defaults.
    [ "$WHISPER_MODEL" = "small" ] && {
        _val=$(_read_setting WHISPER_MODEL_DEFAULT)
        [ -n "$_val" ] && WHISPER_MODEL="$_val"
    }
    [ "$CLEANUP_MODEL" = "llama3.1-8b-4bit" ] && {
        _val=$(_read_setting CLEANUP_MODEL_DEFAULT)
        [ -n "$_val" ] && CLEANUP_MODEL="$_val"
    }
    [ "$SUMMARY_MODEL" = "Qwen2.5-32B-4bit" ] && {
        _val=$(_read_setting SUMMARY_MODEL_DEFAULT)
        [ -n "$_val" ] && SUMMARY_MODEL="$_val"
    }
fi
```

**Important note on "not supplied" detection:** The safest implementation tracks whether each flag was explicitly set by using a sentinel (e.g. `WHISPER_MODEL_EXPLICIT=false`, set to `true` inside the `--whisper-model` case). This avoids the edge case where the user explicitly passes `--whisper-model small` (intending to force the built-in default) and the settings file overrides them. The sentinel approach is recommended over comparing against the built-in default string.

### Pattern 4: `candidates.conf` — shell-sourceable array declarations, one block per stage

**What:** `candidates.conf` declares per-stage candidate lists as whitespace-separated values assigned to shell variables. Since bash 3.2 has no arrays in the standard sense when sourcing with `source`, the file uses simple newline-separated values with a known key per stage. The benchmark script reads them with `grep`/`while read` rather than `source` (same safe-parse approach as settings.conf).

**When to use:** Always. Avoid `source`-ing config files that may be machine-written (by the skill) to prevent accidental code execution.

**Trade-offs:** Slightly more verbose parsing, but eliminates an injection vector. The skill writes a known format; the benchmark reads it with a known parser.

**Example format for `config/candidates.conf`:**
```
# Candidate models for benchmarking — written by refresh-mlx-candidates skill
# Last updated: 2026-06-14
# Format: one HF model ID per line under each STAGE_CANDIDATES block

WHISPER_CANDIDATES
mlx-community/whisper-small-mlx
mlx-community/whisper-large-v3-turbo
mlx-community/whisper-large-v3-mlx

CLEANUP_CANDIDATES
mlx-community/Meta-Llama-3.1-8B-Instruct-4bit
mlx-community/Mistral-7B-Instruct-v0.3-4bit

SUMMARIZE_CANDIDATES
mlx-community/Qwen2.5-32B-Instruct-4bit
mlx-community/Qwen2.5-14B-Instruct-4bit
```

**Parsing in `benchmark.sh`:**
```bash
# Extract candidates for a given stage header (bash 3.2 portable)
# Usage: read_candidates WHISPER_CANDIDATES candidates.conf
read_candidates() {
    local header="$1"
    local file="$2"
    local in_block=false
    while IFS= read -r line; do
        case "$line" in
            "$header") in_block=true ;;
            ""|\#*) [ "$in_block" = true ] && break ;;
            *_CANDIDATES) [ "$in_block" = true ] && break ;;
            *) [ "$in_block" = true ] && printf '%s\n' "$line" ;;
        esac
    done < "$file"
}
```

### Pattern 5: Skill-refresh loop with staleness check and offline fallback

**What:** `benchmark.sh` checks whether `config/candidates.conf` is missing or older than a configurable age (default 7 days). If stale and `--skip-research` is not set, it invokes the `claude` CLI headlessly to run the refresh skill. If the `claude` CLI is unavailable or the skill exits non-zero, it falls back gracefully: if a `candidates.conf` exists (even stale), it uses it with a warning; if no file exists at all, it aborts with a clear message explaining how to create one manually.

**When to use:** Always — the skill is a convenience, not a hard requirement. The benchmark must work without Claude CLI access (offline, corporate proxy, etc.).

**Trade-offs:** Headless `claude -p` invocation is slow (model inference startup). The staleness check prevents re-running it on every benchmark. The 7-day default is configurable via `CANDIDATE_MAX_AGE_DAYS` in `settings.conf`.

**Example:**
```bash
# In benchmark.sh
CANDIDATES_FILE="$SCRIPT_DIR/config/candidates.conf"
SKILL_CMD="claude"
CANDIDATE_MAX_AGE_DAYS=7

refresh_candidates_if_needed() {
    local skip_research="${1:-false}"
    local needs_refresh=false

    if [ ! -f "$CANDIDATES_FILE" ]; then
        needs_refresh=true
    else
        # Check file age in days (bash 3.2 / macOS stat compatible)
        local file_epoch now_epoch age_days
        file_epoch=$(stat -f %m "$CANDIDATES_FILE" 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        age_days=$(( (now_epoch - file_epoch) / 86400 ))
        if [ "$age_days" -gt "$CANDIDATE_MAX_AGE_DAYS" ]; then
            needs_refresh=true
            echo "candidates.conf is ${age_days} days old (threshold: ${CANDIDATE_MAX_AGE_DAYS}). Refreshing..." >&2
        fi
    fi

    if [ "$needs_refresh" = false ] || [ "$skip_research" = true ]; then
        return 0
    fi

    if ! command -v "$SKILL_CMD" &>/dev/null; then
        echo "Warning: 'claude' CLI not found; cannot auto-refresh candidate list." >&2
        if [ -f "$CANDIDATES_FILE" ]; then
            echo "Using existing (possibly stale) candidates.conf." >&2
            return 0
        else
            echo "Error: candidates.conf missing and cannot auto-generate. Create it manually." >&2
            echo "  See: config/candidates.conf format in README or run: claude -p 'run refresh-mlx-candidates'" >&2
            return 1
        fi
    fi

    echo "Running refresh-mlx-candidates skill via claude CLI..." >&2
    if ! "$SKILL_CMD" -p "Run the refresh-mlx-candidates skill. Write output to $CANDIDATES_FILE" \
            --output-format stream-json > /dev/null 2>&1; then
        echo "Warning: skill run failed. " >&2
        if [ -f "$CANDIDATES_FILE" ]; then
            echo "Using existing candidates.conf." >&2
            return 0
        fi
        echo "Error: No candidates.conf available. Aborting." >&2
        return 1
    fi

    echo "candidates.conf refreshed." >&2
}
```

## Data Flow

### Benchmark Run Flow

```
transcribrr.sh --benchmark --sample sample.mp3
    │
    └── exec benchmark.sh --sample sample.mp3
              │
              ├─[1] staleness check → maybe exec claude -p refresh-mlx-candidates
              │         └── skill writes config/candidates.conf
              │
              ├─[2] read config/candidates.conf
              │         → WHISPER_CANDIDATES[], CLEANUP_CANDIDATES[], SUMMARIZE_CANDIDATES[]
              │
              ├─[3] mkdir results/benchmark_<timestamp>/
              │         whisper/   cleanup/   summarize/
              │
              ├─[4] Whisper stage sweep:
              │   for each model in WHISPER_CANDIDATES:
              │       copy sample.mp3 → results/.../whisper/
              │       run_stage transcribe.sh input.mp3 $model
              │       → OUTPUT_FILE captured, wall_time recorded
              │       → results/.../whisper/timings.tsv row appended
              │
              ├─[5] Cleanup stage sweep:
              │   use OUTPUT_FILE from whisper stage (one representative transcript
              │   OR one per whisper model — see note below)
              │   for each model in CLEANUP_CANDIDATES:
              │       run_stage cleanup-transcript.sh $transcript $model
              │       → OUTPUT_FILE captured, wall_time recorded
              │
              ├─[6] Summarize stage sweep:
              │   use OUTPUT_FILE from cleanup stage (or raw transcript if --no-cleanup)
              │   for each model in SUMMARIZE_CANDIDATES:
              │       run_stage summarize-transcript.sh $cleaned $model
              │       → OUTPUT_FILE captured, wall_time recorded
              │
              ├─[7] Generate results/benchmark_<timestamp>/report.md
              │       Per stage: table of model | wall_time | tok_s | output_path
              │       Actual output text embedded or linked
              │
              └─[8] Print report path; prompt user to select winners:
                      "Open report.md, then run: transcribrr.sh --select-defaults"
```

**Note on stage dependency for benchmarking:** Cleanup and summarize benchmarks depend on a transcript input. The cleanest approach is to run the whisper sweep first using the sample, take the output from the current default whisper model (or the first candidate) as the fixed input for all cleanup candidates, and similarly for summarize. This isolates each stage's quality/speed independently rather than creating a full combinatorial matrix (N×M×P runs). A `--full-matrix` flag could be added later if needed.

### Default-Resolution Flow (normal pipeline run)

```
transcribrr.sh <input> [flags]
    │
    ├─[1] Parse flags → set WHISPER_MODEL, CLEANUP_MODEL, SUMMARY_MODEL
    │       (or leave at built-in literals if flag not supplied)
    │
    ├─[2] Load config/settings.conf (if exists)
    │       For each model var: if still at built-in literal → apply settings value
    │       Flag value always preserved (sentinel pattern)
    │
    ├─[3] preflight_check (unchanged)
    │
    └─[4] Pipeline stages (unchanged, consume resolved model vars)
```

### Selection / settings.conf write flow

```
Human reads results/benchmark_<ts>/report.md
    │
    └── transcribrr.sh --select-defaults
            │   (or benchmark.sh --select)
            │
            ├── Interactive: prompt "Best whisper model? [list]"
            ├── Interactive: prompt "Best cleanup model? [list]"
            ├── Interactive: prompt "Best summary model? [list]"
            │
            └── Write config/settings.conf:
                    WHISPER_MODEL_DEFAULT=<chosen>
                    CLEANUP_MODEL_DEFAULT=<chosen>
                    SUMMARY_MODEL_DEFAULT=<chosen>
```

This is intentionally interactive (it IS the human-in-the-loop step). It only runs when explicitly invoked, never during a normal pipeline run.

## Integration Points

### Exact Touch Points in Existing Scripts

The following lists every modification needed to existing files. Everything else is new files only.

#### `transcribrr.sh` — modifications required

| Location | Change |
|----------|--------|
| Flag-parsing `while` block (line 97) | Add `--benchmark`, `--sample`, `--skip-research` cases |
| After flag parsing, before `preflight_check` | Add `--benchmark` dispatch block (`exec benchmark.sh ...`) |
| After flag parsing, before `preflight_check` | Add settings.conf default-resolution block (Pattern 3) |
| Built-in defaults block (lines 14-19) | Add sentinel variables: `WHISPER_MODEL_EXPLICIT=false` etc. |
| `--whisper-model` case (line 100) | Add `WHISPER_MODEL_EXPLICIT=true` |
| `--cleanup-model` case (line 103) | Add `CLEANUP_MODEL_EXPLICIT=true` |
| `--summary-model` case (line 107) | Add `SUMMARY_MODEL_EXPLICIT=true` |
| `print_help()` (line 32) | Document `--benchmark`, `--sample`, `--skip-research`, `--select-defaults` |

**Stage scripts (`transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh`) — no modifications needed.** They already accept `--model` flags and already emit `OUTPUT_FILE=`. The `benchmark.sh` reuses the contract as-is.

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| `transcribrr.sh` → `benchmark.sh` | `exec` with forwarded flags | `exec` replaces the process; no return |
| `benchmark.sh` → stage scripts | subprocess + stdout capture (`grep "^OUTPUT_FILE="`) | Identical to existing transcribrr.sh pattern |
| `benchmark.sh` → `claude` CLI | `"$SKILL_CMD" -p "..."` subprocess | Non-blocking stderr; failure handled gracefully |
| stage scripts → `benchmark.sh` | `OUTPUT_FILE=<path>` on stdout | Existing contract; no change to stage scripts |
| `config/candidates.conf` | Parsed by `benchmark.sh` (never sourced) | Written by skill or manually |
| `config/settings.conf` | Parsed by `transcribrr.sh` (never sourced) | Written by `--select-defaults` step |

## Anti-Patterns

### Anti-Pattern 1: Sourcing config files written by the skill

**What people do:** `source config/candidates.conf` or `. config/candidates.conf` for convenience.
**Why it's wrong:** The skill (or an attacker who modifies the file) can execute arbitrary bash. A candidates file with `$(rm -rf ~)` in a model ID would run silently.
**Do this instead:** Parse with `grep`, `while read`, and `cut`. Accept only lines that match a known pattern (optional but good: validate each HF model ID against `mlx-community/*` or `*/` format before passing to stage scripts).

### Anti-Pattern 2: Inline all benchmark logic in `transcribrr.sh`

**What people do:** Add a 200-line benchmark block inside the existing 523-line `transcribrr.sh`.
**Why it's wrong:** The file becomes untestable as a unit; `set -euo pipefail` interactions with the benchmark loop (which needs to tolerate per-model failures without aborting the whole run) become a minefield.
**Do this instead:** `--benchmark` flag dispatches immediately to `benchmark.sh`. The benchmark script can set its own error-handling policy (trap per-model failures, continue to next model, log the failure to the report).

### Anti-Pattern 3: Storing benchmark results in `.planning/`

**What people do:** Write benchmark outputs to `.planning/research/` or `.planning/` because it's already a structured directory.
**Why it's wrong:** `.planning/` is version-controlled planning documentation. Benchmark results can be large (multiple model outputs per run) and are ephemeral operational data, not project docs.
**Do this instead:** `results/benchmark_<timestamp>/` at repo root, gitignored. Only `report.md` (the human-readable summary) might be worth optionally committing; that's the user's choice.

### Anti-Pattern 4: Running the full N×M×P combinatorial benchmark matrix

**What people do:** Run every whisper model × every cleanup model × every summary model.
**Why it's wrong:** With 3 candidates per stage and 3 stages, that is 27 full pipeline runs. Each run takes 10-60 minutes on real audio. The user waits hours and gains little insight (cleanup quality is mostly independent of which whisper model produced the transcript for a given sample).
**Do this instead:** Run each stage independently against a fixed input for that stage. Whisper candidates all process the same sample mp3. Cleanup candidates all process the same (one) transcript. Summarize candidates all process the same cleaned transcript. 3+3+3 = 9 stage runs instead of 27.

### Anti-Pattern 5: Interactive prompts during normal pipeline runs

**What people do:** Add "Did you want to run a benchmark? [y/N]" prompts when settings.conf is missing.
**Why it's wrong:** Breaks the `--unattended` contract that is core to v1.0. Any script or cron job piping to transcribrr.sh would hang.
**Do this instead:** If `settings.conf` is absent, silently fall through to built-in defaults. Never prompt during a normal run. The benchmark/selection workflow is explicitly invoked only when `--benchmark` or `--select-defaults` is passed.

## Scaling Considerations

This is a single-user local tool. Scaling in the traditional sense does not apply. The relevant "scaling" concern is benchmark runtime as the candidate list grows.

| Candidate count per stage | Benchmark wall time estimate | Mitigation |
|--------------------------|------------------------------|------------|
| 2-3 per stage (default) | 30-90 min for 10-min sample | Acceptable |
| 5-6 per stage | 75-225 min | Use shorter `--sample` (2-3 min clip) |
| 10+ per stage | Multi-hour | Add `--max-candidates N` flag |

**Recommendation:** The skill should produce a focused list (3-4 models per stage max), ranked by likely quality/speed. The benchmark is not a brute-force sweep; it validates the skill's curated shortlist.

## Sources

- Direct code read: `/Users/gareth/git/transcribrr/transcribrr.sh` (all patterns confirmed against actual implementation)
- Direct code read: `/Users/gareth/git/transcribrr/transcribe.sh` (OUTPUT_FILE contract, --model flag, MODEL_LABEL sanitization)
- Direct code read: `/Users/gareth/git/transcribrr/cleanup-transcript.sh` (OUTPUT_FILE contract, --model flag, HF ID passthrough)
- Direct code read: `/Users/gareth/git/transcribrr/summarize-transcript.sh` (OUTPUT_FILE contract, --model flag, --style flag)
- Direct code read: `/Users/gareth/git/transcribrr/.planning/PROJECT.md` (v2.0 requirements, constraints)

---
*Architecture research for: transcribrr v2.0 — benchmarking + model auto-selection*
*Researched: 2026-06-14*
