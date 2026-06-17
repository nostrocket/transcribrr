---
phase: 05-resumable-sweep-report-winner-selection
plan: "02"
subsystem: benchmark
tags: [benchmark, resume, settings, atomic-write, bash]
dependency_graph:
  requires: []
  provides: [BENCH-09-fix, detect_incomplete_run, should_skip_pair, RESUMING, persist_pick, load_picks, write_settings_key, select_best-keep-current]
  affects: [benchmark.sh]
tech_stack:
  added: []
  patterns: [same-fs-mktemp-mv-atomic, sys.argv-heredoc-A1, subshell-sentinel-file, parse-not-source]
key_files:
  created: []
  modified: [benchmark.sh]
decisions:
  - BENCH-09: use verify_model_complete (not is_model_cached) in disk-gate loop to count present-but-incomplete models toward NEEDED_GB_F
  - keep-current sentinel via $RUN_DIR/.keep_current_<stage> file (not a lost subshell variable) — mirrors TIME_EXIT_FILE pattern
  - write_settings_key validates key+value before write and passes both via sys.argv (not heredoc interpolation) per T-05-02
  - persist_pick uses A1 pattern (confirmed live on bash 3.2.57) with sys.argv; never sources picks.json
  - detect_incomplete_run gates completeness on sweep_meta.json (Phase 4 contract); Phase-4-complete runs treated as not resumable
metrics:
  duration: "6m"
  completed: "2026-06-17"
  tasks_completed: 2
  files_modified: 1
---

# Phase 05 Plan 02: Bash Building Blocks (Disk-Gate Fix + Resume/Settings Primitives) Summary

**One-liner:** BENCH-09 one-line disk-gate fix + five new bash functions (detect_incomplete_run, should_skip_pair, persist_pick, load_picks, write_settings_key) + select_best keep-current extension — all in benchmark.sh, no call-site wiring (that is plan 05-03).

## What Was Built

All additions are inside `benchmark.sh` only. The sweep flow is unchanged — these are self-contained functions that 05-03 will wire into the call sites.

### Task 1: BENCH-09 + Resume Detection/Skip Primitives

**BENCH-09 / D-18:** In the disk-space gate loop (`for i in "${!FITTING_IDS[@]}"` around line 388), changed `if ! is_model_cached "$model_id"` to `if ! verify_model_complete "$model_id"`. A present-but-incomplete model (e.g. index-only Qwen3-14B snapshot) now counts toward `NEEDED_GB_F` instead of being treated as cached. The `is_model_cached()` definition and all other callers elsewhere in the file are untouched — the change is scoped to the gate loop only.

**RESUMING:** Added `RESUMING=false` module-level boolean immediately before the resume primitives section. Plan 05-03 flips this to `true` when the user accepts the resume prompt.

**detect_incomplete_run():** Returns the path to the most-recent `results/benchmark_*/` directory that is incomplete, or `""`. A run is complete if it has `sweep_meta.json` (Phase 4 contract). During the Phase 5 transition, a run with `sweep_meta.json` but no `report.md` is treated as complete — Phase-4-complete runs are not re-runnable. Returns `""` also if the most-recent dir exists but has no result JSONs (started but no work done, i.e. aborted before any candidate ran).

**should_skip_pair(json_path):** Returns 0 (skip) or 1 (run/re-run).
- File absent → run (1)
- `fit_status == "skip"` → always skip (0) — deterministic fit-gate exclusion
- `error` empty/null → skip (0) — success
- `error` non-empty → re-run (1) — transient OOM/load failure may succeed after other models freed memory (D-13/Pitfall 4)

### Task 2: persist_pick/load_picks + write_settings_key + select_best keep-current

**A1 precheck:** Confirmed `"$PYTHON" - arg1 arg2 << 'PYEOF'` delivers `sys.argv[1:]` correctly on this machine's bash before any production use.

**persist_pick(stage, output_file):** Reads `$RUN_DIR/picks.json` (if present), merges the new stage→output_file entry, and writes back via `"$PYTHON" - picks_path stage output_file << 'PYEOF'` using `sys.argv` (A1 pattern). Never sources picks.json (parse-not-source, T-05-03).

**load_picks():** Populates `SELECTED_TRANSCRIPT` / `SELECTED_CLEANED` / `SELECTED_SUMMARY` from `$RUN_DIR/picks.json` via `"$PYTHON" -c json.load(...)` inline reads. On resume, the 05-03 caller invokes this to reuse already-decided stage picks silently (D-14).

