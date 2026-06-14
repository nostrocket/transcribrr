# Phase 3: Candidate Config & Pipeline Settings Integration - Context

**Gathered:** 2026-06-14
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver the **config layer** for v2.0, two halves:

1. **`config/candidates.conf`** — a committed, vetted candidate-model list (per stage: transcription, cleanup, summarization) that the benchmark engine will *parse, never source*. Each candidate carries an HF ID, friendly label, stage, and approximate size.
2. **`settings.conf` reading in `transcribrr.sh`** — the normal pipeline reads selected model defaults from `config/settings.conf` with correct **flag > settings > built-in** precedence, plus a clear error path when a settings model can't load.

**In scope:** candidates.conf format + shipped vetted list; settings.conf precedence/resolution in `transcribrr.sh`; CFG-03 error handling; provenance reporting. Requirements: MODEL-01, MODEL-02, MODEL-03, CFG-01, CFG-02, CFG-03.

**Out of scope (later phases):** the benchmark sweep itself, hardware-fit checks, resumable runs, report/selection writing of settings.conf (Phases 4–5), and the Claude refresh skill (Phase 6). This phase only *defines and reads* the config; it does not *generate* it via benchmarking.

</domain>

<decisions>
## Implementation Decisions

### candidates.conf format (MODEL-01)
- **D-01:** Record format is **KEY=value blocks**, one block per candidate, introduced by a `[candidate]` header line. Keys per block: `stage=`, `id=` (full HF model ID), `label=` (friendly label, matching the existing stage-script label vocabulary where applicable), `size_gb=` (numeric approximate size). Example:
  ```
  [candidate]
  stage=summarize
  id=mlx-community/Qwen2.5-32B-Instruct-4bit
  label=Qwen2.5-32B-4bit
  size_gb=18
  ```
- **D-02:** The file is **parsed, never sourced** (PITFALLS: avoid `source` on machine-written config — the Phase 6 skill writes this file). Parse with `grep` / `while read` / line-state, bash 3.2 portable (no `mapfile`, no associative arrays). `stage` values: `whisper`, `cleanup`, `summarize`.
- **D-03:** `config/candidates.conf` is **committed** to the repo — it ships the MODEL-02 vetted list. (Phase 6 later refreshes it in place.)

### settings.conf — location & lifecycle (CFG-01)
- **D-04:** `config/settings.conf` is **gitignored** (per-user generated file). A committed **`config/settings.conf.example`** ships to document the format. Built-in defaults stay in `transcribrr.sh` — they are NOT duplicated into a committed settings.conf.
- **D-05:** A fresh clone has no `settings.conf` → the pipeline **silently falls through to built-in defaults**. Never prompt on missing settings (PITFALLS).
- **D-06:** settings.conf keys for this phase are exactly the three model defaults: `WHISPER_MODEL_DEFAULT`, `CLEANUP_MODEL_DEFAULT`, `SUMMARY_MODEL_DEFAULT`. (Other keys like `CANDIDATE_MAX_AGE_DAYS` belong to later phases — do not add them here.) settings.conf is also parsed safely (not blindly sourced).

### Precedence & provenance (CFG-02)
- **D-07:** Resolution order is **flag > settings.conf > built-in default**. Implemented via a **per-flag sentinel**: each `--*-model` case branch sets `WHISPER_MODEL_EXPLICIT=true` / `CLEANUP_MODEL_EXPLICIT=true` / `SUMMARY_MODEL_EXPLICIT=true`. After flag parsing, settings.conf fills a model **only when its sentinel is false**. This correctly satisfies success criterion #3 — `--whisper-model small` (explicitly naming the built-in default) still beats a settings.conf value. Do NOT use the "compare against built-in default string" approach (it can't distinguish explicit-default from not-supplied).
- **D-08:** The settings.conf read happens **once, after flag parsing, before preflight** (ARCHITECTURE Pattern 3).
- **D-09:** On a normal run, print a **one-line-per-stage provenance summary** before the pipeline starts, showing each model and its source (`flag` / `settings.conf` / `built-in`):
  ```
  Models:
    whisper  = turbo            (settings.conf)
    cleanup  = llama3.1-8b-4bit (built-in)
    summary  = Qwen2.5-32B-4bit (flag)
  ```
  The provenance tracked here also feeds the CFG-03 error message (D-10).

### Invalid-model error handling (CFG-03)
- **D-10:** Use **catch-and-translate**, not pre-loading. Let the stage script attempt the model load; if it exits non-zero / logs a load error, `transcribrr.sh` translates that into a clear, actionable message that (a) names the offending model, (b) states it came from `config/settings.conf` (using D-07/D-09 provenance), and (c) points to `transcribrr.sh --benchmark` or passing an explicit `--<stage>-model` flag. No network check, no eager model load — normal runs stay offline-friendly.
  ```
  Error: summary model 'mlx-community/Foo-99B' from config/settings.conf could not be loaded.
  Fix: run `transcribrr.sh --benchmark` to reselect, or pass --summary-model <label|hf-id>.
  ```
