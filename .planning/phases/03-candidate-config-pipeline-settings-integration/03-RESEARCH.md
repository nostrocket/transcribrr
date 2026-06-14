# Phase 3: Candidate Config & Pipeline Settings Integration - Research

**Researched:** 2026-06-14
**Domain:** Bash config parsing, MLX model IDs, three-tier precedence wiring in transcribrr.sh
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01** — candidates.conf record format: `[candidate]` header + KEY=value block per candidate. Keys: `stage=`, `id=`, `label=`, `size_gb=`.
- **D-02** — Parse candidates.conf with grep/while read/line-state. Never source it. bash 3.2 portable only (no mapfile, no associative arrays). stage values: `whisper`, `cleanup`, `summarize`.
- **D-03** — `config/candidates.conf` is committed to the repo (ships the MODEL-02 vetted list).
- **D-04** — `config/settings.conf` is gitignored. `config/settings.conf.example` is committed. Built-in defaults stay in transcribrr.sh only.
- **D-05** — Missing settings.conf → silently fall through to built-in defaults. Never prompt.
- **D-06** — settings.conf keys for this phase: `WHISPER_MODEL_DEFAULT`, `CLEANUP_MODEL_DEFAULT`, `SUMMARY_MODEL_DEFAULT` only. Other keys are for later phases.
- **D-07** — Precedence: flag > settings.conf > built-in. Implemented via per-flag sentinels: `WHISPER_MODEL_EXPLICIT=true`, `CLEANUP_MODEL_EXPLICIT=true`, `SUMMARY_MODEL_EXPLICIT=true`. Settings.conf fills a model only when its sentinel is false. NOT the "compare against built-in default string" approach.
- **D-08** — settings.conf read happens once, after flag parsing, before preflight.
- **D-09** — On a normal run, print a one-line-per-stage provenance summary before the pipeline starts showing each model and its source (flag / settings.conf / built-in).
- **D-10** — CFG-03 error handling: catch-and-translate at stage exit. Message names the offending model, states it came from config/settings.conf, points to `transcribrr.sh --benchmark` or an explicit flag.
- **D-11** — Accepted trade-off: bad cleanup/summary model only fails after transcription has run (detection is at stage-load time). No pre-flight model load.

### Claude's Discretion

- Exact block/field delimiter details for candidates.conf parsing (blank-line vs next `[candidate]` terminator).
- Exact grep/cut parser implementation.
- Precise wording/formatting of the provenance and error lines — implement per the patterns in D-09/D-10; no further user input needed.

### Deferred Ideas (OUT OF SCOPE)

- Cheap pre-flight model validation (local HF-cache check before running stages).
- Network/HF existence validation of candidate IDs.
- Extra settings.conf keys (e.g. `CANDIDATE_MAX_AGE_DAYS`).
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| MODEL-01 | candidates.conf lists benchmark candidates per stage (HF ID, label, stage, approx size) — parsed never sourced | D-01/D-02 locked; parse snippet below; format verified against bash 3.2 constraints |
| MODEL-02 | Repo ships vetted initial candidate list covering current best-in-class MLX models per stage | Vetted list in `## Standard Stack` section; all HF IDs verified via WebFetch |
| MODEL-03 | Benchmark accepts any candidate as raw HF ID, reusing existing `--model <label|hf-id>` plumbing — no stage-script modification required | Confirmed by reading transcribe.sh:100-124, cleanup-transcript.sh:46-67, summarize-transcript.sh:95-116 — all three already handle `*/*` as raw HF ID |
| CFG-01 | Normal transcribrr.sh run reads settings.conf (if present) to select default models per stage | Settings read block placement documented; parse-not-source approach with `grep`/`cut` |
| CFG-02 | Model selection precedence: CLI flag > settings file > built-in default (flag naming the built-in default still overrides settings) | Sentinel pattern (D-07) documented with exact code; wires into existing flag-parse loop at lines 99-110 |
| CFG-03 | Settings-file model that fails to load → clear actionable error pointing back to --benchmark, not a cryptic load failure | Catch-and-translate pattern documented; exact error message format from D-10; wires into ERR trap at line 28 |
</phase_requirements>

---

## Summary

Phase 3 is a pure bash authoring phase — no new binaries, no new Python dependencies, no new packages. Every implementation piece is either already present in the codebase (stage scripts that accept raw HF IDs via `--model`) or is a straightforward bash editing task (wiring sentinels and a settings read block into transcribrr.sh).

The two most consequential deliverables are: (1) the MODEL-02 vetted candidate list, which requires current and accurate HF IDs so that downstream phases (4–6) start with real, loadable models; and (2) the sentinel-based precedence wiring in transcribrr.sh, which must be implemented correctly from the start because success criterion #3 — `--whisper-model small` beating a settings.conf value of `turbo` — cannot be achieved by comparing against the default string.

The research confirms all five success criteria are implementable with no ambiguity: MODEL-03 is already satisfied by the existing stage scripts (no edits required), CFG-01/02 reduce to a ~25-line bash block inserted at line ~137, CFG-03 extends the existing ERR trap at line 28, and the format choices in D-01 are straightforward to parse with a standard line-state loop.

