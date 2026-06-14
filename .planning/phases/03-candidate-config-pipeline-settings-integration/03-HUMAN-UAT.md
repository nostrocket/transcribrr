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
result: [pending]

### 2. WR-01 label namespace decision (code review finding)
expected: A decision is made about the 7 of 13 `candidates.conf` labels (`turbo-4bit`, `distil-large-v3`, `qwen3-8b-4bit`, `Qwen3-14B-4bit`, `Qwen3-32B-4bit`, `Llama3.3-70B-4bit`) that have no matching `case` entry in the stage scripts. A user copying one of these labels into `settings.conf` will get "Unknown model" failures. Decide one of: (a) add label coverage to the stage scripts now, (b) update `settings.conf.example`/docs to say "use raw HF IDs", or (c) defer label resolution to Phase 4.
result: [pending]

## Summary

total: 2
passed: 0
issues: 0
pending: 2
skipped: 0
blocked: 0

## Gaps
