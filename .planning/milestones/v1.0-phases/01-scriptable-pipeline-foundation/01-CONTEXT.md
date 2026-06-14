# Phase 1: Scriptable Pipeline Foundation - Context

**Gathered:** 2026-06-14
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver a single new orchestrator script, `transcribrr.sh`, that accepts a **local MP3** and runs `transcribe.sh` → `cleanup-transcript.sh` → `summarize-transcript.sh` **fully unattended**. Models and summary style are chosen by flag (defaulting to the README-recommended models); each stage's output file is located automatically and fed to the next; the script provides `--help`, upfront dependency checks, and clear per-stage progress.

**In scope:** the wrapper + the non-interactive refactor of the three existing MLX scripts needed to drive them unattended.
**Out of scope (this phase):** YouTube download, MP3 extraction, metadata capture, and final single-markdown assembly — those are Phase 2. No Go, no reimplementation of transcription/summarization.

</domain>

<decisions>
## Implementation Decisions

### Non-interactive driving
- **D-01:** Refactor each of the three existing scripts (`transcribe.sh`, `cleanup-transcript.sh`, `summarize-transcript.sh`) to **parse its own flags** (e.g. `--model`, and `--style` for summarize). This is the chosen mechanism over stdin-piping or env-var guards — it gives the cleanest long-term CLI even though it is the largest edit to the existing scripts.
- **D-02:** When a model/style flag is **not** supplied, the script uses the README-recommended default **silently — no `read -p` prompt**. The interactive menus are replaced by flag-or-default behavior. (Note: this intentionally changes the current hand-run behavior; the menus no longer appear by default.)
- **D-03:** `transcribrr.sh` always passes explicit flags to each sub-script, so it never triggers a prompt and never depends on prompt order/count.