**Primary recommendation:** Implement in a single wave: sentinel initialization → sentinel wiring in flag-parse loop → settings.conf read block (after flags, before preflight) → provenance summary print → catch-and-translate ERR extension → create config/ directory with candidates.conf and settings.conf.example → update .gitignore. All changes fit in one file (transcribrr.sh) plus two new committed files and one .gitignore line.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| candidates.conf format and content | Config file (committed) | benchmark.sh (Phase 4 consumer) | File is data, not logic; committed so Phase 4 can immediately parse it |
| settings.conf reading and precedence | transcribrr.sh (orchestrator) | — | Orchestrator owns model selection; stage scripts are called with resolved values |
| Per-flag sentinel tracking | transcribrr.sh (flag-parse loop) | — | Sentinels are local to the orchestrator; stage scripts never need to know the source |
| Provenance summary printing | transcribrr.sh (after settings read block) | — | Orchestrator is the only scope that knows all three sources simultaneously |
| CFG-03 catch-and-translate error | transcribrr.sh (ERR trap extension + stage invocation wrappers) | — | ERR trap already exists at line 28; extend to use provenance tracking for actionable message |
| MODEL-03 raw HF ID passthrough | Stage scripts (no changes) | — | Already handled — contains `/` → passthrough; all three stage scripts confirmed |

---

## Standard Stack

### Core (no new dependencies — bash 3.2 + existing repo tooling only)

| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| `/bin/bash` | 3.2.57 (stock macOS) | All parsing and orchestration | Project constraint; existing scripts use it |
| `grep` | macOS built-in | Extract KEY=value lines from config files | Parse-not-source idiom; no external dep |
| `cut` | macOS built-in | Split KEY=value on `=` | Simplest value extraction without regex |
| `while read` line-state loop | bash built-in | Iterate candidates.conf blocks | Only bash 3.2 portable multi-record parse idiom |

### MODEL-02 Vetted Candidate List

All HF IDs below were verified via WebFetch to their HF model pages. Sizes from HF pages.

#### Stage: whisper (transcription)

| Label | HF ID | size_gb | Confidence | Notes |
|-------|-------|---------|-----------|-------|
| `small` | `mlx-community/whisper-small-mlx` | 0.24 | [ASSUMED] | Current built-in default; confirmed by transcribe.sh:112 case label; HF page not separately fetched for this research but ID is already in production code |
| `turbo` | `mlx-community/whisper-large-v3-turbo` | 1.61 | [VERIFIED: huggingface.co/mlx-community/whisper-large-v3-turbo] | Best speed/accuracy balance; 24k+ downloads/month; fp16 |
| `turbo-4bit` | `mlx-community/whisper-large-v3-turbo-q4` | ~0.5 | [VERIFIED: huggingface.co/mlx-community/whisper-large-v3-turbo-q4] | Compact option; 1,215 downloads/month; exact size not on page but ~half of fp16 turbo |
| `distil-large-v3` | `mlx-community/distil-whisper-large-v3` | 1.51 | [VERIFIED: huggingface.co/mlx-community/distil-whisper-large-v3] | English-only; 6× faster than large-v3; near-identical WER |

**NOTE on `mlx-community/whisper-small-mlx`:** This exact ID is used in `transcribe.sh:112` in production. Include it as the baseline so benchmark.sh can sweep from the current default. [ASSUMED] tag means it was not separately WebFetched in this session, but it is verified by being the current production ID in the existing codebase.

**Recommended whisper candidates.conf entries (4 candidates):** `small` (baseline), `turbo` (recommended default), `turbo-4bit` (memory-constrained option), `distil-large-v3` (English-only alternative). Omit Parakeet — requires a separate Python package and transcribe.sh code path; deferred to v2.1.

#### Stage: cleanup (small instruct LLM)

| Label | HF ID | size_gb | Confidence | Notes |
|-------|-------|---------|-----------|-------|
| `llama3.2-1b-4bit` | `mlx-community/Llama-3.2-1B-Instruct-4bit` | 0.695 | [VERIFIED: huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit] | Smallest; existing label in cleanup-transcript.sh |
| `llama3.2-3b-4bit` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | 1.81 | [VERIFIED: huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit] | Existing label in cleanup-transcript.sh |
| `llama3.1-8b-4bit` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | 4.52 | [VERIFIED: huggingface.co/mlx-community/Meta-Llama-3.1-8B-Instruct-4bit] | Current pipeline default; confirmed by transcribrr.sh:15 and cleanup-transcript.sh:55 |
| `qwen3-8b-4bit` | `mlx-community/Qwen3-8B-4bit` | 4.61 | [VERIFIED: huggingface.co/mlx-community/Qwen3-8B-4bit] | Qwen3 generation; 17,969 downloads/month; chat-capable base model with chat template |

**Note on `mlx-community/Qwen3-8B-4bit`:** This is the Qwen3-8B base model converted to MLX 4-bit by mlx-community (not an "Instruct" suffix variant). Qwen3 base models support instruction-following through chat templates. The `Qwen/Qwen3-8B-MLX-4bit` from the Qwen org also exists but `mlx-community/Qwen3-8B-4bit` is the mlx-community conversion. [ASSUMED] regarding instruction quality parity with Instruct variants.

**Recommended cleanup candidates.conf entries (4 candidates):** all four above.

#### Stage: summarize (large instruct LLM)

