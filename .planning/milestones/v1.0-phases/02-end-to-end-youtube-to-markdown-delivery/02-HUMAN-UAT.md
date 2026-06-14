---
status: resolved
phase: 02-end-to-end-youtube-to-markdown-delivery
source: [02-VERIFICATION.md]
started: 2026-06-14T12:23:39Z
updated: 2026-06-14T13:59:00Z
closure: static-verification-accepted
---

## Current Test

Closed 2026-06-14 — operator accepted **static verification** as the closure bar.
Runtime UAT (yt-dlp + ffmpeg + MLX + network) was NOT executed; scenarios below are
recorded as `skipped (runtime not executed)`, not as observed passes.

## Tests

### 1. Full URL-to-markdown pipeline (core user story)
expected: With yt-dlp + ffmpeg installed and `.venv`/MLX models available, run `./transcribrr.sh "https://www.youtube.com/watch?v=<short-video>"`. The script downloads MP3, captures metadata, runs transcribe→cleanup→summarize, and writes exactly ONE `<sanitized-title>.md` at the CWD root containing, in order: a `#` title, a bulleted metadata block (Title, Channel, Source URL, Duration, Upload date, Models used), `## Summary`, then `## Transcript`. Stage banners show 1/5→4/5 then assemble (5/5).
result: skipped — static verification accepted (runtime not executed)

### 2. Playlist URL rejection
expected: With yt-dlp installed, `./transcribrr.sh "https://www.youtube.com/playlist?list=..."` aborts with a clear "playlist not supported" named error BEFORE any download.
result: skipped — static verification accepted (runtime not executed)

### 3. --no-cleanup behavior
expected: `./transcribrr.sh "<url>" --no-cleanup` embeds the RAW transcript and the header `**Models used:**` line shows `cleanup=skipped`.
result: skipped — static verification accepted (runtime not executed)

### 4. No-overwrite safety
expected: Running the pipeline twice on the same video refuses to overwrite the existing final `.md` (exits non-zero with the refuse message).
result: skipped — static verification accepted (runtime not executed)

### 5. Stock /bin/bash 3.2 runtime
expected: A real end-to-end run under stock `/bin/bash` 3.2.57 succeeds (no `mapfile`/syntax errors at runtime). `bash -n` already passes under 3.2.57.
result: skipped — static verification accepted (runtime not executed)

## Summary

total: 5
passed: 0
issues: 0
pending: 0
skipped: 5
blocked: 0

closed_via: static verification (operator-accepted 2026-06-14); runtime UAT not executed

## Gaps
