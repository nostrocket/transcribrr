---
phase: 05-resumable-sweep-report-winner-selection
plan: "01"
subsystem: benchmark-helpers
tags: [python, difflib, textwrap, divergence, report, benchmark]
dependency_graph:
  requires: []
  provides: [benchmark_helpers.py divergence subcommand, benchmark_helpers.py report subcommand]
  affects: [benchmark.sh wave-2 integration (05-03)]
tech_stack:
  added: [benchmark_helpers.py (Python 3.11 stdlib only)]
  patterns: [SequenceMatcher sentence alignment, majority-consensus outlier counting, side-by-side column rendering, argparse subcommands]
key_files:
  created: [benchmark_helpers.py, test_benchmark_helpers.py]
  modified: []
decisions:
  - "Used difflib.SequenceMatcher over normalized sentence units (not raw lines) per RESEARCH recommendation — handles transcript segment-level alignment correctly"
  - "2-candidate fallback path: report divergence count only, emit 'no outlier ranking with 2 candidates' — no majority possible with 2 transcripts"
  - "Control-char stripping applied via regex [x00-x08][x0b-x0c][x0e-x1f][x7f-x9f] on all rendered cells (T-05-04), label validation [A-Za-z0-9._-]+ with exit 2 (T-05-05)"
  - "report subcommand reads output_file from each JSON (absolute path, outside run dir per Pitfall 7), isfile-guarded before reading excerpts"
  - "All terminal output to stderr for both subcommands — stdout always empty to avoid polluting select_best capture in benchmark.sh"
metrics:
  duration: 4m
  completed: "2026-06-17"
  tasks_completed: 2
  files_created: 2
---

# Phase 5 Plan 01: benchmark_helpers.py — Divergence + Report Summary

Standalone Python helper (stdlib only) providing sentence-level cross-model transcript divergence alignment with majority-consensus outlier counting, and a comparison report builder that renders a compact terminal ASCII table and writes a self-contained `report.md` with full excerpts.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| TDD RED | Failing test suite for divergence + report | e395f5e | test_benchmark_helpers.py |
| TDD GREEN | Implement benchmark_helpers.py (both subcommands) | 5dde56a | benchmark_helpers.py |

## What Was Built

### benchmark_helpers.py (725 lines, stdlib only)

**`divergence` subcommand** (`run_divergence`):
- Accepts `--transcripts label:filepath ...` and `--term-width INT`
- `strip_header()` drops `Model:`/`Source:`/`Date:` lines + following blank before alignment (Pitfall 1)
- `normalize()`: lowercase + strip non-word/non-space + collapse whitespace — used for compare only; original text displayed
- `split_sentences()`: regex lookbehind on `[.!?]\s+`; fallback to newline split if <5 units
- `align_to_anchor()`: `SequenceMatcher` on normalized units; maps `equal` + `replace` opcodes to anchor positions
- `find_outliers()`: `Counter` majority consensus; returns `(consensus_norm, outlier_labels)` or `(None, [])` on agreement
- `render_side_by_side()`: `textwrap.wrap` at `col_w = max(20, (term_width - gap*(n-1))//n)` — no truncation (D-04)
- 3+ candidates: prints per-model outlier count + % of divergent positions (RPT-05)
- 2 candidates: prints divergence count + "(no outlier ranking with 2 candidates)" (D-03 fallback)
- Label validation `[A-Za-z0-9._-]+` with `sys.exit(2)` (V5 / T-05-05)
- Control-char stripping on all rendered cells (`[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f-\x9f]`, T-05-04)
- All output via `sys.stderr`; stdout always empty
- Exit 0 success, 1 read failure leaving <2 readable, 2 bad args

**`report` subcommand** (`run_report`):
- Accepts `--run-dir DIR` and `--term-width INT`
- Reads all `*_result.json` under `DIR/whisper/`, `DIR/cleanup/`, `DIR/summarize/`
- Reads `DIR/sweep_meta.json` and `DIR/picks.json` (tolerates absence)
- `_render_terminal_table()`: compact ASCII to stderr (plain `-` rules, columns: Stage/Model/Speed/Mem/Fit)
- `_write_report_md()`: per-stage results table, full excerpts inline, Selected Winners table, optional divergence summary
- `output_file` read with `os.path.isfile()` guard; missing files produce `(output file not found: PATH)` note in report.md
- Empty run dir (zero JSONs): writes minimal valid report.md, exits 0
- stdout always empty; `report.md` is the only file written

## Verification Results

All plan-specified verification commands pass:

```
PASS_T1_3CAND   — 3-candidate divergence: outlier in stderr, no "Model: x" header lines
PASS_T1_2CAND   — 2-candidate fallback: exit 0, divergence count, "no outlier ranking"
PASS_T2         — report: report.md created, "turbo" in both report.md and terminal stderr
```

Test suite (11 tests): 11 passed, 0 failed.

Additional verifications:
- `import difflib,textwrap,re,json,collections,subprocess` — stdlib OK (no pip installs)
- Stdout empty for both subcommands: confirmed
- Control-char injection test: `\x1b[31m` escape sequences stripped from rendered output
- File length: 725 lines (above 150-line minimum from plan artifacts spec)

## TDD Gate Compliance

| Gate | Commit | Status |
|------|--------|--------|
| RED (test) | e395f5e | test(05-01): add failing tests — 8 of 11 failed (file missing) |
| GREEN (impl) | 5dde56a | feat(05-01): implement benchmark_helpers.py — 11 of 11 pass |

## Deviations from Plan

None — plan executed exactly as written.

The plan specified Tasks 1 and 2 as separate TDD tasks both modifying `benchmark_helpers.py`. The implementation committed both tasks' implementation together in the GREEN commit (5dde56a) since both subcommands are in the same file and both were complete at the same time. Tests were committed separately as the RED commit (e395f5e) per TDD protocol.

## Threat Flags

No new threat surface beyond what the plan's threat model covers. The two threats mitigated:
- T-05-04: Control-char stripping implemented on all rendered transcript cells
- T-05-05: Label validation `[A-Za-z0-9._-]+` with exit 2 on mismatch

## Self-Check

- [x] `benchmark_helpers.py` exists at worktree root
- [x] `test_benchmark_helpers.py` exists at worktree root
- [x] Commit e395f5e: `test(05-01): add failing tests`
- [x] Commit 5dde56a: `feat(05-01): implement benchmark_helpers.py`
- [x] PASS_T1_3CAND verified
- [x] PASS_T1_2CAND verified
- [x] PASS_T2 verified

## Self-Check: PASSED