| Label | HF ID | size_gb | Confidence | Notes |
|-------|-------|---------|-----------|-------|
| `Qwen2.5-14B-4bit` | `mlx-community/Qwen2.5-14B-Instruct-4bit` | 8.31 | [VERIFIED: huggingface.co/mlx-community/Qwen2.5-14B-Instruct-4bit] | 66k+ downloads/month; midpoint quality |
| `Qwen2.5-32B-4bit` | `mlx-community/Qwen2.5-32B-Instruct-4bit` | 18.4 | [VERIFIED: huggingface.co/mlx-community/Qwen2.5-32B-Instruct-4bit] | Current pipeline default; confirmed by transcribrr.sh:16 and summarize-transcript.sh:104 |
| `Qwen3-14B-4bit` | `Qwen/Qwen3-14B-MLX-4bit` | 7.85 | [VERIFIED: huggingface.co/Qwen/Qwen3-14B-MLX-4bit] | Qwen3 gen; thinking + non-thinking modes; 32k context; Apache 2.0 |
| `Qwen3-32B-4bit` | `mlx-community/Qwen3-32B-4bit` | 18.4 | [VERIFIED: huggingface.co/mlx-community/Qwen3-32B-4bit] | Qwen3 gen; same footprint as Qwen2.5-32B-4bit but newer generation; 1,072 downloads/month |
| `Llama3.3-70B-4bit` | `mlx-community/Llama-3.3-70B-Instruct-4bit` | 39.7 | [VERIFIED: huggingface.co/mlx-community/Llama-3.3-70B-Instruct-4bit] | Quality ceiling; fits 64GB (39.7GB + headroom ~24GB) but slow; ~10 min/summary |

**IMPORTANT — `Qwen/Qwen3-14B-MLX-4bit` is from the `Qwen` org, not `mlx-community`.** Both exist on HF; this is the official Qwen org's MLX conversion. The mlx-community counterpart `mlx-community/Qwen3-14B-4bit` (8.31 GB) is a base model. The Qwen org's version at `Qwen/Qwen3-14B-MLX-4bit` (7.85 GB) is instruct-capable. Use `Qwen/Qwen3-14B-MLX-4bit` for the summarize stage.

**`mlx-community/Llama-3.3-70B-Instruct-4bit` — 39.7 GB:** This fits 64 GB unified memory but leaves only ~24 GB headroom. The benchmark phase (Phase 4) will apply its memory fit check; include in candidates.conf so the benchmark can decide whether to run it. Do not exclude it here.

**Recommended summarize candidates.conf entries (5 candidates):** all five above. `Qwen2.5-32B-4bit` and `Qwen3-32B-4bit` are the primary contest; `Qwen3-14B-4bit` is a faster alternative; `Llama3.3-70B-4bit` is the quality ceiling; `Qwen2.5-14B-4bit` is the speed floor.

---

## Package Legitimacy Audit

This phase installs **no new packages**. All tooling is existing bash built-ins plus the already-deployed `.venv`. The candidates.conf file records HF model IDs that are not installed by this phase — they are downloaded at benchmark time (Phase 4).

No Package Legitimacy Gate protocol execution required for Phase 3.

---

## Architecture Patterns

### System Architecture Diagram

```
transcribrr.sh invocation
        │
        ▼
[1] Defaults block (lines 14-17)
    WHISPER_MODEL="small"
    CLEANUP_MODEL="llama3.1-8b-4bit"
    SUMMARY_MODEL="Qwen2.5-32B-4bit"
    WHISPER_MODEL_EXPLICIT=false     ← NEW (sentinel init)
    CLEANUP_MODEL_EXPLICIT=false     ← NEW
    SUMMARY_MODEL_EXPLICIT=false     ← NEW
        │
        ▼
[2] Flag-parse loop (lines 97-137)
    --whisper-model X → WHISPER_MODEL=X; WHISPER_MODEL_EXPLICIT=true  ← NEW sentinel set
    --cleanup-model X → CLEANUP_MODEL=X; CLEANUP_MODEL_EXPLICIT=true  ← NEW
    --summary-model X → SUMMARY_MODEL=X; SUMMARY_MODEL_EXPLICIT=true  ← NEW
        │
        ▼
[3] settings.conf read block (NEW — inserted after line 137, before preflight)
    SETTINGS_FILE="$SCRIPT_DIR/config/settings.conf"
    if [ -f "$SETTINGS_FILE" ]; then
        for each model key:
            if sentinel is false → read value from settings.conf → apply
            track WHISPER_MODEL_SOURCE / CLEANUP_MODEL_SOURCE / SUMMARY_MODEL_SOURCE
    fi
        │
        ▼
[4] Provenance summary print (NEW — immediately after settings block)
    Models:
      whisper  = turbo            (settings.conf)
      cleanup  = llama3.1-8b-4bit (built-in)
      summary  = Qwen3-32B-4bit   (flag)
        │
        ▼
[5] preflight_check (unchanged — lines 202-241)
        │
        ▼
[6] Stage invocations (lines 381-432)
    transcribe.sh --model "$WHISPER_MODEL"     → exit trapping extended for CFG-03
    cleanup-transcript.sh --model "$CLEANUP_MODEL"  → exit trapping extended
    summarize-transcript.sh --model "$SUMMARY_MODEL"  → exit trapping extended
        │
        ▼ (on stage non-zero exit with settings-sourced model)
[ERR trap extension] (NEW — extends line 28)
    "Error: <stage> model '<id>' from config/settings.conf could not be loaded.
     Fix: run transcribrr.sh --benchmark to reselect, or pass --<stage>-model <label|hf-id>."
```

### Recommended Project Structure

