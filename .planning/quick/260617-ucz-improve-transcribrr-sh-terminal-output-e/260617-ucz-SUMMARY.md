---
phase: quick-260617-ucz
plan: "01"
subsystem: transcribrr.sh
tags: [ux, terminal-output, narration, bash, color]
dependency_graph:
  requires: []
  provides: [stage-narration, color-banner, completion-recap]
  affects: [transcribrr.sh]
tech_stack:
  added: []
  patterns: [stderr-only narration, ANSI TTY guard, two-arg stage banner]
key_files:
  created: []
  modified: [transcribrr.sh]
decisions:
  - "Route ALL human narration to stderr; stdout reserved for machine-readable ^OUTPUT_FILE= lines only"
  - "Color emitted only when stderr is TTY and NO_COLOR is unset — plain scalar vars, printf-built escapes"
  - "Metadata banner split from download banner (metadata is a dry probe; download is a separate I/O stage)"
  - "Provenance (Models:) block routed to stderr for stream consistency"
metrics:
  duration: "~12m"
  completed: "2026-06-17"
  tasks_completed: 3
  files_modified: 1
---

# Quick Task 260617-ucz: Improve transcribrr.sh Terminal Output Summary

**One-liner:** Color/TTY-aware stage banners with WHAT+WHY narration, explicit ffmpeg step, surfaced video metadata, and a richer completion recap — all routed to stderr.

## What Was Done

### Task 1 — Color/TTY-aware banner helper + narration helpers (stderr-routed)

Added a color-setup block (plain scalar vars `C_BOLD`, `C_DIM`, `C_RESET` set via
`printf '\033[...m'`) that emits ANSI codes only when `[ -t 2 ]` (stderr is a TTY)
and `[ -z "${NO_COLOR:-}" ]`. Falls back to empty strings in redirected/unattended runs.

Rewrote `stage_banner()` to accept two args (title, optional why-line) and route ALL
output to stderr via a `{ ...; } >&2` group. Wraps title in `${C_BOLD}...${C_RESET}`
and why-line in `${C_DIM}...${C_RESET}`.

Added `narrate()` helper for one-line sub-step messages to stderr.

Added a stream convention comment documenting stdout=machine / stderr=human.

**Commit:** 78b5573

### Task 2 — Narrate each stage with WHAT + WHY and surface video context

Updated all stage banner call sites:
- Metadata banner: removed misleading "and downloading audio" wording; added why line
- After metadata parsed: `narrate()` surfaces Title / Channel / Duration / Work dir
- Download banner: renamed "Download & extract audio"; added why line; added explicit
  `narrate()` call naming ffmpeg (resolves the user's stated complaint about the
  previously-silent ffmpeg extraction step)
- Transcribe banner: added why line; added `narrate()` before `_run_transcribe` call
- Cleanup banners: added why line; replaced bare `echo` (stdout) with `narrate()` for
  the --no-cleanup skip message
- Summarize banners: added why line with model and style
- Assemble banners: added why line for both URL and local paths

Stage numbering for URL path: metadata=1/5, download=1/5, transcribe=2/5,
cleanup=3/5, summarize=4/5, assemble=5/5. Local path: 1/3 through 3/3 unchanged.

All `_run_*` functions and `^OUTPUT_FILE=` grep captures left untouched.

**Commit:** bdda64a

### Task 3 — Richer completion summary + redirect-safe provenance

Routed the pre-pipeline provenance block (`Models:` printf lines) to stderr for
stream consistency (was the only remaining bare stdout narration outside _run_*).

Upgraded the final completion block:
- Moved to `{ ...; } >&2`
- Wrapped "Pipeline complete!" in `${C_BOLD}...${C_RESET}`
- Added recap: Markdown path, Source URL, Title, Duration, Models line
- Models line handles `--no-cleanup` case (`cleanup=skipped`)

**Commit:** 43cea8f

## Deviations from Plan

None — plan executed exactly as written. Stage numbering was clarified (both metadata
and download use "1/5" per plan intent: metadata is a dry probe for the same "Stage 1"
I/O block as the download).

## Known Stubs

None.

## Threat Flags

None — output-only changes; no new network endpoints, auth paths, file access patterns,
or schema changes.

## Self-Check

- [x] transcribrr.sh modified and committed (3 commits: 78b5573, bdda64a, 43cea8f)
- [x] `bash -n transcribrr.sh` passes (syntax valid, bash 3.2-safe)
- [x] No bash 4+ constructs (no `declare -A`, `mapfile`, `readarray`, `${var^^}`)
- [x] `NO_COLOR=1 --help 2>/dev/null | cat -v` produces no raw escape sequences
- [x] `stage_banner` count = 11 (all stages covered, URL+local variants)
- [x] ffmpeg narration present (download stage narrate call)
- [x] `^OUTPUT_FILE=` capture contracts unchanged
- [x] All narration routes to stderr; stdout clean

## Self-Check: PASSED
