# Requirements: transcribrr v2.0 — Model Benchmarking & Auto-Selection

**Defined:** 2026-06-14
**Core Value:** One command takes a YouTube URL to a finished markdown file (summary + full transcript) reliably and unattended — reusing the existing MLX scripts. v2.0 lets the user discover the best current MLX models for their hardware and lock them in as defaults.

## v2.0 Requirements

Requirements for the Model Benchmarking & Auto-Selection milestone. Each maps to exactly one roadmap phase.

### Candidate Models (MODEL)

- [x] **MODEL-01**: A `candidates.conf` config file lists benchmark candidates per stage (transcription, cleanup, summarization), each with HF ID, friendly label, stage, and approximate size — parsed (never sourced) by the benchmark engine.
- [x] **MODEL-02**: The repo ships a vetted initial candidate list covering current best-in-class MLX models per stage (e.g. whisper-large-v3-turbo / distil-large-v3 for ASR; Llama-3.x / Qwen3 small for cleanup; Qwen3-14B/32B, Qwen2.5-32B, Llama-3.3-70B for summarization).
- [x] **MODEL-03**: The benchmark accepts any candidate as a raw HF ID, reusing the existing `--model <label|hf-id>` plumbing in the stage scripts (no stage-script modification required).

### Hardware Fit (HW)

- [ ] **HW-01**: The script detects the current hardware's total unified memory at runtime (not a hardcoded assumption).
- [ ] **HW-02**: Before benchmarking, each candidate is checked against detected available memory; models that would not fit (with a safety headroom) are excluded from the sweep and reported as skipped with the reason.
- [ ] **HW-03**: Only models that fit the detected architecture are ever loaded — an unfit model is never executed.

### Benchmark Engine (BENCH)

- [x] **BENCH-01**: A `--benchmark` mode runs each fitting candidate through its real pipeline stage on a sample input, producing real per-model output.
- [ ] **BENCH-02**: Each candidate runs in its own subprocess so MLX/Metal memory is released between models (prevents mid-sweep OOM).
- [ ] **BENCH-03**: Each model gets a discarded warm-up pass before the timed pass so model-load/JIT-compile time does not contaminate measurements.
- [ ] **BENCH-04**: The engine records wall-clock time per stage and derives the speed metric (RTF for transcription, tokens/sec for the LLM stages) and peak memory per model.
- [ ] **BENCH-05**: The engine captures a real output excerpt from each model for side-by-side quality comparison.
- [ ] **BENCH-06**: The benchmark obtains a default audio sample by downloading it on first run and caching it locally, so runs are reproducible without bundling a file in the repo.
- [x] **BENCH-07**: Missing benchmark dependencies (notably `mlx-whisper`, absent from `.venv`) are auto-installed as part of `--benchmark` setup, consistent with the existing auto-install-deps behavior.
- [ ] **BENCH-08**: Live progress is shown during the sweep (current model, stage, elapsed) so a long run is clearly not hung.

### Resumable Sweep (RESUME)

- [ ] **RESUME-01**: Partial results are persisted after each model completes, so an interrupted sweep is not lost.
- [ ] **RESUME-02**: A resumed sweep skips model/stage pairs already completed and continues from where it stopped.

### Report & Selection (RPT)

- [ ] **RPT-01**: After the sweep, a comparison report shows real per-model/per-stage results (speed, memory, fit, output excerpt) as both a terminal table and a saved markdown file.
- [ ] **RPT-02**: The user picks the winning model per stage from the report (no automated scoring); choosing "keep current" is allowed.
- [ ] **RPT-03**: The chosen winners are written to a settings file via an atomic write (never a partial/corrupt file).

### Pipeline Auto-Selection (CFG)

- [x] **CFG-01**: A normal `transcribrr.sh` run reads the settings file (if present) to select default models per stage.
- [x] **CFG-02**: Model selection precedence is explicit and correct: CLI flag > settings file > built-in default (a flag that names the built-in default still overrides the settings file).
- [x] **CFG-03**: On a normal run, a settings-file model that no longer exists/loads produces a clear, actionable error pointing back to `--benchmark`, not a cryptic load failure.

### Candidate Refresh Skill (SKILL)

