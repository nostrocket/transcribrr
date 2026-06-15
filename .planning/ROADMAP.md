# Roadmap: transcribrr — YouTube-to-Markdown Pipeline

## Milestones

- ✅ **v1.0 MVP** — Phases 1–2 (shipped 2026-06-14) — see [milestones/v1.0-ROADMAP.md](milestones/v1.0-ROADMAP.md)
- 🚧 **v2.0 Model Benchmarking & Auto-Selection** — Phases 3–6 (in progress)

## Phases

<details>
<summary>✅ v1.0 MVP (Phases 1–2) — SHIPPED 2026-06-14</summary>

- [x] Phase 1: Scriptable Pipeline Foundation (2/2 plans) — completed 2026-06-14
- [x] Phase 2: End-to-End YouTube-to-Markdown Delivery (2/2 plans) — completed 2026-06-14

Full details: [milestones/v1.0-ROADMAP.md](milestones/v1.0-ROADMAP.md)

</details>

> **Note:** v1.0 shipped code-complete with all 22 requirements implemented and statically verified. Hands-on UAT (real yt-dlp/MLX pipeline runs) is tracked as deferred in STATE.md → Deferred Items and in `phases/*/*-HUMAN-UAT.md`.

### 🚧 v2.0 Model Benchmarking & Auto-Selection (In Progress)

**Milestone Goal:** Discover the best current MLX models for each pipeline stage, benchmark them on this hardware with real outputs, let the user pick winners, and have the normal pipeline automatically use them as defaults.

- [x] **Phase 3: Candidate Config & Pipeline Settings Integration** - Candidate format defined, vetted initial list ships, and the normal pipeline reads a settings file with correct three-tier precedence (completed 2026-06-14)
- [ ] **Phase 4: Benchmark Engine Core** - Hardware-aware sweep runs each fitting candidate in its own subprocess with warm-up, captures real speed/memory/output metrics, and shows live progress
- [ ] **Phase 5: Resumable Sweep, Report & Winner Selection** - Sweep survives interruption, a comparison report surfaces real per-model results, and winner choices are written atomically to settings
- [ ] **Phase 6: Claude Skill — Candidate Refresh** - A Claude Code skill researches and writes `candidates.conf`; `--benchmark` auto-launches it with graceful offline fallback and untrusted-output validation

## Phase Details

### Phase 3: Candidate Config & Pipeline Settings Integration

**Goal**: Users have a working `candidates.conf` with a vetted model list and the normal pipeline reads `settings.conf` with correct flag > settings > built-in precedence
**Depends on**: Phase 2 (existing `transcribrr.sh`)
**Requirements**: MODEL-01, MODEL-02, MODEL-03, CFG-01, CFG-02, CFG-03
**Success Criteria** (what must be TRUE):

  1. `config/candidates.conf` exists, lists real HF model IDs for all three stages, and is parsed by `benchmark.sh` without being sourced
  2. Running `transcribrr.sh` without flags and with a `config/settings.conf` present selects the models specified in that file
  3. Passing `--whisper-model small` on the command line overrides a `settings.conf` that specifies a different model (flag always wins)
  4. A `settings.conf` referencing a non-existent or unloadable model produces a clear, actionable error message directing the user to `--benchmark`, not a cryptic load failure
  5. Any HF model ID from `candidates.conf` is accepted by the existing stage scripts via the `--model` flag without modifying those scripts**Plans**: 2 plans
- [x] 03-01-PLAN.md — config/candidates.conf vetted list, settings.conf.example, .gitignore (MODEL-01, MODEL-02)
- [x] 03-02-PLAN.md — transcribrr.sh three-tier precedence, settings.conf read, CFG-03 error, MODEL-03 confirm (MODEL-03, CFG-01/02/03)

### Phase 4: Benchmark Engine Core

**Goal**: Running `transcribrr.sh --benchmark` executes a complete sweep of all hardware-fitting candidates through their real pipeline stages with warm-up, measured timing, peak memory, and live progress
**Depends on**: Phase 3
**Requirements**: HW-01, HW-02, HW-03, BENCH-01, BENCH-02, BENCH-03, BENCH-04, BENCH-05, BENCH-06, BENCH-07, BENCH-08
**Success Criteria** (what must be TRUE):

  1. The detected system memory is printed at sweep start and matches the actual hardware (e.g. 64 GB on an M2 Max)
  2. A candidate whose approximate size exceeds available memory with safety headroom is skipped before execution with a logged reason; no unfit model is ever loaded
  3. Each candidate runs in a fresh subprocess — confirmed by `ps` showing one Python process per model, none overlapping; a sweep of multiple large models completes without OOM
  4. Timing starts after the warm-up pass completes; the reported RTF/tok-s reflects steady-state inference, not model-load latency
  5. A real output excerpt (transcript/cleaned/summary text) from each model appears in the sweep's per-model result file
  6. A default benchmark audio sample is downloaded and cached on first run; subsequent runs use the local cache without network access
  7. Live progress is printed during the sweep showing current model, stage, and elapsed time — a long run does not appear hung

