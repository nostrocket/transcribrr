# Stack Research

**Domain:** Local MLX pipeline benchmarking & auto-selection (bash + Python, Apple Silicon)
**Researched:** 2026-06-14
**Confidence:** HIGH — all facts verified against installed package source and CLI behavior

---

## What This Research Covers

Stack additions needed for v2.0: `--benchmark` mode, a settings file, and a Claude skill that auto-launches headlessly to refresh the model candidate list. The existing stack (bash 3.2, mlx-lm 0.31.3, mlx 0.31.2, huggingface_hub 1.19.0, `.venv`) is already deployed and working; this document covers only what changes.

---

## Recommended Stack

### Core Technologies

| Technology | Installed Version | Purpose | Why Recommended |
|------------|------------------|---------|-----------------|
| `mlx_lm.generate(verbose=True)` | mlx-lm 0.31.3 (in `.venv`) | LLM stage benchmarking — real token counts + tps + peak memory | Already installed; `verbose=True` prints `Prompt: N tokens, X.XXX tokens-per-sec`, `Generation: N tokens, X.XXX tokens-per-sec`, `Peak memory: X.XXX GB` all to stdout — directly greppable from a wrapper Python script. No new dep. |
| `mlx_lm.benchmark` CLI | mlx-lm 0.31.3 (in `.venv`) | Synthetic throughput benchmark for LLM models using random tokens | Built into existing install; outputs `prompt_tps=X, generation_tps=X, peak_memory=X` — useful for quick model-to-model comparison without needing a real transcript. |
| `mx.device_info()` | mlx 0.31.2 (in `.venv`) | Get total unified memory and max recommended working set for fit check | Returns `{'memory_size': 68719476736, 'max_recommended_working_set_size': 55662788608}` — the `max_recommended_working_set_size` (~52GB on M2 Max 64GB) is the right threshold for "will this model fit without swapping". Call once at benchmark start. |
| `mlx-whisper` | 0.4.3 (NOT in `.venv` — needs install) | Whisper transcription stage; `mlx_whisper` CLI binary used by `transcribe.sh` | `transcribe.sh` expects `.venv/bin/mlx_whisper` but it is missing from the current `.venv`. Must be installed to run the transcription benchmark stage. See dependency note below. |
| `/usr/bin/time -l` | macOS built-in | Peak RSS measurement for the Whisper stage from bash | MLX's own `mx.get_peak_memory()` is the best option when running Python inline; `/usr/bin/time -l` is the fallback for timing an external process. Output field: `maximum resident set size` (in bytes). Parse with `awk '/maximum resident/{print $1}'`. |
| `sysctl hw.memsize` | macOS built-in | Get total unified memory (bytes) for fit check from bash | `sysctl hw.memsize` returns the correct 64GB (`68719476736`) on Apple Silicon. Used in bash when not in a Python context. Divide by `1073741824` for GB via `bc`. |
| `hf models ls` | huggingface_hub 1.19.0 (`hf` binary in `.venv/bin`) | Query mlx-community models from HF Hub for candidate-list skill | `hf models ls --author mlx-community --search whisper --sort downloads --limit 20` — outputs tab-delimited id/downloads/tags to stdout, machine-parseable. The old `huggingface-cli` is deprecated; `hf` is its replacement and is already installed. |
| `claude` CLI | installed on PATH | Auto-launch skill headlessly from benchmark script | `claude -p "/skill-name <args>" --permission-mode bypassPermissions --no-session-persistence` — see headless invocation section. |
| Sourced `.sh` settings file | bash 3.2 built-in | Persist winning model choices per stage | Plain `KEY=value` file sourced with `. settings.sh` — works in bash 3.2, no extra tools, human-readable, trivially written from a bash script with `printf`. |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `mlx.core` (`mx`) | 0.31.2 | `mx.device_info()` for memory sizing; `mx.get_peak_memory()` for LLM peak memory in Python | Use in the Python benchmark helper script called from the bash orchestrator |
| `python3` (system) | 3.11.6 | JSON parsing of HF API responses if needed; numeric calculations | Already on PATH; use when `bc` precision is insufficient or when parsing structured data |
| `bc` | macOS built-in | RTF calculation: `echo "scale=3; $WALL_TIME / $AUDIO_DURATION" \| bc` | Already used in `transcribe.sh`; same pattern for RTF and tok/s calculations |
| `ffmpeg` | brew-installed | Audio duration extraction for RTF denominator | Already required by `transcribrr.sh`; `ffmpeg -i <file> 2>&1 \| awk '/Duration/{print $2}'` — identical to existing code in `transcribe.sh` |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| `mlx_lm.benchmark` CLI | Standalone synthetic LLM throughput measurement | Run as `.venv/bin/mlx_lm.benchmark --model <hf-id> --num-trials 3` — outputs `Averages: prompt_tps=X, generation_tps=X, peak_memory=X` in one line, greppable |
| `.venv/bin/hf` | HF Hub model search for Claude skill | `hf models ls --author mlx-community --search <term> --sort downloads --limit 20 --expand downloads,tags` — tab-delimited output, pipeable to `awk`/`grep` in bash |

