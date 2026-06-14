---
phase: 01-scriptable-pipeline-foundation
plan: "01"
subsystem: pipeline-scripts
tags: [bash, refactor, cli, non-interactive, mlx]
dependency_graph:
  requires: []
  provides: [non-interactive-transcribe, non-interactive-cleanup, non-interactive-summarize, OUTPUT_FILE-emission]
  affects: [transcribe.sh, cleanup-transcript.sh, summarize-transcript.sh]
tech_stack:
  added: []
  patterns: [while-flag-loop, friendly-label-to-hf-id-case, canonical-sed-sanitizer, OUTPUT_FILE-emission]
key_files:
  created: []
  modified:
    - transcribe.sh
    - cleanup-transcript.sh
    - summarize-transcript.sh
decisions:
  - "Arg loops converted from for-arg to while-[[$#-gt-0]] to support two-token --flag value pairs"
  - "Friendly labels map via case statement to HF IDs; raw HF IDs (containing /) use canonical sed sanitizer"
  - "OUTPUT_FILE= emission placed on success path only, after each script's write block/heredoc"
  - "cleanup-transcript.sh pre-assignment bug fixed: removed _cleaned.txt (no label) assignment"
  - "summarize-transcript.sh unsanitized custom label bug fixed: canonical sed sanitizer applied"
metrics:
  duration: "4 minutes"
  completed: "2026-06-14"
  tasks_completed: 3
  tasks_total: 3
  files_changed: 3
---

# Phase 1 Plan 1: Non-Interactive Sub-Script Refactor Summary

**One-liner:** Flag-driven model/style selection with silent defaults and `OUTPUT_FILE=` emission replacing interactive `read -p` menus in all three MLX pipeline scripts.

## What Was Built

Refactored three existing MLX pipeline bash scripts to run fully unattended via CLI flags, enabling the plan 02 orchestrator to chain them without any interactive prompts. Each script now:

- Accepts a `--model` flag (and `--style` for summarize-transcript.sh) with friendly label or raw Hugging Face model ID
- Defaults silently to the README-recommended model/style when the flag is absent
- Emits a machine-parseable `OUTPUT_FILE=<path>` line on the success path after writing the output file
- Rejects unrecognized `-*` flags with an "Unknown option:" error message to stderr

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add --model flag and OUTPUT_FILE= emission to transcribe.sh | 461a833 | transcribe.sh |
| 2 | Add --model flag and OUTPUT_FILE= emission to cleanup-transcript.sh | d743fc2 | cleanup-transcript.sh |
| 3 | Add --model and --style flags and OUTPUT_FILE= emission to summarize-transcript.sh | cabeaeb | summarize-transcript.sh |

## Decisions Made

1. **While loop over for-arg loop:** All three scripts now use `while [[ $# -gt 0 ]]` with `shift 2` for two-token flags (`--flag value`). The original `for arg in "$@"` form cannot consume the next positional argument for a flag value.

2. **Friendly label allow-list via case:** Unknown friendly labels (non-`/` values) exit 1 with a "Valid labels:" message instead of falling through to a default. This matches the threat model's T-01-02 requirement for explicit validation.

3. **Raw HF ID detection via `*/*` glob:** The same pattern used by `mlx-chat.sh` line 314 is applied in all three scripts. When a flag value contains `/`, it is treated as a raw HF ID and the canonical sed sanitizer is applied to produce a safe `MODEL_LABEL`.

4. **OUTPUT_FILE= placed after write block only:** In `transcribe.sh`, the emission follows the `} > "$OUTPUT_FILE"` block inside the success branch. In `cleanup-transcript.sh` and `summarize-transcript.sh`, it follows the Python heredoc (`PYTHON_SCRIPT` end marker) on the success path.

## Deviations from Plan

None - plan executed exactly as written.

## Bug Fixes Applied

**1. [Rule 2 - Pre-existing bug] cleanup-transcript.sh pre-assignment removed**
- **Found during:** Task 2 (called out explicitly in PLAN.md as Pitfall 2)
- **Issue:** Line 26 set `OUTPUT_FILE="${BASENAME}_cleaned.txt"` (no label suffix) before MODEL_LABEL was determined. Line 61 later reassigned correctly but the earlier value could be emitted in error paths.
- **Fix:** Removed the line-26 pre-assignment; only `${BASENAME}_cleaned_${MODEL_LABEL}.txt` remains, positioned after MODEL_LABEL is known.
- **Files modified:** cleanup-transcript.sh
- **Commit:** d743fc2

**2. [Rule 2 - Pre-existing bug] summarize-transcript.sh unsanitized custom label fixed**
- **Found during:** Task 3 (called out in PLAN.md as Pitfall 3)
- **Issue:** The original case-5 custom model path set `MODEL_LABEL="$MODEL"` without sanitization. A raw HF ID like `mlx-community/Qwen2.5-32B-Instruct-4bit` would embed a `/` in the output filename, breaking the `.gitignore` pattern match and producing an invalid path.
- **Fix:** Replaced with the canonical sed sanitizer applied to the `--model` value when it contains `/`.
- **Files modified:** summarize-transcript.sh
- **Commit:** cabeaeb

## Security / Threat Model

All threat mitigations from the plan's STRIDE register were implemented:

| Threat ID | Status | Implementation |
|-----------|--------|---------------|
| T-01-01 | Mitigated | Canonical sed sanitizer applied to all `/`-containing model values in all three scripts |
| T-01-02 | Mitigated | Friendly labels and styles validated against fixed allow-lists; exit 1 on unknown values |
| T-01-03 | Mitigated | All file paths and flag values referenced with double-quoted expansions; no eval |
| T-01-04 | Mitigated | `OUTPUT_FILE=` emission placed only on success path, after write completes |

## Known Stubs

None. All three scripts are fully functional; the flag parsing, model selection, and OUTPUT_FILE= emission are wired end-to-end.

## Threat Flags

None. No new network endpoints, auth paths, file access patterns, or schema changes introduced. Changes are limited to argument parsing and stdout emission within existing scripts.

## Self-Check: PASSED

- [x] transcribe.sh exists and syntax-checks clean (`bash -n`)
- [x] cleanup-transcript.sh exists and syntax-checks clean
- [x] summarize-transcript.sh exists and syntax-checks clean
- [x] No `read -p` outside comments in any of the three files
- [x] Each file contains `echo "OUTPUT_FILE=$OUTPUT_FILE"` on success path
- [x] Commits 461a833, d743fc2, cabeaeb exist in git log
- [x] summarize-transcript.sh still accepts `--install`
- [x] cleanup-transcript.sh has no `_cleaned.txt` (bare, no label) assignment
- [x] Output filename templates unchanged (`*_transcript_*.txt`, `*_cleaned_*.txt`, `*_summary_*.md`)