### Output discovery (chaining stages)
- **D-04:** Each sub-script emits its produced output path on a **stable, machine-parseable final line** (e.g. `OUTPUT_FILE=<path>`). `transcribrr.sh` captures that line to feed the next stage. Chosen over filename prediction (avoids duplicating the scripts' model-label sanitization logic) and over globbing newest (avoids races with stale outputs).

### Script name & artifact location
- **D-05:** The new orchestrator script is named **`transcribrr.sh`** (the canonical project entrypoint), placed at repo root alongside the existing scripts.
- **D-06:** Intermediate artifacts (transcript `.txt`, cleaned `.txt`, `.log`) are written **next to the input MP3** — the existing scripts' current behavior. Already covered by `.gitignore` patterns. (A dedicated output dir was considered and deferred to Phase 2 if needed.)

### Flag & CLI design
- **D-07:** Model/style flags accept **friendly labels** matching the existing menus (`--whisper-model small`, `--cleanup-model llama3.1-8b-4bit`, `--summary-model Qwen2.5-32B-4bit`, `--summary-style blog`). If a flag value **contains a `/`**, it is treated as a raw Hugging Face model ID — preserving the scripts' existing "custom model" capability.
- **D-08:** Defaults follow the README recommendations: whisper `small`, cleanup `llama3.1-8b-4bit`, summary model `Qwen2.5-32B-4bit`, summary style `blog`.
- **D-09:** `--no-cleanup` skips the cleanup stage (per CL-03); when skipped, the raw transcript feeds directly into summarize.
- **D-10:** **Preflight check before stage 1, fail-fast with named cause** (ROB-01): verify the three sub-scripts exist and are executable, `ffmpeg` is on `PATH`, and the input MP3 exists. Abort immediately with a specific message identifying what is missing. Each sub-script continues to handle its own `.venv` auto-install as today (not duplicated in the wrapper).
- **D-11:** `--help` prints usage covering the input-file argument and all flags (CLI-02). Per-stage progress announces which stage is running — transcribe → cleanup → summarize (CLI-03).

### Claude's Discretion
- Exact wording/format of `--help` output and the per-stage progress banners.
- Exact name of the machine-parseable output line key (`OUTPUT_FILE=` is a suggestion).
- Exact flag long-names where not specified above, and whether to add short aliases.
- How the three sub-scripts are refactored internally to map a flag value → existing model/label/style variables (must preserve current output-filename conventions so `.gitignore` keeps matching).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project planning
- `.planning/PROJECT.md` — milestone definition, Key Decisions (yt-dlp over Go, bash-only, reuse MLX scripts).
- `.planning/REQUIREMENTS.md` — v1 requirements; Phase 1 owns DL-01, CLI-01/02/03, ROB-01, TR-01/02/03, CL-01/02/03, SUM-01/02/03.
- `.planning/ROADMAP.md` § "Phase 1: Scriptable Pipeline Foundation" — goal and 5 success criteria.

### Scripts to orchestrate AND refactor (read in full before editing)
- `transcribe.sh` — interactive Whisper model menu at `read -p` (line ~101); output `<basename>_transcript_<label>.txt`; runs whisper in background with a progress monitor; uses `ffmpeg` for duration; does **not** use `set -euo pipefail`.
- `cleanup-transcript.sh` — `set -euo pipefail`; LLM model menu at `read -p` (line ~37); output `<basename>_cleaned_<label>.txt`; strips the `Model:/Source:/Date:` header from its input.
- `summarize-transcript.sh` — `set -euo pipefail`; **two** prompts (model ~line 87, style ~line 118) + `--install` flag already present; output `<basename>_summary_<label>_<style>.md`; also strips the metadata header.

### Conventions
- `README.md` § "Typical workflow" and the per-script tables — the recommended models/defaults and the exact filename conventions the wrapper relies on.
- `.gitignore` — output patterns (`*_transcript_*.txt`, `*_transcription_*.log`, `*_whisper_*.pid`, `*_cleaned_*.txt`, `*_summary_*.md`) that the refactor must keep matching.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- The three MLX scripts already compute the correct output filenames and echo the path (e.g. `transcribe.sh`: `echo "Transcript: $OUTPUT_FILE"`). Making that line machine-parseable (D-04) is a small change, not new logic.
- `summarize-transcript.sh` already parses a flag (`--install`) and supports custom model IDs — the flag-parsing pattern and the model→label mapping cases exist to extend.
- `.venv` auto-install lives in `summarize-transcript.sh` (`setup_venv`); the wrapper should not duplicate it.

### Established Patterns
- Model selection maps a menu choice → `MODEL` + `MODEL_LABEL`; the label is embedded in the output filename. The flag refactor must feed this same mapping so filenames stay convention-compliant (and gitignored).
- Sub-scripts write outputs **relative to the input file's directory** — consistent with D-06.
- `cleanup-transcript.sh` and `summarize-transcript.sh` strip the `Model:/Source:/Date:` header on input. Consequence: a cleaned transcript loses that header, so summarize's title falls back to the filename. Relevant to Phase 2's rich header, not blocking for Phase 1.

### Integration Points
- `transcribrr.sh` (new, repo root) invokes the three scripts in sequence, passing flags (D-03), capturing each `OUTPUT_FILE` line (D-04), honoring `--no-cleanup` (D-09), after a preflight check (D-10).

</code_context>

<specifics>
## Specific Ideas

- The wrapper is the canonical entrypoint named after the project (`transcribrr.sh`).
- Friendly-label flags should read like the README menus so the CLI matches existing documentation vocabulary.
- Raw HF model IDs detected by the presence of `/` (e.g. `mlx-community/whisper-large-v3-turbo`).

</specifics>

<deferred>
## Deferred Ideas

- **Browser-cookie auth passthrough** (`--cookies-from-browser`) — v2 (REQUIREMENTS.md).
- **Playlist / batch URL support** — v2.
- **Configurable output directory / keep-vs-discard intermediates toggle** — v2; Phase 1 keeps artifacts next to the MP3.
- **Optional `--interactive` flag to restore the old `read -p` menus** — not needed for v1; D-02 removes the prompts by default. Note for the roadmap backlog if hand-run menu selection is later missed.
- **YouTube download + MP3 extraction + metadata capture + single-markdown assembly** — Phase 2 (by design).

None of the above are in Phase 1 scope.

</deferred>

---

*Phase: 1-Scriptable Pipeline Foundation*
*Context gathered: 2026-06-14*