- **D-11:** Accepted trade-off: a bad **cleanup/summary** model (settings-sourced) only fails *after* transcription has run, since detection is at stage-load time. This was chosen over a pre-flight load (too expensive — would load multi-GB models just to validate). Keep the existing fail-fast ERR trap that names the failing stage.

### Claude's Discretion
- Exact block/field delimiter details for candidates.conf parsing (blank-line vs next `[candidate]` terminator), exact `grep`/`cut` parser implementation, and the precise wording/formatting of the provenance and error lines — implement per the patterns above; no further user input needed.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements & Roadmap
- `.planning/ROADMAP.md` §"Phase 3" — goal, 5 success criteria, requirement IDs (MODEL-01/02/03, CFG-01/02/03).
- `.planning/REQUIREMENTS.md` §Candidate Models (MODEL), §Pipeline Auto-Selection (CFG) — full requirement text and the Out-of-Scope table.

### v2.0 Research (grounds the chosen patterns)
- `.planning/research/ARCHITECTURE.md` — **Pattern 3** (three-tier default resolution, including the sentinel note for criterion #3), **Pattern 4** (candidates.conf parse-not-source), config dir layout (`config/`), and the table mapping which script reads which file. Note: this CONTEXT overrides Pattern 4's bare-ID example — use the `[candidate]` KEY=value format (D-01).
- `.planning/research/PITFALLS.md` — "don't `source` machine-written config", "don't prompt when settings.conf is absent / fall through to built-in defaults".
- `.planning/research/STACK.md`, `.planning/research/FEATURES.md` — milestone-level stack/feature context (MODEL-02 candidate suggestions live in REQUIREMENTS + STACK).

### Existing code (read before editing)
- `transcribrr.sh` — orchestrator; defaults at lines 14–17, flag-parse loop lines 97–135, stage invocations ~376–428. This is the file modified for CFG-01/02/03.
- `transcribe.sh` (lines ~100–123), `cleanup-transcript.sh`, `summarize-transcript.sh` — stage scripts; already accept `--model <label|hf-id>` and treat a value containing `/` as a raw HF ID (MODEL-03 needs no changes here).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`transcribrr.sh` flag-parse `case` loop (lines 97–135):** the `--whisper-model` / `--cleanup-model` / `--summary-model` branches are where the `*_EXPLICIT=true` sentinels get added (D-07). Built-in defaults already live at lines 14–17.
- **Stage scripts' `--model` plumbing:** `transcribe.sh:100-123` resolves a label via `case`, or treats `*/*` as a raw HF ID (sanitizing for filenames). `cleanup-transcript.sh` / `summarize-transcript.sh` follow the same idiom. **MODEL-03 is already satisfied** — any HF ID from candidates.conf flows through `--model` unchanged; no stage-script edits required.
- **ERR trap + `CURRENT_STAGE`:** `transcribrr.sh:27-28` already names the failing stage on error — extend/complement it for the CFG-03 translated message (D-10/D-11).

### Established Patterns
- **Bash 3.2 only** (stock Apple-Silicon macOS): no `mapfile`, no associative arrays — a `mapfile` slip was caught in v1.0 code review (PROJECT.md Key Decisions). All new parsing must be 3.2-portable.
- **`SCRIPT_DIR`-relative paths** (`transcribrr.sh:10`) — reference `config/candidates.conf` / `config/settings.conf` as `$SCRIPT_DIR/config/...`.
- **Defaults baked as literals** in the script (`WHISPER_MODEL="small"`, etc.) — keep as the built-in tier; settings.conf is a layer above, flags above that.

### Integration Points
- **New `config/` directory** at repo root: `candidates.conf` (committed), `settings.conf.example` (committed), `settings.conf` (gitignored, runtime-generated).
- **`.gitignore`** must add `config/settings.conf`.
- **settings.conf read block** inserted in `transcribrr.sh` after the flag-parse loop (~line 135) and before preflight.

</code_context>

<specifics>
## Specific Ideas

- candidates.conf record shape and the provenance/error message formats are pinned to the previews the user approved during discussion (see D-01, D-09, D-10).
- MODEL-02 (the *content* of the shipped vetted list) is intentionally left for the researcher to populate from current best mlx-community models per stage (REQUIREMENTS MODEL-02 lists starting suggestions: whisper-large-v3-turbo / distil-large-v3; Llama-3.x / Qwen3 small for cleanup; Qwen3-14B/32B, Qwen2.5-32B, Llama-3.3-70B for summarization).

</specifics>

<deferred>
## Deferred Ideas

- **Cheap pre-flight model validation** (local HF-cache check before running stages) — considered for CFG-03 but rejected in favor of catch-and-translate; revisit only if late-stage failures prove painful in practice.
- **Network/HF existence validation** of candidate IDs — belongs to Phase 6 (SKILL-03 validates skill output); explicitly excluded from normal runs (offline constraint).
- **Extra settings.conf keys** (e.g. `CANDIDATE_MAX_AGE_DAYS`) — introduced in Phases 5/6, not here.

None of the discussion strayed outside the phase scope.

</deferred>

---

*Phase: 3-Candidate Config & Pipeline Settings Integration*
*Context gathered: 2026-06-14*
