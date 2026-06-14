---
phase: quick-260615-1ek
plan: "01"
subsystem: transcribe.sh
tags: [bash, venv, mlx-whisper, auto-install, unattended]
dependency_graph:
  requires: []
  provides: [auto-provisioned .venv with mlx-whisper on first transcribe.sh run]
  affects: [transcribe.sh]
tech_stack:
  added: []
  patterns: [setup_venv pattern (mirrors summarize-transcript.sh)]
key_files:
  created: []
  modified: [transcribe.sh]
decisions:
  - setup_venv mirrors summarize-transcript.sh exactly — same .venv, same idiom, ensures shared environment
  - No set -euo pipefail added — transcribe.sh has no strict mode and relies on trap/cleanup
metrics:
  duration: "2m 30s"
  completed: "2026-06-14T17:05:33Z"
  tasks_completed: 1
  files_changed: 1
---

# Phase quick-260615-1ek Plan 01: Auto-install mlx-whisper into .venv on first run Summary

**One-liner:** Added `setup_venv` function to `transcribe.sh` that creates `.venv` and pip-installs `mlx-whisper` when absent, replacing the dead-end "Please install it first" hard error with the same auto-provision idiom used by `summarize-transcript.sh`.

## What Was Built

`transcribe.sh` previously hard-exited with `exit 1` and a manual install instruction when `.venv/bin/mlx_whisper` was absent. The script now:

1. Defines `VENV_DIR`, `PYTHON`, `PIP` pointing at `$SCRIPT_DIR/.venv` — the shared venv already used by `summarize-transcript.sh` for mlx-lm.
2. Calls `setup_venv()` which:
   - Creates `.venv` via `python3 -m venv` only if the directory is absent
   - Checks importability with `"$PYTHON" -c "import mlx_whisper" 2>/dev/null`
   - If absent: upgrades pip silently, then `pip install mlx-whisper`, then prints a success line
3. Sets `WHISPER_CMD="$VENV_DIR/bin/mlx_whisper"` after setup so the rest of the script (the `mlx_whisper` invocation at the transcription step) is unchanged.

## Tasks

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Replace hard error with setup_venv-style auto-install | 998c43c | transcribe.sh |

## Deviations from Plan

None - plan executed exactly as written.

## Known Stubs

None.

## Threat Flags

None. `pip install` against PyPI mirrors the identical pattern already present in `summarize-transcript.sh`; no new trust boundary introduced.

## Self-Check: PASSED

- transcribe.sh modified: FOUND (worktree path confirmed)
- Commit 998c43c: FOUND
- bash -n passes: CONFIRMED
- VENV_DIR defined: CONFIRMED
- pip install mlx-whisper present: CONFIRMED
- import mlx_whisper importability check present: CONFIRMED
- WHISPER_CMD="$VENV_DIR/bin/mlx_whisper" set: CONFIRMED
- "Please install it first" removed: CONFIRMED