---

## Key Integration Points

### 1. Memory Fit Check — Two Approaches

**From Python** (preferred for LLM benchmark helpers):
```python
import mlx.core as mx
info = mx.device_info()
total_gb = info['memory_size'] / 1e9            # 68.7 on M2 Max 64GB
fit_limit_gb = info['max_recommended_working_set_size'] / 1e9  # ~52GB
peak_gb = mx.get_peak_memory() / 1e9
fits = peak_gb < fit_limit_gb
```
`mx.device_info()` is the non-deprecated form (replaces `mx.metal.device_info()`). `mx.get_peak_memory()` resets to zero at Python process start — call after model load + generate, not before.

**From bash** (for the orchestrator or Whisper stage):
```bash
TOTAL_MEM_BYTES=$(sysctl -n hw.memsize)    # 68719476736 on 64GB M2 Max
TOTAL_MEM_GB=$(echo "scale=1; $TOTAL_MEM_BYTES / 1073741824" | bc)
# For Whisper stage RSS via /usr/bin/time -l:
TIME_OUTPUT=$( { /usr/bin/time -l "$SCRIPT_DIR/.venv/bin/mlx_whisper" ... ; } 2>&1 )
PEAK_RSS_BYTES=$(echo "$TIME_OUTPUT" | awk '/maximum resident/{print $1}')
PEAK_RSS_GB=$(echo "scale=2; $PEAK_RSS_BYTES / 1073741824" | bc)
```
Note: `/usr/bin/time -l` writes its stats to **stderr**. The `2>&1` redirect is required to capture them alongside stdout. "maximum resident set size" is in bytes on macOS arm64.

### 2. LLM Stage Timing — Python verbose=True

The existing scripts call `generate(..., verbose=False)`. For benchmarking, change to `verbose=True`. When `verbose=True`, `mlx_lm.generate()` prints the following to **stdout**:

```
==========
<generated text>
==========
Prompt: 512 tokens, 145.678 tokens-per-sec
Generation: 1024 tokens, 48.234 tokens-per-sec
Peak memory: 18.432 GB
```

Parse from a wrapper:
```bash
OUTPUT=$(.venv/bin/python bench_llm.py --model "$MODEL" --prompt-file "$SAMPLE")
GEN_TPS=$(echo "$OUTPUT" | grep "^Generation:" | grep -o '[0-9.]*tokens-per-sec' | grep -o '^[0-9.]*')
PEAK_MEM=$(echo "$OUTPUT" | grep "^Peak memory:" | awk '{print $3}')
```

Or use `mlx_lm.benchmark` for a quicker synthetic test (no real sample needed):
```bash
.venv/bin/mlx_lm.benchmark --model "$HF_ID" --num-trials 3 --prompt-tokens 512 --generation-tokens 512 \
    | grep "^Averages:" \
    | sed 's/.*generation_tps=\([0-9.]*\).*/\1/'
```
`mlx_lm.benchmark` output: `Averages: prompt_tps=XXX.XXX, generation_tps=XXX.XXX, peak_memory=XX.XXX`

