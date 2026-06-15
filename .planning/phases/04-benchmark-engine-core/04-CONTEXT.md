# Phase 4: Benchmark Engine Core - Context

**Gathered:** 2026-06-15
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver the **benchmark engine core**: `transcribrr.sh --benchmark` dispatches to a new `benchmark.sh` that runs a hardware-aware, **staged interactive** sweep. For each pipeline stage (whisper → cleanup → summarize) it runs every hardware-fitting candidate in its own fresh subprocess, with a warm-up pass, measured steady-state speed (RTF / tok-s), peak memory, a real output excerpt, and live progress — then the human picks the best output for that stage, and that pick becomes the input to the next stage.

**In scope (Phase 4):** `--benchmark`/`--sample`-style flag dispatch in `transcribrr.sh`; the `benchmark.sh` engine; hardware memory detection (HW-01); memory-fit gate with safety headroom (HW-02/03); disk-space gate before downloads; pre-fetch of uncached fitting candidates; subprocess-per-candidate execution with warm-up (BENCH-02/03); per-stage metrics — speed + peak memory (BENCH-04); real output excerpt capture (BENCH-05); default audio sample download + cache (BENCH-06); auto-install of `mlx-whisper` (BENCH-07); live progress (BENCH-08); per-candidate JSON result files; **interactive per-stage selection** that drives chaining. Requirements: HW-01/02/03, BENCH-01..08.

**Out of scope (later phases):**
- **Phase 5:** the saved markdown `report.md`, resumable sweeps, and the atomic write of the human's per-stage picks to `config/settings.conf` (RPT-01/02/03, RESUME-01/02). Phase 4 *makes* the picks interactively (as the chaining mechanism) and persists per-candidate JSON results; Phase 5 turns those into a saved report and writes winners to settings.
- **Phase 6:** the Claude refresh skill and `--benchmark` auto-launch of it (SKILL-01..04).

**Out of scope (milestone-level, per REQUIREMENTS Out-of-Scope):** automated scoring / auto-pick (human is the judge); full N×M×P matrix; mid-sweep model downloads; multi-pass timing averaging (FUT-05); cloud/API models.

</domain>

<decisions>
## Implementation Decisions

### Sweep flow — staged interactive pipeline
- **D-01:** The sweep is an **interactive, staged pipeline**, not an unattended batch. For each stage in order (whisper → cleanup → summarize): run every fitting candidate, display its speed/peak-memory/output-excerpt, then prompt the human to **pick the single best output**. That pick is carried forward as the **input to the next stage** (this is the "chain from one upstream" decision — the upstream is human-selected, not auto-chosen).
- **D-02:** **Run all hardware-fitting candidates** per stage (no cap). The fit gate (D-07/D-08) determines which candidates run; everything that fits is benchmarked.
- **D-03:** `--benchmark` **requires an interactive TTY**. With no TTY (piped from `/dev/null`, cron, or a non-interactive caller) it **aborts cleanly** with a clear message rather than hanging at a selection prompt. ⚠️ See Cross-Phase Implications — this changes Phase 6's success criterion #3.
- **D-04:** **Phase 4 makes the per-stage picks; Phase 4 does NOT write `settings.conf`.** Phase 4 persists per-candidate JSON results and the human's per-stage selections (in the run directory). Phase 5 owns the saved `report.md`, resumability, and the **atomic `settings.conf` write** of the winners.

