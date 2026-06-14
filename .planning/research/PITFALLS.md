# Pitfalls Research

**Domain:** MLX model benchmarking + auto-selection in a bash pipeline (Apple Silicon / v2.0 addition)
**Researched:** 2026-06-14
**Confidence:** HIGH (benchmark/memory/bash sections verified from MLX GitHub issues + Apple community; HIGH/MEDIUM noted per claim)

---

## Critical Pitfalls

### Pitfall 1: Download Time Absorbed Into RTF

**What goes wrong:**
The first `mlx_lm.load()` or `mlx_whisper` call for a model that is not already cached in `~/.cache/huggingface/hub` silently downloads several GBs before inference starts. If the benchmark timer wraps the entire Python invocation, the recorded RTF/tok-s figure is dominated by network I/O, not inference speed. A slow internet session will make a large 4-bit model appear slower than a small one even if its actual inference rate is faster.

**Why it happens:**
`mlx_lm.load()` is the single entry point for both cache-hit and cache-miss paths — it returns identically whether it spent 2 seconds or 8 minutes. There is no return code or log line the bash wrapper can trivially distinguish from normal load latency.

**How to avoid:**
Pre-download every candidate model before the benchmark sweep starts, in a dedicated `--benchmark-prepare` step (or a pre-flight inside `--benchmark`). Use `huggingface-cli download <model-id>` or a dry-run Python call that exits after `load()` without measuring. Only start the timing clock after the download guard passes. Verify cache presence by checking `~/.cache/huggingface/hub/models--<org>--<name>/snapshots/` before calling `load()`.

**Warning signs:**
- First candidate in a sweep is always suspiciously slower than subsequent ones.
- RTF variance between runs of the same model spans 10×+ (network variance vs inference variance).
- The benchmark log shows no per-model load time, only total time.

**Phase to address:** Benchmark infrastructure phase (the phase that writes `--benchmark` mode). Must be designed into the timing harness from the start; retrofitting is error-prone.

---

### Pitfall 2: Cold-Load vs Warm-Cache Timing Conflation

**What goes wrong:**
MLX compiles Metal kernels on first use and caches them in `~/Library/Caches/com.apple.metal/`. The first inference on a freshly loaded model takes materially longer than the second — community benchmarks report cold TTFT vs cached TTFT can differ by 10–30×. If the benchmark runs a single sample per model and records that one number, every model's score is contaminated by compile latency, not steady-state throughput.

**Why it happens:**
MLX's lazy evaluation means Metal kernels are not compiled until the first `mx.eval()` completes. This compile-and-cache step is invisible to Python — `generate()` returns only when inference finishes, no separate compile-time metric is surfaced.

**How to avoid:**
Run one warm-up pass (short prompt, discard output) before starting the clock. Record the warm-up run time separately if desired as "cold load" data. For RTF, run at least 2–3 samples of the benchmark audio clip and average, discarding the first. In the benchmark report, label timings as "warm" and note that cold-start figures will be higher.

**Warning signs:**
- First-model RTF always worse than expected; subsequent models are consistent.
- Re-running `--benchmark` a second time with models already in HF cache produces materially different results than the first run.

**Phase to address:** Benchmark infrastructure phase.

---

### Pitfall 3: Unified-Memory Pressure and Swap Skewing Results

**What goes wrong:**
macOS reserves approximately 25% of unified memory for the OS/frameworks/KV-cache headroom; on a 64 GB machine this leaves roughly 48 GB usable before macOS begins compressing and swapping. If other apps (browser tabs, Xcode, Simulator) are consuming RAM during a benchmark sweep, a model that genuinely fits 64 GB may swap mid-inference, showing 3–5× degraded throughput that will not reproduce in production use. Conversely, if the same sweep later runs with less memory pressure the model looks faster, and the benchmark results are not reproducible.

**Why it happens:**
Apple's unified memory architecture means GPU and CPU share the same physical DRAM. macOS will silently compress and swap any region not actively executing Metal ops. No warning is emitted to the Python process; `generate()` just takes longer.

**How to avoid:**
Before `--benchmark` runs: print an explicit memory-pressure warning if `vm_stat` shows `Pages swapped out` is non-zero or if `sysctl hw.memsize` - current RSS > safety threshold. Recommend the user quit browsers and other heavy apps. In the benchmark report, record the pre-run available memory so comparisons are honest. Do not attempt to programmatically kill other apps — just warn and gate.

