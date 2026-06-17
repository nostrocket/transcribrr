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
--whisper-model <label>     tiny | base | small (default) | medium | large-v3 | turbo
--cleanup-model <label>     llama3.2-1b-4bit | llama3.2-3b-4bit | llama3.1-8b-4bit (default) | llama3.1-8b-8bit
--summary-model <label>     Qwen2.5-7B-4bit | Qwen2.5-14B-4bit | Qwen2.5-32B-4bit (default) | Qwen2.5-32B-8bit
--summary-style <style>     executive | detailed | bullets | chapters | blog (default)
--no-cleanup                Skip transcript cleanup, feed raw transcript to summarizer
--benchmark                 Interactive sweep to pick the best model at each stage
--no-install                Fail instead of auto-installing missing dependencies
--help                      Show full help
```
