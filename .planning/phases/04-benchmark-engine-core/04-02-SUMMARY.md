---
phase: 04-benchmark-engine-core
plan: "02"
subsystem: benchmark-hardware-awareness
tags: [benchmark, hardware, memory, disk-gate, hf-cache, pre-fetch, sample-audio, bash]
dependency_graph:
  requires:
    - 04-01 (benchmark.sh skeleton, setup_venv, parse_candidates, helpers)
  provides:
    - RAM detection and 75% usable ceiling (HW-01)
    - Fit gate skipping unfit candidates before any load (HW-02/03)
    - Disk-space gate before any hf download (D-09)
    - is_model_cached() offline cache detection (Pitfall D mitigation)
    - Model pre-fetch via .venv/bin/hf for uncached fitting candidates (D-08)
    - Sample audio download+cache (EWo7-azGHic default) or local-file passthrough (BENCH-06)
    - AUDIO_DURATION_S computed once for RTF denominator (plan 04-03)
  affects:
    - benchmark.sh (new sections between setup_venv and smoke section)
tech_stack:
  added: []
  patterns:
    - sysctl hw.memsize → awk integer GB conversion
    - awk float compare for fit gate (bash 3.2 — no (( )) float)
    - HF cache dir existence check as offline cache detection
    - .venv/bin/hf download for pre-fetch (not deprecated legacy tool)
    - df -g for disk space gate with hard-abort before any download
    - yt-dlp MP3 extraction with sample_<VIDEO_ID>.mp3 cache path
    - ffmpeg + LC_NUMERIC=C bc for audio duration (reuse transcribe.sh idiom)
key_files:
  created: []
  modified:
    - benchmark.sh
decisions:
  - "awk used for all float arithmetic: fit gate, disk gate, NEEDED_GB accumulation (bash 3.2, PITFALLS #12)"
  - "is_model_cached() guard before every hf download call prevents network latency on cached models (Pitfall D)"
  - "Disk gate accumulates uncached-only sizes with +0.5 rounding to integer GB before df comparison"
  - "huggingface-cli string excluded from source entirely; comment rephrased to avoid triggering grep-count acceptance criterion"
  - "FITTING_IDS/LABELS/SIZES/STAGES indexed arrays built during fit-gate loop for reuse in disk gate and pre-fetch"
metrics:
  duration: "6m"
  completed: "2026-06-15"
  tasks_completed: 2
  tasks_total: 2
  files_created: 0
  files_modified: 1
---

# Phase 4 Plan 2: Hardware Awareness and Acquisition Layer Summary

**One-liner:** RAM detection via `sysctl hw.memsize`, 75% fit gate with awk float compare, offline HF cache detection, disk-space gate before any `hf download`, model pre-fetch via `.venv/bin/hf`, and sample audio download+cache with local-file vs URL branching.

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Memory detection, fit gate, HF cache detection, disk-space gate | 9ea7585 | benchmark.sh |
| 2 | Model pre-fetch and default audio sample download + cache | 962e5ad | benchmark.sh |

## What Was Built

**Task 1 — Hardware awareness and gates:**
- `MEMSIZE_BYTES=$(sysctl -n hw.memsize)` → `TOTAL_GB` (awk) → `USABLE_GB` at 75% (awk)
- Prints `Detected RAM: ${TOTAL_GB} GB | Usable ceiling: ${USABLE_GB} GB (75%)` at sweep start (HW-01 success criterion)
- `is_model_cached()`: builds `models--<org>--<name>` cache dir name via `sed 's|/|--|g'`; returns 0 when `$HF_CACHE/$cache_name/snapshots` is non-empty; fully offline (no network)
- Fit gate: per-candidate awk compare `size_gb + BENCH_OVERHEAD_BUFFER_GB <= USABLE_GB`; SKIP log `SKIP $label: ${size_gb}+${overhead}=${estimate} GB > ${USABLE_GB} GB usable` (HW-02)
- Fitting candidates collected into `FITTING_IDS`/`FITTING_LABELS`/`FITTING_SIZES`/`FITTING_STAGES` indexed arrays (bash 3.2 safe; no `declare -A`)
- Disk gate: sums `size_gb` of fitting-but-uncached candidates into `NEEDED_GB` (awk accumulation with +0.5 ceiling rounding); reads `AVAIL_GB` from `df -g "$HF_CACHE" | awk 'NR==2 {print $4}'`; hard-aborts with `Error: Insufficient disk space... Need: X GB | Available: Y GB` before any `hf download` (D-09)
- Disk gate exit at line 246; first `hf download` at line 264 — ordering verified

