---
phase: 02-end-to-end-youtube-to-markdown-delivery
reviewed: 2026-06-14T00:00:00Z
depth: standard
files_reviewed: 2
files_reviewed_list:
  - transcribrr.sh
  - .gitignore
findings:
  critical: 2
  warning: 5
  info: 4
  total: 11
status: issues_found
---

# Phase 02: Code Review Report

**Reviewed:** 2026-06-14
**Depth:** standard
**Files Reviewed:** 2
**Status:** issues_found

## Summary

`transcribrr.sh` is a bash orchestrator that auto-detects YouTube URL vs local
audio, downloads/extracts MP3 via `yt-dlp`, runs transcribe → cleanup → summarize,
then assembles one markdown via temp file + atomic `mv`.

The shell-injection surface is well handled: every expansion is quoted, the
title sanitizer reduces `/` and shell-meta chars to `_` (path traversal via `/`
is neutralized — verified), `--` is implicitly unnecessary because URL/paths are
always last positional args passed quoted, and the document is written with
`printf`/`cat` rather than re-expanded heredocs. The atomic-write pattern and
EXIT/ERR trap coexistence are correct.

However, two correctness defects can produce wrong output or fail on the
platform the project explicitly targets, and several robustness/quality gaps
remain. The largest concerns are (1) `mapfile` is unavailable on the stock macOS
`/bin/bash` named in the shebang, and (2) the metadata field-count guard accepts
misaligned fields when a video title contains a newline, silently corrupting
`VIDEO_ID`, `VIDEO_CHANNEL`, and the working-directory / output naming.

## Critical Issues

### CR-01: `mapfile` is unsupported on the shebang interpreter (`/bin/bash` 3.2) — script aborts on every URL run on stock macOS

**File:** `transcribrr.sh:1,230`
**Issue:** The shebang is `#!/bin/bash`. On macOS the system `/bin/bash` is
version 3.2.57 (Apple ships nothing newer for licensing reasons), and `mapfile`
(a.k.a. `readarray`) does not exist in bash 3.2. Verified locally:
`/bin/bash --version` → `GNU bash, version 3.2.57`, and `mapfile` →
`mapfile: command not found`. The project's stated platform is "Apple Silicon
macOS." Any user who invokes the script via its shebang (`./transcribrr.sh <url>`,
the documented usage) on a default macOS install will hit the metadata stage and
abort with `mapfile: command not found` under `set -e`. This breaks the entire
URL path — the core value of the phase. It only works for users who happen to
run it under an explicitly-installed Homebrew bash 5.
**Fix:** Replace `mapfile` with a bash-3.2-compatible read loop, or read fields
individually. Example replacement for lines 230–245:
```bash
META=()
while IFS= read -r line; do
    META+=("$line")
done < <(yt-dlp \
    --simulate --no-playlist \
    --print "%(title)s" --print "%(channel|uploader)s" \
    --print "%(webpage_url)s" --print "%(duration_string)s" \
    --print "%(upload_date)s" --print "%(id)s" \
    "$URL" 2>/dev/null)
```
(See also CR-02 for the field-misalignment hardening that should accompany this.)

### CR-02: Metadata field-count guard accepts misaligned fields — newline in title silently corrupts `VIDEO_ID`, channel, and output paths

**File:** `transcribrr.sh:242-252`
**Issue:** The guard is `if [ "${#META[@]}" -lt 6 ]`. `yt-dlp --print` emits one
line per field, but a YouTube title (or channel name) can legitimately contain a
newline. When it does, `mapfile`/read splits the title across two array slots and
every subsequent field shifts down by one. Verified: a 7-line input (title spans
2 lines) gives `count=7` (passes the `-lt 6` guard) but
`VIDEO_CHANNEL`=title-line-2, `VIDEO_ID`=upload-date, etc. The result is a
corrupted `WORK_DIR` (`${SAFE_TITLE}_${VIDEO_ID}` with the wrong id), a wrong
`-o` download template region, and a markdown header with the channel/id fields
all shifted. The failure is silent — no error, just wrong data and a misnamed
output file. The guard checks only the lower bound, never `!= 6`.
**Fix:** Make the count check exact, which converts a silent corruption into a
loud failure:
```bash
if [ "${#META[@]}" -ne 6 ]; then
    echo "Error: metadata stage returned ${#META[@]} fields, expected exactly 6 (title may contain a newline)." >&2
    exit 1
fi
```
For a more robust fix, capture each field with its own `yt-dlp --print` call (or
use `--print-to-file` / a delimiter that cannot appear in a field, e.g. a NUL via
`--print "%(title)s"` per-field substitution) so a multiline title cannot shift
positions.

