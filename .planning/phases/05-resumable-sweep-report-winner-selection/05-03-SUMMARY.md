---
phase: 05-resumable-sweep-report-winner-selection
plan: "03"
subsystem: benchmark
tags: [benchmark, resume, divergence, report, settings, wiring, bash, integration]

# Dependency graph
requires:
  - phase: 05-resumable-sweep-report-winner-selection
    plan: "01"
    provides: [benchmark_helpers.py divergence subcommand, benchmark_helpers.py report subcommand]
  - phase: 05-resumable-sweep-report-winner-selection
    plan: "02"
    provides: [detect_incomplete_run, should_skip_pair, persist_pick, load_picks, write_settings_key, select_best keep-current]
provides:
  - Resumable benchmark sweep: RUN_DIR conditionally reuses incomplete run after Y/n prompt; mkdir only on fresh runs
  - Skip loop: should_skip_pair guards all three stage loops; already-completed pairs are not re-run
  - Pick reuse: load_picks populates SELECTED_TRANSCRIPT/CLEANED/SUMMARY on resume; no re-prompt for decided stages
  - Current-default reads: CURRENT_WHISPER_DEFAULT / CURRENT_CLEANUP_DEFAULT / CURRENT_SUMMARY_DEFAULT from settings.conf via parse-not-source
  - Divergence view: immediately before whisper select_best prompt (>= 2 candidates), DIVERG_ARGS built from WHISPER_RESULTS_LIST, rendered >&2 (non-fatal)
  - Per-stage atomic persistence: each new pick persisted to picks.json AND written to settings.conf; keep-current (sentinel file) writes nothing to settings.conf
  - Post-sweep report: terminal ASCII table + report.md produced after sweep_meta.json is written
  - Human-verified end-to-end on real TTY: approved by user
affects: [Phase 6 Claude Skill integration]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - RUN_DIR-resume-branch: detect_incomplete_run → prompt → load_picks OR mint fresh run dir + mkdir
    - subshell-sentinel-file: keep-current detection via $RUN_DIR/.keep_current_<stage> file surviving the $() subshell (mirrors TIME_EXIT_FILE pattern)
    - DIVERG_ARGS-before-select_best: build from WHISPER_RESULTS_LIST → divergence >&2 → select_best → rm -f list (strict order to avoid reading deleted file)
    - parse-not-source-current-defaults: _read_setting helper reads settings.conf without sourcing it

key-files:
  created: []
  modified: [benchmark.sh]

key-decisions:
  - "DIVERG_ARGS built and divergence invoked BEFORE select_best AND before rm -f WHISPER_RESULTS_LIST — strict ordering prevents reading a deleted file (Pitfall 7)"
  - "keep-current detected via $RUN_DIR/.keep_current_<stage> sentinel file (not a lost subshell variable); sentinel always rm -f'd after reading to prevent leak into next stage"
  - "On resume, stages with a recorded pick in picks.json are chained silently (no re-prompt); partially-completed stages re-run only missing/error candidates then call select_best on full list"
  - "settings.conf write skipped when keep-current sentinel present; a SIGINT between persist_pick and write_settings_key leaves picks.json updated but settings.conf unchanged — documented minor gap, acceptable"
  - "BENCH-09 delivered in 05-02; this plan satisfies RESUME-01/02 and RPT-01..05 via wiring, not re-implementation"

patterns-established:
  - "Resume branch at RUN_DIR assignment: detect_incomplete_run → Y/n prompt → load_picks (reuse) or fresh RUN_TS + mkdir (new)"
  - "Per-stage skip guard: should_skip_pair before running candidate; continue on skip-0, run on run-1"
  - "Divergence-before-pick order: DIVERG_ARGS → benchmark_helpers.py divergence >&2 → select_best → rm -f results list"
  - "Post-pick sentinel check: [ -f $RUN_DIR/.keep_current_<stage> ] → rm -f; if absent → write_settings_key"

requirements-completed: [RESUME-01, RESUME-02, RPT-01, RPT-02, RPT-03, RPT-04, RPT-05]

# Metrics
duration: ~15min (Tasks 1+2 executor) + human TTY verify
completed: "2026-06-17"
---

# Phase 5 Plan 03: Resume Wiring + Divergence View + Report Integration Summary

**Full end-to-end wiring in benchmark.sh: resumable runs with skip loop and pick reuse, pre-whisper divergence view redirected to stderr, per-stage atomic persistence via sentinel-file keep-current detection, and post-sweep terminal table + report.md — all human-verified on a real TTY.**

## Performance

- **Duration:** ~15 min (Tasks 1+2) + human TTY verification pass
- **Started:** 2026-06-17
- **Completed:** 2026-06-17
- **Tasks:** 3 (2 auto + 1 human-verify checkpoint — approved)
- **Files modified:** 1 (benchmark.sh)

## Accomplishments

