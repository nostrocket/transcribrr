# Feature Research

**Domain:** Local-model benchmarking add-on for a bash-based MLX transcription/summarization pipeline
**Researched:** 2026-06-14
**Confidence:** MEDIUM-HIGH (model sizes from HF pages = HIGH; benchmark UX patterns = MEDIUM from real tools; Claude-skill patterns = MEDIUM)

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features a `--benchmark` mode must have to feel complete and trustworthy.

| Feature | Why Expected | Complexity | Pipeline Dependency |
|---------|--------------|------------|---------------------|
| Run each candidate model through its actual pipeline stage on a real sample | Benchmarks without real output are useless — users need to see what they're buying | MEDIUM | Calls existing `transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh` via same flags as production; `--whisper-model <id>`, `--cleanup-model <id>`, `--summary-model <id>` already exist |
| Capture and display real stage output (transcript excerpt / cleaned excerpt / summary excerpt) | Speed numbers alone don't tell you if a model hallucinates or produces garbage — seeing output next to numbers is the point | LOW | Read stage output files that the subscripts already emit |
| Measure wall-clock time per stage and compute RTF (ASR) or tok/s (LLM) | The primary objective metric; users shopping between models need apples-to-apples numbers | LOW | Time each subscript invocation; derive RTF from audio duration (already in pipeline metadata) |
| Memory-fit pre-check: skip models that exceed available RAM before attempting load | Without this, benchmark crashes mid-run on an OOM; 64GB M2 Max fits all current candidates but the check future-proofs it | MEDIUM | `mx.metal.get_active_memory()` or `sysctl hw.memsize` available in bash; model size must come from candidate config file |
| One-model-per-stage winner selection: human reads report, picks winner per stage | Automated scoring is contentious and error-prone; the user is the judge | LOW | No code dependency; requires report to be readable |
| Write chosen winners to a settings file that transcribrr.sh reads as defaults | Without persistence, the benchmark is a one-off exercise with no payoff | LOW | `transcribrr.sh` needs a `~/.transcribrr/settings` or `$SCRIPT_DIR/.transcribrr-defaults` check added |
| Warm-up run per model before timing begins | Without warm-up, first-inference model-load time contaminates timing; a known pattern from every serious benchmark tool | LOW | One short invocation per model before the timed run |
| Clear progress output: which model is running, which stage, elapsed time | Long benchmark run (potentially 30-90 min total) needs live feedback so the user doesn't wonder if it hung | LOW | `stage_banner()` pattern already in `transcribrr.sh` |
| Candidate list driven by a config/text file, not hardcoded | Candidates will evolve; hardcoding means every update requires a script edit | LOW | New `.transcribrr-candidates` config format |

### Differentiators (Competitive Advantage)

