---
status: partial
phase: 05-resumable-sweep-report-winner-selection
source: [05-VERIFICATION.md]
started: 2026-06-17T12:47:34Z
updated: 2026-06-17T12:47:34Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Divergence view renders at real terminal width
expected: Before the whisper "Select the best" prompt, every disagreeing line is shown in full with each model's variant labeled, columns wrapped to terminal width, plus a per-model outlier count (or, with exactly 2 candidates, divergence counts + "no outlier ranking" note). No winner auto-picked.
result: [pending]

### 2. Winner selection writes correct label to settings.conf
expected: Selecting a winner per stage writes the matching `*_MODEL_DEFAULT=<label>` to config/settings.conf; choosing "[k] Keep current" (offered only when current default is a candidate) writes nothing.
result: [pending]

### 3. Resume skips completed pairs after Ctrl-C
expected: Ctrl-C mid-whisper, then re-run → "Resume interrupted run from <ts>? [Y/n]" appears; Yes skips already-completed model/stage pairs and does not re-prompt decided stages.
result: [pending]

### 4. Ctrl-C atomicity on settings.conf write
expected: A Ctrl-C during the settings.conf write leaves the file either fully written or unchanged — never partial/corrupt.
result: [pending]

### 5. End-to-end report + CR-03 resume settings write on real MLX output
expected: After a complete sweep, report.md and the terminal ASCII table show real speed (RTF=… / … tok/s, NOT n/a), memory, fit status, and excerpts per model per stage. On a resumed run, the winner picked before interruption IS persisted to settings.conf (CR-03 fix — new since the original checkpoint approval).
result: [pending]

## Summary

total: 5
passed: 0
issues: 0
pending: 5
skipped: 0
blocked: 0

## Gaps
