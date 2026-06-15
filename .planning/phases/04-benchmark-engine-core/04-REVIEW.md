---
phase: 04-benchmark-engine-core
reviewed: 2026-06-15T00:00:00Z
depth: standard
files_reviewed: 3
files_reviewed_list:
  - benchmark.sh
  - transcribrr.sh
  - .gitignore
findings:
  critical: 2
  warning: 5
  info: 2
  total: 9
status: issues_found
---

# Phase 4: Code Review Report

**Reviewed:** 2026-06-15
**Depth:** standard
**Files Reviewed:** 3
**Status:** issues_found

## Summary

`benchmark.sh` (~966 lines) is the main deliverable for Phase 4. `transcribrr.sh` received minimal additions (flag dispatch for `--benchmark`/`--sample`). `.gitignore` is a one-line addition.

The `.gitignore` change is correct. The `transcribrr.sh` additions (flag parse, exec-dispatch, help text) are correct and well-guarded. The `benchmark.sh` implementation correctly follows most of the locked decisions (D-01 through D-17) and research patterns, including: bash 3.2 portability (no `declare -A`, no float in `(( ))`), the `/usr/bin/time -l 2>"$TIME_OUT"` pattern with correct stderr separation, the parse-not-source rule for `candidates.conf`, Python heredoc JSON writing for text fields, and the staged interactive pipeline.

Two critical correctness bugs are present that would cause the sweep to malfunction silently (failure detection never fires) or abort unexpectedly under realistic conditions. Five warnings cover logic errors and resource issues that degrade reliability.

---

## Critical Issues

### CR-01: `candidate_exit` is always 0 — failure detection never fires

**File:** `benchmark.sh:509-514`
**Issue:** The timed-pass pipeline ends with `|| true`, which makes the entire compound command return exit code 0 regardless of what happened upstream. The `candidate_exit=$?` that follows always captures 0. This completely defeats D-16's continue-on-failure design: a candidate that OOMs, crashes, or never emits `OUTPUT_FILE=` is treated identically to a successful run. The `if [ "$candidate_exit" -ne 0 ]` check at line 524 never triggers, so error JSON is never written for failed candidates.

As a direct consequence, execution falls through to the metrics section with potentially empty `peak_bytes` (if the stage script exited before `/usr/bin/time -l` could record anything), causing `write_success_json` to embed an empty value in a Python literal (`"peak_mem_bytes": ,`) — a SyntaxError that exits the Python process nonzero, which (with `set -e` restored at line 515) aborts the entire sweep at the first candidate failure.

The core problem: in `STAGE_OUT=$( cmd1 | cmd2 | grep || true )`, bash evaluates `|| true` on the pipeline exit status, giving the whole compound expression an exit of 0. With `pipefail` still active inside the subshell, even a rightmost-nonzero exit from `grep` (no `OUTPUT_FILE=` line) feeds into `|| true` and becomes 0.

**Fix:** Capture the stage script exit code before the pipeline, using a wrapper subshell or a temp file written by the stage exit:

```bash
# Approach A: capture time exit code in a temp file
TIME_EXIT_FILE=$(mktemp)
set +e
STAGE_OUT=$(
    (
        /usr/bin/time -l "$stage_script" "$input_file" \
            --model "$model_id" $STAGE_EXTRA
        echo $? > "$TIME_EXIT_FILE"
    ) 2>"$TIME_OUT" \
    | tee "$STDOUT_TMP" /dev/stderr \
    | { grep "^OUTPUT_FILE=" || true; }
)
set -e
candidate_exit=$(cat "$TIME_EXIT_FILE" 2>/dev/null || echo 1)
rm -f "$TIME_EXIT_FILE"
```

Alternatively: run the stage script in a subshell, write its exit to `$TIME_OUT` as a header line, or use a FIFO. The critical invariant: `candidate_exit` must reflect `/usr/bin/time`'s exit (which mirrors the stage script's exit), not the `|| true`-neutralized pipeline exit.

---

### CR-02: Disk-space gate aborts with awk syntax error when `df` returns unexpected output

**File:** `benchmark.sh:242-243`
**Issue:** `AVAIL_GB=$(df -g "$HF_CACHE" 2>/dev/null | awk 'NR==2 {print $4}')` silently produces an empty string if `df` produces no `NR==2` line or an unexpected column layout (network mount, APFS peculiarity, future macOS changes). The immediately following `awk "BEGIN { if ($NEEDED_GB <= $AVAIL_GB) ... }"` then has a bare numeric comparison against an empty token — `awk` exits with `syntax error` and a nonzero code, which kills the entire script via `set -e` before any model is tested.

Verified behaviour:
```
$ AVAIL_GB=""; awk "BEGIN { if (5 <= $AVAIL_GB) print \"yes\" }" 2>&1
awk: syntax error at source line 1
context is  BEGIN { if (5 <=  >>>  ) <<<
```

**Fix:** Validate `AVAIL_GB` after `df` and fail with a human-readable message:

