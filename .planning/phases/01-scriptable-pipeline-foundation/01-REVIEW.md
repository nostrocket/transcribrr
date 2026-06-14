---
phase: 01-scriptable-pipeline-foundation
reviewed: 2026-06-14T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - transcribe.sh
  - cleanup-transcript.sh
  - summarize-transcript.sh
  - transcribrr.sh
findings:
  critical: 2
  warning: 7
  info: 5
  total: 14
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-06-14T00:00:00Z
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

Reviewed the four bash scripts forming the MLX transcription/summarization pipeline:
`transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh`, and the new
orchestrator `transcribrr.sh`.

The orchestrator's stage-output capture pattern interacts badly with `set -euo pipefail`:
when a sub-script fails to emit its `OUTPUT_FILE=` line, the `grep` in the capture pipeline
returns non-zero, which aborts the script *before* the carefully-written per-stage validation
checks can run — making those error messages dead code and surfacing only a generic trap
message (CR-01). The ERR trap echoes but never propagates a non-zero exit (CR-02), so the
final reported exit status can be misleading. Additionally, `transcribe.sh` is the only script
without `set -euo pipefail`, leaving several failure paths silent (WR-01). Several quoting,
boundary, and consistency defects round out the findings.

All findings were verified by executing minimal reproductions in a scratch shell, not by
inspection alone.

## Critical Issues

### CR-01: Stage-validation error messages are unreachable; pipeline aborts with a generic trap message instead

**File:** `transcribrr.sh:172-180` (and identically `188-196`, `209-219`)
**Issue:**
The capture pattern is:
```bash
STAGE_OUT=$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
    | tee /dev/stderr \
    | grep "^OUTPUT_FILE=")
TRANSCRIPT_FILE="${STAGE_OUT#OUTPUT_FILE=}"

if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Error: transcribe stage did not produce a valid output file." >&2
    exit 1
fi
```
With `set -euo pipefail` (line 3), if the sub-script fails or simply does not print a line
matching `^OUTPUT_FILE=`, `grep` exits non-zero. Under `pipefail` the whole pipeline returns
non-zero, and because it is the right-hand side of a command-substitution assignment, `set -e`
aborts the script *at that line*. Control never reaches the `if [ -z "$TRANSCRIPT_FILE" ] ...`
guard. The dedicated, user-friendly error message is dead code in exactly the failure scenario
it was written for.

Reproduction (confirmed):
```bash
set -euo pipefail
trap 'echo "TRAP fired during stage"' ERR
STAGE_OUT=$(echo "hello" | tee /dev/stderr | grep "^NOPE=")  # script aborts here
echo "after assignment"   # never printed
# -> prints "TRAP fired during stage", exits 1
```
Net effect: a transcription/cleanup/summarize failure produces only
`Error: transcribrr.sh failed during stage: transcribe` (from the trap), and the explicit,
more actionable per-stage messages never appear. Worse, a sub-script that succeeds but is
modified to stop emitting `OUTPUT_FILE=` will also abort here rather than hitting the intended
validation branch.

**Fix:** Decouple the grep from the failure path so the explicit guards can run. For example,
capture full output, check the sub-script's own exit status, then extract the line without
letting a no-match `grep` abort:
```bash
set +e
STAGE_OUT="$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" | tee /dev/stderr)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "Error: transcribe stage exited with status $rc." >&2
    exit 1
fi
TRANSCRIPT_FILE="$(printf '%s\n' "$STAGE_OUT" | grep '^OUTPUT_FILE=' | tail -1)"
TRANSCRIPT_FILE="${TRANSCRIPT_FILE#OUTPUT_FILE=}"
if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Error: transcribe stage did not produce a valid output file." >&2
    exit 1
fi
```
(`tail -1` also hardens against more than one matching line.) Apply the same change to all three
stages.

### CR-02: ERR trap reports the failure but does not preserve a non-zero exit; final status can be misleading

**File:** `transcribrr.sh:22-23`
**Issue:**
```bash
CURRENT_STAGE="preflight"
trap 'echo "Error: transcribrr.sh failed during stage: $CURRENT_STAGE" >&2' ERR
```
The trap only echoes; it does not `exit`. Whether the script exits non-zero relies entirely on
`set -e` still being in force at the failing command. But `set -e` is disabled inside many
contexts (commands in `if`/`while` conditions, `&&`/`||` chains, etc.), so a failure that occurs
in such a context will fire the ERR trap's message yet allow the script to continue, and the
script can ultimately exit `0` after printing the alarming error line. An unattended caller
keying off the exit code (the stated use case — "single unattended command") may treat a failed
run as success. The trap also does not re-raise, so even where it does fire, the exit code that
reaches the OS is whatever `set -e` happens to produce, not a deliberate value.

