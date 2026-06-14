# Retrospective — transcribrr

A living retrospective appended at each milestone close.

## v1.0 MVP — shipped 2026-06-14

**Scope:** 2 phases, 4 plans. Turned the README's manual 4-step workflow into one unattended command (`transcribrr.sh`) that takes a YouTube URL (or local audio) → one markdown file (rich header → summary → full transcript), reusing the existing MLX scripts + `yt-dlp`.

**Verification:** All 22 v1 requirements implemented and statically verified. Both phases at `human_needed` (hands-on UAT deferred — the environment lacks yt-dlp/MLX/network). 0 unsatisfied requirements; milestone audit status `tech_debt` (deferred UAT only).

### What worked
- **Walking-skeleton-first (MVP mode).** Phase 1 made the three interactive scripts flag-driven and emit `OUTPUT_FILE=`; Phase 2 layered URL/download/metadata/assembly on top without touching that contract. Clean vertical slices.
- **`OUTPUT_FILE=` capture contract** decoupled the orchestrator from each sub-script's filename logic — no globbing, no stale-file races.
- **Code review caught real, platform-specific bugs.** The reviewer *executed* the script and found a `mapfile` call that breaks on stock macOS bash 3.2.57 (the actual target) and a metadata field-shift — both invisible to static plan-checking. The plan-checker separately caught a `set -u` unbound-variable crash for local input. Layered review earned its keep.

### What didn't
- **REQUIREMENTS.md traceability drifted.** 7 Phase-1 requirements stayed `Pending` after they were implemented; the milestone audit had to reconcile them. The Phase 1 verifier had already flagged this — it should have been corrected at phase close.
- **Environment fragility.** A mid-run `xcode-select` switch to unlicensed Xcode broke every `git` call; worked around with `DEVELOPER_DIR`, then fixed at the system level. Worktree isolation was unusable until then, forcing sequential execution.
- **bash-3.2 target not enforced early.** The `mapfile` slip would have been avoided by a `#!/bin/bash` + 3.2 lint gate from the start.

### Decisions that held
- yt-dlp over a Go library; single bash script; reuse MLX scripts unchanged; flags-with-defaults; atomic temp+mv for the final file. (yt-dlp real-world reliability still pending hands-on UAT.)

### Carry-forward
- Close the deferred hands-on UAT (`/gsd-verify-work 1`, `/gsd-verify-work 2`) on an Apple-Silicon box with deps installed.
- Keep a bash-3.2 compatibility check on any new shell code.

## Cross-Milestone Trends

- (v1.0 is the first milestone — trends will accrue from v1.1 onward.)
