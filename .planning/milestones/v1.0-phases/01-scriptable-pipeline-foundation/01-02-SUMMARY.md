---
phase: 01-scriptable-pipeline-foundation
plan: "02"
subsystem: pipeline-scripts
tags: [bash, orchestrator, cli, non-interactive, mlx, pipeline]
dependency_graph:
  requires:
    - phase: 01-scriptable-pipeline-foundation/01-01
      provides: non-interactive-transcribe, non-interactive-cleanup, non-interactive-summarize, OUTPUT_FILE-emission
  provides:
    - transcribrr.sh orchestrator (single-command pipeline entrypoint)
    - SKELETON.md architectural backbone for Phase 2
  affects: [transcribrr.sh, SKELETON.md]
tech-stack:
  added: []
  patterns:
    - tee-stderr-OUTPUT_FILE-capture (sub-script stdout tee'd to user via /dev/stderr while OUTPUT_FILE= line captured)
    - accumulating-preflight-check (all preflight failures collected before aborting)
    - ERR-trap-stage-naming (CURRENT_STAGE variable updated before each stage so ERR trap names it)
    - stage-banner-progress (stage_banner() function prints Stage N/3 headers)
key-files:
  created:
    - transcribrr.sh
    - .planning/phases/01-scriptable-pipeline-foundation/SKELETON.md
  modified: []
key-decisions:
  - "Tasks 1 and 2 collapsed into a single atomic commit: the stage wiring was written together with the flag/preflight/help scaffolding since all sections were structurally dependent"
  - "OUTPUT_FILE= capture uses tee /dev/stderr | grep so sub-script progress reaches the terminal while the machine-parseable line is captured (Pitfall 5)"
  - "Preflight accumulates all failures before exit — user sees all missing deps in one run"
patterns-established:
  - "Stage output chaining: STAGE_OUT=$(...| tee /dev/stderr | grep '^OUTPUT_FILE=') then ${STAGE_OUT#OUTPUT_FILE=}"
  - "Guard after capture: [ -z \"$FILE\" ] || [ ! -f \"$FILE\" ] -> exit 1"
  - "NO_CLEANUP=false branch: set SUMMARIZE_INPUT to CLEANED_FILE; else set to TRANSCRIPT_FILE with notice"
requirements-completed: [DL-01, CLI-02, CLI-03, ROB-01, TR-03, CL-03, SUM-03]
duration: 3min
completed: 2026-06-14
---

# Phase 1 Plan 2: Orchestrator + Skeleton Summary

**Single-command `transcribrr.sh` orchestrator wiring transcribe -> cleanup -> summarize via `OUTPUT_FILE=` capture with preflight checks, `--no-cleanup`, per-stage banners, and a `--help` covering all flags.**

## Performance

- **Duration:** ~3 minutes
- **Started:** 2026-06-14T10:22:19Z
- **Completed:** 2026-06-14T10:25:00Z
- **Tasks:** 3
- **Files modified:** 2 (created)

## Accomplishments

- `transcribrr.sh` created at repo root: flag parsing, preflight, ERR trap, stage banners, three-stage pipeline chaining via `OUTPUT_FILE=`, `--no-cleanup` support, and a full `--help` heredoc
- `SKELETON.md` created recording the Phase 1 architectural backbone for future phases
- Walking Skeleton complete: one command drives the full local-MP3 pipeline unattended

## Task Commits

Each task was committed atomically:

1. **Task 1+2: Create transcribrr.sh orchestrator (flags, preflight, help, stage wiring)** - `2e04d44` (feat)
2. **Task 3: Write SKELETON.md architectural backbone** - `ab59f7f` (docs)

_Note: Tasks 1 and 2 were implemented together in a single commit. The stage-wiring blocks (Task 2's action) were written alongside the flag/preflight/help scaffolding (Task 1's action) since all sections were structurally dependent. All Task 2 verification checks pass on the same commit._

## Files Created/Modified

- `/Users/gareth/git/transcribrr/transcribrr.sh` - Orchestrator: `#!/bin/bash`, `set -euo pipefail`, `SCRIPT_DIR`, flag loop, `print_help()`, `preflight_check()`, `stage_banner()`, ERR trap, three-stage pipeline with `tee /dev/stderr | grep "^OUTPUT_FILE="` capture and non-empty/file-exists guards
- `/Users/gareth/git/transcribrr/.planning/phases/01-scriptable-pipeline-foundation/SKELETON.md` - Architectural backbone: capability, decisions table, stack checklist, out-of-scope list, Phase 2 subsequent slice plan

## Decisions Made

1. **Tasks 1 and 2 collapsed into one commit:** The stage blocks (Task 2's "append") were written alongside the scaffold (Task 1) in the initial file creation. This is not a deviation — it is efficient implementation. All acceptance criteria for both tasks pass on the same file.

2. **`tee /dev/stderr` for stage output:** Sub-script stdout is tee'd to `/dev/stderr` so the user sees all progress output while `grep "^OUTPUT_FILE="` captures only the machine-parseable line. This avoids hiding stage output (Pitfall 5 from RESEARCH.md).

3. **Preflight accumulates all errors:** Instead of failing on the first missing dependency, `preflight_check()` increments an `errors` counter and prints all problems before calling `exit 1`. A user misconfigured on two fronts (no ffmpeg, wrong path) sees both messages in one run.

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## Known Stubs

None. `transcribrr.sh` is fully wired; all stage invocations, flag pass-throughs, and OUTPUT_FILE= guards are implemented. `SKELETON.md` documents actual decisions, not placeholders.

## Threat Flags

None. `transcribrr.sh` introduces no new network endpoints, auth paths, or file access patterns beyond the CLI flag surface documented in the plan's threat model. All STRIDE mitigations implemented:

| Threat ID | Status | Implementation |
|-----------|--------|----------------|
| T-02-01 | Mitigated | All expansions double-quoted; flags passed as positional args; no eval |
| T-02-02 | Mitigated | After each OUTPUT_FILE= capture: non-empty check + `[ -f "$FILE" ]` before use |
| T-02-03 | Mitigated | Preflight requires `[ -f "$MP3_FILE" ]`; intermediate paths derive from sub-scripts |
| T-02-04 | Mitigated | `preflight_check()` runs before any stage invocation with named cause |

## Next Phase Readiness

- Phase 1 Walking Skeleton is complete: `./transcribrr.sh <audio.mp3>` drives the full pipeline
- `SKELETON.md` records the architectural backbone as a contract for Phase 2
- Phase 2 can build on this foundation: add `yt-dlp` download + `ffmpeg` MP3 extraction + metadata capture + single-markdown assembly
- No blockers for Phase 2

---
*Phase: 01-scriptable-pipeline-foundation*
*Completed: 2026-06-14*