**Fix:** Make the trap explicit and authoritative:
```bash
trap 'rc=$?; echo "Error: transcribrr.sh failed during stage: $CURRENT_STAGE (exit $rc)" >&2; exit "$rc"' ERR
```
This guarantees a deterministic non-zero exit and surfaces the real status to unattended callers.

## Warnings

### WR-01: `transcribe.sh` lacks `set -euo pipefail`, unlike the other three scripts

**File:** `transcribe.sh:1-5` (whole file)
**Issue:** `cleanup-transcript.sh`, `summarize-transcript.sh`, and `transcribrr.sh` all start
with `set -euo pipefail`, but `transcribe.sh` does not. Consequences:
- Unset-variable typos are silent (no `-u`).
- A failing `cat "$WHISPER_OUTPUT"` / `rm "$WHISPER_OUTPUT"` (lines 248, 250) does not abort;
  the script proceeds to print "Done!" and `OUTPUT_FILE=...` even if assembling the final
  transcript failed, so the orchestrator may accept a truncated/empty transcript.
- `DURATION_STR=$(ffmpeg ... | grep ... | awk ... )` (line 89) silently yields empty on a
  pipeline failure rather than being caught.

**Fix:** Add `set -uo pipefail` after the shebang (full `-e` is harder here because the script
intentionally backgrounds whisper and tolerates some non-fatal greps; at minimum add `-u` and
`pipefail`, and explicitly check the exit status of the final transcript-assembly block before
emitting `OUTPUT_FILE=`).

### WR-02: Final `OUTPUT_FILE=` is emitted even when the transcript file was never assembled

**File:** `transcribe.sh:242-257`
**Issue:** The header+body assembly only runs `if [ -f "$WHISPER_OUTPUT" ]` (line 242). If
whisper exited 0 but the expected `${AUDIO_DIR}/${AUDIO_STEM}.txt` is absent (e.g. mlx_whisper
changed its output naming, or the stem contains characters that altered the filename), the
`if` block is skipped, `$OUTPUT_FILE` is never created, yet because `EXIT_CODE -eq 0` the script
still prints `OUTPUT_FILE=$OUTPUT_FILE` (line 257). The orchestrator's `[ ! -f "$TRANSCRIPT_FILE" ]`
guard would then catch it — but only after CR-01 is fixed; today it aborts at the grep instead.
Either way the contract ("`OUTPUT_FILE=` means the file exists") is violated.

**Fix:** Only print the success block / `OUTPUT_FILE=` after confirming the file exists:
```bash
if [ $EXIT_CODE -eq 0 ] && [ -f "$OUTPUT_FILE" ]; then
    echo "OUTPUT_FILE=$OUTPUT_FILE"
    ...
else
    echo "Error: transcript output not produced" >&2
    exit 1
fi
```

### WR-03: `cleanup-transcript.sh` word-count uses fragile `sed` that diverges from the Python stripper

**File:** `cleanup-transcript.sh:78-82`
**Issue:**
```bash
TRANSCRIPT_BODY=$(sed '/^Model:/d; /^Source:/d; /^Date:/d; /^$/d' "$TRANSCRIPT_FILE" | head -1 > /dev/null && sed '1,/^$/d' "$TRANSCRIPT_FILE" 2>/dev/null || cat "$TRANSCRIPT_FILE")
WORD_COUNT=$(echo "$TRANSCRIPT_BODY" | wc -w | tr -d ' ')
```
The first `sed | head -1 > /dev/null` is a no-op whose only effect is its exit status; the real
work is `sed '1,/^$/d'`, which deletes from line 1 *to the first blank line*. If the transcript
has **no** blank line after the header (or no header at all), `/^$/` never matches and `sed`
deletes the entire file, yielding an empty `TRANSCRIPT_BODY` and a reported word count of `0`
(reproduced). The Python heredoc (lines 106-110) strips the header correctly and independently,
so the *processing* is fine — but the user is shown a misleading "Transcript: 0 words". The two
code paths implement the same intent with different, inconsistent logic.

**Fix:** Reuse one source of truth. Simplest: compute the word count in the Python block (which
already strips correctly) and drop lines 78-82, or replace line 78 with the same forgiving logic
the Python uses (skip leading `Model:`/`Source:`/`Date:`/blank lines, then take the rest).

### WR-04: Chunking can exceed the model context window when text lacks sentence terminators

**File:** `cleanup-transcript.sh:126-135` and `summarize-transcript.sh:339-348`
**Issue:** Both chunkers only emit a chunk when `current_count >= chunk_size AND word.endswith
(('.', '!', '?', ...))`. A transcript segment with no sentence-ending punctuation for a long
stretch (common with raw ASR output, numbers, or non-English text) will keep accumulating words
far beyond `chunk_size`, producing a single oversized chunk. For cleanup that can blow the small
model's context window; for summarize it can exceed the 20k/18k-word budget the comments
explicitly try to respect (lines 320-326 of summarize), causing truncated or failed generation.

