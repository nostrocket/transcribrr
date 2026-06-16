# Phase 5: Resumable Sweep, Report & Winner Selection - Context

**Gathered:** 2026-06-16
**Status:** Ready for planning

<domain>
## Phase Boundary

Turn Phase 4's per-candidate JSON results and staged in-sweep picks into a **resumable, reportable, persisted** benchmark experience. Concretely, Phase 5 adds five capabilities to the existing `benchmark.sh`:

1. **Resumable sweep (RESUME-01/02):** Ctrl-C leaves partial results; restarting auto-detects the interrupted run and continues without re-running completed model/stage pairs.
2. **Comparison report (RPT-01):** after the sweep, results render both as a terminal ASCII table and a saved `report.md` in the run directory.
3. **Cross-model transcript divergence view (RPT-04/05):** before the whisper winner prompt, candidate transcripts are aligned and every divergent line is shown per-model, with a per-model outlier count.
4. **Atomic winner persistence (RPT-02/03):** the per-stage in-sweep picks are written to `config/settings.conf` via an atomic write that is never left partial/corrupt.
5. **Disk-gate completeness fix (BENCH-09):** the pre-download disk-space gate counts present-but-incomplete models toward the required-space estimate.

**In scope (Phase 5):** RESUME-01/02, RPT-01..05, BENCH-09. The report builder, the divergence-view renderer, the resume detection/skip logic, the per-stage atomic `settings.conf` write, and the one-line disk-gate fix.

**Out of scope (later / milestone-level):**
- **Phase 6:** the Claude refresh skill and `--benchmark` auto-launch (SKILL-01..04).
- **Milestone Out-of-Scope (carried from Phase 4):** automated scoring / auto-pick (the human is always the judge), full N×M×P matrix, mid-sweep model downloads, multi-pass timing averaging (FUT-05), cloud/API models.

**Boundary with Phase 4 (locked):** Phase 4 already performs the interactive per-stage `select_best` pick as the chaining mechanism (the upstream input to the next stage is human-selected). Phase 5 does **not** re-architect that flow — it (a) inserts the divergence view immediately before the whisper pick, (b) persists each pick to `settings.conf`, (c) builds the report, and (d) makes the whole sweep resumable.

</domain>

<decisions>
## Implementation Decisions

### Divergence view — alignment & comparison (RPT-04/05)
- **D-01:** **Sentence/segment-level alignment**, not raw char/line diff (raw desyncs on timing/whitespace per RPT-04). Align candidate transcripts at the sentence/segment unit.
- **D-02:** **Normalize before comparing, display original.** Lowercase + strip punctuation + collapse whitespace to decide whether a unit diverges; render the **original** text in the view so the user reads the real words. Only genuine wording differences register as divergence.
- **D-03:** **Outlier counting = majority consensus (RPT-05).** At each divergent unit, the variant matching the most models is the consensus; every model whose text differs from consensus gets +1 outlier. **2-candidate fallback:** with only two candidates there is no majority — report the divergence count but show **no outlier ranking** (descriptive only; tool never auto-picks).
- **D-04:** **Layout = side-by-side columns rendered at the terminal's real width.** Use `tput cols` to size columns and **wrap within each column** (no fixed 80-col assumption, no truncation). The same divergence detail also goes into `report.md`.
- **D-05:** Divergence view is shown **immediately before the whisper (transcription) winner prompt** (RPT-04 placement), so the user reads disagreements right before picking the transcription winner.

