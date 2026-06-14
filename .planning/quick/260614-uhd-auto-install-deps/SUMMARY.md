---
phase: quick
plan: 260614-uhd
subsystem: cli
tags: [bash, homebrew, yt-dlp, ffmpeg, preflight]

requires: []
provides:
  - ensure_dep helper that auto-installs missing CLI deps via Homebrew
  - --no-install flag to opt out of auto-install and preserve fail-with-hint behavior
affects: [transcribrr.sh users who rely on preflight error messages]

tech-stack:
  added: []
  patterns:
    - "ensure_dep <cmd> <formula>: single shared helper for dep resolution across preflight"

key-files:
  created: []
  modified:
    - transcribrr.sh

key-decisions:
  - "Auto-install is silent-unattended by default (no prompt) — consistent with the project's unattended core value"
  - "yt-dlp install remains inside the IS_URL=true guard — only required when processing a URL"
  - "ensure_dep returns 1 on failure so caller can increment error counter, preserving accumulate-then-abort preflight style"
  - "brew absence check inside ensure_dep gives a named, actionable error rather than a cryptic brew: not found"

requirements-completed: []

duration: 10min
completed: 2026-06-14
---

# Quick Task 260614-uhd: Auto-install missing deps via Homebrew

**`ensure_dep` helper auto-installs ffmpeg and yt-dlp via Homebrew when missing, with a `--no-install` opt-out that preserves the existing fail-with-hint behavior.**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-06-14
- **Completed:** 2026-06-14
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- Added `ensure_dep <command> <brew-formula>` helper that auto-installs missing deps, re-checks, and fails with a named message if brew is absent, install fails, or dep is still missing after install
- Added `NO_INSTALL=false` default and `--no-install` flag parsing; documented in `print_help`
- Replaced two duplicated inline `brew install` hint blocks in `preflight_check` with single `ensure_dep` calls — one for ffmpeg (always), one for yt-dlp (URL-conditional)
- Both `bash -n` and `/bin/bash -n` pass; no bash-5-only constructs introduced

## Task Commits

1. **Task 1: Add --no-install flag + auto-install logic to preflight** - `d8701a5` (feat)

## Files Created/Modified

- `transcribrr.sh` - Added `NO_INSTALL` default, `--no-install` flag, `ensure_dep` helper, updated `preflight_check` to use it

## Decisions Made

- `ensure_dep` returns 1 (not exits) so the preflight error-accumulation loop continues collecting all failures before aborting — preserves existing UX
- Brew output is shown live (not suppressed) so the user sees install progress
- `Installed <cmd>.` confirmation printed to stderr after successful auto-install

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## Self-Check

- [x] `transcribrr.sh` contains `NO_INSTALL=false` default
- [x] `transcribrr.sh` contains `--no-install)` case in flag parser
- [x] `print_help` documents `--no-install`
- [x] `ensure_dep` function present
- [x] `preflight_check` uses `ensure_dep ffmpeg ffmpeg` and `ensure_dep yt-dlp yt-dlp`
- [x] `bash -n transcribrr.sh`: PASSED
- [x] `/bin/bash -n transcribrr.sh`: PASSED
- [x] Commit d8701a5 exists

## Self-Check: PASSED

---
*Quick task: 260614-uhd-auto-install-deps*
*Completed: 2026-06-14*
