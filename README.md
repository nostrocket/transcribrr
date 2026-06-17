# transcribrr

YouTube-to-Markdown on Apple Silicon. One command takes a URL to a finished markdown file with summary and full transcript.

**Requirements:** Apple Silicon Mac, `yt-dlp`, `ffmpeg`, Python 3

---

## Usage

```bash
./transcribrr.sh <youtube-url>
./transcribrr.sh <audio.mp3>
```

That's it. Dependencies are installed automatically on first run.

Output: a markdown file with video metadata, a blog-post summary, and the full cleaned transcript.

---

## Options

```
--whisper-model <label>     tiny | base | small | medium | large-v3 | turbo | turbo-4bit (default)
--cleanup-model <label>     llama3.2-1b-4bit | llama3.2-3b-4bit | llama3.1-8b-4bit (default)
--summary-model <label>     Qwen2.5-14B-4bit | Qwen2.5-32B-4bit (default) | Qwen3-14B-4bit | Qwen3-32B-4bit
--summary-style <style>     executive | detailed | bullets | chapters | blog (default)
--no-cleanup                Skip transcript cleanup, feed raw transcript to summarizer
--benchmark                 Interactive sweep to pick the best model at each stage
--no-install                Fail instead of auto-installing missing dependencies
--help                      Show full help
```

---

## Model defaults

On first run, transcribrr checks your machine's RAM and auto-writes `config/settings.conf` with recommended defaults if they fit. The defaults are:

| Stage | Model | Size |
|-------|-------|------|
| Whisper | `turbo-4bit` | ~0.5 GB |
| Cleanup | `llama3.1-8b-4bit` | ~4.5 GB |
| Summary | `Qwen2.5-32B-4bit` | ~18 GB |

The pipeline runs one model at a time, so you need enough RAM for the largest stage (~22 GB with overhead). If your machine doesn't have enough, the first run will tell you to run `--benchmark` to pick smaller models.

---

## Benchmarking (optional)

Benchmarking is entirely optional — the defaults work well on most Apple Silicon Macs. Run it if you want to tune for your hardware or explore different quality/speed trade-offs.

```bash
./transcribrr.sh --benchmark
```

The benchmark runs every available model at each pipeline stage (whisper → cleanup → summarize), measures speed and memory on a short sample clip, shows you a real output excerpt for each, and asks you to pick the winner. Your picks are saved to `config/settings.conf` and become the new defaults.

To benchmark on your own audio instead of the built-in sample:

```bash
./transcribrr.sh --benchmark --sample talk.mp3
./transcribrr.sh --benchmark --sample "https://www.youtube.com/watch?v=..."
```