### Winner selection & settings.conf persistence (RPT-02/03)
- **D-06:** **Picks are in-sweep and final.** The existing per-stage `select_best` pick is the winner for that stage. The whisper pick is final and chains forward; cleanup and summarize benchmarking each build on the previously selected output (staged pipeline, unchanged from Phase 4 D-01).
- **D-07:** **Atomic per-stage write.** As each stage's winner is confirmed, write that stage's key to `config/settings.conf` via an atomic temp+`mv` (reuse the `transcribrr.sh:567` pattern). Three writes max across a sweep. Criterion #6 (Ctrl-C leaves the file whole-or-absent) is satisfied by each write being atomic.
- **D-08:** **Only write changed stages.** Write only the stage keys for which the user picked a new winner. A stage left at "keep current" is **not** written (its existing `settings.conf` key / built-in default is left untouched). settings.conf may therefore be partial — that is intended.
- **D-09:** **"Keep current" = an extra menu entry** in the `select_best` prompt, listed after candidates `[1..N]`. Picking a candidate chains it forward **and** saves it as the stage default; picking the keep-current entry chains forward the candidate **matching the current default** and writes nothing for that stage. The keep-current entry is offered **only when the current default is among the run candidates** (otherwise there is no produced output to chain).
- **D-10:** Settings keys are exactly the three established in Phase 3: `WHISPER_MODEL_DEFAULT`, `CLEANUP_MODEL_DEFAULT`, `SUMMARY_MODEL_DEFAULT`. Write friendly labels or raw HF IDs consistent with `settings.conf.example`.

### Resumable sweep (RESUME-01/02)
- **D-11:** **Resume trigger = auto-detect + prompt.** On `--benchmark`, if the most-recent `results/benchmark_<ts>/` directory is incomplete (unfinished pairs, no final `sweep_meta.json`/`report.md`), prompt `Resume interrupted run from <ts>? [Y/n]`. Yes → resume that run dir; No → start a fresh run dir.
- **D-12:** **Per-pair completion (RESUME-02)** detected by presence of that candidate's result JSON in the run dir. Persist partial results after **each model completes** (RESUME-01) so an interruption loses at most the in-flight candidate.
- **D-13:** **On resume: skip success + fit-gate SKIP JSONs; RE-RUN error JSONs.** Success and deterministic fit-gate skips are skipped. An errored pair (OOM / load failure) is re-run — a prior OOM may have been caused by memory pressure from a model that has since finished, so it deserves another attempt.
- **D-14:** **Reuse recorded picks on resume.** Persist each stage's selected output path when the winner is picked. On resume, reuse already-decided stages silently (chain forward from the recorded selection) and resume at the **first stage that was not completed**. No re-prompting for stages already decided.

### Report (RPT-01)
- **D-15:** **Terminal compact / `report.md` complete.** Both built from one data source. Terminal renders a compact scannable table; `report.md` adds full excerpts and the divergence detail.
- **D-16:** **Minimal results table columns:** model label / speed (RTF for whisper, tok/s for LLMs) / peak memory / fit status. (Drops the params/quant/on-disk detail that the existing ma2 "Model inventory" table already shows on screen.)
- **D-17:** **Full excerpts inline in `report.md`** so the markdown is a self-contained archive. (Whisper full transcripts already appear in the divergence view; the report excerpts cover cleanup/summarize and provide the whisper text too.)

### Disk-gate completeness (BENCH-09)
- **D-18:** **Point the disk-space gate at `verify_model_complete`, not `is_model_cached`.** At `benchmark.sh:388` the gate currently uses presence-only `is_model_cached`, so an index-only model (e.g. `Qwen3-14B`) is treated as cached and excluded from the space estimate even though the pre-fetch loop (already gated on `verify_model_complete`) will re-download it. Change the gate's per-model check to `verify_model_complete` so present-but-incomplete models are counted toward `NEEDED_GB`. Mechanical, ~one-line change; verified by criterion #7 (an index-only model is included in the gate total).