Features that make the benchmark tool notably better than running models by hand.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Resumable sweep: skip already-completed model/stage combinations | A 10-model × 3-stage sweep is ~90 min; if it crashes at model 8, re-running from scratch wastes hours | MEDIUM | Write a partial-results JSON/TSV after each model completes; check on resume; vLLM's `--resume` is precedent |
| Side-by-side output juxtaposition in the report | Reading outputs sequentially is hard; a markdown table with one row per model and columns for speed + truncated output excerpt makes comparison instant | MEDIUM | Markdown table generation in bash; truncate outputs to ~80-char excerpt |
| Automatic HF model-size fetch for memory-fit check | If the candidate config lists only a HF model ID (not a local size), query HF Hub metadata to get size before attempting load | HIGH | `curl` to HF Hub API; adds network dependency; could be skipped in `--no-install` spirit |
| `--benchmark-sample <file>` flag: use a custom audio sample | Default sample is a bundled short clip; letting the user supply their own domain-representative audio makes results more meaningful | LOW | Flag parsing addition; validate it's an audio file; no pipeline change |
| Claude skill that researches and updates candidate list | Auto-populates the candidate config with current best-in-class MLX models without manual HF browsing | HIGH | Requires `claude` CLI on PATH; skill is a SKILL.md + optional bash harness; `transcribrr.sh --benchmark` auto-launches it if candidate file is stale or missing |
| Dry-run mode (`--benchmark-dry-run`): enumerate candidates and check memory fit without running any inference | Lets the user audit what will run before committing 90 min of compute | LOW | Just print the candidate table with estimated memory and skip/proceed flags |
| Parallel metadata fetch (not parallel inference) | Fetch HF metadata for all candidates concurrently while first model is running; doesn't speed up inference but reduces idle gaps | MEDIUM | Background `curl` jobs in bash; requires careful job management |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Automated model scoring / auto-pick winner | "Just tell me which model is best" feels convenient | Quality is subjective to the user's audio domain, accent, and style expectations; any scoring formula embeds hidden assumptions and gives false confidence in a wrong pick | Present numbers and excerpts; human picks |
| Benchmark all models at all quantizations (e.g., 4bit AND 8bit for every model) | Thorough coverage | Combinatorial explosion: 5 ASR × 4 quantizations × 2 LLM stages × 4 quantizations = 160 runs; 10+ hours of compute | Keep one recommended quant per model in the candidate list; let the user manually add variants if they want |
| Auto-download models during benchmark sweep | Convenient UX | A 17GB model downloading mid-sweep freezes timing numbers for that model AND blocks subsequent models; wastes bandwidth on models the user may reject | Require models to be pre-downloaded; emit clear error if missing with download command hint |
| Cloud/API comparison mode (include OpenAI Whisper API, etc.) | Curious what the tradeoffs are vs cloud | Out of scope for a deliberately local pipeline; adds auth, billing, network latency variance | Out of scope; document clearly |
| Automatic model update / background refresh of candidates | Always-current candidates | Silent background scripts that modify config files erode user trust; tool should be deterministic | Claude skill runs on explicit user request only; settings file is written on explicit user confirmation |
| WER computation (word-error-rate vs reference transcript) | More rigorous than RTF | Requires a ground-truth reference transcript that doesn't exist at benchmark time; WER on real-world audio needs human annotation | Report RTF + show excerpt; user assesses quality subjectively |
| Real-time streaming output during benchmark | Looks cool | Interleaves timing measurement with I/O; distorts the speed numbers being measured | Capture full output to temp file, then display after completion |

---

## Feature Dependencies

```
[Candidate config file]
    └──required by──> [Memory-fit pre-check]
    └──required by──> [Benchmark sweep runner]
                           └──required by──> [Side-by-side report]
                                                  └──required by──> [Human picks winner]
                                                                          └──required by──> [Write settings file]
                                                                                                 └──required by──> [transcribrr.sh reads defaults]

[Warm-up run]
    └──required by──> [Timed benchmark run] (warm-up precedes timed run per model)

[Resumable sweep (partial results file)]
    └──enhances──> [Benchmark sweep runner]

[Claude skill]
    └──writes──> [Candidate config file]
    └──launched by──> [transcribrr.sh --benchmark] (when candidate file absent/stale)

[--benchmark-sample flag]
    └──enhances──> [Benchmark sweep runner]

[Dry-run mode]
    └──requires──> [Candidate config file]
    └──conflicts with──> [Benchmark sweep runner] (dry-run skips actual inference)
```

### Dependency Notes

- **Candidate config file required before anything else:** All benchmark features depend on knowing which models to sweep. The Claude skill produces this file; it can also be hand-edited. Benchmark runner must validate this file exists and is parseable before starting.
- **transcribrr.sh --benchmark flag is the entry point:** It should check for the candidate config, optionally launch the Claude skill if absent, then delegate to a `benchmark.sh` subscript (matching the existing script-per-concern pattern).
- **Settings file write requires explicit user action:** The report is presented; user types chosen model IDs; they are written. No silent writes. This matches how the existing pipeline's defaults work (flags, not magic).
- **Resumable sweep enhances but does not block MVP:** Can be deferred to v2.1 without breaking the core loop.

---

## MVP Definition

### Launch With (v2.0)

Minimum viable benchmark that delivers the core value: discover better models and lock them in.