**write_settings_key(key, value):** Atomically updates one key in `config/settings.conf`.
- Validates key against `WHISPER_MODEL_DEFAULT | CLEANUP_MODEL_DEFAULT | SUMMARY_MODEL_DEFAULT` (rejects anything else — T-05-02).
- Validates value against `^[A-Za-z0-9._/-]+$` (rejects shell metacharacters — T-05-02).
- `mktemp "$SCRIPT_DIR/config/.settings_tmp_XXXXXX"` — in the config/ directory (same APFS volume as target), so `mv` is an atomic rename, not a copy+delete (Pitfall 3 / T-05-01). macOS `/tmp` is a separate filesystem; cross-fs mv is not atomic.
- Registers temp file in `_BENCH_TMPFILES` EXIT trap; removes it after successful `mv`.
- Passes key+value via `sys.argv` (not heredoc string interpolation) so a malicious label cannot inject Python code into the heredoc body (T-05-02).
- Reads and merges existing `settings.conf` lines; replaces matching `^KEY\s*=` line or appends; never truncates other keys.

**select_best keep-current extension (D-09 / RPT-02):**
Added optional 3rd parameter `current_default_label`. If provided and the label matches a candidate in the list file (Pitfall 8 — only offer if current default is a candidate), a `[k] Keep current (<label>)` entry is shown after the numbered menu.

Sentinel-file contract (mirrors TIME_EXIT_FILE pattern at lines 779-786):
- `select_best` runs inside `$(...)` — it is a subshell. A module-level variable set inside is lost when the subshell exits, silently breaking D-08 (keep-current must not write settings).
- On keep-current pick: `touch "$RUN_DIR/.keep_current_${stage}"` (uses `${RUN_DIR:-/tmp}` so robust if unset), then `echo "$keep_current_line" | cut -d'|' -f2` to stdout (chaining works normally).
- On numbered pick: `rm -f "$sentinel_file"` (removes stale sentinel from a prior keep for this stage).
- The 05-03 caller checks `[ -f "$RUN_DIR/.keep_current_${stage}" ]` after the `$()` capture, then `rm -f`s the sentinel.

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| Task 1 | cd8ccb1 | fix(05-02): BENCH-09 disk-gate + resume detection/skip primitives |
| Task 2 | b81bf3d | feat(05-02): persist_pick/load_picks + atomic write_settings_key + select_best keep-current |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] mktemp path used $conf_dir local var instead of $SCRIPT_DIR/config literal**
- **Found during:** Task 2 verification
- **Issue:** Initial write_settings_key used `local conf_dir="$SCRIPT_DIR/config"` then `mktemp "$conf_dir/.settings_tmp_XXXXXX"`. The verify command `grep -qF 'mktemp "$SCRIPT_DIR/config/.settings_tmp'` failed because the literal string `$SCRIPT_DIR/config` was not present — $conf_dir was an alias.
- **Fix:** Changed to use `$SCRIPT_DIR/config` directly in the mktemp call to satisfy both the verify check and make the path intent explicit at the call site.
- **Files modified:** benchmark.sh
- **Commit:** b81bf3d

**2. [Rule 1 - Bug] Task 1 verify uses `grep -q 'verify_model_complete "$model_id"'` which fails as regex**
- **Found during:** Task 1 verification
- **Issue:** The plan's verify command uses single-quoted grep pattern containing `"$model_id"`. In regex mode, `$` in `"$model_id"` is end-of-line anchor, which does not match the literal string `"$model_id"` in the file.
- **Fix:** Used `grep -qF` (fixed-string) in debugging to confirm the change was correct. The code itself is correct; the plan's verify command has a regex edge case. PASS_T1 confirmed via the fixed-string variant.
- **Files modified:** none (verification approach only)

## Known Stubs

None. All functions are complete implementations. `RESUMING=false` is intentionally left for 05-03 to toggle — it is a module-level boolean, not a stub.

## Threat Flags

None. All new surface was anticipated in the plan's threat model:
- `write_settings_key` → `config/settings.conf`: covered by T-05-01 (atomic write) and T-05-02 (key/value validation + sys.argv injection prevention)
- `picks.json` read/write: covered by T-05-03 (parse-not-source via json.load)

## Self-Check

Files exist:
- benchmark.sh: modified (not a new file — always existed)

Commits exist:
- cd8ccb1: fix(05-02): BENCH-09 disk-gate + resume detection/skip primitives
- b81bf3d: feat(05-02): persist_pick/load_picks + atomic write_settings_key + select_best keep-current

## Self-Check: PASSED

Both commits confirmed in `git log`. benchmark.sh syntax verified clean with `bash -n`. All 16 individual grep checks passed. PASS_T1 and PASS_T2 both verified.