**Task 2 — Pre-fetch and sample audio:**
- Pre-fetch loop: for every fitting candidate, `is_model_cached` guard; if cached print `Cached: $label`; if not, print download message and run `"$HF_CLI" download "$model_id"` (`.venv/bin/hf`, not the deprecated legacy tool)
- Default `BENCH_SAMPLE_URL="https://www.youtube.com/watch?v=EWo7-azGHic"` (D-13, full video)
- Local-file branch: `if [ -n "$BENCH_SAMPLE_ARG" ] && [ -f "$BENCH_SAMPLE_ARG" ]` → `SAMPLE_MP3="$BENCH_SAMPLE_ARG"` (no download, no caching)
- URL branch: override default if `BENCH_SAMPLE_ARG` is set; extract `VIDEO_ID` via `grep -oE '[?&]v=[^&]+'`; cache path `$RESULTS_DIR/sample_${VIDEO_ID}.mp3`; download with `yt-dlp -x --audio-format mp3 --no-playlist` on first run; reuse cached file on subsequent runs
- Audio duration: ffmpeg idiom from `transcribe.sh` (lines 103-113); `IFS=: read h m s`; `AUDIO_DURATION_S=$(echo "$h * 3600 + $m * 60 + $s" | LC_NUMERIC=C bc)` — stored for plan 04-03 RTF computation

## Verification Results

- `bash -n benchmark.sh`: PASS
- `grep -q 'sysctl -n hw.memsize' benchmark.sh`: PASS
- `grep -q '0.75' benchmark.sh`: PASS
- `grep -q 'df -g' benchmark.sh`: PASS
- `grep -q 'is_model_cached' benchmark.sh`: PASS
- `grep -nE '\(\([^)]*(size_gb|USABLE_GB|NEEDED_GB).*\)\)'`: 0 matches (all awk, no (( )) float) PASS
- Disk gate exit line (246) < hf download line (264): PASS
- `grep -c 'huggingface-cli' benchmark.sh` == 0: PASS (comment rephrased to exclude the string)
- `grep -q 'EWo7-azGHic' benchmark.sh`: PASS
- `grep -q 'AUDIO_DURATION_S' benchmark.sh`: PASS
- `grep -qF '[ -f "$BENCH_SAMPLE_ARG" ]' benchmark.sh`: PASS
- `grep -q 'LC_NUMERIC=C bc' benchmark.sh`: PASS

## Deviations from Plan

**1. [Rule 1 - Bug] Comment containing 'huggingface-cli' triggered grep-count acceptance criterion**
- **Found during:** Task 2 verification
- **Issue:** Comment "NOT deprecated huggingface-cli" caused `grep -c 'huggingface-cli' benchmark.sh` to return 1 instead of 0, failing the automated check
- **Fix:** Rephrased comment to "NOT the deprecated legacy tool" (no `huggingface-cli` string)
- **Files modified:** benchmark.sh
- **Commit:** 962e5ad (included in Task 2 commit)

## Known Stubs

None. The `TODO: REMOVE AFTER 04-04` smoke section from plan 04-01 is intentionally preserved per the sequential execution instructions. Plans 04-03 and 04-04 complete the sweep logic.

## Threat Flags

No new threat surface beyond the plan's `<threat_model>`. Mitigations confirmed present:
- **T-04-04 (path traversal):** `sed 's|/|--|g'` flattens slashes in cache name; model_id always double-quoted
- **T-04-05 (command injection):** `"$HF_CLI" download "$model_id"` — fixed binary, quoted argument, never eval'd
- **T-04-06 (disk/memory exhaustion):** disk gate and fit gate both implemented and hard-abort before resource commitment
- **T-04-08 (--sample → yt-dlp):** value double-quoted; local-path branch guarded by `[ -f ]` before use

## Self-Check: PASSED

- `/Users/gareth/git/transcribrr/benchmark.sh`: FOUND (modified)
- Commit 9ea7585: FOUND
- Commit 962e5ad: FOUND
- `bash -n benchmark.sh`: exits 0
- All Task 1 + Task 2 automated checks: PASSED