- [ ] Candidate config file format (TSV or TOML): one row per candidate with `stage`, `hf_id`, `label`, `approx_size_gb` — read by benchmark runner and Claude skill
- [ ] `benchmark.sh` subscript: iterates candidates by stage, runs warm-up then timed invocation via existing subscripts, captures output, writes partial-results TSV
- [ ] Memory-fit pre-check: compare `approx_size_gb` from config against `sysctl hw.memsize` result; skip + warn if model would leave < 8GB headroom
- [ ] Side-by-side report: markdown file + terminal ASCII table showing model, RTF or tok/s, output excerpt (80 chars), pass/fail memory check
- [ ] Human winner selection: prompt user to enter winning model label per stage (or `skip` to keep current default)
- [ ] Write settings file: `$SCRIPT_DIR/.transcribrr-defaults` with `WHISPER_MODEL`, `CLEANUP_MODEL`, `SUMMARY_MODEL`; `transcribrr.sh` sources it if present
- [ ] `--benchmark` flag in `transcribrr.sh`: validate deps, check for candidate config, launch `benchmark.sh`
- [ ] Claude skill (`skills/research-mlx-models/SKILL.md`): researches current mlx-community models per stage, writes candidate config; auto-launched by `--benchmark` if config absent

### Add After Validation (v2.1)

- [ ] Resumable sweep — add after first real multi-model run reveals how often interruptions occur
- [ ] `--benchmark-sample <file>` flag — add when users report default sample isn't representative of their content
- [ ] Dry-run mode — add when users ask for a way to preview before committing

### Future Consideration (v3+)

- [ ] Automatic HF model-size fetch via API — deferred; `approx_size_gb` in config is good enough for now
- [ ] Parallel metadata fetch — deferred; complexity vs. benefit too low for v2

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Candidate config file | HIGH | LOW | P1 |
| Benchmark sweep runner (warm-up + timed + output capture) | HIGH | MEDIUM | P1 |
| Memory-fit pre-check | HIGH | LOW | P1 |
| Side-by-side report (markdown + terminal) | HIGH | MEDIUM | P1 |
| Human winner selection + settings file write | HIGH | LOW | P1 |
| transcribrr.sh reads settings file as defaults | HIGH | LOW | P1 |
| Claude skill for candidate research | HIGH | HIGH | P1 |
| Resumable sweep | MEDIUM | MEDIUM | P2 |
| `--benchmark-sample` flag | MEDIUM | LOW | P2 |
| Dry-run mode | MEDIUM | LOW | P2 |
| Automated HF size fetch | LOW | HIGH | P3 |

**Priority key:**
- P1: Must have for v2.0 launch
- P2: Add in v2.1 after validation
- P3: Future consideration only

---

## Candidate Model Shortlist

All models below are confirmed present in `mlx-community` (or official org-published MLX variants) as of 2026-06-14. Sizes are from HF model pages (HIGH confidence) except where noted MEDIUM.

### Stage 1: ASR / Whisper

The existing pipeline accepts labels like `turbo` which map to `mlx-community/whisper-large-v3-turbo` inside `transcribe.sh`. The benchmark sweep needs HF IDs.

| Label | HF ID | Approx Size | Speed (RTF on Apple Silicon) | WER / Quality | Notes |
|-------|--------|-------------|------------------------------|---------------|-------|
| `small` | `mlx-community/whisper-small` | ~240 MB | Very fast | Lower accuracy | Current default; good baseline |
| `turbo` | `mlx-community/whisper-large-v3-turbo` | ~1.6 GB (fp16) | ~130× real-time | ~7.75% WER (English) | Best speed/quality balance; strong recommendation |
| `turbo-4bit` | `mlx-community/whisper-large-v3-turbo-4bit` | ~463 MB | Faster than fp16 | Slightly degraded vs fp16 | Tight-memory option; notable size reduction |
| `distil-large-v3` | `mlx-community/distil-whisper-large-v3` | ~1.5 GB | ~6× faster than large-v3 | Near-identical to large-v3 for long-form; English-only | Good English-only alternative to turbo |
| `large-v3` | `mlx-community/whisper-large-v3-mlx-4bit` | ~3 GB (4bit) | ~55× real-time | ~13.2% WER (YouTube-commons) | Max accuracy; slower; fits 64GB easily |
| `parakeet-0.6b` | `mlx-community/parakeet-tdt-0.6b-v3` | ~2.5 GB | >2,000× real-time | ~8% WER English-only | Dramatically faster; English-only; separate Python package (`parakeet-mlx`), not mlx-whisper — requires transcribe.sh integration |
| `parakeet-1.1b` | `mlx-community/parakeet-tdt-1.1b` | ~4–5 GB (est.) | Fast | Lower WER than 0.6b | Higher accuracy parakeet; English-only; same integration caveat |