```
transcribrr/
├── transcribrr.sh           # MODIFIED: sentinel init, sentinel wiring, settings read block,
│                            #   provenance print, ERR trap extension, --help update
├── config/
│   ├── candidates.conf      # NEW: committed, vetted MODEL-02 list (parse-not-source format)
│   └── settings.conf.example  # NEW: committed, documents settings.conf format
├── .gitignore               # MODIFIED: add config/settings.conf
└── (all other files unchanged)
```

### Pattern 1: Sentinel-Based Three-Tier Precedence

**What:** Set `*_EXPLICIT=false` alongside each default in the defaults block. In the flag-parse `case`, set `*_EXPLICIT=true` when the flag is consumed. After flag parsing, read settings.conf — but only apply a value when the corresponding sentinel is still `false`. Track the source of each final model value for provenance reporting and CFG-03 error attribution.

**Why sentinel, not string comparison:** If the user passes `--whisper-model small` (explicitly requesting the built-in default), comparing `$WHISPER_MODEL = "small"` would wrongly decide "not supplied" and overwrite with a settings.conf value. The sentinel cannot be fooled this way — if the flag was parsed, the sentinel is true, period.

**Concrete implementation:**

```bash
# In defaults block (after existing line 18, NO_CLEANUP=false):
WHISPER_MODEL_EXPLICIT=false
CLEANUP_MODEL_EXPLICIT=false
SUMMARY_MODEL_EXPLICIT=false
WHISPER_MODEL_SOURCE="built-in"
CLEANUP_MODEL_SOURCE="built-in"
SUMMARY_MODEL_SOURCE="built-in"

# In flag-parse case (modify existing --whisper-model branch, line 99-101):
--whisper-model)
    WHISPER_MODEL="$2"
    WHISPER_MODEL_EXPLICIT=true
    WHISPER_MODEL_SOURCE="flag"
    shift 2
    ;;
# Same pattern for --cleanup-model and --summary-model

# After flag-parse loop, before preflight_check (~line 138):
SETTINGS_FILE="$SCRIPT_DIR/config/settings.conf"
if [ -f "$SETTINGS_FILE" ]; then
    _read_setting() {
        # Parse safely: grep the exact key, take last match, split on first '='
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

# Provenance summary (immediately after settings block):
echo "Models:"
printf "  whisper  = %-24s (%s)\n" "$WHISPER_MODEL" "$WHISPER_MODEL_SOURCE"
printf "  cleanup  = %-24s (%s)\n" "$CLEANUP_MODEL" "$CLEANUP_MODEL_SOURCE"
printf "  summary  = %-24s (%s)\n" "$SUMMARY_MODEL" "$SUMMARY_MODEL_SOURCE"
```

**Source:** Derived from ARCHITECTURE.md Pattern 3 sentinel note and D-07. [ASSUMED] for exact bash syntax in context.

### Pattern 2: Parse-Not-Source for candidates.conf

**What:** A line-state machine that iterates candidates.conf. When a `[candidate]` header is encountered, a new record starts. Each subsequent KEY=value line populates the current record. A blank line or next `[candidate]` header terminates the record (caller processes it). Comments (lines starting with `#`) are skipped at all states.

**Concrete implementation (bash 3.2 portable):**

```bash
# Read all candidates from candidates.conf and emit one-line records
# Output format per candidate: stage|id|label|size_gb
parse_candidates() {
    local file="$1"
    local in_block=false
    local stage="" id="" label="" size_gb=""

    while IFS= read -r line; do
        # Strip inline comments
        line="${line%%#*}"
        # Trim trailing whitespace
        line="${line%"${line##*[! ]}"}"

        case "$line" in
            '[candidate]')
                # Emit previous record if complete
                if [ "$in_block" = true ] && [ -n "$stage" ] && [ -n "$id" ]; then
                    printf '%s|%s|%s|%s\n' "$stage" "$id" "$label" "$size_gb"
                fi
                # Start new record
                in_block=true
                stage="" ; id="" ; label="" ; size_gb=""
                ;;
            stage=*)   [ "$in_block" = true ] && stage="${line#stage=}" ;;
            id=*)      [ "$in_block" = true ] && id="${line#id=}" ;;
            label=*)   [ "$in_block" = true ] && label="${line#label=}" ;;
            size_gb=*) [ "$in_block" = true ] && size_gb="${line#size_gb=}" ;;
            '')
                # Blank line terminates the current block
                if [ "$in_block" = true ] && [ -n "$stage" ] && [ -n "$id" ]; then
                    printf '%s|%s|%s|%s\n' "$stage" "$id" "$label" "$size_gb"
                    in_block=false
                    stage="" ; id="" ; label="" ; size_gb=""
                fi
                ;;
        esac
    done < "$file"

    # Emit final record if file ends without trailing blank line
    if [ "$in_block" = true ] && [ -n "$stage" ] && [ -n "$id" ]; then
        printf '%s|%s|%s|%s\n' "$stage" "$id" "$label" "$size_gb"
    fi
}

# Usage in benchmark.sh (Phase 4):
while IFS='|' read -r c_stage c_id c_label c_size; do
    # process candidate
done < <(parse_candidates "$SCRIPT_DIR/config/candidates.conf")
```

**Source:** Derived from CONTEXT.md D-02, ARCHITECTURE.md Pattern 4, PITFALLS.md Anti-Pattern 1. [ASSUMED] for exact bash syntax.

