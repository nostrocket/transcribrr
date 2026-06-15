---
status: partial
phase: 03-candidate-config-pipeline-settings-integration
source: [03-VERIFICATION.md]
started: 2026-06-14T16:49:16.322Z
updated: 2026-06-14T16:49:16.322Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. CFG-03 runtime error path
expected: With an invalid model label set in `config/settings.conf` (e.g. `SUMMARY_MODEL_DEFAULT=does-not-exist`), running the pipeline against a real audio file aborts with an actionable stderr message containing `from config/settings.conf could not be loaded` (the catch-and-translate error, not just the generic ERR trap).
result: passed — verified 2026-06-15 via live runs. With a bogus `WHISPER_MODEL_DEFAULT` from settings.conf, the transcribe stage failed and stderr printed `whisper model '…' from config/settings.conf could not be loaded` + the benchmark hint. Control run with a built-in model showed only the generic stage error (no settings hint) — confirming the source-gating is correct. Additionally, a full end-to-end YouTube run (flag-sourced models) completed all 5 stages successfully.

### 2. WR-01 label namespace decision (code review finding)
expected: A decision is made about the 7 of 13 `candidates.conf` labels (`turbo-4bit`, `distil-large-v3`, `qwen3-8b-4bit`, `Qwen3-14B-4bit`, `Qwen3-32B-4bit`, `Llama3.3-70B-4bit`) that have no matching `case` entry in the stage scripts. A user copying one of these labels into `settings.conf` will get "Unknown model" failures. Decide one of: (a) add label coverage to the stage scripts now, (b) update `settings.conf.example`/docs to say "use raw HF IDs", or (c) defer label resolution to Phase 4.
result: deferred — Phase 3 approved by user 2026-06-15 without resolving this. Carried forward as an open decision (candidate for Phase 4 label resolution). Tracked in Gaps below.

## Summary

total: 2
passed: 1
issues: 0
pending: 1
skipped: 0
blocked: 0

## Gaps

- **WR-01 label namespace** (open decision): 7 of 13 `candidates.conf` labels have no `case` entry in the stage scripts, so copying one into `settings.conf` yields an "Unknown model" failure. Resolution deferred at Phase 3 approval — revisit in Phase 4 (label resolution) or via a doc fix / stage-script label coverage. Raw HF IDs (`org/model`) work today via the `*/*` passthrough.