**Key notes on Parakeet:** Parakeet uses a separate CLI (`parakeet-mlx`) rather than `mlx_whisper`, so benchmarking it requires a code path in `transcribe.sh` that branches on model type. This is a non-trivial integration. Classify as a v2.1 stretch goal unless the user specifically wants it.

**Recommended candidates for v2.0 sweep:** `small`, `turbo`, `distil-large-v3`, `large-v3` (4bit). Skip Parakeet in v2.0; add in v2.1 with a dedicated integration flag.

### Stage 2: Cleanup LLM (Small Instruct)

Cleanup is a short structured task (fix filler words, punctuation, run-on sentences). A 1B–8B model is sufficient; quality above 8B has diminishing returns for this task.

| Label | HF ID | Approx Size | Notes |
|-------|--------|-------------|-------|
| `llama3.2-1b-4bit` | `mlx-community/Llama-3.2-1B-Instruct-4bit` | ~695 MB | Current smallest label; baseline candidate |
| `llama3.2-3b-4bit` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | ~1.8 GB | Current default label in codebase; good cleanup quality |
| `llama3.1-8b-4bit` | `mlx-community/Llama-3.1-8B-Instruct-4bit` | ~4.5 GB | Current pipeline default; solid cleanup |
| `qwen3-4b-4bit` | `mlx-community/Qwen3-4B-Instruct-2507-4bit` | ~2.5 GB (est.) | Qwen3 generation; thinking/non-thinking modes; good instruction following; MEDIUM confidence on size |
| `qwen3-8b-4bit` | `Qwen/Qwen3-8B-MLX-4bit` | ~4.3 GB | Qwen3 8B; strong instruction following; cleanup-appropriate size |

**Recommended candidates for v2.0 sweep:** `llama3.2-1b-4bit`, `llama3.2-3b-4bit`, `llama3.1-8b-4bit`, `qwen3-8b-4bit`. The 1B is a floor; 8B is the ceiling for cleanup given the task complexity.

### Stage 3: Summarization LLM (Large Instruct)

Summarization benefits from larger context window and stronger reasoning. 14B–32B is the sweet spot on 64GB. The existing pipeline defaults to `Qwen2.5-32B-4bit` (18.4 GB).

| Label | HF ID | Approx Size | Notes |
|-------|--------|-------------|-------|
| `Qwen2.5-7B-4bit` | `mlx-community/Qwen2.5-7B-Instruct-4bit` | ~4.5 GB (est.) | Existing label in codebase; fast; lower quality than 32B |
| `Qwen2.5-14B-4bit` | `mlx-community/Qwen2.5-14B-Instruct-4bit` | ~8–9 GB (est.) | Good midpoint; MEDIUM confidence on size |
| `Qwen2.5-32B-4bit` | `mlx-community/Qwen2.5-32B-Instruct-4bit` | ~18.4 GB | Current default; strong summarization quality |
| `Qwen3-14B-4bit` | `Qwen/Qwen3-14B-MLX-4bit` | ~7.85 GB | Qwen3 generation; thinking mode for nuanced summaries; better reasoning than Qwen2.5-14B |
| `Qwen3-32B-4bit` | `Qwen/Qwen3-32B-MLX-4bit` | ~17.4 GB | Qwen3 generation; thinking mode; matches Qwen2.5-32B size but newer generation |
| `Llama3.3-70B-4bit` | `mlx-community/Llama-3.3-70B-Instruct-4bit` | ~37 GB | Fits 64GB (headroom ~27GB); GPT-4-class quality; slow (~10 min per summary); worth benchmarking for quality ceiling |
| `Gemma3-27B-4bit` | `mlx-community/gemma-3-27b-it-qat-4bit` | ~16.8 GB | QAT model; strong multilingual; multimodal (image+text) but text-only use is valid |