```bash
AVAIL_GB=$(df -g "$HF_CACHE" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -z "$AVAIL_GB" ] || ! echo "$AVAIL_GB" | grep -qE '^[0-9]+$'; then
    echo "Warning: cannot determine available disk space for $HF_CACHE." \
         "Skipping disk-space gate." >&2
    # or: hard-abort with an error if a conservative stance is preferred
    AVAIL_GB=0
fi
```

---

## Warnings

### WR-01: `VIDEO_ID` is empty for `youtu.be` short-format URLs — cache collision

**File:** `benchmark.sh:287-288`
**Issue:** `VIDEO_ID=$(echo "$BENCH_SAMPLE_URL" | grep -oE '[?&]v=[^&]+' | sed 's/[?&]v=//')` only matches URLs that contain a `?v=` or `&v=` parameter. A `youtu.be/EWo7-azGHic` short URL produces an empty `VIDEO_ID`, resulting in `SAMPLE_MP3="$RESULTS_DIR/sample_.mp3"`. Two problems follow: (1) yt-dlp still downloads correctly but uses the wrong output path template; (2) any two different `youtu.be` URLs both map to `sample_.mp3`, so the second benchmark run with a different video silently reuses the first run's cached audio (wrong sample, no re-download).

**Fix:** Extract the video ID from the path component for `youtu.be` URLs, or fall back to calling `yt-dlp --print "%(id)s"` (which transcribrr.sh already does for metadata) to get the canonical ID:

```bash
VIDEO_ID=$(echo "$BENCH_SAMPLE_URL" | grep -oE '[?&]v=[^&]+' | sed 's/[?&]v=//')
# Fallback: youtu.be/ID format
if [ -z "$VIDEO_ID" ]; then
    VIDEO_ID=$(echo "$BENCH_SAMPLE_URL" | grep -oE 'youtu\.be/([^?&]+)' | sed 's|youtu.be/||')
fi
# Last resort: derive from yt-dlp
if [ -z "$VIDEO_ID" ]; then
    VIDEO_ID=$(yt-dlp --no-playlist --simulate --print "%(id)s" "$BENCH_SAMPLE_URL" 2>/dev/null || echo "unknown")
fi
```

---

### WR-02: Elapsed-time progress display is static — always shows "elapsed: 0s"

**File:** `benchmark.sh:506`
**Issue:** `printf "  [%s]  %-35s  elapsed: 0s\r" "$stage" "$label"` is printed once before the timed subprocess launches. There is no update loop — for a multi-hour transcription of the full benchmark video (D-13 specifies the full video), the terminal line stays frozen at `elapsed: 0s` for the entire duration. This was explicitly flagged as the BENCH-08 concern ("does not appear hung"). While a full background-process timer loop is complex, a static `0s` is actively misleading.

The RESEARCH doc (Pattern 8) specifies `printf "  [whisper %d/%d]  %-35s  elapsed: %ds\r"` with a `$elapsed` variable that updates, implying a background timer or periodic print was intended.

**Fix:** Use a background timer that periodically re-prints the progress line until the timed subprocess completes. Minimal approach:

```bash
# Launch a background heartbeat that updates every 5 seconds
(
    local _start=$t_start
    while true; do
        local _now; _now=$(date +%s)
        local _elapsed=$((_now - _start))
        printf "  [%s]  %-35s  elapsed: %ds\r" "$stage" "$label" "$_elapsed"
        sleep 5
    done
) &
TIMER_PID=$!

# ... run timed subprocess ...

kill "$TIMER_PID" 2>/dev/null; wait "$TIMER_PID" 2>/dev/null
echo ""  # finalize the \r line
```

---

### WR-03: Arg parser in `benchmark.sh` infinite-loops on positional arguments and crashes on bare `--sample`

**File:** `benchmark.sh:48-60`
**Issue:** Two bugs in the argument-parsing loop:

1. **Infinite loop:** The `case` statement handles `--sample` and `-*` but has no default `*)` case. A positional argument (not starting with `-`) matches nothing, so no `shift` occurs and `$#` never decrements — infinite loop.

2. **Unbound variable crash:** `--sample` with no following value (user types `benchmark.sh --sample`) executes `BENCH_SAMPLE_ARG="$2"` with `$2` unset. With `set -u` active, bash immediately exits: `line N: $2: unbound variable`. The same issue exists in `transcribrr.sh:153` for `--sample`.

**Fix:** Add a default case and guard `$2` access:

```bash
        --sample)
            if [ $# -lt 2 ]; then
                echo "Error: --sample requires an argument." >&2
                exit 1
            fi
            BENCH_SAMPLE_ARG="$2"
            shift 2
            ;;
        # ... existing -* case ...
        *)
            echo "Error: unexpected argument: $1" >&2
            echo "Usage: benchmark.sh [--sample <url|mp3>]" >&2
            exit 1
            ;;
```

Apply the `$# -lt 2` guard to all flag-with-value cases in `transcribrr.sh` as well.

---

### WR-04: No EXIT trap — temp files leaked on SIGINT, SIGTERM, or `select_best` exit

