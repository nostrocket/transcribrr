# Phase 1: Scriptable Pipeline Foundation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-14
**Phase:** 1-Scriptable Pipeline Foundation
**Areas discussed:** Non-interactive driving, Output discovery, Script name & artifacts, Flag & CLI design

---

## Non-interactive driving — mechanism

| Option | Description | Selected |
|--------|-------------|----------|
| Env-var override in each script | Add a guard before each `read -p` so an env var bypasses the prompt; backward-compatible standalone use | |
| Pipe canned answers to stdin | Leave scripts untouched; `printf '3\n' \| ./script.sh`; fragile re: prompt order/count | |
| Add proper flags to each script | Refactor each script to parse its own `--model`/`--style` flags; wrapper passes flags | ✓ |

**User's choice:** Add proper flags to each script
**Notes:** Largest edit to the existing scripts but cleanest long-term CLI.

## Non-interactive driving — behavior when no flag given

| Option | Description | Selected |
|--------|-------------|----------|
| Prompt interactively as today | No flag → fall back to existing `read -p` menu (backward-compatible) | |
| Use the default silently, no prompt | No flag → use README-recommended default, no prompt; menus effectively removed | ✓ |

**User's choice:** Use the default silently, no prompt
**Notes:** Intentionally changes current hand-run behavior; fully non-interactive everywhere.

## Output discovery

| Option | Description | Selected |
|--------|-------------|----------|
| Script prints its output path; wrapper captures it | Stable final line (e.g. `OUTPUT_FILE=<path>`); no duplicated label logic | ✓ |
| Wrapper predicts the filename | Wrapper reconstructs filename from the label it passed; risks drift | |
| Glob the newest matching file | Pick newest `*_transcript_*.txt` etc.; racy with stale outputs | |

**User's choice:** Script prints its output path; wrapper captures it
**Notes:** Leverages the fact that the scripts are already being edited.

## Script name & artifacts — name

| Option | Description | Selected |
|--------|-------------|----------|
| transcribrr.sh | Canonical project entrypoint name | ✓ |
| pipeline.sh | Descriptive, neutral | |
| run.sh | Short, conventional | |

**User's choice:** transcribrr.sh

## Script name & artifacts — artifact location

| Option | Description | Selected |
|--------|-------------|----------|
| Next to the input MP3 | Existing behavior; already gitignored | ✓ |
| Dedicated output directory | Tidier but adds path-management logic | |

**User's choice:** Next to the input MP3

## Flag & CLI design — flag values

| Option | Description | Selected |
|--------|-------------|----------|
| Friendly labels, with raw HF ID passthrough | `--whisper-model small`; value containing `/` = raw HF ID | ✓ |
| Friendly labels only | No custom-model path in v1 | |
| Raw HF model IDs only | Explicit but verbose | |

**User's choice:** Friendly labels, with raw HF ID passthrough

## Flag & CLI design — preflight strictness

| Option | Description | Selected |
|--------|-------------|----------|
| Check everything upfront, fail fast with named cause | Verify scripts, ffmpeg, input before stage 1; abort with specific message | ✓ |
| Minimal check, let stages fail naturally | Only verify input exists | |

**User's choice:** Check everything upfront, fail fast with named cause

---

## Claude's Discretion

- Exact `--help` text and per-stage progress banner wording.
- Exact key name for the machine-parseable output line (`OUTPUT_FILE=` suggested).
- Exact flag long-names where unspecified, and any short aliases.
- Internal refactor of each sub-script mapping flag value → existing model/label/style variables (must preserve output-filename conventions).

## Deferred Ideas

- Browser-cookie auth passthrough (`--cookies-from-browser`) — v2.
- Playlist / batch URL support — v2.
- Configurable output directory / keep-vs-discard intermediates toggle — v2.
- Optional `--interactive` flag to restore the old `read -p` menus — backlog if hand-run menu selection is later missed.
- YouTube download + MP3 extraction + metadata capture + single-markdown assembly — Phase 2 (by design).