### Claude's Discretion
- The exact alignment algorithm for D-01/D-02 (sentence splitting + sequence alignment is bash-3.2-hostile; a small Python helper in `.venv` is the natural choice — researcher to recommend; e.g. `difflib.SequenceMatcher` / token alignment on normalized text). Render decision (D-04) and outlier rule (D-03) are locked; the *mechanism* is open.
- Exact `report.md` structure/headings, terminal table glyphs, column ordering, and excerpt length for the report's non-divergence sections.
- The resume run-dir "incomplete" heuristic details (which sentinel marks a run "finished" — recommend the presence of a final `report.md` and/or all expected pairs having JSONs).
- Whether to expose an explicit `--resume <dir>` flag in addition to auto-detect (D-11 specifies auto-detect+prompt; an explicit flag is a welcome-but-optional add for non-interactive use).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements & Roadmap
- `.planning/ROADMAP.md` §"Phase 5: Resumable Sweep, Report & Winner Selection" — goal, 7 success criteria, requirement IDs (BENCH-09, RESUME-01/02, RPT-01..05).
- `.planning/REQUIREMENTS.md` §Benchmark Engine (BENCH-09), §Resumable Sweep (RESUME-01/02), §Report & Selection (RPT-01..05) — full requirement text including RPT-04/05's alignment-based, no-auto-pick wording; §Out of Scope (auto-scoring, full matrix, mid-sweep download, multi-pass all excluded).

### v2.0 Research (grounds the chosen patterns)
- `.planning/research/ARCHITECTURE.md` — Pattern 1 (`benchmark.sh` dispatch), Pattern 2 (`OUTPUT_FILE=` reuse, stage scripts unchanged), **Pattern 3** (three-tier default resolution — the `settings.conf` write must produce keys this resolver reads), the Benchmark Run Flow, Anti-Patterns 2/3/4.
- `.planning/research/PITFALLS.md` — #1 (download latency → pre-fetch), #4 (thermal cool-down), #7 (subprocess OOM catch — relevant to D-13 re-run-errors), **#12** (bash 3.2: no `mapfile`/`declare -A`, no float in `(( ))`, `LC_NUMERIC=C`/`awk` for floats; don't `source` machine-written config). "Looks Done But Isn't" checklist applies.

### Prior phase context (carry-forward — read before implementing)
- `.planning/phases/04-benchmark-engine-core/04-CONTEXT.md` — the full Phase 4 decision set this phase builds on: **D-04** (Phase 5 owns report.md + resumability + atomic settings.conf write), **D-01** (staged interactive pipeline, human-selected upstream), **D-15** (one JSON result file per candidate + `sweep_meta.json` — the resume/report contract), **D-16** (continue-on-failure), D-10/D-11 (peak mem via `/usr/bin/time -l`, RTF/tok-s).
- `.planning/phases/03-candidate-config-pipeline-settings-integration/03-CONTEXT.md` — **D-04/D-05/D-06** (`config/settings.conf` location, gitignored, keys `WHISPER_MODEL_DEFAULT`/`CLEANUP_MODEL_DEFAULT`/`SUMMARY_MODEL_DEFAULT`), **D-07** (flag > settings > built-in resolution the write must feed), the parse-not-source rule.

### Existing code (read before editing)
- `benchmark.sh` — the engine this phase extends. Key landmarks:
  - `select_best()` (~line 893) — the interactive per-stage pick; D-09 adds a "keep current" menu entry; D-05 inserts the divergence view immediately before the whisper invocation (~line 1065).
  - `RUN_DIR="$RESULTS_DIR/benchmark_${RUN_TS}"` (line 873) — resume (D-11) must detect/reuse an existing incomplete run dir instead of always minting a new timestamp.
  - Disk-space gate (lines 375–409), specifically `if ! is_model_cached "$model_id"` at **line 388** — BENCH-09/D-18 changes this to `verify_model_complete`.
  - `verify_model_complete()` (line 244), `is_model_cached()` (line 230), `params_for_id()` (line 304) — existing helpers (added by quick task `ma2`).
  - `write_success_json` (566) / `write_error_json` (604) / `write_skip_json` (636) — the per-candidate JSON writers that define "completed" for resume (D-12/D-13).
  - `sweep_meta.json` writer (lines 1240–1267) — explicitly notes "Phase 5 will read $RUN_DIR to write config/settings.conf"; the run-level metadata the report/resume read.
