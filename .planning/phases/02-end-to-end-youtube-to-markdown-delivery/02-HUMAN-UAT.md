---
status: partial
phase: 02-end-to-end-youtube-to-markdown-delivery
source: [02-VERIFICATION.md]
started: 2026-06-14T12:23:39Z
updated: 2026-06-14T12:23:39Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Full URL-to-markdown pipeline (core user story)
expected: With yt-dlp + ffmpeg installed and `.venv`/MLX models available, run `./transcribrr.sh "https://www.youtube.com/watch?v=<short-video>"`. The script downloads MP3, captures metadata, runs transcribe→cleanup→summarize, and writes exactly ONE `<sanitized-title>.md` at the CWD root containing, in order: a `#` title, a bulleted metadata block (Title, Channel, Source URL, Duration, Upload date, Models used), `## Summary`, then `## Transcript`. Stage banners show 1/5→4/5 then assemble (5/5).
result: [pending]

### 2. Playlist URL rejection
expected: With yt-dlp installed, `./transcribrr.sh "https://www.youtube.com/playlist?list=..."` aborts with a clear "playlist not supported" named error BEFORE any download.
result: [pending]

### 3. --no-cleanup behavior
expected: `./transcribrr.sh "<url>" --no-cleanup` embeds the RAW transcript and the header `**Models used:**` line shows `cleanup=skipped`.
result: [pending]

### 4. No-overwrite safety
expected: Running the pipeline twice on the same video refuses to overwrite the existing final `.md` (exits non-zero with the refuse message).
result: [pending]

### 5. Stock /bin/bash 3.2 runtime
expected: A real end-to-end run under stock `/bin/bash` 3.2.57 succeeds (no `mapfile`/syntax errors at runtime). `bash -n` already passes under 3.2.57.
result: [pending]

## Summary

total: 5
passed: 0
issues: 0
pending: 5
skipped: 0
blocked: 0

## Gaps