**Models that do NOT fit 64GB (exclude from candidates):**
- Llama-3.3-70B-8bit: ~75 GB — exceeds 64GB
- Qwen2.5-72B-4bit: ~40 GB fits, but inference is very slow; low value vs 32B quality

**Recommended candidates for v2.0 sweep:** `Qwen2.5-32B-4bit` (baseline), `Qwen3-14B-4bit`, `Qwen3-32B-4bit`, `Llama3.3-70B-4bit` (quality ceiling). Optionally add `Gemma3-27B-4bit` as a diverse architecture candidate.

---

## Benchmark Report Format

### Terminal output during sweep

```
==========================================
  Benchmarking stage: transcribe
  Model 2/4: mlx-community/whisper-large-v3-turbo
==========================================

  [warm-up]  Running warm-up pass...
  [timed]    Running timed pass... done (47s, RTF: 131x)
  [output]   Saved to /tmp/benchmark_turbo_transcript.txt
```

### Final report (markdown + terminal ASCII)

The report renders as both a markdown file (machine-readable, human-saveable) and a terminal table:

```
## Stage: transcribe

| Model           | RTF     | Size   | Memory OK | Excerpt (first 80 chars)                   |
|-----------------|---------|--------|-----------|--------------------------------------------|
| whisper-small   | 800×    | 240MB  | YES       | "so today we're gonna talk about uh the..."  |
| whisper-turbo   | 131×    | 1.6GB  | YES       | "So today we are going to talk about the..." |
| distil-large-v3 | 240×    | 1.5GB  | YES       | "So today we are going to talk about the..." |
| whisper-large   | 55×     | 3.0GB  | YES       | "So today, we're going to talk about the..." |

Winner for transcribe? Enter label (or Enter to keep current 'small'):
```

### Settings file (written after human picks)

```bash
# .transcribrr-defaults — written by benchmark on 2026-06-14
# Edit manually or re-run: transcribrr.sh --benchmark
WHISPER_MODEL="turbo"
CLEANUP_MODEL="llama3.1-8b-4bit"
SUMMARY_MODEL="Qwen3-32B-4bit"
```

`transcribrr.sh` sources this file early in startup if it exists, before flag parsing, so CLI flags always override.

---

## Benchmark Sweep Behavior

### Sample selection

- **Default sample:** A bundled 2–3 minute MP3 of English speech (stored in `samples/benchmark_sample.mp3`). Long enough that RTF numbers stabilize; short enough that each model run takes 30–120 seconds.
- **Custom sample:** `--benchmark-sample <file>` overrides the default for domain-representative testing.
- **Why not a YouTube URL:** Benchmark must be offline-reproducible; network variance would corrupt timing.

### Warm-up strategy

One warm-up pass per model per stage immediately before the timed pass. The warm-up run: uses the same sample, discards all output and timing. Purpose: allow Metal to JIT-compile shaders and load model weights into active GPU memory. This is the universal pattern across Ollama benchmarks, NVIDIA AIPerf, and Apple's own MLX benchmarking guidance.

### Number of timed passes

One timed pass per model per stage. Multiple passes offer marginal variance reduction but multiply benchmark time by N. With a 2-minute sample and 4 candidates per stage × 3 stages = 12 runs, one pass per model keeps the sweep under 60 minutes. If the user wants statistical confidence, they re-run manually.

### Resumable sweep

Partial results written to `benchmark_results_<timestamp>.tsv` after each model completes. On resume (`--benchmark-resume`), read the TSV and skip already-completed model/stage pairs. This makes interruption-safe sweeps possible without re-running completed models.

### Memory-fit check

Before attempting to load a model:
1. Read `approx_size_gb` from candidate config.
2. Query available unified memory: `sysctl hw.memsize` (total) minus estimated active usage.
3. If `approx_size_gb > available_gb - 8` (8GB headroom), skip with a warning: `"SKIP: [model] (~17GB) would leave <8GB headroom on this system; skipping."`.
4. For MLX, `mx.metal.set_memory_limit()` can enforce a ceiling before load, but this requires Python. A bash-level size guard is simpler and sufficient for 64GB hardware where most candidates fit comfortably.

---

## Sources