**File:** `benchmark.sh:43, 715, 793, 868`
**Issue:** The only `trap` registered is the ERR handler that prints a stage name. There is no EXIT or signal trap to clean up:
- Stage list files (`WHISPER_RESULTS_LIST`, `CLEANUP_RESULTS_LIST`, `SUMMARIZE_RESULTS_LIST`) allocated with `mktemp` at the top of each stage block
- Warmup temp files (`.wav`/`.txt`) inside `run_candidate` — cleaned on normal paths but leaked if `ffmpeg` for the warmup audio fails (with `set -e` aborting before `rm -f "$warmup_input"`)
- The stage list files are also leaked when `select_best` calls `exit 1` (zero-candidate case), because the `rm -f "$list_file"` at the call site is never reached

**Fix:** Register an EXIT trap at the top of the script that removes all temp files:

```bash
# After the mktemp calls for list files are reached, track them:
_BENCH_TMPFILES=()
_bench_cleanup() { rm -f "${_BENCH_TMPFILES[@]}" 2>/dev/null; }
trap '_bench_cleanup' EXIT

# When allocating:
WHISPER_RESULTS_LIST=$(mktemp /tmp/benchmark_whisper_list_XXXXXX)
_BENCH_TMPFILES+=("$WHISPER_RESULTS_LIST")
```

Alternatively, use a single cleanup trap that removes everything under `/tmp/benchmark_*` owned by the current process (by PID prefix in the mktemp template).

---

### WR-05: Disk-space gate underreports needed space for sub-1-GB models — can skip gate entirely

**File:** `benchmark.sh:236`
**Issue:** `NEEDED_GB=$(awk "BEGIN{printf \"%d\", $NEEDED_GB + $size_gb + 0.5}")` is intended to round up to the nearest GB, but `awk`'s `%d` format truncates (does not round). For `size_gb=0.24`: `0.24 + 0.5 = 0.74 → 0 GB`. For `size_gb=0.695`: `0.695 + 0.5 = 1.195 → 1 GB`. The pattern fails for any model smaller than 0.5 GB — they contribute 0 to `NEEDED_GB`. If all uncached models are sub-0.5-GB (the four whisper models range from 0.24 to 1.61 GB), `NEEDED_GB` may total to 0 even though real downloads are needed, causing the gate to be skipped entirely (`if [ "$NEEDED_GB" -gt 0 ]` fails).

**Fix:** Use `awk`'s ceiling arithmetic:

```bash
NEEDED_GB=$(awk "BEGIN{printf \"%d\", int($NEEDED_GB + $size_gb) + 1}")
# Or accumulate as float and ceil at the end:
NEEDED_GB_F=$(awk "BEGIN{printf \"%.3f\", $NEEDED_GB_F + $size_gb}")
# ... after loop:
NEEDED_GB=$(awk "BEGIN{ v=$NEEDED_GB_F; printf \"%d\", (v == int(v)) ? v : int(v)+1 }")
```

---

## Info

### IN-01: No `--benchmark` example in `print_help()` Examples section

**File:** `transcribrr.sh:102-111`
**Issue:** The `Options` section at line 86 documents `--benchmark` and `--sample`, but the `Examples` section contains only URL-and-local-file processing examples. Given that `--benchmark` is a new, prominent feature with unusual interactive requirements (TTY guard, staged selection), at least one example would significantly aid discoverability.

**Fix:** Add to the `Examples` section:

```
  transcribrr.sh --benchmark
  transcribrr.sh --benchmark --sample /path/to/local.mp3
  transcribrr.sh --benchmark --sample https://www.youtube.com/watch?v=OTHER_ID
```

---

### IN-02: Python `-c` and heredoc strings embed shell variables without path-safety guarantees

**File:** `benchmark.sh:748-771, 822-846, 897-928`
**Issue:** The three repeated Python read-back blocks (one per stage) embed `$RUN_DIR`, `$label`, and other values directly into Python `-c "..."` single-quoted command strings. If `SCRIPT_DIR` (and therefore `RUN_DIR`) contains a space or if a future `candidates.conf` label contains a single quote, the Python `-c` string breaks with a syntax error.

Example vulnerable pattern (line 748):
```python
# If label = "turbo" and RUN_DIR = "/Users/gareth/my projects/transcribrr/results/..." 
with open('/Users/gareth/my projects/transcribrr/results/.../turbo_result.json') as f:
#                         ^ Python sees this as two arguments, SyntaxError
```

Similarly, the heredoc JSON writers (`write_success_json`, etc.) expand `$output_file` and `$result_json_path` into Python `open("$path", ...)` string literals — same space/quote risk.

**Fix:** Pass path arguments to Python via environment variables or positional arguments instead of interpolating into the Python source:

```bash
CAND_ERROR=$(RESULT_JSON="$RUN_DIR/whisper/${label}_result.json" \
    "$PYTHON" -c '
import json, os
with open(os.environ["RESULT_JSON"]) as f:
    d = json.load(f)
print(d.get("error") or "")
' 2>/dev/null || echo "read_error")
```

This approach handles spaces, quotes, and backslashes in paths without any escaping.

---

_Reviewed: 2026-06-15_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
