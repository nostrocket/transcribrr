---
phase: 03-candidate-config-pipeline-settings-integration
plan: "02"
subsystem: transcribrr.sh
tags: [config, settings, precedence, sentinels, provenance, CFG-01, CFG-02, CFG-03, MODEL-03]
dependency_graph:
  requires: []
  provides: [settings.conf-precedence, provenance-summary, CFG-03-error-handling]
  affects: [transcribrr.sh]
tech_stack:
  added: []
  patterns:
    - sentinel-based three-tier precedence (flag > settings.conf > built-in)
    - parse-not-source grep/cut config reading
    - if ! STAGE_OUT=$(_run_*) set-e-safe wrapper idiom
key_files:
  created: []
  modified:
    - transcribrr.sh
decisions:
  - Sentinel pattern (not string-compare) for flag precedence — correctly handles explicit --whisper-model small overriding settings.conf
  - _run_*() wrapper functions with `if ! STAGE_OUT=` idiom — avoids set -euo pipefail swallowing stage failures that || after pipeline would cause
  - || true added to _read_setting grep pipeline — grep exits 1 on no-match; pipefail would abort before any built-in fallback without this fix
metrics:
  duration: "9m"
  completed_date: "2026-06-15"
  tasks_completed: 3
  files_modified: 1
---

# Phase 3 Plan 02: Pipeline Settings Integration Summary

Three-tier model precedence (flag > settings.conf > built-in) wired into `transcribrr.sh` via per-flag sentinels, with parse-not-source settings reading, provenance summary, and set-e-safe CFG-03 catch-and-translate stage wrappers.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Sentinel init + flag wiring + settings.conf read block + provenance summary | aa2926b | transcribrr.sh |
| 2 | CFG-03 catch-and-translate _run_* stage wrappers | fb97bdc | transcribrr.sh |
| 3 | Confirm MODEL-03 + behavioral verification | 6df44a6 | transcribrr.sh (bug fix only) |

## What Was Built

**Task 1 — Three-tier precedence plumbing:**
- Added 6 sentinel/source variables to the defaults block immediately after `SUMMARY_MODEL=`: `WHISPER/CLEANUP/SUMMARY_MODEL_EXPLICIT=false` and `WHISPER/CLEANUP/SUMMARY_MODEL_SOURCE="built-in"`
- Wired `*_EXPLICIT=true` and `*_SOURCE="flag"` into each `--*-model` case branch between the assignment and `shift 2`
- Inserted a `settings.conf` read block after the flag-parse `done` and before URL detection / preflight: `_read_setting()` helper using anchored `grep "^${1}="` / `tail -1` / `cut -d= -f2-` (parse-not-source); sentinel-gated apply for each model key; unconditional provenance summary printed to stdout

**Task 2 — CFG-03 wrappers:**
- Replaced each of the three inline `STAGE_OUT=$(... | tee /dev/stderr | { grep || true; })` patterns with `_run_transcribe()` / `_run_cleanup()` / `_run_summarize()` wrapper functions preserving the exact pipeline
- Changed all three call sites to `if ! STAGE_OUT=$(_run_*)` idiom (set-e-safe per Pitfall 1 — `||` after the `{ grep || true; }` pipeline would always exit 0 and swallow failures)
- Each failure branch checks `*_MODEL_SOURCE = "settings.conf"` before printing the D-10 actionable CFG-03 message; always exits 1
- Preserved existing empty-output guards, `CURRENT_STAGE` assignments, and the ERR trap

**Task 3 — Verification:**
- Confirmed MODEL-03 satisfied: all three stage scripts (`transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh`) contain `if [[ "$MODEL_FLAG" == */* ]]` passthrough; zero stage-script edits in this plan's git diff
- Behavioral tests (temp settings.conf, nonexistent MP3): settings.conf `WHISPER_MODEL_DEFAULT=turbo` with no flag → provenance shows `turbo (settings.conf)`; same settings.conf with `--whisper-model small` → provenance shows `small (flag)` — sentinel correctly beats settings.conf even when flag names the built-in default
- Temp `config/settings.conf` cleaned up after tests

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `set -euo pipefail` aborts script when settings key not in settings.conf**

