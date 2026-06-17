---
phase: 05-resumable-sweep-report-winner-selection
verified: 2026-06-17T00:00:00Z
status: human_needed
score: 7/7 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Run ./benchmark.sh --benchmark in a real terminal with >=2 whisper candidates. After candidates complete, confirm the divergence view appears BEFORE the 'Select the best' prompt — side-by-side columns labeled per model, wrapped at terminal width, with per-model outlier count (or 'no outlier ranking' with 2 candidates). Confirm no recommended winner is shown."
    expected: "Divergence columns render correctly, per-model outlier counts shown, no auto-pick"
    why_human: "Column wrapping, TTY width behavior, and the correct ordering of divergence-before-prompt cannot be confirmed without a live terminal session that runs real MLX inference"
  - test: "After the whisper divergence view appears, select a winner. Confirm config/settings.conf now contains WHISPER_MODEL_DEFAULT=<selected-label>. If the current default was among candidates, confirm [k] Keep current was offered; selecting it must leave settings.conf unchanged."
    expected: "settings.conf updated atomically; keep-current writes nothing"
    why_human: "Interactive prompt, sentinel file mechanism, and actual settings.conf update require a live TTY with running candidates"
  - test: "Run --benchmark, kill with Ctrl-C mid-whisper-stage, then re-run. Confirm 'Resume interrupted run from <ts>? [Y/n]' prompt appears. Confirm Yes skips already-completed candidates and does not re-prompt for stages that already had a pick in picks.json."
    expected: "Resume prompt appears; completed pairs skipped; decided picks reused without re-prompting"
    why_human: "Resume skip logic and pick reuse require interrupting a real sweep mid-run — cannot simulate statically"
  - test: "During a settings.conf write (after selecting a winner), confirm the file is never left partial. One way: inspect with a concurrent tail -f or check that the file is either fully written or absent after a kill-9 scenario."
    expected: "settings.conf is either fully written (atomic mv) or absent — never partially written"
    why_human: "Ctrl-C atomicity guarantee (criterion #6) requires observing actual OS-level atomic rename behavior under interruption"
  - test: "After a complete sweep, confirm: (a) a terminal ASCII table printed immediately to stderr, (b) results/<run_ts>/report.md exists with per-stage tables, speed values (RTF=x.xxx or N tok/s — not 'n/a'), memory, fit status, output excerpts, and a Selected Winners section. (c) CR-03 resume path: run --benchmark, kill after whisper picks but before cleanup; resume; confirm settings.conf shows the whisper winner even though it was set on the resume path."
    expected: "Terminal table shows real speed numbers; report.md complete; CR-03 settings reconciliation works end-to-end on a real run"
    why_human: "End-to-end report content quality and CR-03 resume-write correctness require a full multi-candidate sweep with real MLX output"
---

# Phase 5: Resumable Sweep, Report & Winner Selection — Verification Report