- [ ] **SKILL-01**: A Claude Code skill researches current best mlx-community models per stage and writes/refreshes `candidates.conf`.
- [ ] **SKILL-02**: `--benchmark` auto-launches the skill via the headless `claude` CLI when the candidate list is missing or stale, with a permission mode and timeout that keep the run unattended.
- [ ] **SKILL-03**: Skill output is validated as untrusted before use — each candidate ID must exist on HF, be MLX-compatible (`library_name`), and match the stage's model type; invalid entries are rejected.
- [ ] **SKILL-04**: When the `claude` CLI is unavailable or offline, `--benchmark` degrades gracefully (a `--no-skill-refresh` path / existing candidates.conf is used) rather than failing.

## Future Requirements (v2.1+)

Acknowledged but deferred. Not in the current roadmap.

### Deferred Benchmark Features

- **FUT-01**: `--benchmark-sample <file>` to supply a custom, domain-representative audio sample.
- **FUT-02**: Dry-run mode (`--benchmark-dry-run`) that enumerates candidates and fit checks without running inference.
- **FUT-03**: Parakeet ASR support (`parakeet-mlx`) — a separate, non-`mlx_whisper` code path in `transcribe.sh`.
- **FUT-04**: Automatic HF model-size fetch via the Hub API (instead of `approx_size` in `candidates.conf`).
- **FUT-05**: Multiple timed passes per model for statistical confidence.

## Out of Scope

Explicitly excluded. Anti-features from research with reasoning.

| Feature | Reason |
|---------|--------|
| Automated model scoring / auto-pick winner | Quality is subjective to the user's audio domain and style; any scoring formula embeds hidden assumptions and gives false confidence. The human is the judge. |
| Benchmark every quantization of every model | Combinatorial explosion (100+ runs, 10+ hours). One recommended quant per candidate; user adds variants manually. |
| Auto-download models mid-sweep | A multi-GB download mid-run contaminates timing and blocks subsequent models. Models must be pre-downloaded; the sweep emits a clear hint if one is missing. |
| Cloud/API model comparison (OpenAI Whisper API, etc.) | The pipeline is deliberately local; adds auth, billing, and network-latency variance. |
| Background/automatic candidate refresh | Silent config-mutating background scripts erode trust. The skill runs only on explicit `--benchmark`-driven need. |
| WER computation vs reference transcript | No ground-truth reference exists at benchmark time; real-world WER needs human annotation. Excerpt + RTF + human judgment instead. |
| Streaming output during timed runs | Interleaving I/O with timing distorts the speed numbers. Capture to temp file, display after. |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| MODEL-01 | Phase 3 | Complete |
| MODEL-02 | Phase 3 | Complete |
| MODEL-03 | Phase 3 | Complete |
| HW-01 | Phase 4 | Pending |
| HW-02 | Phase 4 | Pending |
| HW-03 | Phase 4 | Pending |
| BENCH-01 | Phase 4 | Complete |
| BENCH-02 | Phase 4 | Pending |
| BENCH-03 | Phase 4 | Pending |
| BENCH-04 | Phase 4 | Pending |
| BENCH-05 | Phase 4 | Pending |
| BENCH-06 | Phase 4 | Pending |
| BENCH-07 | Phase 4 | Complete |
| BENCH-08 | Phase 4 | Pending |
| RESUME-01 | Phase 5 | Pending |
| RESUME-02 | Phase 5 | Pending |
| RPT-01 | Phase 5 | Pending |
| RPT-02 | Phase 5 | Pending |
| RPT-03 | Phase 5 | Pending |
| CFG-01 | Phase 3 | Complete |
| CFG-02 | Phase 3 | Complete |
| CFG-03 | Phase 3 | Complete |
| SKILL-01 | Phase 6 | Pending |
| SKILL-02 | Phase 6 | Pending |
| SKILL-03 | Phase 6 | Pending |
| SKILL-04 | Phase 6 | Pending |

**Coverage:**

- v2.0 requirements: 26 total
- Mapped to phases: 26
- Unmapped: 0 ✓

---
*Requirements defined: 2026-06-14*
*Last updated: 2026-06-14 — traceability filled after roadmap creation*