- Resume flow: `detect_incomplete_run` wraps RUN_DIR assignment; on resume `load_picks` reuses decided stage picks without re-prompting; `should_skip_pair` guards all three stage loops so completed pairs are skipped
- Divergence view: `DIVERG_ARGS` built from `WHISPER_RESULTS_LIST` immediately before it is deleted; `benchmark_helpers.py divergence` invoked `>&2` (preventing stdout pollution of `SELECTED_TRANSCRIPT` capture), with `set +e`/`set -e` for non-fatal failure handling
- Atomic per-stage persistence: `persist_pick` + `write_settings_key` called after each `select_best`; keep-current detected via `$RUN_DIR/.keep_current_<stage>` sentinel file (subshell-safe) which is always `rm -f`'d after reading; keep-current skips `write_settings_key`
- Post-sweep report: `benchmark_helpers.py report` invoked after `sweep_meta.json` is written, producing terminal ASCII table to stderr and `$RUN_DIR/report.md`
- Current defaults read at sweep start via parse-not-source `_read_setting` helper, passed as 3rd arg to each `select_best` call
- Human-verified on real TTY: divergence view appeared before whisper prompt, settings.conf updated correctly, resume prompt appeared after Ctrl-C, completed pairs were skipped on resume — approved by user

## Task Commits

1. **Task 1: Resume wiring (RUN_DIR branch, skip loop, pick reuse) + current-default reads** — `dd34256` (feat)
2. **Task 2: Divergence view + per-stage persistence/settings write + report invocation** — `9815e54` (feat)
3. **Task 3: Human verify end-to-end resumable sweep on real TTY** — checkpoint:human-verify, gate=blocking — APPROVED by user
4. **State update (pause):** `1c67f57` (docs — STATE.md paused at Task 3)

## Files Created/Modified

- `benchmark.sh` — Resume branch at RUN_DIR assignment, skip loop guards (3 stage loops), pick reuse on resume, current-default reads, DIVERG_ARGS build + divergence invocation before whisper select_best, per-stage persist_pick + sentinel-file keep-current check + write_settings_key, report invocation after sweep_meta.json

## Decisions Made

- **DIVERG_ARGS ordering**: The list-read → divergence → select_best → rm-f order is strict and enforced by code position; divergence must read `WHISPER_RESULTS_LIST` before the existing `rm -f` deletes it (Pitfall 7 from RESEARCH.md).
- **Subshell sentinel for keep-current**: `select_best` runs inside `$(...)` so any variable it sets is lost; the `$RUN_DIR/.keep_current_<stage>` file survives the subshell. This mirrors the existing `TIME_EXIT_FILE` pattern at lines 779-786.
- **Pitfall 6 gap accepted**: SIGINT between `persist_pick` and `write_settings_key` leaves `picks.json` updated but `settings.conf` missing the key. On resume, the pick is reused (chained) but the settings write is not retried this phase. Documented as a known minor gap — acceptable per plan decision.
- **BENCH-09 delivered in 05-02**: The disk-gate fix was implemented in plan 05-02. This plan satisfies RESUME-01/02 and RPT-01..05 via call-site wiring only, not re-implementation.

## Deviations from Plan

None — plan executed exactly as written. All three tasks completed as specified. Tasks 1 and 2 wired the Wave-1 building blocks into the call sites in `benchmark.sh` without modifying the function implementations. Task 3 (human-verify checkpoint) was approved by the user after running the full end-to-end sweep on a real TTY.

## Issues Encountered

None. `bash -n benchmark.sh` clean after both wiring tasks. All automated verify checks (PASS_T1, PASS_T2) passed. Human TTY verification approved without issues reported.

## User Setup Required

None — no external service configuration required. All wiring is internal to `benchmark.sh`.

## Next Phase Readiness

- Phase 5 complete: all 3 plans done, all 9 Phase 5 requirements satisfied (BENCH-09 in 05-02; RESUME-01/02, RPT-01..05 in 05-01/05-03)
- Phase 6 (Claude Skill — Candidate Refresh) can proceed: it depends on a working sweep that accepts a hand-authored `candidates.conf`, which is now fully operational and verified
- Known gap carried forward: if a SIGINT occurs between `persist_pick` and `write_settings_key`, `settings.conf` may be missing the new key (picks.json has it). Phase 6 is unaffected; a future hardening pass could retry the settings write on resume.

## Known Stubs

None. All wiring is live: resume prompt, skip loop, divergence view, persistence, settings write, and report are all fully connected to real implementations from 05-01 and 05-02.

## Threat Flags

No new threat surface beyond the plan's threat model. Threats mitigated as planned:
- T-05-08 (divergence stdout pollution): explicit `>&2` on divergence invocation — `SELECTED_TRANSCRIPT` capture stays clean
- T-05-09 (helper subprocess failure): `set +e`/`set -e` bracket around divergence and report calls; non-zero exit warns and continues

## Self-Check

Files exist:
- [x] `benchmark.sh` — modified (exists at repo root)
- [x] `benchmark_helpers.py` — created in 05-01 (exists at repo root)

Commits exist:
- [x] dd34256 — feat(05-03): resume wiring (Task 1)
- [x] 9815e54 — feat(05-03): divergence view + per-stage persistence/settings write + report invocation (Task 2)
- [x] 1c67f57 — docs(05-03): STATE.md pause update

## Self-Check: PASSED

---
*Phase: 05-resumable-sweep-report-winner-selection*
*Completed: 2026-06-17*