**Phase Goal:** Interrupted sweeps can be resumed without re-running completed models, a comparison report renders real results side-by-side (including a cross-model transcript divergence view that makes transcription errors easy to spot), and winner selections are persisted atomically.
**Verified:** 2026-06-17T00:00:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Killing a sweep leaves partial-results file; restart skips completed pairs and continues | VERIFIED (code) / HUMAN-NEEDED (live test) | `should_skip_pair` guards all 3 stage loops (6 calls in benchmark.sh); `detect_incomplete_run` returns most-recent incomplete dir; `load_picks` reuses decided stage picks. Resume prompt at line 1108. Human TTY approval in 05-03-SUMMARY. |
| 2 | After a complete sweep, report.md exists with speed/memory/fit/excerpt per model per stage | VERIFIED | `benchmark_helpers.py report` invoked at line 1721 after sweep_meta.json. CR-01 fix confirmed: `_format_speed` reads `speed_metric`/`speed_value` (lines 382-392), not the old non-existent `rtf` key. Test `test_report_3whisper_jsons` asserts `RTF=0.020` in both stderr and report.md. Spot-check confirms `RTF=0.123` renders correctly. |
| 3 | Same results render as terminal ASCII table immediately after sweep — no separate command | VERIFIED | `_render_terminal_table` called inside `run_report`, output to stderr. Invoked at line 1721 immediately after sweep_meta.json. No separate command required by caller. Test confirms terminal output to stderr. |
| 4 | Before whisper winner prompt: divergence view with every disagreeing line labeled, per-model outlier count, never auto-picks | VERIFIED (code) / HUMAN-NEEDED (live TTY) | `DIVERG_ARGS` built from `WHISPER_RESULTS_LIST` lines 1407-1410; helper invoked with `>&2` at line 1413-1416; `select_best` called at line 1419. Order confirmed: divergence line 1413 < select_best line 1419. PASS_T1_3CAND and PASS_T1_2CAND both confirmed live. No `print` to stdout anywhere in `run_divergence`. |
| 5 | User selects winner per stage (or keep-current) via prompt; choice written to config/settings.conf | VERIFIED (code) / HUMAN-NEEDED (live TTY) | `select_best` extended with 3rd param `current_default_label`; `[k] Keep current` offered only when default is a candidate (line 1192-1195); sentinel `.keep_current_<stage>` file survives `$()` subshell; `write_settings_key` called on new pick (lines 1435, 1555, 1676); keep-current skips it. CR-03 fix: resume path calls `winner_label_for_output` + `write_settings_key` for all 3 stages. |
| 6 | Ctrl-C during settings.conf write leaves file fully written or absent — never partial | VERIFIED (code) / HUMAN-NEEDED (live Ctrl-C) | `write_settings_key` uses `mktemp "$SCRIPT_DIR/config/.settings_tmp_XXXXXX"` (same directory as target — same APFS volume), then `mv "$tmp_conf" "$conf_path"` (atomic OS rename). Temp registered in `_BENCH_TMPFILES` EXIT trap. macOS /tmp cross-fs mv pitfall explicitly avoided (code comment at line 510). |
| 7 | Pre-download disk-space gate counts present-but-incomplete model toward required-space estimate | VERIFIED | Disk-gate loop at lines 588-594 uses `verify_model_complete "$model_id"` (not `is_model_cached`). PASS_T1 from plan verify confirmed. `is_model_cached()` definition preserved; only the gate loop changed. |

**Score:** 7/7 truths verified (5 require human confirmation for live TTY behaviors)

### Deferred Items

None.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `benchmark_helpers.py` | divergence + report subcommands (stdlib only) | VERIFIED | 725 lines; both subcommands implemented; stdlib only confirmed |
| `benchmark.sh` | BENCH-09 fix + resume/skip/persist/settings functions + wiring | VERIFIED | All functions present and wired; bash -n clean |
| `test_benchmark_helpers.py` | Test suite (11 tests) | VERIFIED | 11/11 pass via `.venv/bin/python test_benchmark_helpers.py` |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `benchmark_helpers.py report` | `$RUN_DIR/report.md` | `os.path.join(run_dir, 'report.md')` write | VERIFIED | Line 614 of benchmark_helpers.py writes report.md; `test_report_3whisper_jsons` confirms file creation |
| `benchmark_helpers.py report` | per-candidate result JSON `output_file` field | `json.load + os.path.isfile guard` | VERIFIED | `_read_output_file` at lines 406-419; isfile guard present |
| `disk-space gate` | `verify_model_complete` | replacing `is_model_cached` in gate loop | VERIFIED | Lines 588-594: `if ! verify_model_complete "$model_id"` |
| `write_settings_key` | `config/settings.conf` | `mktemp "$SCRIPT_DIR/config/.settings_tmp_XXXXXX"` + `mv` | VERIFIED | Line 514: same-dir mktemp; atomic rename |
| `RUN_DIR assignment` | `detect_incomplete_run` | conditional resume vs fresh run dir + mkdir guard | VERIFIED | Lines 1105-1131: detect → prompt → load_picks or fresh mint |
| `whisper select_best call` | `benchmark_helpers.py divergence` | DIVERG_ARGS from WHISPER_RESULTS_LIST, `>&2` | VERIFIED | Lines 1407-1419: DIVERG_ARGS built, divergence invoked >&2 BEFORE select_best |
| `each stage pick` | `write_settings_key + persist_pick` | post-select_best, skipped when keep-current sentinel present | VERIFIED | Lines 1424-1437 (whisper), 1544-1555 (cleanup), 1666-1676 (summarize) |
| `after sweep_meta.json` | `benchmark_helpers.py report` | report invocation writing report.md | VERIFIED | Lines 1717-1724: report invoked immediately after sweep_meta.json at line 1695 |
| `CR-03: resume path` | `write_settings_key` | `winner_label_for_output` re-derives label, then writes settings | VERIFIED | Lines 1388-1403 (whisper), 1527-1538 (cleanup), 1648-1659 (summarize) |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `_render_terminal_table` (benchmark_helpers.py) | `stage_results` dict | `_load_stage_results` reads `*_result.json` files via `json.load` | YES — CR-01 fix: reads `speed_metric`/`speed_value` fields that `write_success_json` actually writes | FLOWING |
| `_write_report_md` (benchmark_helpers.py) | `stage_results`, `meta`, `picks` | same JSON sources as above | YES | FLOWING |
| `run_divergence` (benchmark_helpers.py) | transcript text | `open(filepath, errors='replace')` from DIVERG_ARGS | YES — reads real transcript files from output_file paths | FLOWING |
| `load_picks` (benchmark.sh) | `SELECTED_TRANSCRIPT/CLEANED/SUMMARY` | `"$PYTHON" -c json.load(open('$picks_path'))` | YES — reads real picks.json written by `persist_pick` | FLOWING |

