# Roadmap: transcribrr — YouTube-to-Markdown Pipeline

## Overview

This milestone delivers a single bash script that takes a YouTube URL all the way to one finished markdown file (rich header → summary → full transcript), reusing the existing MLX scripts (`transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh`) and `yt-dlp` + `ffmpeg`. The hard part is not new transcription logic — it is making three *interactive* scripts run unattended and wiring their staged outputs together reliably. The journey: first make the existing pipeline scriptable end-to-end on a local MP3 (non-interactive model/style selection, dependency checks, per-stage progress, output-file location), then wrap that with YouTube download + metadata capture and assemble the final single markdown with fail-fast robustness.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Scriptable Pipeline Foundation** - Drive the existing MLX scripts unattended via flags, with dependency checks, help, and per-stage progress (completed 2026-06-14)
- [ ] **Phase 2: End-to-End YouTube-to-Markdown Delivery** - Download + MP3 + metadata, then assemble one robust markdown file from a single command

## Phase Details

### Phase 1: Scriptable Pipeline Foundation

**Goal**: A single new bash script accepts a local MP3 and runs transcribe → cleanup → summarize fully unattended, selecting models/style by flag and locating each stage's output to feed the next — with dependency checks, `--help`, and clear per-stage progress.
**Mode:** mvp
**Depends on**: Nothing (first phase)
**Requirements**: DL-01, CLI-01, CLI-02, CLI-03, ROB-01, TR-01, TR-02, TR-03, CL-01, CL-02, CL-03, SUM-01, SUM-02, SUM-03
**Success Criteria** (what must be TRUE):

  1. Running the new script with an MP3 and flags completes transcribe → cleanup → summarize with zero interactive prompts (the existing scripts' `read -p` selections are satisfied non-interactively).
  2. Whisper model, cleanup model, and summary model/style are each chosen via flags, defaulting to the README-recommended models, and `--no-cleanup` skips the cleanup stage.
  3. The script locates each stage's output file (`*_transcript_*.txt`, `*_cleaned_*.txt`, `*_summary_*.md`) and passes it to the next stage without the user supplying paths.
  4. `--help` prints usage (URL/file argument and all flags); a missing dependency or existing script aborts with a clear, named message.
  5. The script prints which stage is running (transcribe → cleanup → summarize) as it progresses.

**Plans**: 2 plans
Plans:
**Wave 1**

- [x] 01-01-PLAN.md — Make the three MLX sub-scripts non-interactive (flag-driven) and emit OUTPUT_FILE=

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 01-02-PLAN.md — Create transcribrr.sh orchestrator (preflight, stage chaining, --no-cleanup, help, progress) + SKELETON.md

### Phase 2: End-to-End YouTube-to-Markdown Delivery

**Goal**: From a single command with a YouTube URL, the script downloads audio to MP3, captures video metadata, runs the full pipeline from Phase 1, and assembles one markdown file (rich header → summary → full transcript) — failing fast with a named stage on any error and only writing the final file on full success.
**Mode:** mvp
**Depends on**: Phase 1
**Requirements**: DL-02, DL-03, DL-04, OUT-01, OUT-02, OUT-03, ROB-02, ROB-03
**Success Criteria** (what must be TRUE):

  1. Given a YouTube URL, the script downloads and exports MP3 audio via `yt-dlp`/`ffmpeg` and captures title, channel, source URL, duration, and upload date.
  2. The script produces exactly one markdown file containing, in order, a rich header (title, channel, URL, duration, upload date, models used), the summary, and the full transcript.
  3. The final markdown filename is derived from the sanitized video title at a predictable path.
  4. If any stage fails, the script aborts with a message naming the failing stage and does not write a partial final markdown file.

**Plans**: 2 plans
Plans:
**Wave 1**

- [x] 02-01-PLAN.md — URL auto-detection + conditional yt-dlp preflight + playlist rejection + metadata capture + MP3 download feeding the existing pipeline (DL-02/03/04, ROB-02)

**Wave 2** *(blocked on Wave 1 completion — same file, sequential)*

- [x] 02-02-PLAN.md — Assemble single rich-header markdown (atomic temp+mv), transcript-variant selection, predictable filename, .gitignore working dirs (OUT-01/02/03, ROB-02/03)

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Scriptable Pipeline Foundation | 2/2 | Complete   | 2026-06-14 |
| 2. End-to-End YouTube-to-Markdown Delivery | 2/2 | Complete   | 2026-06-14 |