### 3. Whisper RTF — Derive from Wall Time + Audio Duration

`mlx_whisper` does NOT output RTF or elapsed time. Its `--verbose True` output is segment timestamps (`[HH:MM:SS.mmm --> HH:MM:SS.mmm] text`) — which `transcribe.sh` already monitors for progress. RTF is computed externally:

```bash
AUDIO_DURATION_S=$(ffmpeg -i "$AUDIO_FILE" 2>&1 | awk '/Duration/{split($2,a,":");print a[1]*3600+a[2]*60+a[3]}')
START_T=$(date +%s)
.venv/bin/mlx_whisper "$AUDIO_FILE" --model "$MODEL" --output-format txt ...
WALL_T=$(( $(date +%s) - START_T ))
RTF=$(echo "scale=3; $WALL_T / $AUDIO_DURATION_S" | bc)   # <1.0 = faster than real-time
```
RTF < 1.0 means faster than real-time (good). RTF > 1.0 means slower. A 60-minute audio at RTF=0.3 takes ~18 minutes to transcribe.

For peak memory of the Whisper stage, wrap with `/usr/bin/time -l` as shown in section 1.

### 4. Headless Claude Invocation

Launch a named skill non-interactively from a bash script:

```bash
SKILL_OUTPUT=$(claude -p "/mlx-model-scout" \
    --permission-mode bypassPermissions \
    --no-session-persistence \
    --output-format text \
    2>&1)
EXIT_CODE=$?
```

Flags:
- `-p` / `--print` — non-interactive, print response and exit. Required.
- `--permission-mode bypassPermissions` — no interactive permission prompts. Required for unattended runs.
- `--no-session-persistence` — do not write session to disk.
- `--output-format text` — plain text output (default; explicit for clarity).
- Skill invocations are `/skill-name` as the prompt argument.

`claude` exits 0 on success. Capture stdout for the skill's output. The `ANTHROPIC_API_KEY` env var must be set (OAuth/keychain is not read in `--bare` or non-interactive modes).

For the benchmark script, confirm API key is present before launching:
```bash
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "Error: ANTHROPIC_API_KEY must be set to run the model-scout skill." >&2
    exit 1
fi
```

### 5. Claude Skill Structure

A skill lives at `.claude/skills/<name>/SKILL.md` with YAML frontmatter:

```markdown
---
name: mlx-model-scout
description: "Research current best mlx-community models per stage and write candidate config"
allowed-tools:
  - Read
  - Write
  - Bash
---

<objective>
Research HF Hub for current top mlx-community models for whisper/cleanup/summary stages.
Write vetted candidate lists to .benchmark/candidates.sh.
</objective>
```

The `allowed-tools` list must include `Bash` (for running `hf models ls`), `Write` (to write the candidate config), and `Read`. Keep it minimal — no `Edit`, no `Agent`, no `AskUserQuestion` for a headless skill.

Place at `/Users/gareth/git/transcribrr/.claude/skills/mlx-model-scout/SKILL.md` (project-local skill directory).

### 6. Settings File Format

Use a sourced bash `.sh` file, not JSON. Rationale: works in bash 3.2 with no tools; written with `printf` from bash; read with `. settings.sh`; human-editable.

```bash
# .transcribrr-settings.sh — written by benchmark; read by transcribrr.sh
WHISPER_MODEL="turbo"
CLEANUP_MODEL="llama3.2-3b-4bit"
SUMMARY_MODEL="Qwen2.5-14B-4bit"
# Updated: 2026-06-14 by benchmark
```

Write from bash:
```bash
printf 'WHISPER_MODEL="%s"\n' "$CHOSEN_WHISPER" > .transcribrr-settings.sh
printf 'CLEANUP_MODEL="%s"\n' "$CHOSEN_CLEANUP" >> .transcribrr-settings.sh
printf 'SUMMARY_MODEL="%s"\n' "$CHOSEN_SUMMARY" >> .transcribrr-settings.sh
printf '# Updated: %s by benchmark\n' "$(date +%Y-%m-%d)" >> .transcribrr-settings.sh
```

