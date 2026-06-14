# Walking Skeleton — transcribrr

**Phase:** 1
**Generated:** 2026-06-14

## Capability Proven End-to-End

A user runs `./transcribrr.sh <local.mp3>` and gets a summary markdown file produced by transcribe -> cleanup -> summarize, fully unattended with zero interactive prompts.

## Architectural Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Orchestration | Single bash entrypoint `transcribrr.sh` at repo root (D-05) | Matches the existing repo idiom; no new toolchain; one command is the core value |
| Stage chaining | Each sub-script emits `OUTPUT_FILE=<path>` on stdout; orchestrator captures via `grep "^OUTPUT_FILE="` (D-04) | Avoids duplicating each sub-script's filename-derivation logic; immune to races with stale outputs; no globbing |
| Non-interactive driving | Per-script `--model`/`--style` flags with silent README defaults; orchestrator always passes explicit flags (D-01, D-02, D-03, D-08) | Cleanest long-term CLI; flag-or-default removes `read -p` menus without breaking existing script conventions |
| Artifact location | Intermediates (`*_transcript_*.txt`, `*_cleaned_*.txt`, `*_summary_*.md`) written next to the input MP3; already covered by `.gitignore` (D-06) | Preserves current sub-script behavior; no output-dir config needed in Phase 1 |
| Error model | Orchestrator uses `set -euo pipefail` + ERR trap naming `$CURRENT_STAGE`; sub-scripts keep their own strict-mode posture — `transcribe.sh` intentionally non-strict (D-10) | Fail-fast with named cause at the orchestrator level; preserving `transcribe.sh`'s background-process monitor loop which is incompatible with strict mode |
| Preflight | All dependency checks (input file, three sub-scripts executable, `ffmpeg` on PATH) run before any heavy MLX work; failures accumulated and reported together (ROB-01) | Avoids wasting GPU time on trivially detectable misconfiguration |
| --no-cleanup flag | Skips the cleanup stage and passes raw transcript directly to summarize (D-09, CL-03) | Optional shortcut for speed or when cleanup model is unavailable; downstream strips its own header |

## Stack Touched in Phase 1

- [x] Project scaffold — four bash scripts at repo root; no build system required
- [x] Routing — `transcribrr.sh` orchestrates the pipeline end-to-end via `$SCRIPT_DIR/<script>` invocations
- [ ] Database / persistence — filesystem outputs next to the MP3 (intermediates) and `*_summary_*.md` (final artifact)
- [x] UI — CLI flags + `--help`; per-stage banners (`Stage 1/3`, `Stage 2/3`, `Stage 3/3`)
- [x] Deployment — local run command: `./transcribrr.sh <audio.mp3>` (Apple Silicon macOS, MLX requirement)

## Out of Scope (Deferred to Later Slices)

- YouTube URL input and `yt-dlp` download
- MP3 extraction via `ffmpeg` from video container
- Video metadata capture (title, channel, URL, duration, upload date)
- Single-markdown assembly (rich header + summary + full transcript in one file)
- Browser-cookie auth passthrough (`--cookies-from-browser`) for bot-detection bypass
- Playlist and batch URL support
- Configurable output directory (`--output-dir`)
- Keep-vs-discard intermediates toggle
- Optional `--interactive` flag to restore `read -p` model/style menus

## Subsequent Slice Plan

Each later phase adds one vertical slice on top of this skeleton without altering its architectural decisions:

- Phase 2: From a YouTube URL — download MP3 via `yt-dlp`/`ffmpeg`, capture metadata (title, channel, URL, duration, upload date), run the Phase 1 pipeline, and assemble one rich-header markdown file (header + summary + full transcript) written only on full success
