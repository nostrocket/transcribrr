---
phase: 02-end-to-end-youtube-to-markdown-delivery
plan: "02"
subsystem: orchestrator
tags: [assemble, atomic-mv, markdown-assembly, gitignore, bash]
dependency_graph:
  requires: [02-01]
  provides: [end-to-end-url-to-markdown]
  affects: [transcribrr.sh, .gitignore]
tech_stack:
  added: []
  patterns: [mktemp-atomic-mv, exit-trap-cleanup, printf-no-reexpansion, transcript-variant-selection, summary-header-strip]
key_files:
  modified:
    - transcribrr.sh
    - .gitignore
decisions:
  - "VIDEO_* metadata fields defaulted with ${VAR:-NA} in assemble stage so local-MP3 path works without set -u crash"
  - "VIDEO_UPLOAD_DATE preferred over re-reformat: URL path already has VIDEO_UPLOAD_DATE set by metadata stage; assemble stage uses ${VIDEO_UPLOAD_DATE:-$_VID_DATE} to avoid double-reformatting"
  - "printf used (not heredoc) so variable values are not re-expanded (Security Domain)"
  - "EXIT trap set before TEMP_MD write, cleared immediately after successful mv — interacts safely with existing ERR trap"
metrics:
  duration: "2m"
  completed: "2026-06-14"
  tasks_completed: 2
  tasks_total: 2
  files_changed: 2
---

# Phase 02 Plan 02: Assemble Stage — Atomic Markdown Assembly and Gitignore Summary

Assemble stage that atomically writes one rich-header markdown file (title + metadata block + stripped summary + transcript) from a mktemp temp file via atomic mv, with transcript-variant selection and per-video working-directory gitignore coverage.

## What Was Built

**Task 1 — Assemble stage in transcribrr.sh:**

Replaced the Phase 1 "Done" block with a complete assemble stage:

- `CURRENT_STAGE="assemble"` + Stage 5/5 banner (ROB-02: ERR trap names assemble failures)
- `set -u`-safe defaults for `VIDEO_*` metadata fields via `${VAR:-...}` so local-MP3 runs produce the markdown without an unbound-variable crash
- Upload date: uses `VIDEO_UPLOAD_DATE` (already set by metadata stage for URL path); for local path, defaults `VIDEO_UPLOAD_DATE_RAW` to NA and reformats if it matches `^[0-9]{8}$`
- Transcript variant selection: `EMBED_TRANSCRIPT="$CLEANED_FILE"` when cleanup ran; `"$TRANSCRIPT_FILE"` when `--no-cleanup` (CONTEXT.md locked decision)
- `FINAL_MD_PATH="$(pwd)/${SAFE_TITLE}.md"` — anchored to CWD root, SAFE_TITLE not re-derived (set by Plan 01 on both URL and local paths) (OUT-03, T-02-06)
- `TEMP_MD=$(mktemp)` + `trap 'rm -f "$TEMP_MD"' EXIT` — temp file cleaned on premature exit (T-02-05, ROB-03)
- Document written with `printf` (not heredoc) to prevent re-expansion; order: `# title`, bulleted metadata (`**Title:**`, `**Channel:**`, `**Source URL:**`, `**Duration:**`, `**Upload date:**`, `**Models used:**`), `## Summary`, summary content with header stripped via `sed '1,/^---/d'`, `## Transcript`, embedded transcript (OUT-01, OUT-02)
- `**Models used:**` shows `cleanup=<model>` or `cleanup=skipped` depending on `--no-cleanup` flag
- `mv "$TEMP_MD" "$FINAL_MD_PATH"` — atomic; FINAL_MD_PATH exists only after all stages succeed
- `trap - EXIT` immediately after successful mv removes cleanup trap
- No `rm` of any intermediate files — transcript, cleaned, summary, MP3 all retained (CONTEXT.md)
- Final message: `Markdown: $FINAL_MD_PATH`

**Task 2 — .gitignore per-video working directories:**

- Appended `*_*/` glob to `.gitignore` matching `<SAFE_TITLE>_<VIDEO_ID>/` working dirs created by URL mode
- Comment documents that root `*.md` output is intentionally NOT gitignored
- All existing intermediate patterns (`*_transcript_*.txt`, `*_cleaned_*.txt`, `*_summary_*.md`, `*_transcription_*.log`, `*_whisper_*.pid`) preserved unchanged

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| Task 1 | 035dfdc | feat(02-02): add assemble stage — atomic temp+mv rich-header markdown |
| Task 2 | 82db2e2 | chore(02-02): gitignore per-video working directories |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing critical functionality] Upload date double-reformat guard**
- **Found during:** Task 1 implementation
- **Issue:** The plan specified re-running the `YYYYMMDD` → `YYYY-MM-DD` reformat in the assemble stage. However, for the URL path, `VIDEO_UPLOAD_DATE` is already correctly set (as a reformatted date or NA) by the metadata stage in Plan 01. Calling the reformat again on an already-reformatted date would produce malformed output (e.g. `2026-06-14` → `2026-06-14` is idempotent for valid dates but the guard `^[0-9]{8}$` would not match a reformatted date, so it would pass through unchanged — not harmful, but the logic path is cleaner).
- **Fix:** Added `_VID_DATE_RAW="${VIDEO_UPLOAD_DATE_RAW:-NA}"` to default the raw value (unset on local path), applied the `^[0-9]{8}$` guard, then used `_VID_UPLOAD_DATE="${VIDEO_UPLOAD_DATE:-$_VID_DATE}"` to prefer the already-processed `VIDEO_UPLOAD_DATE` (URL path) over the locally recomputed value. This ensures idempotency and avoids any double-reformat edge case.
- **Files modified:** transcribrr.sh
- **Commit:** 035dfdc

## Known Stubs

None. All variables wired; assemble stage produces a complete document for both URL and local-MP3 paths.

## Threat Flags

No new security surface beyond the plan's threat model. All T-02-05, T-02-06, T-02-07, T-02-SC mitigations applied:

| Threat | Mitigation | Status |
|--------|-----------|--------|
| T-02-05: partial markdown read as complete | mktemp + atomic mv; EXIT trap removes temp on premature exit | Applied |
| T-02-06: filename from video title | SAFE_TITLE from Plan 01 allow-list sanitizer; FINAL_MD_PATH anchored to $(pwd)/ | Applied |
| T-02-07: metadata embedded verbatim | printf (no re-expansion); local-user-chosen content; accept disposition | Applied |

## Self-Check: PASSED

- transcribrr.sh exists: confirmed
- .gitignore updated: confirmed, `*_*/` pattern present, existing patterns intact
- Commits 035dfdc and 82db2e2 verified in git log
- `bash -n transcribrr.sh` passes
- `CURRENT_STAGE="assemble"` present
- `mktemp` present
- `sed '1,/^---/d'` present
- `EMBED_TRANSCRIPT` present
- `Models used` present
- `mv "$TEMP_MD"` present
- `*_*/` in .gitignore
- `_transcript_` in .gitignore (existing pattern preserved)