## Warnings

### WR-01: Empty `SAFE_TITLE` produces a hidden `.md` / `.<id>` working dir

**File:** `transcribrr.sh:142,263,265,389`
**Issue:** If a title sanitizes to the empty string (e.g. a title of all
non-alphanumeric chars like `???///`, or a local input literally named `.mp3`),
`SAFE_TITLE` becomes `""`. Verified: `FINAL_MD_PATH` then becomes
`$(pwd)/.md` (a hidden dotfile that is easy to lose/overwrite) and `WORK_DIR`
becomes `$(pwd)/_<VIDEO_ID>`. The output is technically produced but hidden and
non-obvious; repeated runs of different all-symbol titles collide on the same
`.md`.
**Fix:** After sanitizing, fall back to a non-empty default:
```bash
if [ -z "$SAFE_TITLE" ]; then
    SAFE_TITLE="${VIDEO_ID:-transcribrr_output}"
fi
```
Apply on both the URL path (after line 263) and the local path (after line 142,
using the video id is unavailable there — use `transcribrr_output` or a timestamp).

### WR-02: Sub-script output capture silently aborts via ERR trap instead of the friendly guard

**File:** `transcribrr.sh:301-309,322-330,347-357`
**Issue:** Each stage uses `STAGE_OUT=$(... | tee /dev/stderr | grep "^OUTPUT_FILE=")`.
Under `set -o pipefail`, if the sub-script never prints an `OUTPUT_FILE=` line
(e.g. it failed partway, or changed its contract), `grep` exits non-zero, the
pipeline fails, and `set -e` aborts the assignment immediately — verified. The
carefully-written guard `if [ -z "$TRANSCRIPT_FILE" ] ...` on the next lines is
therefore **unreachable** in the no-marker case; the user gets the generic ERR
trap message ("failed during stage: transcribe") rather than the specific
"transcribe stage did not produce a valid output file." This is a degraded
diagnostic, not a crash, but it makes the guards dead code for their intended
trigger.
**Fix:** Allow grep to fail without aborting, so the explicit guard runs:
```bash
STAGE_OUT=$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
    | tee /dev/stderr \
    | { grep "^OUTPUT_FILE=" || true; })
```
Apply to all three stages (transcribe, cleanup, summarize).

### WR-03: `yt-dlp` errors are swallowed by `2>/dev/null` in the metadata stage

**File:** `transcribrr.sh:230-239`
**Issue:** The metadata `yt-dlp` invocation redirects stderr to `/dev/null`. When
yt-dlp fails for actionable reasons — bot-detection / "Sign in to confirm you're
not a robot", age-gating, geo-block, or a stale yt-dlp version (exactly the 2026
reliability scenario called out in `CLAUDE.md`) — the user sees only
"metadata stage returned fewer fields than expected (got 0, need 6)" with no
clue that they need cookies or a yt-dlp upgrade. Reliability against YouTube
changes is a stated constraint.
**Fix:** Capture stderr to a temp file or variable and surface it on failure:
```bash
META_ERR=$(mktemp)
META=()
while IFS= read -r line; do META+=("$line"); done < <(yt-dlp ... "$URL" 2>"$META_ERR")
if [ "${#META[@]}" -ne 6 ]; then
    echo "Error: metadata stage failed. yt-dlp said:" >&2
    cat "$META_ERR" >&2
    rm -f "$META_ERR"; exit 1
fi
rm -f "$META_ERR"
```

### WR-04: Local-mode `SAFE_TITLE` only strips `.mp3`, yet non-MP3 audio is documented as supported