**Warning signs:**
- Activity Monitor shows memory pressure in yellow/red during the sweep.
- RTF degrades monotonically across the sweep (later models look slower as system warms up and RAM fills).
- `vm_stat | grep "Pageouts"` shows non-zero Pageouts.

**Phase to address:** Benchmark infrastructure phase (add pre-flight memory check before sweep begins).

---

### Pitfall 4: Thermal Throttling Contaminating Later Candidates

**What goes wrong:**
Running a full benchmark sweep — multiple Whisper models then multiple LLM models — is a sustained-load workload. Sustained Metal compute at ~14W raises M-series GPU temperature; once the chip crosses its thermal threshold, clock speeds are reduced to protect hardware. A model benchmarked as candidate 7-of-10 may record 30–40% worse RTF than if it ran first, purely due to thermal state, not model capability. The "winner" then becomes the model that was lucky enough to run first or after a cool-down gap.

**Why it happens:**
The M2 Max has no active cooling in some configurations. Sustained LLM inference does not give the chip time to cool between candidates. The kernel throttles silently.

**How to avoid:**
Insert a short idle pause (30–60 seconds) between each candidate to allow temperature to recover. Alternatively, run candidates in randomised order across multiple sweep passes and average, so thermal position is decorrelated from model identity. Record wall-clock time per candidate; if elapsed time is anomalously shorter than expected, flag as potentially throttled. Tools like `sudo powermetrics -s smc` can surface die temperature; a bash pre/post wrapper can log it without adding Python dependencies.

**Warning signs:**
- Later candidates in a sweep consistently underperform their documented community benchmarks.
- Physical chassis is warm to the touch when sweep finishes.
- Repeating the sweep in reversed order produces a reversed ranking.

**Phase to address:** Benchmark infrastructure phase (inter-candidate cool-down and optional thermal logging).

---

### Pitfall 5: Single-Sample RTF Variance

**What goes wrong:**
Transcription RTF is computed from one audio clip. A 60-second clip means one data point. MLX inference is not perfectly deterministic per run (memory bus contention, Metal scheduler variance, background daemons). A single measurement can swing ±15% from run to run. Selecting a Whisper model based on a single-sample RTF risks picking one that happened to score well by luck.

**Why it happens:**
The benchmark is designed for speed (one pass per candidate). Single samples are fast to implement but statistically noisy.

**How to avoid:**
Run each Whisper candidate at least twice on the same clip and report the mean ± range. For LLM stages, run two prompts of similar token length and average tok/s. Document the sample count in the benchmark report so the user can judge confidence.

**Warning signs:**
- Two runs of the same model give RTF values that differ by more than 10%.
- The benchmark report shows only one data point per model with no variance indicator.

**Phase to address:** Benchmark infrastructure phase.

---

### Pitfall 6: MLX Metal Memory Not Released Between Candidates (OOM Mid-Sweep)

