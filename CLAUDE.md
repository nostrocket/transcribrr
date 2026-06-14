<!-- GSD:project-start source:PROJECT.md -->

## Project

**transcribrr — YouTube-to-Markdown Pipeline**

transcribrr is a local, Apple-Silicon transcription/summarization toolkit built from standalone bash scripts (MLX Whisper for transcription, Qwen via MLX for summarization). This milestone adds a single bash script that drives the **entire pipeline end-to-end**: given a YouTube URL, it downloads the video, extracts MP3 audio, transcribes it, cleans the transcript, summarizes it, and writes one markdown file containing a rich header, the summary, and the full transcript.

It is for the project owner (and anyone on Apple Silicon) who today runs the README's four-step workflow by hand and wants a single unattended command instead.

**Core Value:** One command takes a YouTube URL to a finished markdown file (summary + full transcript) reliably and unattended — reusing the existing MLX scripts rather than reinventing them.

### Constraints

- **Tech stack**: Bash only — no Go. Wrap `yt-dlp` + `ffmpeg`; orchestrate existing MLX scripts. Matches the repo's existing idiom.
- **Reliability**: Downloader must survive YouTube's 2026 changes → `yt-dlp` (kept updatable), optionally with browser-cookie auth for bot detection.
- **Platform**: Apple Silicon macOS (MLX requirement, inherited from existing scripts).
- **Unattended**: Must run without interactive prompts when flags are supplied.

<!-- GSD:project-end -->

<!-- GSD:stack-start source:STACK.md -->

## Technology Stack

Technology stack not yet documented. Will populate after codebase mapping or first phase.
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
