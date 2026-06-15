---
phase: 04-benchmark-engine-core
fixed_at: 2026-06-15T00:00:00Z
review_path: .planning/phases/04-benchmark-engine-core/04-REVIEW.md
iteration: 1
findings_in_scope: 7
fixed: 7
skipped: 0
status: all_fixed
---

# Phase 4: Code Review Fix Report

**Fixed at:** 2026-06-15
**Source review:** `.planning/phases/04-benchmark-engine-core/04-REVIEW.md`
**Iteration:** 1

**Summary:**
- Findings in scope: 7 (CR-01, CR-02, WR-01, WR-02, WR-03, WR-04, WR-05)
- Fixed: 7
- Skipped: 0

Note: WR-02 (elapsed progress frozen at 0s) was fixed atomically as part of the CR-01 commit, since both changes touch the same timed-pass block in `run_candidate`. The fix is correct and complete; it is attributed to CR-01's commit hash.

---

## Fixed Issues

### CR-01: `candidate_exit` is always 0 — failure detection never fires

**Files modified:** `benchmark.sh`
**Commit:** `f7017e2`
**Applied fix:** Introduced `TIME_EXIT_FILE=$(mktemp)` inside `run_candidate`. The stage subprocess now runs inside an inner group subshell that writes its exit code to `TIME_EXIT_FILE` via `printf '%s' "$?"`. The outer pipeline's `|| true` still suppresses grep's no-match exit (so a successful run with no `OUTPUT_FILE=` line does not register as a candidate failure), but the stage script's real exit is captured before `|| true` can neutralize it. `candidate_exit=$(cat "$TIME_EXIT_FILE")` then reads the real value, so the `if [ "$candidate_exit" -ne 0 ]` failure guard in Step 3 fires correctly on OOM/crash.

Also fixed WR-02 in the same commit: replaced the static `printf "elapsed: 0s\r"` with a background ticker subprocess that re-prints the progress line every 5 seconds with real elapsed time. The ticker is killed and waited before metrics are collected, and a final `printf` line with actual `wall_time` replaces the terminal's `\r` line on completion.

---

### CR-02: Disk-space gate aborts with awk syntax error when `df` returns unexpected output

**Files modified:** `benchmark.sh`
**Commit:** `5bbcb12`
**Applied fix:** Added a validation guard immediately after `AVAIL_GB=$(df -g ...)`: checks `[ -z "$AVAIL_GB" ]` and `! echo "$AVAIL_GB" | grep -qE '^[0-9]+$'`. If either fails, emits a warning to stderr and sets `AVAIL_GB="$NEEDED_GB"` (treats space as exactly sufficient, allowing the sweep to proceed). This prevents the bare-variable awk syntax error that previously killed the script via `set -e` before any model was tested.

---

### WR-01: `VIDEO_ID` is empty for `youtu.be` short-format URLs — cache collision

**Files modified:** `benchmark.sh`
**Commit:** `15e80fe`
**Applied fix:** Added two additional extraction attempts after the original `?v=`/`&v=` grep: (1) `grep -oE 'youtu\.be/([^?&]+)'` to handle `youtu.be/<id>` short URLs; (2) `cksum`-based hash of the full URL as last-resort fallback so any two distinct URLs produce distinct cache file names and never collide on `sample_.mp3`.

---

### WR-02: Elapsed-time progress display is static — always shows "elapsed: 0s"

**Files modified:** `benchmark.sh`
**Commit:** `f7017e2` (fixed as part of CR-01 — same timed-pass block)
**Applied fix:** Background ticker subprocess launched before the timed pass prints an updating `elapsed: Ns` line every 5 seconds. Killed and waited before metrics are read. Final `printf` with actual `wall_time` is printed after the ticker exits, giving accurate total elapsed on the completion line.

---

### WR-03: Arg parser in `benchmark.sh` infinite-loops on positional arguments and crashes on bare `--sample`

**Files modified:** `benchmark.sh`, `transcribrr.sh`
**Commit:** `6776edc`
**Applied fix:**
- Added a `*)` default case to `benchmark.sh`'s arg-parsing loop that prints an error and exits, preventing the infinite loop when a positional argument matches no case and no `shift` occurs.
- Added a `[ $# -lt 2 ]` guard before `BENCH_SAMPLE_ARG="$2"` in both `benchmark.sh` and `transcribrr.sh`, so bare `--sample` without a value prints an actionable error instead of crashing with `unbound variable` under `set -u`.

---

### WR-04: No EXIT trap — temp files leaked on SIGINT, SIGTERM, or `select_best` exit

**Files modified:** `benchmark.sh`
**Commit:** `cee43b6`
**Applied fix:**
- Added a global `_BENCH_TMPFILES=()` tracking array and `_bench_cleanup()` function immediately after the ERR trap. The EXIT/INT/TERM trap calls `_bench_cleanup`, which `rm -f`s all registered paths. The ERR trap's `CURRENT_STAGE` reporting is unaffected.
- Each `WHISPER_RESULTS_LIST`, `CLEANUP_RESULTS_LIST`, and `SUMMARIZE_RESULTS_LIST` allocation is immediately followed by `_BENCH_TMPFILES+=("$<VAR>")` to register it.
- Added a `trap 'rm -f "$warmup_input" 2>/dev/null' RETURN` inside `run_candidate` immediately after the warmup file is created, so it is removed even when `ffmpeg` fails under `set -e` before the normal `rm -f` is reached. `warmup_input=""` after the normal `rm -f` prevents the RETURN trap from double-removing.

---

### WR-05: Disk-space gate underreports needed space for sub-1-GB models

**Files modified:** `benchmark.sh`
**Commit:** `1728785`
**Applied fix:** Replaced the single integer accumulator with a float accumulator `NEEDED_GB_F` that sums raw `size_gb` values with `awk` `%.3f` format. After the loop, a ceiling awk expression converts `NEEDED_GB_F` to `NEEDED_GB`: `(v == int(v)) ? v : int(v)+1`. This ensures every sub-0.5 GB model contributes at least 1 GB to the total rather than 0, so an all-tiny uncached set correctly engages the disk-space gate.

---

## Skipped Issues

None — all in-scope findings were fixed.

---

## Regression Check Results

Post-fix `bash -n` on both modified files:
- `bash -n benchmark.sh`: PASS
- `bash -n transcribrr.sh`: PASS

Constraint checks:
- `grep -c '2>&1' benchmark.sh` = 0 (PASS — no stderr-to-stdout merges)
- `grep -c 'declare -A' benchmark.sh` = 0 (PASS — bash 3.2 portable)
- `settings.conf` references = 2 comments/echo strings only — no writes (PASS, D-04 preserved)
- TTY guard `[ ! -t 0 ]` present (PASS, D-03 preserved)
- `parse_candidates` last-block flush present (PASS, Pitfall E preserved)

---

_Fixed: 2026-06-15_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
