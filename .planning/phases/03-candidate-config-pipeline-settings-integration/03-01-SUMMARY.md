---
phase: 03-candidate-config-pipeline-settings-integration
plan: 01
subsystem: config
tags: [bash, mlx, candidates, config, gitignore]

requires: []
provides:
  - config/candidates.conf with 13 vetted MLX model candidates (4 whisper, 4 cleanup, 5 summarize)
  - config/settings.conf.example committed template for per-user model selections
  - .gitignore rule preventing config/settings.conf from being committed
affects:
  - 03-02 (pipeline settings wiring in transcribrr.sh reads from config/settings.conf)
  - 04 (benchmark engine parses config/candidates.conf to sweep candidates)

tech-stack:
  added: []
  patterns:
    - "parse-not-source config format: [candidate] KEY=value blocks, no shell eval"
    - "gitignore: per-user generated files excluded, committed .example template retained"

key-files:
  created:
    - config/candidates.conf
    - config/settings.conf.example
  modified:
    - .gitignore

key-decisions:
  - "candidates.conf uses [candidate] KEY=value block format (D-01): stage/id/label/size_gb per block"
  - "parse-not-source contract (D-02): no shell-evaluable tokens in config; grep/while-read parsing only"
  - "Qwen3-14B uses Qwen org ID (Qwen/Qwen3-14B-MLX-4bit) not mlx-community (verified: mlx-community/Qwen3-14B-4bit is base model only)"
  - "settings.conf.example committed; settings.conf gitignored — keeps per-user selections out of VCS (D-04)"
  - "exactly 3 model keys in settings.conf.example for Phase 3 (D-06): WHISPER_MODEL_DEFAULT, CLEANUP_MODEL_DEFAULT, SUMMARY_MODEL_DEFAULT"

patterns-established:
  - "Config data file format: [section] KEY=value blocks, blank-line-separated, comment lines with #"
  - "Security T-03-02: verify absence of $(, backtick, export, ;rm in config data files"
  - "Security T-03-05: gitignore per-user generated config, commit only .example template"

requirements-completed: [MODEL-01, MODEL-02]

duration: 5min
completed: 2026-06-15
---

# Phase 3 Plan 01: Candidate Config & Settings Template Summary

**Committed vetted `config/candidates.conf` (13 MLX model candidates across 3 stages) and `config/settings.conf.example` template in parse-not-source [candidate] KEY=value format with gitignore protection for per-user settings**

## Performance

- **Duration:** ~5 min
- **Started:** 2026-06-14T16:23:00Z
- **Completed:** 2026-06-14T16:28:18Z
- **Tasks:** 2
- **Files modified:** 3 (2 created, 1 modified)

## Accomplishments

- Created `config/candidates.conf` with 13 vetted MLX candidates: 4 whisper (small, turbo, turbo-4bit, distil-large-v3), 4 cleanup (llama3.2-1b-4bit, llama3.2-3b-4bit, llama3.1-8b-4bit, qwen3-8b-4bit), 5 summarize (Qwen2.5-14B-4bit, Qwen2.5-32B-4bit, Qwen3-14B-4bit, Qwen3-32B-4bit, Llama3.3-70B-4bit)
- Created `config/settings.conf.example` with exactly the 3 Phase-3 model-default keys (D-06), committed to the repo
- Added `config/settings.conf` gitignore entry (T-03-05 mitigation), leaving `config/settings.conf.example` tracked

## Task Commits

1. **Task 1: Create config/candidates.conf** - `323e41e` (feat)
2. **Task 2: Write settings.conf.example and .gitignore rule** - `ad5da78` (feat)

## Files Created/Modified

- `config/candidates.conf` - Vetted MLX model candidate list, [candidate] KEY=value blocks, parse-not-source, 13 candidates spanning whisper/cleanup/summarize stages
- `config/settings.conf.example` - Committed template documenting WHISPER_MODEL_DEFAULT/CLEANUP_MODEL_DEFAULT/SUMMARY_MODEL_DEFAULT with precedence and usage notes
- `.gitignore` - Appended `config/settings.conf` ignore rule with descriptive comment

## Decisions Made

- Used `Qwen/Qwen3-14B-MLX-4bit` (Qwen org) not `mlx-community/Qwen3-14B-4bit` (base model) for the Qwen3-14B summarize candidate — per RESEARCH verification showing the Qwen org version is instruct-capable
- Blank-line-separated blocks in candidates.conf with EOF fallback emit, as specified in RESEARCH Pitfall 3

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## Known Stubs

None — all values are real vetted HF model IDs from RESEARCH.md with WebFetch-confirmed existence.

## Threat Flags

No new security surface beyond what the plan's threat model covers. T-03-02 (parse-not-source injection) and T-03-05 (accidental settings.conf commit) both mitigated as planned.

## Self-Check

**Files exist:**
- `config/candidates.conf`: FOUND
- `config/settings.conf.example`: FOUND
- `.gitignore` contains `config/settings.conf`: FOUND

**Commits exist:**
- `323e41e` feat(03-01): create config/candidates.conf: FOUND
- `ad5da78` feat(03-01): add settings.conf.example template and gitignore rule: FOUND

## Self-Check: PASSED

## Next Phase Readiness

- `config/candidates.conf` is immediately parseable by Phase 4 benchmark engine via the parse-not-source pattern (Pattern 2 in RESEARCH.md)
- `config/settings.conf.example` documents the format Plan 02 wires into `transcribrr.sh`
- No blockers for Plan 02 (pipeline settings wiring) — disjoint files, runs in parallel per plan frontmatter

---
*Phase: 03-candidate-config-pipeline-settings-integration*
*Completed: 2026-06-15*