**Plans**: 4 plans
**Wave 1**

- [x] 04-01-PLAN.md — transcribrr.sh --benchmark/--sample exec-dispatch, .gitignore results/, benchmark.sh skeleton (TTY guard, setup_venv, helpers, candidates parser) (BENCH-01, BENCH-07)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 04-02-PLAN.md — RAM detection + 75% fit gate, disk-space gate, HF cache detect + pre-fetch, default sample download/cache (HW-01/02/03, BENCH-06)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 04-03-PLAN.md — run_candidate engine: warm-up + /usr/bin/time -l timed pass, RTF/tok-s, peak mem, excerpt, JSON writers, cooldown, live progress, continue-on-failure (BENCH-02/03/04/05/08)

**Wave 4** *(blocked on Wave 3 completion)*

- [ ] 04-04-PLAN.md — staged sweep loop (whisper→cleanup→summarize), skip records, interactive per-stage selection + chaining, sweep_meta.json (BENCH-01, HW-02, BENCH-08)

**UI hint**: no

### Phase 5: Resumable Sweep, Report & Winner Selection

**Goal**: Interrupted sweeps can be resumed without re-running completed models, a comparison report renders real results side-by-side, and winner selections are persisted atomically
**Depends on**: Phase 4
**Requirements**: RESUME-01, RESUME-02, RPT-01, RPT-02, RPT-03
**Success Criteria** (what must be TRUE):

  1. Killing a sweep mid-run (Ctrl-C) leaves a partial-results file; restarting with the same run directory skips all already-completed model/stage pairs and continues from where it stopped
  2. After a complete sweep, a markdown `report.md` exists in the results directory showing speed, memory, fit status, and an output excerpt for each model per stage
  3. The same results render as a terminal ASCII table immediately after the sweep finishes — no separate command required
  4. The user can select a winning model per stage (or choose "keep current") via an interactive prompt after reading the report; the choice is written to `config/settings.conf`
  5. A Ctrl-C during the `settings.conf` write leaves the file either fully written or absent — never a partial/corrupt file

**Plans**: TBD

### Phase 6: Claude Skill — Candidate Refresh

**Goal**: A Claude Code skill can research and write a fresh `candidates.conf`; `--benchmark` auto-launches it when the file is missing or stale, with validation of all skill output and clean degradation when Claude is unavailable
**Depends on**: Phase 4 (working sweep that accepts a hand-authored `candidates.conf`)
**Requirements**: SKILL-01, SKILL-02, SKILL-03, SKILL-04
**Success Criteria** (what must be TRUE):

  1. Running the `refresh-mlx-candidates` skill (manually or via `--benchmark`) produces a syntactically valid `candidates.conf` containing real HF model IDs for all three stages
  2. Every model ID written by the skill passes the validation gate (HF existence check, `library_name: mlx` metadata, correct stage model type) before the sweep begins; any invalid entry is rejected with a logged reason, not silently used
  3. Running `transcribrr.sh --benchmark` fully unattended (piped from `/dev/null`) completes without hanging — the `claude` subprocess exits within its timeout even if no TTY is present
  4. When `claude` is not on PATH or returns non-zero, `--benchmark` falls back to the existing `candidates.conf` (or aborts with a clear message if none exists) instead of failing without explanation

**Plans**: TBD

## Progress

**Execution Order:** Phases execute in numeric order: 3 → 4 → 5 → 6

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Scriptable Pipeline Foundation | v1.0 | 2/2 | Complete | 2026-06-14 |
| 2. End-to-End YouTube-to-Markdown Delivery | v1.0 | 2/2 | Complete | 2026-06-14 |
| 3. Candidate Config & Pipeline Settings Integration | v2.0 | 2/2 | Complete    | 2026-06-15 |
| 4. Benchmark Engine Core | v2.0 | 3/4 | In Progress|  |
| 5. Resumable Sweep, Report & Winner Selection | v2.0 | 0/TBD | Not started | - |
| 6. Claude Skill — Candidate Refresh | v2.0 | 0/TBD | Not started | - |