Note: `load_picks` interpolates `$picks_path` directly into Python `-c` source (same class as WR-01 from code review). The path is `$RUN_DIR/picks.json` where `RUN_DIR` is timestamp-derived (safe in practice), but this is a warning-level finding, not a blocker.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| 3-candidate divergence: outlier in stderr, no header lines, empty stdout | `PASS_T1_3CAND` verify | PASS_T1_3CAND | PASS |
| 2-candidate divergence: divergence count, "no outlier ranking", empty stdout | `PASS_T1_2CAND` verify | PASS_T1_2CAND | PASS |
| Report subcommand: report.md created, turbo in both report.md and stderr | `PASS_T2` verify | PASS_T2 | PASS |
| CR-01 regression: RTF renders as `RTF=0.123`, not `n/a` | Direct invocation with `speed_metric=rtf, speed_value=0.123` | `RTF=0.123` in both stderr and report.md | PASS |
| Report with `speed_metric=rtf, speed_value=0.045`: terminal and markdown both show `RTF=0.045` | Spot-check invocation | `RTF=0.045` in report.md | PASS |
| Test suite (11 tests) | `.venv/bin/python test_benchmark_helpers.py` | 11 passed, 0 failed | PASS |
| bash -n syntax check | `bash -n benchmark.sh` | clean | PASS |

### Probe Execution

No probe scripts defined for Phase 5 (`scripts/*/tests/probe-*.sh` not present). Plan verify commands used instead — all passed.

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| BENCH-09 | 05-02 | Disk-gate uses `verify_model_complete` not `is_model_cached` | SATISFIED | Lines 588-594; PASS_T1 from plan verify |
| RESUME-01 | 05-02, 05-03 | Partial results persisted after each model completes | SATISFIED | `persist_pick` called after each candidate in all 3 stage loops; writes `picks.json` atomically |
| RESUME-02 | 05-02, 05-03 | Resume skips completed pairs, continues from where stopped | SATISFIED | `should_skip_pair` guards all 3 stage loops (6 calls); `detect_incomplete_run` + resume prompt; `load_picks` reuses decided picks |
| RPT-01 | 05-01, 05-03 | Comparison report: terminal table + report.md with speed/mem/fit/excerpt | SATISFIED | `benchmark_helpers.py report` invoked post-sweep; CR-01 fix ensures speed fields render; all verified |
| RPT-02 | 05-02, 05-03 | User picks winner per stage (or keep-current) | SATISFIED | `select_best` extended with 3rd param; keep-current via sentinel file; human-verified on TTY (per 05-03-SUMMARY) |
| RPT-03 | 05-02, 05-03 | Winner written atomically to settings.conf | SATISFIED | `write_settings_key` same-dir mktemp + mv; CR-03 fix adds resume-path write |
| RPT-04 | 05-01, 05-03 | Divergence view before transcription prompt | SATISFIED | Invoked at line 1413 before select_best at 1419; `>&2` prevents stdout pollution |
| RPT-05 | 05-01 | Per-model outlier count in divergence view, never auto-picks | SATISFIED | `find_outliers` + majority consensus; PASS_T1_3CAND confirms outlier output; no winner recommendation in code |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| benchmark.sh | 431-433 | `load_picks` interpolates `$picks_path` into Python `-c` source (WR-01 class) | Warning | Path is timestamp-derived (safe today); same class as WR-01 in code review; no injection risk under normal use |