**File:** `transcribrr.sh:142`
**Issue:** Help text (lines 45–46) advertises "path to a local MP3 (or any
ffmpeg-readable audio) file," but `basename "$MP3_FILE" .mp3` only removes a
`.mp3` suffix. Verified: a `talk.wav` input yields `SAFE_TITLE=talk.wav`, and the
final document is named `talk.wav.md` — the extension leaks into the title and
the H1 header. Inconsistent and ugly for any non-`.mp3` input.
**Fix:** Strip any extension instead of just `.mp3`:
```bash
SAFE_TITLE=$(basename "$MP3_FILE")
SAFE_TITLE="${SAFE_TITLE%.*}"
SAFE_TITLE=$(printf '%s' "$SAFE_TITLE" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
```

### WR-05: `FINAL_MD_PATH` is silently overwritten with no collision protection

**File:** `transcribrr.sh:389,426`
**Issue:** `FINAL_MD_PATH="$(pwd)/${SAFE_TITLE}.md"` and the run ends with an
unconditional `mv "$TEMP_MD" "$FINAL_MD_PATH"`. Two different videos whose titles
sanitize to the same `SAFE_TITLE` (or re-processing the same local file) silently
clobber the previous result. Unlike `WORK_DIR`, the final path does **not**
include `VIDEO_ID`, so URL-mode collisions are quite plausible (e.g. two videos
both titled "Q&A"). Data loss of a prior unattended run with no warning.
**Fix:** Either include the video id in the URL-mode final name, or refuse to
overwrite:
```bash
if [ -e "$FINAL_MD_PATH" ]; then
    echo "Error: $FINAL_MD_PATH already exists; refusing to overwrite." >&2
    exit 1
fi
```

## Info

### IN-01: `.gitignore` pattern `*_*/` is broader than its comment claims

**File:** `.gitignore:22`
**Issue:** The comment says the pattern covers `<SAFE_TITLE>_<VIDEO_ID>/` working
dirs, but `*_*/` ignores *any* directory whose name contains an underscore
anywhere — including unrelated project dirs a contributor might add (e.g.
`my_module/`, `test_data/`). This can hide intended files from git.
**Fix:** Anchor more tightly if feasible, or document the broad scope explicitly.
There is no perfect glob for "title_11charID", but at minimum note that the
pattern is intentionally broad and contributors should `git add -f` legitimate
underscore-named dirs.

### IN-02: `_VID_DATE` reformat block at assemble stage is dead/redundant for both paths

**File:** `transcribrr.sh:377-386`
**Issue:** Lines 377–383 recompute a reformatted date from
`VIDEO_UPLOAD_DATE_RAW`, but line 386 then prefers `${VIDEO_UPLOAD_DATE:-...}`
which the metadata stage already set (reformatted) on the URL path; on the local
path `VIDEO_UPLOAD_DATE_RAW` is unset so the block just produces `NA`. The whole
`_VID_DATE_RAW`/`_VID_DATE` computation is effectively never the value actually
used. Dead logic that obscures intent.
**Fix:** Drop lines 377–383 and use
`_VID_UPLOAD_DATE="${VIDEO_UPLOAD_DATE:-NA}"` directly.

### IN-03: Magic field count `6` duplicated as literal and as `<` bound

**File:** `transcribrr.sh:242-243`
**Issue:** The expected metadata field count `6` appears as a magic number in the
guard and the message. If a `--print` field is added/removed, three places must
change in lockstep. (Becomes more important once CR-02's exact-match check is
applied.)
**Fix:** `EXPECTED_META_FIELDS=6` near the `--print` block and reference it.

### IN-04: URL detection regex `youtu\.?be` over-matches non-YouTube hosts

**File:** `transcribrr.sh:134`
**Issue:** `[[ "$INPUT_ARG" =~ youtu\.?be ]]` matches any argument containing the
substring `youtube` or `youtbe`/`youtube` — e.g. a local file named
`my-youtube-notes.txt` would be misclassified as a URL and sent to yt-dlp, which
then fails confusingly. Low likelihood but a sharp edge.
**Fix:** Anchor to a scheme or a host boundary, e.g. require `^https?://` for URL
classification and treat everything else as a local path, or tighten to
`(^|//|\.)youtu\.?be(\.|/)`.

---

_Reviewed: 2026-06-14_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