**Fix:** Add a hard cap so a chunk is flushed at, e.g., `chunk_size * 1.5` words regardless of
punctuation:
```python
hard_cap = int(chunk_size * 1.5)
if (current_count >= chunk_size and word.endswith(('.', '!', '?'))) or current_count >= hard_cap:
    chunks.append(' '.join(current_chunk)); current_chunk = []; current_count = 0
```

### WR-05: `IFS=: read` without `-r` mangles backslashes in duration/timestamp parsing

**File:** `transcribe.sh:95, 196, 200`
**Issue:** `IFS=: read h m s <<< "$DURATION_STR"` (and the two timestamp reads) omit `-r`.
Without `-r`, `read` interprets backslashes as escape characters. While ffmpeg duration strings
normally contain no backslashes, omitting `-r` is a latent correctness bug and a lint violation
(SC2162). Combined with the missing `set -u` (WR-01), a malformed `DURATION_STR` can also leave
`m`/`s` unset and feed empty operands to `bc`.

**Fix:** Use `IFS=: read -r h m s <<< "$DURATION_STR"` in all three places.

### WR-06: `bc` arithmetic has no guard against division by zero / empty `ELAPSED`

**File:** `transcribe.sh:210-215`
**Issue:** `ELAPSED=$((NOW - START_TIME))` can be `0` on a fast first iteration, after which
`PROCESSING_RATE=$(echo "scale=4; $CURRENT_SECONDS / $ELAPSED" | bc)` divides by zero. `bc`
prints a "Runtime error (divide by zero)" to stderr and returns empty, then
`REMAINING_SECONDS=$(... / $PROCESSING_RATE ...)` divides by an empty/zero rate. Because the
script has no `set -e`, this does not crash, but it spews bc errors and produces a garbage ETA.

**Fix:** Guard the rate computation: `if [ "$ELAPSED" -gt 0 ]; then ...` and skip ETA when
`PROCESSING_RATE` is empty or `0`.

### WR-07: `if $INSTALL_ONLY` / boolean-as-command pattern is fragile

**File:** `summarize-transcript.sh:67`
**Issue:** `if $INSTALL_ONLY; then` executes the *contents* of the variable as a command. Today
`INSTALL_ONLY` is only ever assigned the literal `true`/`false` internally (never from user
input), so it is not exploitable, but it is brittle: any future code path that lets external data
reach this variable becomes a command-execution sink, and a value like `false; rm -rf x` would
run. The orchestrator already uses the safer idiom `[ "$NO_CLEANUP" = false ]`
(transcribrr.sh:184).

**Fix:** Use a string comparison for consistency and safety:
`if [ "$INSTALL_ONLY" = true ]; then`.

## Info

### IN-01: Inconsistent boolean idioms across scripts

**File:** `summarize-transcript.sh:67` vs `transcribrr.sh:184, 199`
**Issue:** `if $INSTALL_ONLY` vs `[ "$NO_CLEANUP" = false ]`. Pick one convention repo-wide
(prefer the string-comparison form — see WR-07) for readability and safety.

### IN-02: Dead/no-op `sed | head -1 > /dev/null` fragment

**File:** `cleanup-transcript.sh:78`
**Issue:** The `sed ... | head -1 > /dev/null && ...` prefix discards its output and exists only
for an exit status that is effectively always success. It obscures intent. Remove it as part of
the WR-03 fix.

### IN-03: Duplicated model-label sanitizer copy-pasted across three scripts

**File:** `transcribe.sh:105`, `cleanup-transcript.sh:50`, `summarize-transcript.sh:99`
**Issue:** The identical
`sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]'`
pipeline is duplicated verbatim. The comments even reference each other ("apply same
sanitization as cleanup-transcript.sh line 50"), which will rot as line numbers shift. Consider a
shared `lib.sh` sourced by all scripts.

### IN-04: `--model "$2"` flag parsing does not detect a missing argument

**File:** `transcribe.sh:42-45`, `cleanup-transcript.sh:13-16`, `summarize-transcript.sh:22-29`, `transcribrr.sh:82-97`
**Issue:** `--model` followed by nothing makes `$2` empty (with `set -u`, `shift 2` can also fail
when only one arg remains, e.g. `shift 2` with `$#==1` errors under some shells). A trailing
`--model` or `--summary-style` with no value silently selects an empty model/style or aborts
unhelpfully. Add an explicit check: `[ $# -ge 2 ] || { echo "--model requires an argument" >&2; exit 1; }`.

### IN-05: `--language en` is hard-coded in transcription

**File:** `transcribe.sh:142`
**Issue:** Whisper is invoked with `--language en` unconditionally. Non-English audio will be
mis-transcribed with no flag to override. Not in scope as a bug, but worth a `--language` flag or
at least `--language auto` default given the "anyone on Apple Silicon" goal stated in CLAUDE.md.

---

_Reviewed: 2026-06-14T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