- `config/settings.conf.example` — the committed format the atomic write must match (three `*_MODEL_DEFAULT` keys).
- `transcribrr.sh:567` — the atomic temp+`mv` write pattern D-07 reuses for the `settings.conf` write.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`select_best()` (`benchmark.sh:893`)** — extend with the "keep current" menu entry (D-09); the divergence view (D-05) is rendered just before the whisper call to it.
- **Per-candidate JSON writers (`write_success_json`/`write_error_json`/`write_skip_json`)** — already the persisted record; resume keys off their presence (D-12/D-13). RESUME-01's "persist after each model" is already true; resume is mostly *read-and-skip* logic on top.
- **`sweep_meta.json` writer** — already declares the Phase 5 hand-off; the report reads the run dir it describes.
- **`verify_model_complete()` (`benchmark.sh:244`)** — already used by the pre-fetch loop; BENCH-09 is just reusing it in the disk gate (D-18).
- **Atomic temp+`mv` pattern (`transcribrr.sh:567`)** — copy for the `settings.conf` write (D-07).
- **`.venv` Python** — available for the divergence alignment helper (sentence split + sequence alignment); bash 3.2 can't do this well.

### Established Patterns
- **Bash 3.2 only** — no `mapfile`/`readarray`, no `declare -A`, no float in `(( ))`; floats via `awk`/`LC_NUMERIC=C`. Flat temp files (not associative arrays) for per-stage mapping, as `select_best` already does.
- **`SCRIPT_DIR`-relative paths** — reference `config/settings.conf`, `results/`, `.venv` relative to the script dir.
- **Continue-on-failure** — a single candidate failure logs an error JSON and the sweep continues (D-16); resume re-runs those errors (D-13).
- **stdout-is-the-return-value discipline in `select_best`** — menu/prompts go to stderr; only the selected path goes to stdout (caller captures via `$(...)`). The divergence view must also write to stderr so it doesn't pollute the captured pick.

### Integration Points
- **`benchmark.sh` only** — no new top-level script. Resume detection wraps the `RUN_DIR` assignment; the report builder + divergence renderer are new functions; the `settings.conf` writer is a new function invoked from `select_best` (or right after it) per stage.
- **`config/settings.conf`** — the atomic write target (gitignored; created if absent).
- **`results/benchmark_<ts>/`** — the run dir resume reuses and the report writes `report.md` into.

</code_context>

<specifics>
## Specific Ideas

- **Divergence view must use real terminal width** (`tput cols`) with side-by-side columns wrapping within each column — the user explicitly wants columns, not stacked blocks, and is fine assuming a wide window (D-04).
- **The whisper pick is the anchor of the staged chain** — it is final, saved, and every downstream stage's benchmarking builds on the transcript the selected whisper model produced (user's own framing of D-06).
- **report.md is for viewing/archive** — the user reads it; the selection itself happens inline during the sweep, not as a separate post-report prompt.

</specifics>

<deferred>
## Deferred Ideas

- **Explicit `--resume <dir>` flag** for non-interactive/scripted resume — D-11 locks auto-detect+prompt; an explicit flag is a welcome optional add (Claude's discretion), not required.
- **Resume across a changed `candidates.conf`** — if the candidate list changed between interruption and resume, the run could be inconsistent. Out of scope for this phase; the planner should at least note/guard the case (e.g. resume against the run dir's own candidate set), but full reconciliation is deferred.
- **Multi-pass timing averaging (FUT-05)** — single timed pass this milestone (carried from Phase 4).
- **Phase 6 TTY implication** (carried from Phase 4 D-03): `--benchmark` requires a TTY; Phase 6's "fully unattended" criterion #3 applies only to the skill-refresh subprocess, not the interactive sweep. Revisit when discussing Phase 6.

</deferred>

---

*Phase: 5-Resumable Sweep, Report & Winner Selection*
*Context gathered: 2026-06-16*
