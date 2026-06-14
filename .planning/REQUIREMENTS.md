# Requirements — YouTube-to-Markdown Pipeline

Single bash script that takes a YouTube URL through the full transcribrr pipeline and emits one markdown file (rich header → summary → full transcript), reusing the existing MLX scripts and `yt-dlp`.

## v1 Requirements

### Download (DL)

- [x] **DL-01**: User can run one command with a YouTube URL to start the full pipeline
- [x] **DL-02**: Script downloads the video/audio from the URL using `yt-dlp`
- [x] **DL-03**: Script exports audio to MP3 (via `yt-dlp -x --audio-format mp3` or `ffmpeg`)
- [x] **DL-04**: Script captures video metadata (title, channel, URL, duration, upload date) for the output header

### Transcribe (TR)

- [ ] **TR-01**: Script transcribes the MP3 by invoking `transcribe.sh` non-interactively
- [ ] **TR-02**: Whisper model size is selectable via flag, defaulting to the README-recommended model
- [x] **TR-03**: Script locates the transcript output file (`*_transcript_*.txt`) to feed the next stage

### Cleanup (CL)

- [ ] **CL-01**: Script cleans the raw transcript by invoking `cleanup-transcript.sh` non-interactively
- [ ] **CL-02**: Cleanup model is selectable via flag with a sensible default
- [x] **CL-03**: Cleanup stage can be disabled via flag (e.g. `--no-cleanup`)

### Summarize (SUM)

- [ ] **SUM-01**: Script summarizes the cleaned transcript by invoking `summarize-transcript.sh` non-interactively
- [ ] **SUM-02**: Summary model and style are selectable via flags with sensible defaults
- [x] **SUM-03**: Script locates the summary output (`*_summary_*.md`) to assemble the final file

### Output (OUT)

- [x] **OUT-01**: Script writes ONE markdown file containing, in order: rich header, summary, full transcript
- [x] **OUT-02**: Rich header includes video title, channel, source URL, duration, upload date, and the models used
- [x] **OUT-03**: Final markdown filename is derived from the video title (sanitized) at a predictable path

### CLI & Unattended (CLI)

- [ ] **CLI-01**: Script runs fully unattended when flags are supplied (no interactive prompts block it)
- [x] **CLI-02**: Script prints usage/help describing the URL argument and all flags
- [x] **CLI-03**: Script reports clear progress per stage (download → mp3 → transcribe → cleanup → summarize → assemble)

### Robustness (ROB)

- [x] **ROB-01**: Script checks for required dependencies (`yt-dlp`, `ffmpeg`, existing scripts) and fails with a clear message if missing
- [x] **ROB-02**: Script fails fast with an actionable message if any stage errors, naming the failing stage
- [x] **ROB-03**: Intermediate artifacts are retained (or cleaned up) predictably; the final markdown is only written on full success

## v2 Requirements (deferred)

- Browser-cookie auth passthrough (`--cookies-from-browser`) for bot-detection-restricted videos
- Playlist / batch URL support
- Keep/discard intermediate files toggle and configurable output directory

## Out of Scope

- Go implementation / Go YouTube library — yt-dlp is more reliable in 2026 (see PROJECT.md Key Decisions)
- Reimplementing transcription or summarization — existing MLX scripts are reused
- Non-YouTube sources, GUI, non-Apple-Silicon platforms, cloud APIs — project is deliberately local

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| DL-01 | Phase 1 | Complete |
| CLI-01 | Phase 1 | Pending |
| CLI-02 | Phase 1 | Complete |
| CLI-03 | Phase 1 | Complete |
| ROB-01 | Phase 1 | Complete |
| TR-01 | Phase 1 | Pending |
| TR-02 | Phase 1 | Pending |
| TR-03 | Phase 1 | Complete |
| CL-01 | Phase 1 | Pending |
| CL-02 | Phase 1 | Pending |
| CL-03 | Phase 1 | Complete |
| SUM-01 | Phase 1 | Pending |
| SUM-02 | Phase 1 | Pending |
| SUM-03 | Phase 1 | Complete |
| DL-02 | Phase 2 | Complete |
| DL-03 | Phase 2 | Complete |
| DL-04 | Phase 2 | Complete |
| OUT-01 | Phase 2 | Complete |
| OUT-02 | Phase 2 | Complete |
| OUT-03 | Phase 2 | Complete |
| ROB-02 | Phase 2 | Complete |
| ROB-03 | Phase 2 | Complete |