**What goes wrong:**
When a Python process loads model A, runs inference, then loads model B in the same process, MLX's Metal allocator does not always release model A's weight buffers even after `del model; gc.collect()`. Memory accumulates across candidates, and the sweep dies with an OOM error partway through — typically on the largest candidate — having produced partial, non-comparable results. This is a confirmed MLX behaviour reported in multiple GitHub issues (ml-explore/mlx #724, #2668, #2254).

**Why it happens:**
The MLX Metal allocator retains buffers in a pool for potential reuse. `mx.metal.clear_cache()` releases the pool but does not defragment the allocator; in-flight references and Metal's own internal state can still hold pages. The only guaranteed release is process exit.

**How to avoid:**
Run each benchmark candidate in a **separate subprocess** (e.g. `python benchmark_one_model.py --model <id> --audio <file>` called from bash). Each subprocess exits cleanly after its run, releasing all Metal memory back to the OS. The orchestrating bash script collects per-model JSON result files and assembles the final report. This is the pattern confirmed by MLX's own benchmarking infrastructure. Do not attempt multi-model sweeps in a single long-lived Python process.

**Warning signs:**
- The sweep crashes on the last (largest) model with `RuntimeError: Metal allocation failed`.
- `vm_stat` shows available pages dropping monotonically across the sweep even with `mx.metal.clear_cache()` calls.
- Earlier candidates produce output; later ones silently produce nothing.

**Phase to address:** Benchmark infrastructure phase (must be the fundamental architectural choice — subprocess-per-candidate).

---

### Pitfall 7: Memory-Fit Estimation Errors for 4-bit / 8-bit MLX Models

**What goes wrong:**
Estimating whether a model fits 64 GB by looking only at weight size is wrong. A 32B-4bit model has ~17 GB of weights, but the KV cache for a 32k-token context window can consume an additional 8–16 GB, plus the Python runtime, the tokenizer, and MLX's internal allocator overhead. A model that appears to fit by 5 GB may OOM mid-inference on a long transcript, killing the benchmark process and potentially leaving a partial output file that the orchestrator misreads as success.

**Why it happens:**
Community documentation (e.g. `summarize-transcript.sh`'s comment "~20 GB RAM for 32B 4-bit model") captures peak weight footprint, not total peak. KV cache grows with input length; a benchmark audio clip produces a longer transcript than typical prompts, so KV cache demand is higher.

**How to avoid:**
Build a conservative fit formula: `fit = weights_gb + kv_cache_gb + 4 (overhead)` where `kv_cache_gb = (layers × heads × head_dim × 2 × context_tokens × 2_bytes) / 1e9`. For the candidate list, pre-compute fit against 48 GB (the safe usable ceiling on 64 GB unified memory). Reject candidates that would exceed 44 GB (leave 4 GB buffer). Catch Python `SystemExit` / `RuntimeError` from `generate()` at the subprocess level and write a `{"error": "oom"}` result file so the sweep continues rather than crashing the orchestrator.

**Warning signs:**
- A benchmark candidate produces no output file and no error message (process killed by OOM).
- `activity_monitor` shows the swap indicator spiking just before a candidate fails.
- `mlx_lm.load()` succeeds but `generate()` crashes mid-token.

**Phase to address:** Benchmark infrastructure phase (fit gate) + candidate list curation (settings/config phase).

---

### Pitfall 8: Headless `claude -p` Blocking on Interactive Permission Prompts

**What goes wrong:**
When `transcribrr.sh --benchmark` auto-launches `claude -p "run skill: refresh-model-candidates"` to invoke the model-curation skill, the Claude process may pause and wait for a human to approve tool use (file writes, bash calls) if it encounters a new tool it has not seen before or if the permission mode defaults to interactive. In a fully unattended run, nothing will ever answer the prompt, causing the benchmark to hang indefinitely.

**Why it happens:**
Claude Code's default REPL permission mode is interactive. `claude -p` (headless/print mode) terminates instead of prompting when it hits a tool-approval gate in strict configurations, but with some permission configs it can still pause. The behavior differs depending on the installed version and configured permission mode.

**How to avoid:**
Launch with explicit permission flags: `claude -p --allowedTools "Read,Write,Bash(python *),Bash(cat *)" "<prompt>"` to whitelist exactly the tools the skill needs. Alternatively use `--permission-mode dontAsk` to suppress all interactive prompts. Never use `--dangerously-skip-permissions` in a script that writes config files, as it removes all guardrails. Document the exact `claude` invocation in the script with the required flags. Add a timeout wrapper (`timeout 120 claude -p ...`) so a hung claude process does not freeze the benchmark indefinitely.

**Warning signs:**
- `--benchmark` hangs for more than 2 minutes with no output after "Launching claude to refresh model candidates...".
- `ps aux | grep claude` shows a claude process in S (sleeping) state with no CPU activity.
- Running the same command manually in a terminal shows a permission approval dialogue.

**Phase to address:** Claude skill integration phase (must be designed unattended from the first line of code).

---

### Pitfall 9: Claude Skill Writing Malformed or Untrusted Config

**What goes wrong:**
The Claude skill researches current mlx-community models and writes its findings to a candidate config file (e.g. `benchmark-candidates.json` or similar). If the skill produces syntactically invalid JSON, a model ID that contains shell metacharacters, a HuggingFace path that 404s, or a quantization label that does not match the actual file format in the repo, the benchmark sweep will fail in obscure ways: JSON parse errors, `load()` exceptions mid-sweep, or silently wrong models being evaluated.

**Why it happens:**
LLM output is not guaranteed to be well-formed structured data. The skill runs autonomously without a human review step. A hallucinated HF model ID (`mlx-community/Qwen3-72B-4bit`) may look plausible but not exist in the registry. The bash script, trusting the config file, will attempt to download and run it.

**How to avoid:**
Treat the skill's output as untrusted input. After the skill writes its config file, the benchmark script must: (1) validate JSON parses without error, (2) check that every model ID matches a safe allowlist regex (`^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$` — no shell metacharacters), (3) verify each HF model ID actually exists by running `huggingface-cli info <model-id>` (exits non-zero on 404), (4) confirm model type matches expected stage (Whisper models for the transcribe stage, LLM models for cleanup/summarize). Fail loudly with a diff between the previous vetted list and the new list before proceeding.

**Warning signs:**
- The skill exits 0 but the config file contains prose text rather than JSON.
- A model ID in the config file contains spaces, quotes, or `$`.
- `huggingface-cli info <id>` returns 404 for one of the candidates.
- The config has a Whisper-architecture model ID in the LLM candidates list or vice-versa.

**Phase to address:** Claude skill integration phase (validation wrapper must be written before the skill is ever invoked from `--benchmark`).

---

### Pitfall 10: Headless `claude` Not Installed / Not on PATH

**What goes wrong:**
The benchmark feature auto-launches `claude` as a subprocess. If `claude` is not installed (the user has never used Claude Code), installed under a different name, or installed in a path not in the non-login shell's `$PATH` (common in cron/launchd invocations), the subprocess call fails immediately. Without a clear error message the user sees only "Error: claude skill refresh failed" with no actionable diagnosis.

**Why it happens:**
`claude` is a globally installed npm binary. macOS non-login shells do not source `.zshrc`; `nvm`-managed or user-local npm installs end up in paths like `/Users/<user>/.nvm/versions/node/<ver>/bin/` which are not in the default PATH.

**How to avoid:**
Add a preflight check for the `claude` binary before attempting skill refresh: `command -v claude &>/dev/null || { echo "Error: 'claude' not found on PATH. Install Claude Code or skip model refresh with --no-skill-refresh."; exit 1; }`. Also check `claude --version` output to confirm it is a recent enough version (headless `--allowedTools` was added in a specific release). Provide a `--no-skill-refresh` flag that skips the claude invocation and uses the existing candidate list, so the benchmark is usable without Claude Code installed.

**Warning signs:**
- `command -v claude` returns nothing.
- `claude --version` exits non-zero or outputs an older version string lacking `--allowedTools`.
- The script works in a login terminal but fails in a cron job or CI environment.

**Phase to address:** Claude skill integration phase (preflight added alongside the skill invocation).

---

### Pitfall 11: Skill Auto-Trigger Recursion

**What goes wrong:**
If the Claude skill that refreshes the model candidate list is declared with a `context: fork` directive or invoked via `/slash-command` style dispatch, and if the skill's own prompt or the claude agent's evaluation causes it to re-invoke itself (e.g. via a self-referential tool call), the skill can enter infinite recursion — each forked sub-agent re-dispatches the same skill. In a headless, unattended `--benchmark` run there is no human to cancel it; it runs until rate-limited or manually killed.

This is a confirmed bug in Claude Code (anthropics/claude-code issue #55592): skills declared with `context: fork` can recursively re-dispatch themselves under Sonnet 4.x when invoked programmatically.

**Why it happens:**
The claude agent harness has no re-entry guard. A skill invoked via `claude -p "Run skill: X"` may internally dispatch `Skill(skill="X", args=...)` again if the reasoning loop reaches a fixed point that matches the original dispatch.

**How to avoid:**
Use `claude -p "<explicit task prompt>"` rather than `/skill-name` dispatch. Write the skill prompt as a single-pass research task with a concrete termination condition ("Write the results to `benchmark-candidates.json` and stop"). Do not use `context: fork` for the model-curation skill. Set `--allowedTools` to exclude the `Skill` tool (`--allowedTools "Read,Write,Bash,WebSearch"`) so the skill cannot dispatch other skills. Add a wall-clock timeout: `timeout 300 claude -p ...` kills any runaway invocation after 5 minutes.

**Warning signs:**
- The `--benchmark` stage has been running for more than 5 minutes with no output to the terminal.
- `ps aux | grep claude` shows multiple claude processes all spawned from the same parent PID.
- CPU usage is pegged at 100% on all efficiency cores with no GPU activity (inference is not running — it is spinning in the planning loop).

**Phase to address:** Claude skill integration phase.

---

### Pitfall 12: Bash 3.2 Incompatibilities in New Benchmark Code

**What goes wrong:**
Stock macOS ships `/bin/bash` at version 3.2.57. v1.0 already hit two bash-3.2 bugs caught in code review: a `mapfile` call (unavailable in 3.2) and an `&` inside a `[[ =~ ]]` regex character class (triggers a tokenisation error). v2.0 benchmark code will introduce new surface area where these traps recur:

- **Associative arrays** (`declare -A map`): unavailable in bash 3.2. Any attempt to use a hash map for model → RTF storage will silently create an indexed array or error, producing corrupt results.
- **Float comparison with `(( ))`**: bash arithmetic is integer-only. `(( rtf < 1.0 ))` truncates `rtf` to 0 or 1 before comparison, always returning wrong results.
- **`bc` locale sensitivity**: `bc` on some locales uses `,` as the decimal separator; `echo "scale=2; 3/7" | bc` returns `0,42` not `0.42`, breaking any downstream `[ "$RTF" '<' "1.0" ]` string comparison.
- **`printf %f` in bash 3.2**: works but locale-dependent decimal separator applies here too.
- **Process substitution with `<<<` heredoc in functions**: generally fine in 3.2 but combining with `IFS` splits inside `while read` loops that parse float fields from Python output can silently strip leading/trailing whitespace in surprising ways.

**Why it happens:**
Developers reach for associative arrays and float arithmetic naturally; these are standard in bash 4+. The existing code's documented 3.2 constraint is easy to forget when writing new functionality quickly.

**How to avoid:**
Enforce a CI/lint check: `bash --version` in the test harness; confirm 3.2 compatibility by running the script explicitly under `/bin/bash` not `/usr/local/bin/bash` (homebrew bash 5.x). Store model→result mappings as flat files (`/tmp/bench_result_<model_label>.json`) rather than in-memory arrays — the subprocess-per-candidate architecture (Pitfall 6) makes this natural. Use `awk` for all float arithmetic (it is available, locale-independent with `OFMT`, and has no bash-version dependency). Use `LC_NUMERIC=C bc` to force POSIX decimal separator.

**Warning signs:**
- Any `declare -A` in new bash code.
- Any `(( ))` comparison involving a variable that could be a float.
- Any `bc` call without `LC_NUMERIC=C`.
- The script runs differently under `/bin/bash` vs `/usr/local/bin/bash`.

**Phase to address:** Every phase that touches bash code. Enforce via code-review checklist item: "Bash 3.2 compat — no associative arrays, no float in `(( ))`, `LC_NUMERIC=C` for `bc`."

---

### Pitfall 13: Settings File Stale Defaults Pointing at Deleted / Renamed Models

**What goes wrong:**
After the user runs `--benchmark`, picks winners, and records them in the settings file (e.g. `~/.transcribrr/settings.json` or `transcribrr.settings`), the file persists indefinitely. A future `mlx-community` rename (e.g. `Qwen2.5-32B-Instruct-4bit` → `Qwen2.5-32B-Instruct-4bit-mlx`) or a model the user later deletes from the HF cache will cause the next normal `transcribrr.sh` run to fail with a cryptic `load()` 404 or file-not-found error, with no indication that the settings file is the source.

**Why it happens:**
The settings file is written once and never automatically re-validated. Model IDs on HuggingFace are stable by policy but community repositories do get reorganised, renamed, or removed. The user may also manually delete a large model from the HF cache to free disk space, forgetting it is the pipeline default.

**How to avoid:**
On every normal pipeline run (not just `--benchmark`), add a cheap pre-flight that validates the model IDs in the settings file. For HF IDs containing `/`, run `huggingface-cli info <id>` with a short timeout. For short labels, confirm the label is in the known-good label table. If validation fails, emit a clear error: "Settings file references model X which is no longer available. Re-run with --benchmark to refresh, or pass --whisper-model / --cleanup-model / --summary-model flags to override." Fall back to the compiled-in defaults, not a crash.

**Warning signs:**
- `transcribrr.sh` fails at `load()` with a 404 after not running for several months.
- The error message shows a model ID that is not in the current `transcribe.sh` label table.
- `huggingface-cli info <model-id>` returns 404.

**Phase to address:** Settings file phase (build validation into the settings-read path from day one, not as a later addition).

---

### Pitfall 14: Flag vs Settings Precedence Confusion

**What goes wrong:**
If the settings file sets `whisper_model = turbo` and the user passes `--whisper-model small` on the command line, the expected behaviour is that the flag wins. If the settings-reading code runs after flag parsing and overwrites the flag values, or if the flag defaults are applied after settings values are read, the user's explicit choice is silently ignored. This is especially confusing in an unattended pipeline — the user expects deterministic behaviour from explicit flags.

**Why it happens:**
Reading the settings file and parsing flags are two independent code paths; their merge order is easy to get backwards when both happen in the setup section of `transcribrr.sh`.

**How to avoid:**
Implement a strict three-tier precedence: (1) compiled-in defaults, (2) settings file overrides defaults, (3) CLI flags override settings. In bash, apply this as: set defaults, then conditionally overwrite from settings file, then re-parse flags and overwrite again. Use a sentinel value (empty string `""`) for flags so you can distinguish "user did not pass this flag" from "user passed this flag explicitly". Document the precedence order in the `--help` output.

**Warning signs:**
- Passing `--whisper-model small` still runs `turbo` when a settings file is present.
- The `--help` text does not mention the settings file or precedence order.
- The settings file is parsed after flag parsing in the script's execution order.

**Phase to address:** Settings file phase.

---

### Pitfall 15: Settings File Corruption on Partial Write

**What goes wrong:**
If `transcribrr.sh` is interrupted (Ctrl-C, power loss, system sleep) while writing the settings file after a benchmark run, the file may be left in a partially written state — valid JSON up to the point of interruption, then truncated. The next run reads a syntactically invalid JSON file and fails in an opaque way, or worse, `jq` / a Python parser raises an exception inside a subshell that is swallowed by `|| true`, silently falling through to use stale or empty values.

**Why it happens:**
Direct file writes in bash (`echo "..." > settings.json`) are not atomic. A SIGINT during the write leaves a partial file. v1.0 already uses the temp+`mv` atomic pattern for the output markdown; the same discipline must be applied to the settings file.

**How to avoid:**
Write settings to a temp file on the same filesystem, then `mv` atomically. Use the same pattern as v1.0's `TEMP_MD=$(mktemp)` + `mv "$TEMP_MD" "$FINAL"`. Set an EXIT trap to remove the temp file on abnormal exit. On every read, validate JSON before using: `python3 -c "import json,sys; json.load(sys.stdin)" < settings.json || { echo "Error: settings file is corrupt, ignoring."; ... }`.

**Warning signs:**
- The settings file exists but `python3 -m json.tool settings.json` exits non-zero.
- File size is suspiciously small (a few bytes instead of expected hundreds).
- A `--benchmark` run that was interrupted mid-write left the file at the exact byte where the write was killed.

**Phase to address:** Settings file phase.

---

### Pitfall 16: mlx-community HF ID 404, Gated, or Not Actually MLX-Converted

**What goes wrong:**
The candidate list produced by the Claude skill may contain a model ID that: (a) does not exist at all on HuggingFace (hallucinated or recently removed), (b) requires a HF login token (gated by the original author despite appearing in mlx-community), or (c) exists in name but has not been properly converted to MLX format — e.g. it contains standard PyTorch weights but was submitted to mlx-community without running the `mlx_lm.convert` step, so `load()` either errors or loads wrong weights silently. The whisper vs LLM type confusion is the worst-case variant: passing an mlx-community LLM model ID to `mlx_whisper` (which expects an encoder-decoder Whisper architecture) will either crash on weight shape mismatch or, if the parameter names happen to partially align, produce garbage transcription output silently.

**Why it happens:**
mlx-community is an open community organisation on HuggingFace — anyone can create a repository under it. Not all repositories are well-maintained. The HF model cards do not enforce a "this is MLX-compatible" badge programmatically. Claude's training data may include now-deleted model IDs.

**How to avoid:**
For every candidate model ID: (1) verify existence with `huggingface-cli info <id>` (exits non-zero on 404 or auth required), (2) check the model card's `library_name` metadata field is `mlx` — `huggingface-cli info <id> --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('library_name')=='mlx'"`, (3) confirm model type: Whisper candidates must have `model_type` = `whisper`; LLM candidates must not. Apply these checks in the config-validation step (Pitfall 9) before any benchmark run.

**Warning signs:**
- `huggingface-cli info <id>` outputs `Repository Not Found` or `Access to model ... is restricted`.
- `mlx_lm.load()` raises `KeyError` on a weight tensor name (wrong architecture).
- `mlx_whisper` on an LLM model ID produces either an immediate crash or a blank/garbled transcript.

**Phase to address:** Claude skill integration phase (validation wrapper) + candidate list curation.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Single long-lived Python process for entire sweep | Simpler code, no subprocess management | MLX Metal memory accumulates; OOM kills sweep midway; results corrupt | Never — the subprocess-per-candidate pattern is not significantly harder to implement |
| Store benchmark results in bash variables / arrays | Avoids temp files | Associative arrays don't exist in bash 3.2; result lost if process exits | Never — use flat JSON files per candidate instead |
| Skip warm-up pass to save time | Faster benchmark run | Cold-start compile latency inflates RTF for every candidate equally, making ranking unreliable | Never for the default path; optionally skip via `--no-warmup` with explicit warning |
| Trust skill output directly as config without validation | Simpler integration | One hallucinated or gated model ID crashes the sweep or inserts garbage into the pipeline defaults | Never — validation is a one-time implementation, not ongoing work |
| Write settings file in-place (no atomic temp+mv) | 3 fewer lines of code | Partial write on SIGINT corrupts the only record of the user's benchmark winners | Never — v1.0 already established the atomic write pattern; copy it |
| Use `declare -A` for model→RTF map | More readable than flat files | Silently broken on bash 3.2; produces incorrect results with no error | Never in this project; use flat files or delegate to Python/awk |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| `claude -p` headless | Omitting permission flags; process blocks waiting for human approval that never comes | Always pass `--allowedTools` + `--permission-mode dontAsk`; wrap with `timeout 300` |
| `claude -p` headless | Not checking `claude` is on PATH before calling it in an unattended script | Preflight `command -v claude` with a helpful error and a `--no-skill-refresh` fallback flag |
| HuggingFace `load()` | Conflating download latency with inference latency | Pre-download all candidates before timing starts; use `huggingface-cli download` as a separate step |
| `mlx.metal.clear_cache()` | Assuming it fully frees memory between model loads in one process | Use subprocess-per-candidate; each process exits cleanly, releasing all Metal memory |
| Settings file read | Parsing JSON with `jq` inside `$()` and swallowing parse errors with `|| true` | Validate JSON structure explicitly before using any field; fail loudly on parse error |
| Whisper vs LLM model IDs | Passing an LLM model ID to `mlx_whisper` or a Whisper model to `mlx_lm` | Enforce model-type check from HF metadata before benchmark; model type is in the HF model card |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| No inter-candidate cool-down | Later candidates score 30–40% worse RTF; ranking changes depending on sweep order | 30–60s idle between candidates; randomise sweep order across runs | From the first 3+ candidate sweep on M-series without active cooling |
| Single-sample variance | Benchmark shows model A beats model B by 8%; re-running reverses ranking | Minimum 2 samples per model, report mean | Any time inference measurement is used for a ranking decision |
| Memory pressure from other apps | Throughput degrades across sweep; results not reproducible | Pre-flight `vm_stat` check; warn if memory pressure is not green before starting | Whenever browser + Xcode + other ML tools are open during benchmarking |
| HF cache miss on first model | First candidate RTF is 10–100× worse than actual inference speed | Pre-download step before timing loop | On any machine that has not previously used the candidate model |

---

## "Looks Done But Isn't" Checklist

- [ ] **Benchmark timing**: Verify timer starts after model warm-up pass, not at `python subprocess.run()` start.
- [ ] **Memory gate**: Verify each candidate runs in a separate subprocess, not in a loop in one Python process.
- [ ] **Skill output validation**: Verify every model ID in the generated candidate config passes `huggingface-cli info` before the sweep starts.
- [ ] **Headless claude**: Verify `--benchmark` completes fully unattended with no TTY (test with `./transcribrr.sh ... --benchmark < /dev/null`).
- [ ] **Settings precedence**: Verify `--whisper-model small` overrides a settings file that specifies `turbo` — test with both present.
- [ ] **Atomic settings write**: Verify Ctrl-C mid-write leaves no partial settings file (test by killing the process during write and checking file is either absent or complete).
- [ ] **Bash 3.2**: Verify the script runs under `/bin/bash` (3.2.57) without errors — test explicitly, not just under homebrew bash.
- [ ] **Stale model validation**: Verify that a settings file referencing a non-existent model ID produces a clear error on the next normal pipeline run, not a silent fallback to defaults.

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Download time mixed into RTF — misleading results | LOW | Re-run `--benchmark` after verifying all models are in HF cache; discard previous results |
| OOM mid-sweep (memory not released) | LOW | Restart sweep with subprocess-per-candidate architecture; previous partial results (JSON files) can be retained for completed candidates |
| Settings file corrupted | LOW | Delete settings file; re-run `--benchmark` to regenerate |
| Claude skill infinite recursion | MEDIUM | Kill `claude` process (`pkill claude`); fix skill invocation to include `--allowedTools` exclusion of `Skill` tool; re-run |
| Hallucinated model ID in candidate config | LOW | Run validation step independently; remove bad ID from config; re-run sweep for affected stage only |
| Thermal throttling skewed results | MEDIUM | Let machine cool 10 minutes; re-run sweep in reversed model order; average results from both runs |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Download time mixed into RTF (#1) | Benchmark infrastructure phase | Test: benchmark a model not in HF cache; confirm timing starts only after load() completes without network |
| Cold-load vs warm-cache conflation (#2) | Benchmark infrastructure phase | Test: run same model twice; confirm second RTF is used as the recorded result |
| Unified-memory pressure (#3) | Benchmark infrastructure phase | Test: benchmark with Activity Monitor open; confirm pre-flight warns if memory pressure is non-green |
| Thermal throttling (#4) | Benchmark infrastructure phase | Test: run 5 candidates back-to-back; confirm inter-candidate pause exists; confirm later candidates do not degrade monotonically |
| Single-sample RTF variance (#5) | Benchmark infrastructure phase | Test: run same model 3 times; confirm benchmark reports N samples and mean |
| MLX memory not released between candidates (#6) | Benchmark infrastructure phase | Test: run 3 large models in sweep; confirm no OOM; confirm `ps` shows separate python process per candidate |
| Memory-fit estimation errors (#7) | Benchmark infrastructure phase + candidate list phase | Test: add a model that exceeds 48 GB estimate; confirm sweep skips it with a clear log message |
| Headless `claude -p` blocking (#8) | Claude skill integration phase | Test: run `--benchmark` piped from `/dev/null`; confirm it completes without waiting for input |
| Skill writing malformed config (#9) | Claude skill integration phase | Test: replace skill output with deliberately malformed JSON; confirm validation rejects it before sweep starts |
| `claude` not on PATH (#10) | Claude skill integration phase | Test: temporarily rename `claude`; confirm clear error and `--no-skill-refresh` fallback works |
| Skill auto-trigger recursion (#11) | Claude skill integration phase | Test: run skill invocation; confirm only one `claude` process spawns; confirm it exits within timeout |
| Bash 3.2 incompatibilities (#12) | Every phase with new bash code | Test: run all scripts explicitly under `/bin/bash --version` → 3.2.57; no `declare -A`, no float in `(( ))` |
| Stale settings model IDs (#13) | Settings file phase | Test: manually set settings file to a non-existent model ID; confirm clear error on next pipeline run |
| Flag vs settings precedence (#14) | Settings file phase | Test: settings file sets model A; `--whisper-model B` flag passed; confirm model B is used |
| Settings file partial write (#15) | Settings file phase | Test: kill process during settings write with SIGINT; confirm file is absent or valid (never partial) |
| Invalid/gated/wrong-type model IDs (#16) | Claude skill integration phase + candidate list phase | Test: inject a 404 model ID into candidate config; confirm validation rejects it before sweep |

---

## Sources

- MLX GitHub issue — memory not released after model loads: https://github.com/ml-explore/mlx-examples/issues/724
- MLX GitHub issue — memory not fully freed (confirmed pattern): https://github.com/ml-explore/mlx/issues/2668
- MLX GitHub issue — Metal allocation failure during generation: https://github.com/ml-explore/mlx-lm/issues/1015
- MLX Metal documentation (clear_cache): https://ml-explore.github.io/mlx/build/html/python/metal.html
- Claude Code issue — skill context:fork infinite recursion: https://github.com/anthropics/claude-code/issues/55592
- Headless Claude Code / CI automation: https://hidekazu-konishi.com/entry/claude_code_cicd_and_headless_automation.html
- Claude Code headless mode guide: https://amux.io/guides/claude-code-headless/
- Apple unified memory usable ceiling (~48 GB on 64 GB): https://willitrunai.com/blog/mlx-vs-ollama-apple-silicon-benchmarks
- Apple Silicon thermal throttling under sustained inference: https://arxiv.org/pdf/2603.23640
- MLX cold TTFT vs cached TTFT benchmark methodology: https://github.com/jundot/omlx/discussions/1391
- MLX vs llama.cpp honest benchmark (cold/warm distinction): https://dev.to/sleepyquant/mlx-vs-llamacpp-on-m1-max-with-35b-q8-the-honest-benchmark-3496
- Float comparison in bash: https://www.baeldung.com/linux/bash-compare-float
- Atomic temp+mv write pattern: https://tech-champion.com/data-science/stop-silent-data-loss-checksum-atomic-writes-temp-file-patterns/
- HuggingFace MLX community model availability: https://huggingface.co/mlx-community
- Using MLX at HuggingFace (library_name metadata): https://huggingface.co/docs/hub/en/mlx

---
*Pitfalls research for: MLX benchmarking + auto-selection addition to transcribrr bash pipeline (v2.0)*
*Researched: 2026-06-14*