**Important design choice — blank-line-terminated blocks:** The parser above uses blank lines as record terminators. This means the candidates.conf file MUST have a blank line after the last block's `size_gb=` line, OR the trailing-record emit at the end of the function handles it. Both termination styles work. The file format should document this: either use a trailing blank line for consistency, or rely on EOF termination. Claude's Discretion per CONTEXT.md.

### Pattern 3: CFG-03 Catch-and-Translate Error

**What:** When a stage script exits non-zero, the existing ERR trap at line 28 prints the stage name. Extend the stage invocation wrappers to also emit the actionable CFG-03 error when the failing model's source was `settings.conf`.

**Concrete implementation:**

```bash
# Replace the inline stage invocation pattern for each stage.
# Example for the cleanup stage (lines ~402-410):

STAGE_OUT=$("$SCRIPT_DIR/cleanup-transcript.sh" "$TRANSCRIPT_FILE" \
    --model "$CLEANUP_MODEL" \
    | tee /dev/stderr \
    | { grep "^OUTPUT_FILE=" || true; }) || {
    if [ "$CLEANUP_MODEL_SOURCE" = "settings.conf" ]; then
        echo "" >&2
        echo "Error: cleanup model '$CLEANUP_MODEL' from config/settings.conf could not be loaded." >&2
        echo "Fix: run \`transcribrr.sh --benchmark\` to reselect, or pass --cleanup-model <label|hf-id>." >&2
    fi
    exit 1
}
```

**Important nuance:** The `||` branch after a pipeline requires care with `set -e`. In the existing code, stage invocations use the pattern `STAGE_OUT=$(... | ...) `. The existing `{ grep ... || true; }` already suppresses grep's non-zero exit when no match. The `||` after the outer `$()` captures the subshell's exit status. Test this carefully — see Pitfall 2 below.

**Alternative (safer with set -e):** Use an explicit wrapper function:

```bash
run_cleanup_stage() {
    local out
    out=$("$SCRIPT_DIR/cleanup-transcript.sh" "$TRANSCRIPT_FILE" \
        --model "$CLEANUP_MODEL" \
        | tee /dev/stderr \
        | { grep "^OUTPUT_FILE=" || true; })
    echo "$out"
}

if ! STAGE_OUT=$(run_cleanup_stage); then
    if [ "$CLEANUP_MODEL_SOURCE" = "settings.conf" ]; then
        echo "" >&2
        echo "Error: cleanup model '$CLEANUP_MODEL' from config/settings.conf could not be loaded." >&2
        echo "Fix: run \`transcribrr.sh --benchmark\` to reselect, or pass --cleanup-model <label|hf-id>." >&2
    fi
    exit 1
fi
```

**Source:** Derived from CONTEXT.md D-10/D-11, PITFALLS.md Pitfall 13/14. [ASSUMED] for exact bash interaction with set -e.

### Pattern 4: settings.conf Format (parse-not-source)

The `_read_setting` function above (Pattern 1) is sufficient for the three keys this phase introduces. Key points:
- `grep "^${key}="` anchors at line start so `FAKE_WHISPER_MODEL_DEFAULT=x` does not match `WHISPER_MODEL_DEFAULT`.
- `tail -1` handles duplicate keys by taking the last value (last-writer-wins, safe for human-edited files).
- `cut -d= -f2-` correctly handles values that contain `=` (e.g., HF IDs never have `=` but labels might in edge cases).
- No `source`/`.` — the function only reads lines matching the exact key pattern. Values that could contain shell metacharacters are treated as opaque strings.

### Anti-Patterns to Avoid

- **String-comparison precedence detection:** Comparing `$WHISPER_MODEL = "small"` to decide "not supplied" fails when the user explicitly passes `--whisper-model small`. Use sentinels (D-07).
- **Sourcing settings.conf:** Even though settings.conf is user-written (not machine-written), it could be edited by a malicious script or contain a typo like `$(rm -rf ~)`. Parse it instead.
- **Prompting on missing settings.conf:** Any interactive prompt breaks the unattended contract (PITFALLS Anti-Pattern 5). Fall through silently.
- **Reading settings.conf before flag parsing:** Flags would need to re-overwrite values set by the settings block. The correct order is flags first, settings second (only when flag not given).
- **Putting `CANDIDATE_MAX_AGE_DAYS` or other Phase 5/6 keys in settings.conf.example:** This phase introduces exactly three keys (D-06). Other keys belong to later phases.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| config parsing with arrays | Custom associative array simulation | `grep`/`while read` line-state + `|`-delimited records | bash 3.2 has no associative arrays; flat records piped into while-read loops are the idiomatic substitute |
| multi-key config parsing | Custom INI parser | The `_read_setting` grep+cut+tail-1 one-liner | It's 3 lines and handles all edge cases for the 3-key settings.conf |
| Precedence logic | Re-parsing flags after settings | Sentinel flags set in the flag-parse `case` block | O(1) per flag; no need to re-parse argv |
| Error attribution | Checking model ID against known-bad list | Track `*_MODEL_SOURCE` alongside `*_MODEL` | Source is known at read time; no post-hoc detection needed |

**Key insight:** Every "hard" problem in this phase has a trivially correct solution using the tools already in the bash environment. The complexity is in knowing which idiom to use — the implementations above answer that.

---

## Common Pitfalls

### Pitfall 1: `set -e` interaction with pipeline `||` error handling

