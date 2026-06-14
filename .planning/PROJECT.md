# transcribrr — YouTube-to-Markdown Pipeline

## What This Is

transcribrr is a local, Apple-Silicon transcription/summarization toolkit built from standalone bash scripts (MLX Whisper for transcription, Qwen via MLX for summarization). This milestone adds a single bash script that drives the **entire pipeline end-to-end**: given a YouTube URL, it downloads the video, extracts MP3 audio, transcribes it, cleans the transcript, summarizes it, and writes one markdown file containing a rich header, the summary, and the full transcript.

It is for the project owner (and anyone on Apple Silicon) who today runs the README's four-step workflow by hand and wants a single unattended command instead.

## Core Value

One command takes a YouTube URL to a finished markdown file (summary + full transcript) reliably and unattended — reusing the existing MLX scripts rather than reinventing them.

## Requirements

### Validated

<!-- Existing, working scripts in the repo. -->

- ✓ Transcribe an audio file via MLX Whisper — `transcribe.sh` (existing)
- ✓ Clean a raw transcript via local LLM — `cleanup-transcript.sh` (existing)
- ✓ Summarize a transcript via Qwen/MLX into markdown — `summarize-transcript.sh` (existing)
- ✓ Interactive MLX model launcher — `mlx-chat.sh` (existing)
- ✓ Single bash script fetches a YouTube video from a URL using `yt-dlp` — v1.0
- ✓ Script extracts/exports audio to MP3 via `yt-dlp -x --audio-format mp3` — v1.0
- ✓ Script transcribes the MP3 by invoking `transcribe.sh` non-interactively — v1.0
- ✓ Script cleans the transcript by invoking `cleanup-transcript.sh` non-interactively — v1.0
- ✓ Script summarizes the cleaned transcript by invoking `summarize-transcript.sh` non-interactively — v1.0
- ✓ Script writes ONE markdown file: rich header → summary → full transcript — v1.0
- ✓ Pipeline runs fully unattended (model/style chosen via flags with sane defaults) — v1.0
- ✓ Graceful fail-fast + clear messaging naming the failing stage; final file only on full success — v1.0

> All v1.0 requirements are implemented and statically verified. Hands-on UAT (real yt-dlp/MLX runs) is deferred and tracked in `phases/*/*-HUMAN-UAT.md` + STATE.md → Deferred Items.

### Active

<!-- Next milestone. Hypotheses until shipped and validated. -->

- [ ] (none yet — define with `/gsd-new-milestone`)

### Out of Scope

- Writing the downloader in Go — research showed `yt-dlp` is materially more reliable in 2026 than pure-Go libraries (kkdai/youtube), which lag YouTube's signature/SABR changes. Go was only mentioned because a Go downloader exists; reliability wins. (See Key Decisions.)
- Reimplementing transcription/summarization natively — the existing MLX scripts are reused as-is.
- Non-YouTube sources, playlists/batch download, GUI, cross-platform (non-Apple-Silicon) support — not needed for v1.
- Cloud transcription/summary APIs — the project is deliberately local.

## Context

- **Existing pipeline is manual.** The README's "Typical workflow" already chains `yt-dlp` → `transcribe.sh` → `cleanup-transcript.sh` → `summarize-transcript.sh` by hand. This milestone automates that exact chain.
- **Existing scripts are interactive.** `transcribe.sh`, `cleanup-transcript.sh`, and `summarize-transcript.sh` prompt for model selection. The new pipeline must drive them non-interactively (pass model selections via flags/stdin/env), which may require small non-interactive hooks in those scripts.
- **Output filename conventions** are established (`*_transcript_*.txt`, `*_cleaned_*.txt`, `*_summary_*.md`) and already gitignored; the pipeline must locate each stage's output to feed the next stage.
- **Dependencies:** `yt-dlp`, `ffmpeg`, Python 3, and the existing `.venv` (auto-installed by the MLX scripts). Apple Silicon required for MLX.

## Constraints

- **Tech stack**: Bash only — no Go. Wrap `yt-dlp` + `ffmpeg`; orchestrate existing MLX scripts. Matches the repo's existing idiom.
- **Reliability**: Downloader must survive YouTube's 2026 changes → `yt-dlp` (kept updatable), optionally with browser-cookie auth for bot detection.
- **Platform**: Apple Silicon macOS (MLX requirement, inherited from existing scripts).
- **Unattended**: Must run without interactive prompts when flags are supplied.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Use `yt-dlp`, not a Go library | 2026 research: yt-dlp is daily-maintained and most reliable; pure-Go libs lag YouTube's signature/SABR arms race | ⚠️ Revisit — wired in v1.0; real-world reliability confirmed only after hands-on UAT |
| Single bash script, no Go | User confirmed Go was incidental; bash matches existing scripts and removes a toolchain | ✓ Good — v1.0 is one `transcribrr.sh` entrypoint |
| Orchestrate existing MLX scripts | Reuse tuned `transcribe.sh`/`cleanup-transcript.sh`/`summarize-transcript.sh` rather than reimplement | ✓ Good — reused unchanged; driven via flags |
| Include cleanup stage | README workflow includes it; cleaner transcript in final markdown | ✓ Good — on by default, `--no-cleanup` to skip |
| Flags with sane defaults | Enables unattended runs while keeping README-recommended models | ✓ Good — all stages flag-driven, silent defaults |
| Rich markdown header | Title/channel/URL/duration/date/models — suited to an archive | ✓ Good — assembled atomically (temp+mv) in v1.0 |
| Target stock bash 3.2.57 (no `mapfile`) | Stock Apple-Silicon macOS ships bash 3.2; a `mapfile` slipped in and was caught by code review | ⚠️ Revisit — fixed in v1.0; keep enforcing 3.2 compat in any new bash |

## Current State

**Shipped: v1.0 MVP (2026-06-14)** — 2 phases, 4 plans. `transcribrr.sh` now takes a YouTube URL (or local audio file) all the way to one finished markdown file (rich header → summary → full transcript), fully unattended, reusing the existing MLX scripts + `yt-dlp`. All 22 v1 requirements implemented and statically verified; 2 critical code-review bugs (a bash-3.2 `mapfile` incompatibility and a metadata field-shift) were caught and fixed. Outstanding: hands-on UAT (real yt-dlp/MLX/network runs), tracked in `phases/*/*-HUMAN-UAT.md`.

Codebase: four bash scripts at repo root (`transcribrr.sh`, `transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh`) + `mlx-chat.sh`. No build system. Apple-Silicon / MLX required.

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-06-14 after v1.0 milestone*
