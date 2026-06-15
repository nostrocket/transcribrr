# Phase 4: Benchmark Engine Core - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-15
**Phase:** 4-Benchmark Engine Core
**Areas discussed:** Stage input chaining, Model download handling, Memory-fit gate, Metrics & cool-down, Audio sample, Result persistence

---

## Stage input chaining

| Option | Description | Selected |
|--------|-------------|----------|
| Chain from one upstream | Run whisper first; one transcript feeds all cleanup candidates; one cleaned output feeds all summarize | ✓ (then refined) |
| Fixed canned reference text | Ship reference transcript/cleaned text in repo | |
| Whisper-only this phase | Defer cleanup/summarize sweeps | |

**User's choice:** Chain from one upstream — **refined to: a human-in-the-loop picks the best output at each stage**, and that pick is the input to the next stage.
**Notes:** Turned the auto-chaining into a staged *interactive* pipeline. Drove follow-up decisions on no-TTY behaviour, per-stage candidate count, and the Phase 4/5 boundary.

### Follow-up: which upstream feeds the next stage
| Option | Description | Selected |
|--------|-------------|----------|
| First fitting candidate (list order) | Deterministic, no-judgment | |
| Current default model | From settings.conf/built-in | |
| Highest-quality fitting model | Needs a quality heuristic | |

**User's choice (free-text):** "Each stage should have a human in the loop to pick the best result. Use the best 3 applicable models for each stage and ask the user to select the best output at each stage." → became the interactive staged design.

### Follow-up: no-TTY behaviour
| Option | Description | Selected |
|--------|-------------|----------|
| Auto-pick first fitting | Interactive on TTY, auto-continue without | |
| Run all, defer all picking | Skip selection when non-interactive | |
| Require a TTY | Abort cleanly without an interactive terminal | ✓ |

**User's choice:** Require a TTY.
**Notes:** Accepted the flagged consequence — Phase 6's "unattended `--benchmark`" criterion #3 must be revisited (recorded in CONTEXT Deferred / Cross-Phase Implications).

### Follow-up: per-stage candidate count
| Option | Description | Selected |
|--------|-------------|----------|
| First 3 fitting, list order | Cap at 3, --max-candidates override | |
| All fitting candidates | No cap | ✓ |
| Fit gate only, decide later | Leave to planner | |

**User's choice:** All fitting candidates.

### Follow-up: Phase 4 / Phase 5 split
| Option | Description | Selected |
|--------|-------------|----------|
| Picks in 4, persistence in 5 | Report + resume + settings.conf write in Phase 5 | ✓ |
| Also write settings.conf in Phase 4 | Pull RPT-03 forward | |

**User's choice:** Picks in 4, persistence in 5.

---

## Model download handling

| Option | Description | Selected |
|--------|-------------|----------|
| Pre-fetch step before timing | Download uncached fitting candidates up front, then time | ✓ |
| Skip-with-hint on cache miss | Benchmark only cached models, hint to download the rest | |
| Pre-fetch, confirm if large | Prompt when total download exceeds a threshold | |

**User's choice:** Pre-fetch step before timing.
**Notes:** Later augmented by the user's request to add a **disk-space gate** before downloading (hard-abort with need-X/have-Y if insufficient).

---

## Memory-fit gate

| Option | Description | Selected |
|--------|-------------|----------|
| size_gb + fixed overhead | Use candidates.conf size_gb + runtime buffer | ✓ |
| KV-cache-aware formula | Precise, needs per-model HF config | |
| size_gb only vs total RAM | Minimal, risks OOM | |

**User's choice:** size_gb + fixed overhead.

| Option | Description | Selected |
|--------|-------------|----------|
| ~75% of detected RAM | Reserve ~25% for OS (PITFALLS #3) | ✓ |
| ~85% of detected RAM | More aggressive | |
| Configurable, default 75% | Tunable | |

**User's choice:** ~75% of detected RAM.

---

## Metrics & cool-down

| Option | Description | Selected |
|--------|-------------|----------|
| External max-RSS via /usr/bin/time -l | Whole-process peak, language-agnostic | ✓ |
| MLX in-process get_peak_memory() | MLX allocations only | |
| Both (RSS primary, MLX cross-check) | Most data | |

**User's choice:** External max-RSS via /usr/bin/time -l.

| Option | Description | Selected |
|--------|-------------|----------|
| No pause, footnote thermal | Fast, note thermal effect | |
| Fixed cool-down between candidates | 30–60s idle for comparable timings | ✓ |
| Configurable pause, default 0 | --cooldown flag | |

**User's choice:** Fixed cool-down between candidates (~45s default recorded).

---

## Audio sample (BENCH-06)

| Option | Description | Selected |
|--------|-------------|----------|
| Researcher picks | Stable public-domain clip, ~2–3 min | |
| Let me specify it | User provides source | ✓ |

**User's choice:** Specified `https://www.youtube.com/watch?v=EWo7-azGHic`.

| Option | Description | Selected |
|--------|-------------|----------|
| Clip to first ~3 min | Fast sweeps, stable RTF | |
| Use the full video | Most representative, longer runs | ✓ |
| Specific length | User-defined | |

**User's choice:** Use the full video.

---

## Result persistence

| Option | Description | Selected |
|--------|-------------|----------|
| JSON-per-candidate, continue on failure | One JSON file per model; failures logged, sweep continues | ✓ |
| Leave format to research/planning | Planner designs it | |
| Let me specify the format | User-defined schema | |

**User's choice:** JSON-per-candidate, continue on failure.

---

## Claude's Discretion

- Exact runtime-overhead buffer GB (fit gate); cool-down duration (~45s default); JSON result-file schema fields; live-progress line format (follow existing `stage_banner` idiom); pre-fetch mechanism (`huggingface-cli download` vs Python `load()` dry-run); no-TTY detection method (`[ -t 0 ]`); optional memory-pressure pre-flight warning.

## Deferred Ideas

- **Phase 6 cross-phase implication:** "require a TTY" (D-03) means Phase 6 success criterion #3 must be reworded — unattended applies to the skill-refresh subprocess, not the interactive sweep. Revisit when Phase 6 is discussed.
- Multi-pass timing averaging (FUT-05) — single pass this milestone.
- `--max-candidates N` cap — rejected in favour of "all fitting"; easy to add later.
- `--cooldown SECONDS` flag — optional exposure of D-14's default.
- Configurable usable-memory fraction — deferred; 75% fixed for now.
- Memory-pressure pre-flight warning (PITFALLS #3) — optional nicety.