- [mlx-community Whisper collection — HuggingFace](https://huggingface.co/collections/mlx-community/whisper) — model variants, sizes
- [mlx-community/whisper-large-v3-turbo-fp16 — HuggingFace](https://huggingface.co/mlx-community/whisper-large-v3-turbo-fp16) — 1.61 GB fp16 size (HIGH)
- [mlx-community/whisper-large-v3-turbo-4bit — HuggingFace](https://huggingface.co/mlx-community/whisper-large-v3-turbo-4bit) — 463 MB size (HIGH)
- [Whisper Large V3 Turbo vs V3: 5× Faster on Mac — Whisper Notes](https://whispernotes.app/blog/introducing-whisper-large-v3-turbo) — RTF, memory, M2 benchmark (MEDIUM)
- [Best open source STT model 2026 — Northflank](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks) — Parakeet vs Whisper WER/RTF comparison (MEDIUM)
- [parakeet-mlx — Simon Willison](https://simonwillison.net/2025/Nov/14/parakeet-mlx/) — Parakeet MLX size and speed (MEDIUM)
- [mlx-community Parakeet collection — HuggingFace](https://huggingface.co/collections/mlx-community/parakeet) — confirmed model IDs (HIGH)
- [distil-whisper/distil-large-v3 — HuggingFace](https://huggingface.co/distil-whisper/distil-large-v3) — 756M params, 6× faster, within 1% WER (HIGH)
- [mlx-community/Llama-3.2-1B-Instruct-4bit — HuggingFace](https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit) — 695 MB (HIGH)
- [mlx-community/Llama-3.2-3B-Instruct-4bit — HuggingFace](https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit) — 1.81 GB (HIGH)
- [mlx-community/Llama-3.1-8B-Instruct-4bit — HuggingFace](https://huggingface.co/mlx-community/Llama-3.1-8B-Instruct-4bit) — 4.52 GB (HIGH)
- [Qwen/Qwen3-8B-MLX-4bit — HuggingFace via search](https://huggingface.co/Qwen/Qwen3-8B-MLX-4bit) — 4.3 GB (MEDIUM)
- [Qwen/Qwen3-14B-MLX-4bit — HuggingFace](https://huggingface.co/Qwen/Qwen3-14B-MLX-4bit) — 7.85 GB (HIGH)
- [Qwen/Qwen3-32B-MLX-4bit — HuggingFace](https://huggingface.co/Qwen/Qwen3-32B-MLX-4bit) — 17.4 GB (HIGH)
- [mlx-community/Qwen2.5-32B-Instruct-4bit — HuggingFace](https://huggingface.co/mlx-community/Qwen2.5-32B-Instruct-4bit) — 18.4 GB (HIGH)
- [mlx-community/Llama-3.3-70B-Instruct-4bit — HuggingFace via search](https://huggingface.co/mlx-community/Llama-3.3-70B-Instruct-4bit) — ~37 GB (MEDIUM)
- [mlx-community/gemma-3-27b-it-qat-4bit — HuggingFace](https://huggingface.co/mlx-community/gemma-3-27b-it-qat-4bit) — 16.8 GB (HIGH)
- [Benchmarking Local LLMs with Ollama — Medium](https://medium.com/@walterdeane/benchmarking-local-llms-with-ollama-and-a-simple-bash-script-8fdb5baf5456) — warm-up pattern, CSV logging, ASCII table (MEDIUM)
- [vLLM Benchmarking Sweeps — vLLM docs](https://docs.vllm.ai/en/latest/benchmarking/sweeps/) — `--resume` pattern for resumable sweeps (MEDIUM)
- [MLX Memory Safety — DEV Community](https://dev.to/sleepyquant/mlx-memory-safety-checklist-6-layer-defense-for-m1m2-apple-silicon-2cbj) — memory limit patterns (MEDIUM)
- [Why I chose Whisper over Parakeet — arunbaby.com](https://www.arunbaby.com/speech-tech/0073-whisper-vs-parakeet-asr-decision/) — Parakeet MLX ecosystem maturity concerns (MEDIUM)

---

*Feature research for: transcribrr v2.0 — Model Benchmarking & Auto-Selection*
*Researched: 2026-06-14*