- **Found during:** Task 3 behavioral verification
- **Issue:** `_read_setting()` function uses `grep "^${1}=" | tail -1 | cut -d= -f2-`. When the key is absent, `grep` exits 1. With `set -euo pipefail`, the pipeline exit status propagates and the script aborts with `Error: transcribrr.sh failed during stage: preflight` before reaching the provenance summary. Only `WHISPER_MODEL_DEFAULT` was in the test settings.conf — attempting to read `CLEANUP_MODEL_DEFAULT` (missing) triggered the abort.
- **Fix:** Added `|| true` after `cut -d= -f2-` in `_read_setting`. This keeps the pipeline exit status at 0 when grep finds no match, returning an empty string — the existing `[ -n "$_val" ]` guard already handles empty correctly.
- **Files modified:** transcribrr.sh (6df44a6)
- **Commit:** 6df44a6

### Plan Verify Command Issues (non-blocking, noted for correctness)

The plan's `<automated>` verify block contains two grep patterns that fail due to shell regex interpretation:

1. `grep -q 'SETTINGS_FILE="$SCRIPT_DIR/config/settings.conf"'` — `$` in a grep BRE pattern is the end-of-line anchor, so `$SCRIPT_DIR` is parsed as "end-of-line followed by `SCRIPT_DIR`" and never matches. Fixed by using `grep -Fq` (fixed-string). File content is correct.

2. `grep -c 'if ! STAGE_OUT=$(_run_'` — `$(_run_` is parsed as "end-of-line followed by `(_run_`" in BRE. Fixed by using `grep -Fc`. File content is correct.

3. `grep -cE '^_run_(transcribe|cleanup|summarize)\(\)'` — The `^` anchor requires the function to be at column 0, but `_run_cleanup()` is correctly indented inside the `if [ "$NO_CLEANUP" = false ]` block per task spec. Fixed by removing `^` anchor. The function exists and works correctly.

All behavioral acceptance criteria and structural checks pass with the corrected grep invocations.

## MODEL-03 Confirmation

All three stage scripts contain the raw HF ID passthrough:
- `transcribe.sh:102`: `if [[ "$MODEL_FLAG" == */* ]]`
- `cleanup-transcript.sh:47`: `if [[ "$MODEL_FLAG" == */* ]]`
- `summarize-transcript.sh:96`: `if [[ "$MODEL_FLAG" == */* ]]`

Zero edits to any stage script in this plan. Any HF ID from `candidates.conf` (e.g. `mlx-community/Qwen3-8B-4bit`, `Qwen/Qwen3-14B-MLX-4bit`) passed via `--model "$CLEANUP_MODEL"` will be accepted as-is.

## Requirements Satisfied

| Requirement | Description | Status |
|-------------|-------------|--------|
| MODEL-03 | Raw HF IDs accepted via --model; no stage-script changes needed | Confirmed |
| CFG-01 | Normal run reads settings.conf (if present) to select default models | Implemented |
| CFG-02 | Precedence: CLI flag > settings.conf > built-in (sentinel-based, D-07) | Implemented + verified |
| CFG-03 | Settings-file model that fails to load → actionable error + benchmark hint | Implemented |

## Known Stubs

None — all wired, no placeholder values flow to output.

## Threat Flags

No new threat surface beyond what is documented in the plan's threat model (T-03-01 through T-03-07). The `config/settings.conf` file access is mitigated by parse-not-source (grep/cut, no source/eval). Verified: `bash -n transcribrr.sh` passes; no source/eval of SETTINGS_FILE present in the file.

## Self-Check: PASSED

- transcribrr.sh: FOUND
- 03-02-SUMMARY.md: FOUND
- aa2926b (Task 1 commit): FOUND
- fb97bdc (Task 2 commit): FOUND
- 6df44a6 (Task 3/fix commit): FOUND
- bash -n transcribrr.sh: exits 0