Load in `transcribrr.sh` before the defaults block:
```bash
SETTINGS_FILE="$SCRIPT_DIR/.transcribrr-settings.sh"
if [ -f "$SETTINGS_FILE" ]; then
    # shellcheck source=/dev/null
    . "$SETTINGS_FILE"
fi
```

CLI flags still override: flag parsing runs after the source, and the existing `while` loop sets variables unconditionally, so `--whisper-model X` wins over the settings file. This is the correct priority: settings file < flag.

### 7. HF Hub Model Discovery

Two approaches, both available without new deps:

**`hf` CLI** (already in `.venv/bin`):
```bash
.venv/bin/hf models ls \
    --author mlx-community \
    --search "whisper" \
    --sort downloads \
    --limit 20 \
    --expand downloads,tags \
    2>/dev/null
```
Output is tab-delimited. Parse `id` and `downloads` with `awk -F'\t' '{print $1, $3}'`.

**HF REST API** (no auth required for public mlx-community models):
```bash
python3 -c "
import urllib.request, json
url = 'https://huggingface.co/api/models?author=mlx-community&search=whisper&limit=20&sort=downloads'
data = json.loads(urllib.request.urlopen(url).read())
for m in data: print(m['modelId'], m.get('downloads', 0))
"
```
The REST API requires no token for public models and returns JSON. Use `urllib.request` (stdlib) to avoid adding the `requests` dep.

The Claude skill should use the `hf` CLI (already on PATH in `.venv`) since it's the most straightforward in a bash context and handles auth automatically if the user is logged in.

---

## Dependency Changes

### mlx-whisper Must Be Added to `.venv`

`transcribe.sh` expects `.venv/bin/mlx_whisper` but **mlx-whisper is not in the current `.venv`**. Installing it adds torch (2.12.0), numba, scipy, tiktoken, and llvmlite — approximately 2-3 GB download.

The benchmark script's `setup_venv()` equivalent must install it:
```bash
if ! "$VENV/bin/python" -c "import mlx_whisper" 2>/dev/null; then
    "$VENV/bin/pip" install mlx-whisper
fi
```

Alternatively, note this in a preflight check so the user can opt in. Either way, the v2.0 benchmark phase MUST address this gap since the Whisper benchmark stage depends on it.

### No Other New Python Deps

All benchmarking capability is already present:
- `mlx_lm.generate(verbose=True)` — built into mlx-lm 0.31.3
- `mlx_lm.benchmark` CLI — built into mlx-lm 0.31.3
- `mx.device_info()`, `mx.get_peak_memory()` — built into mlx 0.31.2
- `hf models ls` — built into huggingface_hub 1.19.0
- HF REST API via `urllib.request` — stdlib

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Sourced `.sh` settings file | JSON file parsed via `python3 -c "import json..."` | If settings need to be read by non-bash tools (e.g. a future web UI). JSON is more portable but adds `python3` as a hard runtime dep for every pipeline run; the sourced `.sh` has zero overhead. |
| `mx.device_info()` for memory limit | `sysctl hw.memsize` | When checking from bash before Python context exists. `sysctl` gives total memory; `mx.device_info()['max_recommended_working_set_size']` is the MLX-calibrated fit threshold (~52GB on 64GB M2 Max). |
| `mlx_lm.generate(verbose=True)` for LLM stats | `mlx_lm.benchmark` CLI | `benchmark` is faster (synthetic tokens, no real prompt) and good for model comparison; `verbose=True` on a real transcript sample gives more representative tok/s at realistic prompt sizes. Use both: benchmark for candidate ranking, real-sample for final validation. |
| `/usr/bin/time -l` for Whisper RSS | `ps -o rss` polling | `ps` polling misses the peak (polls every N seconds); `/usr/bin/time -l` captures the true high-water mark. `ps` is acceptable if `/usr/bin/time` proves unreliable in practice. |
| `hf` CLI for model discovery | Direct `curl` to HF REST API | `curl` is simpler in bash but requires parsing JSON with `python3` or `jq` (not always present). `hf` is already installed and handles auth. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `huggingface-cli` | Deprecated in huggingface_hub 1.x — warns on every call and will be removed | `hf` (already in `.venv/bin`) |
| `mx.metal.device_info()` / `mx.metal.get_active_memory()` | Deprecated in mlx 0.31.x — emits deprecation warnings to stderr | `mx.device_info()` and `mx.get_active_memory()` (top-level, non-metal-namespaced) |
| `mapfile` / `readarray` in bash | Not in bash 3.2.57 (stock macOS) — already caught as a v1.0 bug | `while IFS= read -r line; do arr+=("$line"); done < <(cmd)` — as used in existing `transcribrr.sh` |
| `jq` | Not guaranteed present on macOS without Homebrew; adds a dependency | `python3 -c "import json..."` (python3 3.11 is already on PATH and in `.venv`) |
| `torch` as a direct dep for benchmarking | `mlx-whisper` pulls in torch as a dep, but benchmark code must not import torch directly — it's a 2GB+ package and irrelevant to MLX performance measurement | Use `mlx` / `mlx_lm` APIs only for performance metrics |
| Adding `mlx-whisper` to the benchmark without user opt-in | The install is 2-3 GB and takes significant time; silently installing it in `--benchmark` mode would be surprising | Gate behind an explicit install step or `--install-whisper` flag; warn if missing and skip the Whisper benchmark stage |
| `claude --bare` for skill invocation | `--bare` disables skill resolution (skills resolve via `/skill-name`, but `--bare` skips CLAUDE.md auto-discovery; skill loading still works, but auto-memory and hooks are stripped, which may be desirable) | Use `--permission-mode bypassPermissions --no-session-persistence` without `--bare` unless startup time is critical |

