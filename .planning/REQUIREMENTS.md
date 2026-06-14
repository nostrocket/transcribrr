# Requirements — YouTube-to-Markdown Pipeline

Single bash script that takes a YouTube URL through the full transcribrr pipeline and emits one markdown file (rich header → summary → full transcript), reusing the existing MLX scripts and `yt-dlp`.

## v1 Requirements

### Download (DL)
- [ ] **DL-01**: User can run one command with a YouTube URL to start the full pipeline
- [ ] **DL-02**: Script downloads the video/audio from the URL using `yt-dlp`
- [ ] **DL-03**: Script exports audio to MP3 (via `yt-dlp -x --audio-format mp3` or `ffmpeg`)
- [ ] **DL-04**: Script captures video metadata (title, channel, URL, duration, upload date) for the output header

### Transcribe (TR)
- [ ] **TR-01**: Script transcribes the MP3 by invoking `transcribe.sh` non-interactively
- [ ] **TR-02**: Whisper model size is selectable via flag, defaulting to the README-recommended model
- [ ] **TR-03**: Script locates the transcript output file (`*_transcript_*.txt`) to feed the next stage

### Cleanup (CL)
- [ ] **CL-01**: Script cleans the raw transcript by invoking `cleanup-transcript.sh` non-interactively
- [ ] **CL-02**: Cleanup model is selectable via flag with a sensible default
- [ ] **CL-03**: Cleanup stage can be disabled via flag (e.g. `--no-cleanup`)

### Summarize (SUM)
- [ ] **SUM-01**: Script summarizes the cleaned transcript by invoking `summarize-transcript.sh` non-interactively
- [ ] **SUM-02**: Summary model and style are selectable via flags with sensible defaults
- [ ] **SUM-03**: Script locates the summary output (`*_summary_*.md`) to assemble the final file

### Output (OUT)
- [ ] **OUT-01**: Script writes ONE markdown file containing, in order: rich header, summary, full transcript
- [ ] **OUT-02**: Rich header includes video title, channel, source URL, duration, upload date, and the models used
- [ ] **OUT-03**: Final markdown filename is derived from the video title (sanitized) at a predictable path

### CLI & Unattended (CLI)
- [ ] **CLI-01**: Script runs fully unattended when flags are supplied (no interactive prompts block it)
- [ ] **CLI-02**: Script prints usage/help describing the URL argument and all flags
- [ ] **CLI-03**: Script reports clear progress per stage (download → mp3 → transcribe → cleanup → summarize → assemble)

### Robustness (ROB)
- [ ] **ROB-01**: Script checks for required dependencies (`yt-dlp`, `ffmpeg`, existing scripts) and fails with a clear message if missing
- [ ] **ROB-02**: Script fails fast with an actionable message if any stage errors, naming the failing stage
- [ ] **ROB-03**: Intermediate artifacts are retained (or cleaned up) predictably; the final markdown is only written on full success

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
| DL-01 | Phase 1 | Pending |
| CLI-01 | Phase 1 | Pending |
| CLI-02 | Phase 1 | Pending |
| CLI-03 | Phase 1 | Pending |
| ROB-01 | Phase 1 | Pending |
| TR-01 | Phase 1 | Pending |
| TR-02 | Phase 1 | Pending |
| TR-03 | Phase 1 | Pending |
| CL-01 | Phase 1 | Pending |
| CL-02 | Phase 1 | Pending |
| CL-03 | Phase 1 | Pending |
| SUM-01 | Phase 1 | Pending |
| SUM-02 | Phase 1 | Pending |
| SUM-03 | Phase 1 | Pending |
| DL-02 | Phase 2 | Pending |
| DL-03 | Phase 2 | Pending |
| DL-04 | Phase 2 | Pending |
| OUT-01 | Phase 2 | Pending |
| OUT-02 | Phase 2 | Pending |
| OUT-03 | Phase 2 | Pending |
| ROB-02 | Phase 2 | Pending |
| ROB-03 | Phase 2 | Pending |
