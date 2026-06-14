# Phase 2: End-to-End YouTube-to-Markdown Delivery - Context

**Gathered:** 2026-06-14
**Status:** Ready for planning

<domain>
## Phase Boundary

From a single command with a YouTube URL, `transcribrr.sh` downloads audio to MP3 (via `yt-dlp`), captures video metadata, runs the existing Phase 1 pipeline (transcribe → cleanup → summarize), and assembles exactly one markdown file (rich header → summary → full transcript). It fails fast naming the failing stage and writes the final markdown only on full success.

Requirements in scope: DL-02, DL-03, DL-04, OUT-01, OUT-02, OUT-03, ROB-02, ROB-03.
Builds directly on the Phase 1 walking skeleton (`transcribrr.sh`) without altering its locked architectural decisions (OUTPUT_FILE= stage chaining, flag-or-default driving, `$CURRENT_STAGE` ERR trap, intermediates beside input).

</domain>

<decisions>
## Implementation Decisions

### Input, Download & Dependencies
- **URL vs local input is auto-detected**: if the positional argument matches `http(s)://` / `youtu`(.be|be.com), run the new download stage; otherwise treat it as a local audio file (preserves Phase 1 behavior). Keeps the "one command" core value with no new required subcommand or flag.
- **Download + MP3 extraction uses `yt-dlp -x --audio-format mp3`** (yt-dlp drives ffmpeg internally) — single tool, satisfies DL-02 and DL-03 together.
- **Working location**: downloaded MP3 and all intermediates go in a working directory under the CWD named from the sanitized video title (e.g. `./<sanitized-title>/`); the final `.md` is written at the CWD root. Predictable, avoids clutter, and keeps Phase 1's "intermediates beside the input MP3" invariant (the input MP3 now lives in that working dir).
- **`yt-dlp` is preflight-checked only when the input is a URL**, failing with an actionable `brew install yt-dlp` hint (extends the ROB-01 preflight). `ffmpeg` remains required (already checked).

### Metadata & Final Markdown
- **Metadata capture uses `yt-dlp --print` field templates** (`%(title)s`, `%(channel)s`/`%(uploader)s`, `%(webpage_url)s`, `%(duration_string)s`, `%(upload_date)s`) — captures all DL-04 fields in the same invocation, no second network hit.
- **No `jq` dependency** — rely on yt-dlp's own output templates so the only new tool introduced is `yt-dlp`.
- **Header format (OUT-02)**: a top-level `#` title line followed by a bulleted metadata block (Title, Channel, Source URL, Duration, Upload date, Models used), then `## Summary`, then `## Transcript`. Plain, human-readable markdown. Upload date reformatted from yt-dlp's `YYYYMMDD` to `YYYY-MM-DD`.
- **Transcript variant in the final file**: the cleaned transcript when the cleanup stage ran, otherwise the raw transcript ("full transcript" = best available version, honoring `--no-cleanup`).

### Output Safety & Scope
- **Final filename (OUT-03)**: sanitized video title + `.md` at a predictable path (CWD root), using the same sanitization approach the existing sub-scripts use.
- **Partial-output safety (ROB-03)**: assemble the final markdown into a temp file and `mv` it into place only after all stages succeed — never leave a partial final `.md`.
- **Fail-fast (ROB-02)**: extend the existing `$CURRENT_STAGE` + ERR-trap pattern to name the new stages (`download`, `metadata`, `assemble`) so any failure aborts with the failing stage named.
- **Intermediates are retained** (transcript, cleaned, summary, downloaded MP3) for debuggability; only the final `.md` is gated on full success.
- **Deferred to v2**: browser-cookie auth (`--cookies-from-browser`) and playlist/batch URL support. If a playlist URL is supplied, error clearly rather than guessing.

### Claude's Discretion
- Exact sanitization regex, working-directory naming collisions handling, and precise yt-dlp flag ordering are at the planner/executor's discretion, consistent with codebase conventions.

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `transcribrr.sh` — the Phase 1 orchestrator: flag parsing (`while [[ $# -gt 0 ]]` case loop), `preflight_check()`, `stage_banner()`, `$CURRENT_STAGE` ERR trap, and `OUTPUT_FILE=` capture (`... | tee /dev/stderr | grep "^OUTPUT_FILE="`). Phase 2 inserts a download/metadata stage *before* Stage 1 and an assemble stage *after* Stage 3.
- `transcribe.sh` / `cleanup-transcript.sh` / `summarize-transcript.sh` — non-interactive `--model`/`--style` flags emitting `OUTPUT_FILE=<path>`; reused unchanged.

### Established Patterns
- `set -euo pipefail` + ERR trap naming `$CURRENT_STAGE` at the orchestrator level (transcribe.sh intentionally non-strict — do not change).
- Each stage captures its downstream input via `OUTPUT_FILE=` rather than globbing — avoids stale-file races.
- Flag-or-default driving; silent README defaults; explicit flags always passed to sub-scripts.
- Intermediates written next to the input audio; final artifact path is predictable. `.gitignore` already covers `*_transcript_*.txt`, `*_cleaned_*.txt`, `*_summary_*.md`.

### Integration Points
- New download+metadata stage produces the MP3 that feeds the existing Stage 1 (`transcribe.sh`).
- New assemble stage consumes the Stage 3 summary (`*_summary_*.md`), the transcript (raw or cleaned), and captured metadata to write the single final `.md`.
- Preflight gains a URL-conditional `yt-dlp` check.

</code_context>

<specifics>
## Specific Ideas

- Reuse the SKELETON.md "Subsequent Slice Plan" for Phase 2 verbatim: add one vertical slice (URL → download/metadata → Phase 1 pipeline → single rich-header markdown) on top of the skeleton without altering its architectural decisions.
- Models-used line in the header should reflect the actual whisper/cleanup/summary models used for that run.

</specifics>

<deferred>
## Deferred Ideas

- Browser-cookie auth passthrough (`--cookies-from-browser`) for bot-detection-restricted videos (v2).
- Playlist / batch URL support (v2) — error clearly on playlist URLs for now.
- Keep/discard intermediates toggle and a configurable output directory (`--output-dir`) (v2).

</deferred>