---

## Version Compatibility

| Package | Version | Compatibility Notes |
|---------|---------|---------------------|
| mlx-lm | 0.31.3 | `generate()` `verbose=True` output format (Prompt/Generation/Peak memory lines) — verified against source at this version. Format may change in future versions. |
| mlx | 0.31.2 | `mx.device_info()` non-deprecated API confirmed at this version. `mx.metal.*` variants deprecated. |
| mlx-whisper | 0.4.3 (to install) | Pulls torch 2.12.0 — large download. Pin to 0.4.3 or use `>=0.4` to allow patch updates. |
| huggingface_hub | 1.19.0 | `hf` binary replaces `huggingface-cli`. `list_models()` Python API available. |
| bash | 3.2.57 | No `mapfile`/`readarray`; no `[[ ]]` with process substitution (use `< <(cmd)` pattern); arithmetic with `$(( ))` works; `bc` for float math. All patterns verified in existing scripts. |

---

## Sources

- Installed source: `.venv/lib/python3.11/site-packages/mlx_lm/generate.py` — verified `verbose=True` print format (lines 791-798), `mx.get_peak_memory()` usage (line 737, 751), `GenerationResponse.peak_memory` field (line 295)
- Installed source: `.venv/lib/python3.11/site-packages/mlx_lm/benchmark.py` — verified `mlx_lm.benchmark` CLI output format (lines 145, 165-168)
- Live CLI: `mlx_lm.generate --help`, `mlx_lm.benchmark --help`, `hf models ls --help` — confirmed flags and output
- Live Python: `mx.device_info()` — confirmed `memory_size` and `max_recommended_working_set_size` values on M2 Max 64GB
- Live bash: `/usr/bin/time -l` — confirmed `maximum resident set size` field (bytes) and parseable with `awk`
- Live bash: `sysctl hw.memsize` — confirmed returns 68719476736 (64GB)
- Live CLI: `hf models ls --author mlx-community --search whisper` — confirmed tab-delimited output format
- Live CLI: `claude --help` — confirmed `-p`, `--permission-mode bypassPermissions`, `--no-session-persistence` flags
- PyPI: mlx-whisper 0.4.3 — confirmed torch/numba/scipy deps via `pip install --dry-run`
- Existing codebase: `transcribe.sh` lines 152-227 — confirmed mlx_whisper log format `[HH:MM:SS.mmm --> HH:MM:SS.mmm]` and RTF derivation pattern

---
*Stack research for: transcribrr v2.0 — model benchmarking & auto-selection*
*Researched: 2026-06-14*
