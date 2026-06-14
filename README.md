# transcribrr

Local audio/video transcription and summarization on Apple Silicon using MLX. Three standalone shell scripts and an interactive MLX model launcher.

**Requirements:** Apple Silicon Mac, `ffmpeg`, Python 3

---

## Scripts

### `transcribe.sh` — Transcribe audio to text

```bash
./transcribe.sh recording.mp3
```

Uses MLX Whisper (GPU-accelerated on Apple Silicon). Prompts you to select a model size, then writes a transcript with metadata.

| Model | Parameters | Notes |
|-------|-----------|-------|
| tiny | 39M | Fastest |
| base | 74M | Fast |
| small | 244M | Recommended |
| medium | 769M | High quality |
| large-v3 | 1550M | Best quality |
| turbo | 809M | Near-large, much faster |

- Output: `<basename>_transcript_<model>.txt`
- Progress log: `<basename>_transcription_<model>.log`
- Dependencies auto-installed into `.venv/` (mlx-whisper)

### `cleanup-transcript.sh` — Clean up a raw transcript

```bash
./cleanup-transcript.sh recording_transcript_small.txt
```

Runs the transcript through a local LLM to fix spelling, grammar, and punctuation; removes filler words; adds paragraph breaks at topic transitions. Preserves the speaker's voice.

| Model | RAM | Notes |
|-------|-----|-------|
| Llama 3.2 1B | ~1 GB | Fastest |
| Llama 3.2 3B | ~2 GB | Fast |
| Llama 3.1 8B 4-bit | ~5 GB | Recommended |
| Llama 3.1 8B 8-bit | ~8 GB | Higher quality |

- Output: `<basename>_cleaned_<model>.txt`
- Requires `.venv/` with `mlx-lm` (installed by `summarize-transcript.sh`)

### `summarize-transcript.sh` — Summarize a transcript

```bash
./summarize-transcript.sh transcript.txt
./summarize-transcript.sh --install   # pre-download default model
```

Summarizes using Qwen 2.5 on Apple Silicon. Handles transcripts of any length via intelligent chunking (single-pass up to ~20k words, multi-pass synthesis beyond that).

**Models:**

| Model | RAM |
|-------|-----|
| Qwen 2.5 7B 4-bit | ~5 GB |
| Qwen 2.5 14B 4-bit | ~9 GB |
| Qwen 2.5 32B 4-bit | ~20 GB (default) |
| Qwen 2.5 32B 8-bit | ~34 GB |

**Summary styles:** Executive, Detailed, Bullet-only, Chapter, Blog Post (default)

- Output: `<basename>_summary_<model>_<style>.md`
- Dependencies auto-installed into `.venv/` on first run

### `mlx-chat.sh` — Interactive MLX model launcher

```bash
./mlx-chat.sh ~/mlx-data
```

Pass a data directory for the venv and model cache. Lists installed and available MLX models, then runs in terminal chat mode or OpenAI-compatible server mode (for use with VS Code Copilot, etc.).

---

## Typical workflow

```bash
# 1. Download audio (e.g. with yt-dlp)
yt-dlp -x --audio-format mp3 "https://youtube.com/watch?v=..." -o talk.%(ext)s

# 2. Transcribe
./transcribe.sh talk.mp3

# 3. Clean up the raw transcript
./cleanup-transcript.sh talk_transcript_small.txt

# 4. Summarize
./summarize-transcript.sh talk_transcript_small_cleaned_llama3.1-8b-4bit.txt
```

All scripts install their Python dependencies into `.venv/` on first run — no manual setup required.
