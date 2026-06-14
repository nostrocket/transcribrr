---
phase: 02-end-to-end-youtube-to-markdown-delivery
plan: "01"
subsystem: orchestrator
tags: [yt-dlp, url-detection, metadata, download, bash, preflight]
dependency_graph:
  requires: [01-01, 01-02, 01-03]
  provides: [02-02]
  affects: [transcribrr.sh]
tech_stack:
  added: [yt-dlp]
  patterns: [mapfile-capture, process-substitution-guard, sed-allow-list-sanitizer, atomic-IS_URL-detection]
key_files:
  modified:
    - transcribrr.sh
decisions:
  - "IS_URL detection runs after flag loop, before preflight_check — order enforced to keep yt-dlp check URL-conditional"
  - "Local-MP3 path derives SAFE_TITLE from basename at detection time (not assemble time) to prevent set -u crash in Plan 02 assemble stage"
  - "Playlist pattern [?&]list= stored in variable _PLAYLIST_PATTERN to work around bash ERE character-class tokenization of & in [[ =~ ]] expressions"
  - "metadata and download stages share Stage 1/5 banner; transcribe=2/5, cleanup=3/5, summarize=4/5 (local path retains 1/3, 2/3, 3/3)"
  - "WORK_DIR uses SAFE_TITLE_VIDEO_ID suffix for collision-free per-video directories"
metrics:
  duration: "5m"
  completed: "2026-06-14"
  tasks_completed: 2
  tasks_total: 2
  files_changed: 1
---

# Phase 02 Plan 01: URL Auto-Detection, Metadata Capture, and Download Stage Summary

URL auto-detection, yt-dlp preflight, playlist rejection, single-pass metadata capture with `mapfile`, and per-video MP3 download feeding the unchanged Phase 1 transcription pipeline.

## What Was Built

Extended `transcribrr.sh` with two sets of changes:

**Task 1 — URL detection, help update, conditional preflight:**
- New defaults: `IS_URL=false`, `URL=""`, `INPUT_ARG=""` alongside existing `MP3_FILE=""`
- Positional `*)` flag-parse arm now assigns `INPUT_ARG="$1"` (not `MP3_FILE` directly)
- Detection block after the while loop: `[[ "$INPUT_ARG" =~ ^https?:// ]] || [[ "$INPUT_ARG" =~ youtu\.?be ]]` sets `IS_URL=true` and `URL`, otherwise sets `MP3_FILE` AND derives `SAFE_TITLE` from `basename "$MP3_FILE" .mp3` via the allow-list sanitizer
- `preflight_check()` branches on `IS_URL`: URL path validates `$URL` non-empty; local path validates file existence; yt-dlp binary check added URL-conditionally with `brew install yt-dlp` hint
- `print_help` updated to `<youtube-url|audio.mp3>`, three YouTube URL examples added, "NA" caveat noted for private videos

**Task 2 — url-check, metadata, download stages:**
- `url-check` stage: `CURRENT_STAGE="url-check"` + pattern variable `_PLAYLIST_PATTERN="[?&]list="` to work around bash ERE tokenization; exits with named error before any network call
- `metadata` stage: `CURRENT_STAGE="metadata"` + `mapfile -t META < <(yt-dlp --simulate --no-playlist --print ...)` capturing 6 fields (title, channel/uploader, URL, duration, upload_date, id); explicit `${#META[@]} -lt 6` guard (SC2311: `set -e` not inherited in process substitution); `YYYYMMDD` → `YYYY-MM-DD` date reformat with `[[ =~ ^[0-9]{8}$ ]]` guard; `SAFE_TITLE` via allow-list sed + `WORK_DIR="$(pwd)/${SAFE_TITLE}_${VIDEO_ID}"`
- `download` stage: `CURRENT_STAGE="download"` + `yt-dlp -x --audio-format mp3 --no-playlist -o "${WORK_DIR}/%(title)s.%(ext)s" --print "after_move:filepath"` + file-existence guard with `find "$WORK_DIR" -name "*.mp3"` fallback
- Stage banners renumbered: URL path shows 1/5 (metadata+download), 2/5 (transcribe), 3/5 (cleanup), 4/5 (summarize); local path unchanged at 1/3, 2/3, 3/3
- `CLEANED_FILE=""` initialized before the cleanup conditional to prevent `set -u` unbound variable on `--no-cleanup` path

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| Task 1 | a7b6ccb | feat(02-01): URL auto-detection, yt-dlp preflight, and help update |
| Task 2 | fe859b8 | feat(02-01): url-check, metadata capture, and download stage feeding Stage 1 |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed bash ERE character-class tokenization of & in [[ =~ ]]**
- **Found during:** Task 2 verification (`bash -n transcribrr.sh` reported syntax error)
- **Issue:** `[[ "$URL" =~ [?&]list= ]]` caused `bash: syntax error near unexpected token '&'` because bash's `[[` ERE engine tokenizes `&` as a special character in character class position when unquoted in the conditional expression. This is a known bash behavior across versions 3–5.
- **Fix:** Stored the pattern in a variable `_PLAYLIST_PATTERN="[?&]list="` and used `[[ "$URL" =~ $_PLAYLIST_PATTERN ]]`. This is the standard bash idiom for complex regex patterns in `[[ =~ ]]`.
- **Files modified:** transcribrr.sh
- **Commit:** fe859b8

**2. [Rule 2 - Missing critical functionality] CLEANED_FILE initialization**
- **Found during:** Task 2 implementation review
- **Issue:** Under `set -u`, if `--no-cleanup` is passed, the `CLEANED_FILE` variable is never assigned, meaning the downstream assemble stage (Plan 02) would crash with "CLEANED_FILE: unbound variable" when it tries to reference it.
- **Fix:** Added `CLEANED_FILE=""` initialization before the cleanup conditional block.
- **Files modified:** transcribrr.sh
- **Commit:** fe859b8

## Known Stubs

None. All variables wired; `VIDEO_TITLE`, `VIDEO_CHANNEL`, `VIDEO_URL`, `VIDEO_DURATION`, `VIDEO_UPLOAD_DATE`, `SAFE_TITLE`, and `MP3_FILE` are fully populated on the URL path before reaching the existing transcription pipeline.

## Threat Flags

All new security surface is within the plan's threat model (T-02-01 through T-02-04). No additional threat flags.

| Mitigation | Status |
|-----------|--------|
| T-02-01: URL passed to yt-dlp as double-quoted literal, no eval | Applied |
| T-02-02: SAFE_TITLE allow-list sanitizer strips / and shell-meta chars | Applied |
| T-02-03: META array guard + download file-existence guard | Applied |
| T-02-04: Playlist rejection before network call + --no-playlist defense-in-depth | Applied |

## Self-Check: PASSED

- transcribrr.sh exists and `bash -n` passes
- Commits a7b6ccb and fe859b8 verified in git log
- All Task 1 and Task 2 acceptance criteria verified