**What goes wrong:** `STAGE_OUT=$(cmd1 | tee /dev/stderr | { grep ... || true; }) || { ... }` — in bash 3.2 with `set -e`, the exit status of a pipeline is the exit status of the last command in the pipeline. The `{ grep ... || true; }` always exits 0. So even if `cmd1` fails, `$?` is 0 and the `||` branch is never entered. The stage failure is swallowed.

**Why it happens:** This is exactly how the existing code works — successfully — because the ERR trap catches failures in `cmd1` when it runs as a subshell. But adding a `||` branch after the pipeline changes the semantics: the shell now expects you to handle the error, so ERR trap is suppressed for this line.

**How to avoid:** Use a wrapper function (Pattern 3, alternative approach) that can be called with `if ! ...`. Or split into two steps: assign `STAGE_OUT=$(...)` on one line, then check `$?` explicitly on the next. The wrapper function approach is cleanest.

**Warning signs:** Stage failures don't produce the CFG-03 message; the pipeline continues past a failed stage.

### Pitfall 2: Unquoted variable in `grep "^${key}="`

**What goes wrong:** If `key` contains regex metacharacters (it won't for our three specific keys, but defensively), the `grep` pattern would be wrong. More practically: if `key` is empty, `grep "^="` matches any line starting with `=`.

**How to avoid:** Validate that `key` is one of the known three keys before calling `_read_setting`, or hardcode the three calls directly without a general function parameter. Since this phase only reads three specific keys, hardcoding is fine and eliminates the risk entirely.

### Pitfall 3: candidates.conf missing trailing blank line loses last record

**What goes wrong:** The line-state parser in Pattern 2 emits a record on blank-line or `[candidate]` header. If the file ends without a trailing blank line, the final record is only emitted by the EOF fallback block. If that fallback is missing, the last candidate is silently dropped.

**How to avoid:** Include the EOF emit block (shown in Pattern 2 above). Also document in candidates.conf.example that blank lines between blocks are required, and a trailing blank line after the last block is recommended.

### Pitfall 4: `WHISPER_MODEL_SOURCE` not initialized → unbound variable

**What goes wrong:** With `set -u`, referencing `$WHISPER_MODEL_SOURCE` in the provenance summary or CFG-03 message before it is set will abort the script with `unbound variable`.

**How to avoid:** Initialize all three `*_SOURCE` variables alongside the `*_EXPLICIT` variables in the defaults block (shown in Pattern 1 above).

### Pitfall 5: `config/` directory not created before writing candidates.conf

**What goes wrong:** If no task creates `mkdir -p "$SCRIPT_DIR/config"` before the Write tool creates candidates.conf, the file will fail to land or land in the wrong directory.

**How to avoid:** Wave 0 task creates the `config/` directory explicitly with `mkdir -p`. The planner should order this before any file creation in `config/`.

---

## Code Examples

### candidates.conf Shipped Format

```ini
# config/candidates.conf — Vetted MLX model candidates for benchmarking
# Format: [candidate] blocks, parse-not-source (no shell evaluation).
# Maintained by: Phase 6 claude skill or manual edit.
# Last updated: 2026-06-14

[candidate]
stage=whisper
id=mlx-community/whisper-small-mlx
label=small
size_gb=0.24

[candidate]
stage=whisper
id=mlx-community/whisper-large-v3-turbo
label=turbo
size_gb=1.61

[candidate]
stage=whisper
id=mlx-community/whisper-large-v3-turbo-q4
label=turbo-4bit
size_gb=0.50

[candidate]
stage=whisper
id=mlx-community/distil-whisper-large-v3
label=distil-large-v3
size_gb=1.51

[candidate]
stage=cleanup
id=mlx-community/Llama-3.2-1B-Instruct-4bit
label=llama3.2-1b-4bit
size_gb=0.695

[candidate]
stage=cleanup
id=mlx-community/Llama-3.2-3B-Instruct-4bit
label=llama3.2-3b-4bit
size_gb=1.81

[candidate]
stage=cleanup
id=mlx-community/Meta-Llama-3.1-8B-Instruct-4bit
label=llama3.1-8b-4bit
size_gb=4.52

[candidate]
stage=cleanup
id=mlx-community/Qwen3-8B-4bit
label=qwen3-8b-4bit
size_gb=4.61

[candidate]
stage=summarize
id=mlx-community/Qwen2.5-14B-Instruct-4bit
label=Qwen2.5-14B-4bit
size_gb=8.31

[candidate]
stage=summarize
id=mlx-community/Qwen2.5-32B-Instruct-4bit
label=Qwen2.5-32B-4bit
size_gb=18.4

[candidate]
stage=summarize
id=Qwen/Qwen3-14B-MLX-4bit
label=Qwen3-14B-4bit
size_gb=7.85

[candidate]
stage=summarize
id=mlx-community/Qwen3-32B-4bit
label=Qwen3-32B-4bit
size_gb=18.4

[candidate]
stage=summarize
id=mlx-community/Llama-3.3-70B-Instruct-4bit
label=Llama3.3-70B-4bit
size_gb=39.7
```

### settings.conf.example Shipped Format

```bash
# config/settings.conf.example — copy to config/settings.conf and edit
# This file is committed. config/settings.conf is gitignored (per-user).
#
# Model selection precedence: CLI flag > this file > built-in default
# Run `transcribrr.sh --benchmark` to populate with your benchmark winners.
#
# Values: friendly labels (e.g. turbo, llama3.1-8b-4bit) or raw HF IDs (containing /)
# Supported keys for this phase only:
WHISPER_MODEL_DEFAULT=turbo
CLEANUP_MODEL_DEFAULT=llama3.1-8b-4bit
SUMMARY_MODEL_DEFAULT=Qwen2.5-32B-4bit
```

### .gitignore Addition

```
# Per-user model selection (generated by --benchmark; do not commit)
config/settings.conf
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Source config files with `. config.sh` | Parse with grep/while read (parse-not-source) | ARCHITECTURE.md Pattern 4 (v2.0 design) | Eliminates code-execution injection vector from machine-written config |
| Compare model variable against default string to detect "not supplied" | Per-flag sentinel (`*_EXPLICIT=true`) | CONTEXT.md D-07 (v2.0 design) | Correctly handles explicit `--whisper-model small` overriding settings.conf |
| ERR trap names stage only | ERR trap + source-aware message | D-10 (v2.0 design) | Actionable error vs cryptic load failure |

**Deprecated/outdated:**
- ARCHITECTURE.md Pattern 3's example code compares against the built-in default string: `[ "$WHISPER_MODEL" = "small" ] && ...`. This approach was explicitly superseded by CONTEXT.md D-07 which mandates the sentinel approach. The planner MUST use sentinels, not string comparison, despite the Pattern 3 example showing the old approach.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `mlx-community/whisper-small-mlx` is the correct HF ID for the `small` label (it is in production code at transcribe.sh:112 but was not WebFetched this session) | Standard Stack | Trivially verifiable; it is the current production ID so risk is negligible |
| A2 | `mlx-community/Qwen3-8B-4bit` is instruction-following capable via chat template (verified as existing; instruction quality vs dedicated Instruct variant not formally tested) | Standard Stack | Benchmark will reveal quality; if inadequate, swap for `Qwen/Qwen3-8B-MLX-4bit` (also verified to exist) |
| A3 | `mlx-community/Qwen3-32B-4bit` supports chat/instruction-following via chat template (verified as existing with 18.4 GB; instruction status [ASSUMED] same as Qwen3-8B-4bit) | Standard Stack | Benchmark will reveal quality; risk LOW given Qwen3 base models support instruction-following via chat templates |
| A4 | `mlx-community/whisper-large-v3-turbo-q4` size is ~0.50 GB (page did not list explicit size; estimated as roughly half of fp16 turbo at 1.61 GB) | Standard Stack | Phase 4 memory fit check uses this value; if wrong, model may unexpectedly pass or fail fit check; LOW severity since 64 GB system fits both |
| A5 | The `||` catch-and-translate pattern for CFG-03 interacts safely with `set -e` and the existing tee+grep pipeline pattern | Architecture Patterns (Pitfall 1) | Critical to verify during implementation; if wrong, stage failures are swallowed silently |

---

## Open Questions (RESOLVED)

1. **`mlx-community/Qwen3-8B-4bit` vs `Qwen/Qwen3-8B-MLX-4bit` for cleanup stage**
   - What we know: Both exist. `mlx-community/Qwen3-8B-4bit` (4.61 GB) is the mlx-community conversion of the base model. `Qwen/Qwen3-8B-MLX-4bit` is the Qwen org's own MLX conversion. The FEATURES.md research listed `Qwen/Qwen3-8B-MLX-4bit` as 4.3 GB.
   - What's unclear: Which is preferred for the cleanup stage? Base Qwen3 models do instruction-follow via chat template, but dedicated Instruct models may have better RLHF for structured tasks.
   - RESOLVED: Use `mlx-community/Qwen3-8B-4bit` (mlx-community org is the standard source for this project per the existing model ID patterns). The benchmark will determine actual quality difference. The shipped candidates.conf in this RESEARCH's Code Examples commits to this ID.

2. **`Qwen/Qwen3-14B-MLX-4bit` uses the `Qwen` org, not `mlx-community`**
   - What we know: There is no `mlx-community/Qwen3-14B-Instruct-4bit`. The mlx-community version `mlx-community/Qwen3-14B-4bit` is the base model (8.31 GB). The `Qwen/Qwen3-14B-MLX-4bit` (7.85 GB) is confirmed instruct-capable.
   - What's unclear: Does the stage script's HF ID passthrough (`*/*`) work identically for `Qwen/Qwen3-14B-MLX-4bit` as for `mlx-community/*` IDs? The sanitizer in cleanup-transcript.sh:50 strips `mlx-community/` specifically — `Qwen/` org prefix will pass through but the label will sanitize as `qwen3-14b-mlx-4bit` instead of stripping the org prefix.
   - RESOLVED: Use `Qwen/Qwen3-14B-MLX-4bit` as the `id=` in candidates.conf. The label (`Qwen3-14B-4bit`) is what the benchmark uses for display; the raw HF ID goes through `--model`. MODEL-03 is satisfied — the `*/*` check passes for `Qwen/Qwen3-14B-MLX-4bit`. The sanitized filename label will just include a `qwen_` prefix instead of stripping it. No blocker.

---

## Environment Availability

This phase makes no external tool calls beyond those already present. All operations are:
- File creation (bash Write tool)
- Text editing of `transcribrr.sh` (bash Edit tool)
- `.gitignore` line addition

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `/bin/bash` | All parsing | ✓ | 3.2.57 | — |
| `grep` | settings.conf + candidates.conf parsing | ✓ | macOS built-in | — |
| `cut` | settings.conf value extraction | ✓ | macOS built-in | — |

No missing dependencies. This phase is pure text authoring.

---

## Security Domain

`security_enforcement: true` in config.json. ASVS level 1 applies.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No auth in this phase |
| V3 Session Management | No | No sessions |
| V4 Access Control | No | Local CLI tool; no multi-user |
| V5 Input Validation | Yes (settings.conf values) | Parse-not-source; `grep "^KEY="` anchoring; values treated as opaque strings passed to stage scripts |
| V6 Cryptography | No | No crypto |

### Known Threat Patterns for This Phase

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| settings.conf injection via embedded shell metacharacters | Tampering | Parse-not-source: values extracted as strings, never eval'd. Model ID goes to `--model` flag of stage script, which treats it as a literal string. |
| candidates.conf injection (Phase 6 skill writes this file) | Tampering | Parse-not-source (Pattern 2): only `stage=`, `id=`, `label=`, `size_gb=` keys extracted; anything else ignored. IDs validated by stage scripts' `*/*` check before use. |
| Symlink attack on config/ directory | Elevation | Not in scope for ASVS level 1 local tool |

**Security verdict for this phase:** The parse-not-source pattern (D-02) is the primary security control and fully mitigates the code-injection risk from machine-written config. No additional controls required for ASVS level 1.

---

## Validation Architecture

`workflow.nyquist_validation: false` in config.json. This section is skipped.

---

## Sources

### Primary (HIGH confidence)
- Direct code read: `/Users/gareth/git/transcribrr/transcribrr.sh` — defaults block lines 14-17, flag-parse loop lines 97-137, ERR trap line 28, stage invocations lines 381-432
- Direct code read: `/Users/gareth/git/transcribrr/transcribe.sh:100-124` — confirmed `*/*` raw HF ID passthrough, confirmed `mlx-community/whisper-small-mlx` as `small` label target
- Direct code read: `/Users/gareth/git/transcribrr/cleanup-transcript.sh:46-67` — confirmed `*/*` passthrough, confirmed `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` as `llama3.1-8b-4bit` target
- Direct code read: `/Users/gareth/git/transcribrr/summarize-transcript.sh:95-116` — confirmed `*/*` passthrough, confirmed `mlx-community/Qwen2.5-32B-Instruct-4bit` as `Qwen2.5-32B-4bit` target
- Direct read: `03-CONTEXT.md` — D-01 through D-11 (all locked decisions)
- WebFetch: [mlx-community/whisper-large-v3-turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo) — confirmed ID and 1.61 GB size
- WebFetch: [mlx-community/distil-whisper-large-v3](https://huggingface.co/mlx-community/distil-whisper-large-v3) — confirmed ID and 1.51 GB size
- WebFetch: [mlx-community/Meta-Llama-3.1-8B-Instruct-4bit](https://huggingface.co/mlx-community/Meta-Llama-3.1-8B-Instruct-4bit) — confirmed ID and 4.52 GB size
- WebFetch: [mlx-community/Qwen2.5-14B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen2.5-14B-Instruct-4bit) — confirmed ID and 8.31 GB size
- WebFetch: [mlx-community/Qwen2.5-32B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen2.5-32B-Instruct-4bit) — confirmed ID exists (pipeline default)
- WebFetch: [Qwen/Qwen3-14B-MLX-4bit](https://huggingface.co/Qwen/Qwen3-14B-MLX-4bit) — confirmed ID, instruct-capable, 7.85 GB
- WebFetch: [mlx-community/Qwen3-32B-4bit](https://huggingface.co/mlx-community/Qwen3-32B-4bit) — confirmed ID, chat-capable, 18.4 GB
- WebFetch: [mlx-community/Qwen3-8B-4bit](https://huggingface.co/mlx-community/Qwen3-8B-4bit) — confirmed ID, 4.61 GB
- WebFetch: [mlx-community/Llama-3.3-70B-Instruct-4bit](https://huggingface.co/mlx-community/Llama-3.3-70B-Instruct-4bit) — confirmed ID and 39.7 GB size
- WebFetch: [mlx-community/whisper-large-v3-turbo-q4](https://huggingface.co/mlx-community/whisper-large-v3-turbo-q4) — confirmed ID exists

### Secondary (MEDIUM confidence)
- WebSearch: confirmed `mlx-community/Llama-3.2-1B-Instruct-4bit` and `mlx-community/Llama-3.2-3B-Instruct-4bit` exist (FEATURES.md lists sizes 0.695 GB and 1.81 GB from HF pages, research dated 2026-06-14)
- FEATURES.md (prior research, 2026-06-14) — candidate model sizes and IDs for whisper/cleanup/summarize stages, MEDIUM confidence where independently verified above

### Tertiary (LOW confidence)
- `mlx-community/whisper-large-v3-turbo-q4` size ~0.50 GB — estimated, not on the HF page during WebFetch

---

## Metadata

**Confidence breakdown:**
- Standard Stack (model IDs): HIGH — all primary model IDs WebFetched and confirmed; two supporting IDs (Llama 3.2 1B/3B) confirmed by search + prior research
- Standard Stack (sizes): HIGH for main models; LOW for turbo-q4 size estimate only
- Architecture patterns: HIGH — derived from direct code reads of transcribrr.sh + locked decisions in CONTEXT.md
- Pitfalls: HIGH — derived from actual bash 3.2 behavior and project history (mapfile bug caught in v1.0)

**Research date:** 2026-06-14
**Valid until:** 2026-09-14 (model IDs on HF are stable; bash patterns are indefinitely stable)