### Hardware fit gate (HW-01/02/03)
- **D-05:** Detect total unified memory at runtime (HW-01) — e.g. `sysctl hw.memsize` (bash 3.2 portable; print detected GB at sweep start per success criterion #1).
- **D-06:** **Usable memory ceiling = ~75% of detected RAM** (reserve ~25% for macOS/frameworks per PITFALLS #3 — ~48 GB usable on a 64 GB M2 Max).
- **D-07:** Fit estimate = **`size_gb` (from `candidates.conf`) + a fixed runtime-overhead buffer** (covers Python, tokenizer, KV cache, MLX allocator). No per-model HF-config introspection — uses only data already in `candidates.conf`. Skip any candidate whose estimate exceeds the usable ceiling **before execution**, logging the reason (HW-02/03, success criterion #2). NOTE: because the sample is the full video (D-13), transcripts are long → KV-cache demand is higher; the overhead buffer should be chosen generously. Exact buffer value is Claude's discretion (research to recommend; ~4 GB starting point from PITFALLS #7).

### Downloads & disk (BENCH-06, pre-fetch)
- **D-08:** **Pre-fetch step before timing.** Before the timed sweep, download any fitting-but-uncached candidate (with progress) so no download latency contaminates RTF (PITFALLS #1). Timing starts only once every needed model is present locally. No mid-sweep downloads (milestone Out-of-Scope).
- **D-09:** **Disk-space gate before pre-fetch.** Sum the `size_gb` of all fitting-but-uncached candidates, compare against available space on the HF-cache volume (`df`) plus a buffer, and **hard-abort with a "need X GB, have Y GB" message** if it won't fit — before any download begins. (Memory-fit gate decides what *runs*; disk-space gate decides what can be *fetched*.)

### Metrics (BENCH-04/05)
- **D-10:** **Peak memory measured externally** by wrapping each candidate subprocess in **`/usr/bin/time -l`** and reading "maximum resident set size" — captures the whole process (weights + Python + tokenizer + KV cache + MLX allocator) honestly. (MLX in-process `get_peak_memory()` may optionally be logged as a diagnostic cross-check; not the headline number.)
- **D-11:** **Speed metric:** RTF = wall-time ÷ audio-duration for whisper (audio duration already computed by `transcribe.sh` via ffmpeg); tokens/sec from `mlx_lm`'s own reported generation rate for cleanup/summarize. Timing starts **after** the warm-up pass (BENCH-03, success criterion #4).
- **D-12:** **Real output excerpt** from each model captured into its per-model result file (BENCH-05, success criterion #5) via the existing `OUTPUT_FILE=` contract (ARCHITECTURE Pattern 2 — stage scripts unchanged).

### Audio sample (BENCH-06)
- **D-13:** Default benchmark sample source = **`https://www.youtube.com/watch?v=EWo7-azGHic`**, using the **full video** (no clipping). Downloaded via the existing `yt-dlp` → MP3-extraction path on first run and **cached locally**; subsequent runs reuse the cached MP3 without network access (success criterion #6). Implication: full-length audio means longer per-candidate runs (a multi-model sweep may take a while) and larger KV-cache pressure — reinforces D-07's generous overhead buffer.

### Thermal & timing fidelity
- **D-14:** **Fixed cool-down pause between candidates** (~45 s default, within the 30–60 s range from PITFALLS #4) so back-to-back runs don't let thermal throttling skew later candidates' speed numbers. Exact duration is Claude's discretion; may be exposed as a constant/flag.

### Result persistence & failure handling
- **D-15:** **One JSON result file per candidate** (fields: model id/label, stage, speed metric, peak_mem, output-excerpt path, fit status — or an `{"error": ...}` payload). This is the contract Phase 5's resume/report builds on (RESUME-01/02). Flat files (not bash arrays) — bash 3.2 safe and subprocess-friendly.
- **D-16:** **Continue-on-failure:** a candidate that OOMs or fails to load is logged (error JSON) and the sweep **continues to the next candidate** rather than aborting the whole run (ARCHITECTURE Anti-Pattern 2; PITFALLS #7 subprocess catch).

### Architecture (locked by research / prior phases — not re-litigated)
- **D-17:** `--benchmark` **exec-dispatches** to a new `benchmark.sh` at repo root (ARCHITECTURE Pattern 1); stage scripts (`transcribe.sh` / `cleanup-transcript.sh` / `summarize-transcript.sh`) are **unmodified** and reused via `--model` + `OUTPUT_FILE=` (Pattern 2). Per-stage independent sweep, **not** the N×M×P matrix (Anti-Pattern 4). Results in `results/benchmark_<ts>/`, gitignored (Anti-Pattern 3). `candidates.conf` is **parsed, never sourced** (already shipped in Phase 3).

### Claude's Discretion
- Exact runtime-overhead buffer GB (D-07), cool-down duration (D-14), JSON result schema fields (D-15), live-progress line format (BENCH-08 — follow the existing `stage_banner` idiom + a per-candidate current-model/stage/elapsed line), the pre-fetch mechanism (`huggingface-cli download` vs a Python `load()` dry-run), and the no-TTY detection method (`[ -t 0 ]` / `[ -t 1 ]`). Optional memory-pressure pre-flight warning (PITFALLS #3) is welcome but not required.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements & Roadmap
- `.planning/ROADMAP.md` §"Phase 4: Benchmark Engine Core" — goal, 7 success criteria, requirement IDs (HW-01/02/03, BENCH-01..08).
- `.planning/REQUIREMENTS.md` §Hardware Fit (HW), §Benchmark Engine (BENCH) — full requirement text; §Out of Scope table (auto-scoring, full matrix, mid-sweep download, multi-pass — all excluded); §Future Requirements (FUT-05 multi-pass deferred).

### v2.0 Research (grounds the chosen patterns)
- `.planning/research/ARCHITECTURE.md` — **Pattern 1** (`--benchmark` dispatch to `benchmark.sh`), **Pattern 2** (`OUTPUT_FILE=` reuse, stage scripts unchanged), the Benchmark Run Flow data-flow, Integration Points table (exact `transcribrr.sh` touch points), and Anti-Patterns 2/3/4. NOTE: this CONTEXT overrides the data-flow's "auto-pick the default/first whisper output" note — the upstream input is **human-selected per stage** (D-01).
- `.planning/research/PITFALLS.md` — **#1** (download latency in RTF → pre-fetch, D-08), **#2/#3** (warm-up + memory pressure), **#4** (thermal cool-down, D-14), **#6** (subprocess-per-candidate), **#7** (memory-fit estimate + subprocess OOM catch, D-07/D-16), **#12** (bash 3.2 — no `declare -A`, no float in `(( ))`, `LC_NUMERIC=C`/`awk` for floats). "Looks Done But Isn't" checklist applies.
- `.planning/research/STACK.md`, `.planning/research/FEATURES.md` — milestone stack/feature context.

### Prior phase context (carry-forward)
- `.planning/phases/03-candidate-config-pipeline-settings-integration/03-CONTEXT.md` — `candidates.conf` `[candidate]` block format (D-01/D-02 there), `stage` values (`whisper`/`cleanup`/`summarize`), parse-not-source rule, and the settings/provenance/error patterns the Phase 5 settings write will extend.

### Existing code (read before editing)
- `transcribrr.sh` — orchestrator. Flag-parse loop (lines 103–149) is where `--benchmark`/`--sample` cases are added; add the exec-dispatch after flag parsing/settings read. ERR trap + `CURRENT_STAGE` (lines 33–34), `stage_banner()` (lines 301–308), and the `_run_*` capture idiom (`tee /dev/stderr` + `grep "^OUTPUT_FILE="`, lines 436–520) are the patterns `benchmark.sh` mirrors. `print_help()` needs `--benchmark` documented.
- `transcribe.sh` — `setup_venv()` auto-installs `mlx-whisper` into `.venv` (lines 76–92) — the pattern BENCH-07 extends; audio-duration computation (lines ~103–113) feeds RTF; emits `OUTPUT_FILE=` (line 273).
- `cleanup-transcript.sh`, `summarize-transcript.sh` — `setup_venv()` auto-installs `mlx-lm`; accept `--model <label|hf-id>`; emit `OUTPUT_FILE=`. `summarize-transcript.sh` uses `mlx_lm.generate` (reports tok/s — feeds D-11).
- `config/candidates.conf` — the vetted list the sweep reads (4 whisper / 4 cleanup / 5 summarize candidates with `size_gb`). `.gitignore` already ignores `config/settings.conf` and `*_*/` working dirs; `results/` will need a gitignore entry.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`stage_banner()` (`transcribrr.sh:301`)** — reuse for the live-progress stage headers (BENCH-08).
- **`_run_transcribe/_run_cleanup/_run_summarize` capture idiom** — `"$script" "$input" --model "$m" | tee /dev/stderr | grep "^OUTPUT_FILE="`. `benchmark.sh` wraps the same call (plus `/usr/bin/time -l` for peak mem, D-10) per candidate. Stage scripts need **zero changes**.
- **`setup_venv()` (in each stage script)** — already auto-installs `mlx-whisper`/`mlx-lm` on first import-miss; BENCH-07 is largely satisfied by reusing these on the first benchmark run (confirm/extend rather than reinvent).
- **Audio-duration logic in `transcribe.sh`** — already computes total seconds via ffmpeg; reuse the same approach to derive RTF denominator.
- **Atomic temp+`mv` write pattern (`transcribrr.sh:567–603`)** — the discipline Phase 5's `settings.conf` write will copy (not needed for Phase 4's append-only JSON results, but referenced for continuity).

### Established Patterns
- **Bash 3.2 only** — no `mapfile`/`readarray`, no `declare -A`, no float in `(( ))`; use `awk`/`LC_NUMERIC=C bc` for float math; portable `while read` loops (PITFALLS #12). `candidates.conf` parsed with `grep`/`while read`, never sourced.
- **`SCRIPT_DIR`-relative paths** (`transcribrr.sh:10`) — reference `config/candidates.conf`, `results/`, `.venv` relative to the script dir.
- **`set -euo pipefail` + per-stage `ERR` trap** — `benchmark.sh` will need its own error policy so a single candidate failure does not abort the whole sweep (D-16, Anti-Pattern 2).

### Integration Points
- **New `benchmark.sh`** at repo root (peer of the stage scripts).
- **`transcribrr.sh`**: `--benchmark`/`--sample` flag cases + exec-dispatch block (after flag parse / settings read, before/around `preflight_check`); `print_help()` update.
- **New `results/` directory** (gitignored) holding `benchmark_<timestamp>/` per-run dirs with per-candidate JSON + output excerpts + the cached sample.
- **HF cache** (`~/.cache/huggingface/hub`) — the volume the disk-space gate (D-09) checks and the pre-fetch (D-08) populates.

</code_context>

<specifics>
## Specific Ideas

- **Default sample is a specific YouTube video the user chose:** `https://www.youtube.com/watch?v=EWo7-azGHic`, **full length** (D-13). Downloaded + cached on first benchmark run via the existing yt-dlp path.
- The sweep's per-stage selection prompts are the explicit human-in-the-loop step the user wants — quality is judged by the human from real output excerpts, not auto-scored (consistent with the milestone's "human is the judge" stance).

</specifics>

<deferred>
## Deferred Ideas

- **Phase 6 cross-phase implication (MUST revisit):** D-03 makes `--benchmark` require a TTY. Phase 6 success criterion #3 ("Running `transcribrr.sh --benchmark` fully unattended (piped from `/dev/null`) completes without hanging") can therefore only apply to the **skill-refresh subprocess** (`claude -p` exiting within timeout), not to the interactive sweep completing end-to-end. The roadmap/Phase 6 criterion should be reworded when Phase 6 is discussed. Not changed now.
- **Multi-pass timing averaging** (FUT-05) — single timed pass this milestone.
- **`--max-candidates N` cap** — considered (would limit per-stage runs); rejected in favour of "all fitting candidates" (D-02). Easy to add later if sweeps grow too long.
- **`--cooldown SECONDS` flag** — D-14 fixes a default; exposing it as a flag is optional/discretion.
- **Configurable usable-memory fraction** — D-06 fixes 75%; making it tunable was considered and deferred (not needed now).
- **Memory-pressure pre-flight warning** (PITFALLS #3) — optional nicety, not required for the core.

None of the discussion strayed outside the phase scope except the explicit, recorded Phase 4↔5 boundary shift (interactive picking now lives in Phase 4) and the Phase 6 implication above.

</deferred>

---

*Phase: 4-Benchmark Engine Core*
*Context gathered: 2026-06-15*