No TBD/FIXME/XXX markers found. No placeholders or stub returns found in the phase-modified files.

### Human Verification Required

All 5 items require a real TTY with running MLX inference.

#### 1. Divergence View Rendering on Real TTY

**Test:** Run `./benchmark.sh --benchmark` in a real terminal with at least 2 whisper candidates. After candidates complete, confirm the divergence view appears BEFORE the "Select the best" prompt — columns labeled per model, wrapped at terminal width, with per-model outlier count (or "no outlier ranking" for 2 candidates). Confirm no recommended winner is shown.
**Expected:** Divergence columns render correctly, labels match candidate names, wrapping respects terminal width, no auto-pick shown
**Why human:** Column wrapping at real terminal widths and the exact visual output cannot be confirmed without a live TTY running real MLX inference

#### 2. Winner Selection Writes to settings.conf Correctly

**Test:** After the divergence view, select a winner. Confirm `config/settings.conf` now has `WHISPER_MODEL_DEFAULT=<selected-label>`. If the current default was among candidates, confirm a `[k] Keep current` entry was offered; selecting it must leave settings.conf unchanged.
**Expected:** Correct label written; keep-current writes nothing
**Why human:** Interactive prompt, sentinel file mechanism, and actual settings.conf content require a live run

#### 3. Resume Skip Behavior on Ctrl-C

**Test:** Run `--benchmark`, kill with Ctrl-C mid-whisper stage, then re-run. Confirm the `Resume interrupted run from <ts>? [Y/n]` prompt appears. Accept. Confirm already-completed candidates are skipped and stages with a recorded pick are not re-prompted.
**Expected:** Resume prompt appears; completed pairs skipped; decided picks reused silently
**Why human:** Requires interrupting a real sweep and observing resume behavior

#### 4. Ctrl-C Atomicity (Criterion #6)

**Test:** During a settings.conf write, confirm the file is either fully written or absent after interruption — never partial.
**Expected:** Atomic OS rename ensures whole-or-absent semantics
**Why human:** Requires observing actual OS-level atomic rename behavior under real SIGINT

#### 5. End-to-End Report + CR-03 Resume Write

**Test:** After a complete sweep, confirm: (a) terminal ASCII table printed to stderr with real RTF/tok/s values (not "n/a"), (b) `results/<run_ts>/report.md` exists with per-stage tables, speed values, memory, fit status, excerpts, and Selected Winners section. (c) CR-03 resume path: interrupt after whisper pick, resume, confirm `settings.conf` shows the whisper winner.
**Expected:** Terminal table and report.md have real speed numbers; CR-03 settings reconciliation works on a real resumed run
**Why human:** Real multi-candidate sweep output quality and CR-03 correctness require actual MLX inference

### Gaps Summary

No automated gaps found. All 7 success criteria are verified at the code level. The 5 human verification items above correspond to behaviors explicitly marked `autonomous: false` in 05-03-PLAN.md (Task 3: checkpoint:human-verify, gate=blocking) — they require interactive TTY + real MLX inference and were human-approved during the original execution per 05-03-SUMMARY. The code review blockers (CR-01, CR-02, CR-03) were all fixed and re-verified:

- **CR-01** (4b1682c): `_format_speed` reads `speed_metric`/`speed_value` — confirmed by grep, spot-check rendering `RTF=0.123`, and test `test_report_3whisper_jsons` asserting `RTF=0.020`.
- **CR-02** (20b2773): All JSON writers (`write_success_json`, `write_error_json`, `write_skip_json`, `sweep_meta.json`) use quoted `'PYEOF'` heredocs with all values passed via `sys.argv` — confirmed by grep showing `<< 'PYEOF'` at lines 788, 824, 859, 1695.
- **CR-03** (095d84e): Resume path now calls `winner_label_for_output` + `write_settings_key` in all 3 stage resume branches (lines 1399-1401, 1534-1536, 1655-1657). The `.keep_current_<stage>.persisted` durable marker correctly gates keep-current detection on the resume path.

The 7 remaining open warnings from the code review (WR-01 through WR-07) are quality/robustness issues, none of which block the stated phase goal or success criteria. They are carried forward for a future hardening pass.

---

_Verified: 2026-06-17T00:00:00Z_
_Verifier: Claude (gsd-verifier)_
