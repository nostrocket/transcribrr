---
phase: 03-candidate-config-pipeline-settings-integration
verified: 2026-06-15T00:00:00Z
status: human_needed
score: 5/5 must-haves verified
overrides_applied: 0
deferred:
  - truth: "config/candidates.conf is parseable by benchmark.sh"
    addressed_in: "Phase 4"
    evidence: "Phase 4 goal: 'Benchmark Engine Core'; Phase 4 success criteria 1-7 require parsing candidates.conf. Plan 03-01 explicitly notes: 'The parsed by benchmark.sh half lands in Phase 4; this plan delivers the file the parser will consume.'"
human_verification:
  - test: "Settings-file unloadable model triggers CFG-03 error path"
    expected: "When a stage script exits non-zero with a model that was sourced from settings.conf, stderr should contain 'from config/settings.conf could not be loaded' and 'run `transcribrr.sh --benchmark` to reselect' before the process exits 1"
    why_human: "Triggering the CFG-03 branch requires an actual failed model load (the stage script must exit non-zero). Cannot simulate this without a real MLX model load attempt or modifying a stage script temporarily. The code path is structurally verified but runtime behavior requires a real bad model."
  - test: "WR-01 impact on label-based settings.conf values — user workflow"
    expected: "A user who copies a label from candidates.conf (e.g. turbo-4bit, qwen3-8b-4bit, Qwen3-14B-4bit) into settings.conf should either succeed or receive a clear error. The code review (03-REVIEW.md WR-01) identifies these labels have no matching case in the stage scripts and will produce 'Unknown model' failures."
    why_human: "Requires a real model load attempt to confirm the failure mode. This is a correctness/usability issue flagged by the code reviewer — the phase goal is technically met (precedence wiring works, data files ship), but users following the documented workflow (copy a label from candidates.conf into settings.conf) will hit unexpected failures for 7 of 13 labels."
---

# Phase 3: Candidate Config & Pipeline Settings Integration — Verification Report

**Phase Goal:** Users have a working `candidates.conf` with a vetted model list and the normal pipeline reads `settings.conf` with correct flag > settings > built-in precedence.
**Verified:** 2026-06-15
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (from ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC-1 | `config/candidates.conf` exists, lists real HF model IDs for all three stages, is plain data parseable without sourcing | VERIFIED | File exists at `config/candidates.conf`; 13 `[candidate]` blocks confirmed; 13 valid `stage=` lines; no shell-evaluable tokens (`$(`, backticks, `export`, `;rm`); `bash -n` passes; "parsed by benchmark.sh" portion deferred to Phase 4 (see Deferred section) |
| SC-2 | Running `transcribrr.sh` without flags and with `config/settings.conf` present selects the models specified in that file | VERIFIED | Behavioral test: wrote `WHISPER_MODEL_DEFAULT=turbo` to `config/settings.conf`, ran script with nonexistent MP3; provenance output showed `whisper  = turbo                    (settings.conf)`; temp file cleaned up |
| SC-3 | Passing `--whisper-model small` overrides a `settings.conf` that specifies a different model (flag always wins, even when flag names built-in default) | VERIFIED | Behavioral test: same settings.conf + `--whisper-model small`; provenance showed `whisper  = small                    (flag)` — sentinel correctly beats settings.conf when flag names the built-in default |
| SC-4 | A `settings.conf` model that fails to load produces a clear, actionable error pointing to `--benchmark`, not a cryptic failure | VERIFIED (structural) | Three `if ! STAGE_OUT=$(_run_*)` wrappers exist; three `from config/settings.conf could not be loaded` messages gated by `[ "$*_MODEL_SOURCE" = "settings.conf" ]`; full runtime trigger requires human verification (see Human Verification section) |
| SC-5 | Any HF model ID from `candidates.conf` is accepted by the existing stage scripts via `--model` without modifying those scripts | VERIFIED | `git grep -lE 'MODEL_FLAG.*\*/\*'` finds all three stage scripts; phase commits (323e41e, ad5da78, aa2926b, fb97bdc, 6df44a6) touch zero stage-script files |

**Score:** 5/5 truths verified

### Deferred Items

Items not yet met but explicitly addressed in later milestone phases.

| # | Item | Addressed In | Evidence |
|---|------|-------------|----------|
| 1 | `config/candidates.conf` parsed by `benchmark.sh` | Phase 4 | Phase 4 goal is "Benchmark Engine Core"; its success criteria require sweeping candidates.conf. Plan 03-01 explicitly notes this as the "Phase 4 half" of SC-1. |

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `config/candidates.conf` | 13 [candidate] blocks; 4 whisper, 4 cleanup, 5 summarize; real HF IDs; no shell-evaluable syntax | VERIFIED | 13 `[candidate]` headers; 13 valid `stage=` lines; Qwen3-14B uses `id=Qwen/Qwen3-14B-MLX-4bit` (Qwen org); Llama3.3-70B has `size_gb=39.7`; grep finds no `$(`, backticks, `export`, or `;rm` |
| `config/settings.conf.example` | Exactly 3 non-comment KEY= lines: WHISPER/CLEANUP/SUMMARY_MODEL_DEFAULT; committed | VERIFIED | 3 non-comment lines; all match `^(WHISPER|CLEANUP|SUMMARY)_MODEL_DEFAULT=`; total non-comment count = 3 (no 4th key) |
| `.gitignore` | Contains exact line `config/settings.conf`; does NOT ignore `config/settings.conf.example` | VERIFIED | `grep -x 'config/settings.conf' .gitignore` finds line 28; `grep -x 'config/settings.conf.example'` finds nothing |
| `transcribrr.sh` | Sentinel-based three-tier precedence; `WHISPER_MODEL_EXPLICIT`; settings read block; provenance summary; CFG-03 wrappers | VERIFIED | All structural checks pass; `bash -n` clean |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `transcribrr.sh` flag-parse loop | `*_MODEL_EXPLICIT=true` | Each `--*-model` case branch sets `*_EXPLICIT=true` and `*_SOURCE="flag"` | WIRED | `grep -c '_MODEL_EXPLICIT=true'` returns 3; confirmed in lines 107-108, 113-114, 119-120 |
| `transcribrr.sh` settings read block | `config/settings.conf` | `grep "^${1}=" "$SETTINGS_FILE" \| tail -1 \| cut -d= -f2- \|\| true` inside `[ -f "$SETTINGS_FILE" ]` guard, gated on sentinel=false | WIRED | `SETTINGS_FILE="$SCRIPT_DIR/config/settings.conf"` at line 155; anchored grep at line 162; `|| true` fix present; no source/eval of config file |
| `transcribrr.sh` stage invocations | CFG-03 actionable error | `_run_*()` + `if ! STAGE_OUT=$(_run_*)` + `if [ "$*_MODEL_SOURCE" = "settings.conf" ]` | WIRED | 3 `_run_*()` functions; 3 `if ! STAGE_OUT=$(_run_` call sites; 3 error messages gated on `*_MODEL_SOURCE = "settings.conf"`; no `) || {` pattern remaining |
| `candidates.conf` stage values | stage vocabulary `whisper\|cleanup\|summarize` | `stage=` key per `[candidate]` block | WIRED | All 13 `stage=` lines match `^stage=(whisper\|cleanup\|summarize)$`; 4 whisper, 4 cleanup, 5 summarize |
| `.gitignore` entry | `config/settings.conf` | Exact line `config/settings.conf` in `.gitignore` | WIRED | Line 28 of `.gitignore` confirmed |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|-------------------|--------|
| `transcribrr.sh` provenance print | `$WHISPER_MODEL`, `$CLEANUP_MODEL`, `$SUMMARY_MODEL` and `*_SOURCE` vars | Flag-parse loop → settings.conf read block → built-in defaults | Yes — behavioral test confirmed live data flows through all three resolution paths | FLOWING |
| `config/candidates.conf` | `id=`, `label=`, `stage=`, `size_gb=` values | Static data file (vetted at authoring time) | Yes — 13 real HF model IDs verified present | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Settings.conf model selection shown in provenance | Write `WHISPER_MODEL_DEFAULT=turbo` to `config/settings.conf`; run `./transcribrr.sh /tmp/nope.mp3 2>/dev/null \| grep whisper` | `whisper  = turbo                    (settings.conf)` | PASS |
| Flag beats settings.conf (sentinel test, built-in default) | Same settings.conf + `--whisper-model small`; capture provenance whisper line | `whisper  = small                    (flag)` | PASS |
| Temp settings.conf cleaned up after test | `ls config/settings.conf` after test | File not found | PASS |
| Stage scripts unmodified (MODEL-03) | `git show --name-only <phase commits> \| grep stage scripts` | Zero hits | PASS |

### Probe Execution

No probe scripts declared for this phase. Step 7c: SKIPPED (no `scripts/*/tests/probe-*.sh` exists; phase is config + bash edits only).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|---------|
| MODEL-01 | 03-01-PLAN.md | `candidates.conf` lists benchmark candidates per stage with HF ID, label, stage, approx size — parsed not sourced | SATISFIED | `config/candidates.conf` exists; 13 blocks with all four fields; `[candidate]` KEY=value parse-not-source format; no shell-evaluable tokens |
| MODEL-02 | 03-01-PLAN.md | Vetted initial candidate list covering current best-in-class MLX models per stage | SATISFIED | 4 whisper (small, turbo, turbo-4bit, distil-large-v3), 4 cleanup (llama3.2-1b/3b-4bit, llama3.1-8b-4bit, qwen3-8b-4bit), 5 summarize (Qwen2.5-14B/32B-4bit, Qwen3-14B/32B-4bit, Llama3.3-70B-4bit); Qwen3-14B uses corrected Qwen org ID |
| MODEL-03 | 03-02-PLAN.md | Raw HF IDs accepted via `--model`; no stage-script changes needed | SATISFIED | All three stage scripts contain `if [[ "$MODEL_FLAG" == */* ]]` passthrough; zero stage-script edits in phase commits |
| CFG-01 | 03-02-PLAN.md | Normal run reads settings file if present to select default models | SATISFIED | `if [ -f "$SETTINGS_FILE" ]` guard reads each model key via `_read_setting`; behavioral test confirmed |
| CFG-02 | 03-02-PLAN.md | Precedence: CLI flag > settings file > built-in (flag naming built-in default still overrides) | SATISFIED | Sentinel pattern implemented; behavioral test with `--whisper-model small` overriding `WHISPER_MODEL_DEFAULT=turbo` confirmed correct output |
| CFG-03 | 03-02-PLAN.md | Settings-file model that fails to load → actionable error + `--benchmark` hint | SATISFIED (structural) | Three `_run_*()` + `if ! STAGE_OUT=` wrappers with `*_MODEL_SOURCE = "settings.conf"` gating; full runtime trigger deferred to human verification |

**Note:** REQUIREMENTS.md traceability checkboxes for all 6 IDs remain `[ ]` (Pending) — they were not updated to `[x]` after phase completion. This is a housekeeping gap (does not affect phase goal achievement).

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `config/settings.conf.example` | 7 | "Values: friendly labels (e.g. turbo, llama3.1-8b-4bit)" — but 7 of 13 candidates.conf labels are not accepted by stage scripts (WR-01 from code review) | Warning | User-facing: copying turbo-4bit, distil-large-v3, qwen3-8b-4bit, Qwen3-14B-4bit, Qwen3-32B-4bit, or Llama3.3-70B-4bit into settings.conf will produce "Unknown model" failures from stage scripts. The label-vs-id contract is ambiguous. |

No `TBD`, `FIXME`, or `XXX` markers found in any phase-touched file. No `TODO`, `HACK`, or `PLACEHOLDER` markers found.

### Human Verification Required

#### 1. CFG-03 Runtime Error Path

**Test:** Create a `config/settings.conf` with a model label that will fail to load (e.g. `WHISPER_MODEL_DEFAULT=nonexistent-model-xyz`), then run `./transcribrr.sh <valid_audio.mp3>` and observe stderr.

**Expected:** The error output should contain `Error: whisper model 'nonexistent-model-xyz' from config/settings.conf could not be loaded.` followed by `Fix: run \`transcribrr.sh --benchmark\` to reselect, or pass --whisper-model <label|hf-id>.` — and NOT just the generic ERR trap message.

**Why human:** Triggering the `if ! STAGE_OUT=$(_run_transcribe)` failure branch requires the stage script to actually exit non-zero, which requires a real (failed) MLX model load. Cannot simulate without actual inference runtime.

#### 2. WR-01 Label Namespace Consistency (Code Review Finding)

**Test:** Copy each of these labels from `candidates.conf` into `settings.conf` and run a short pipeline:
- `WHISPER_MODEL_DEFAULT=turbo-4bit` (whisper stage)
- `CLEANUP_MODEL_DEFAULT=qwen3-8b-4bit` (cleanup stage)
- `SUMMARY_MODEL_DEFAULT=Qwen3-14B-4bit` (summarize stage)

**Expected (current behavior):** Each of these will likely produce an "Unknown model" error from the respective stage script because the stage scripts' `case` statements do not include these labels — requiring the user to use the raw HF `id=` value from candidates.conf instead.

**Why human:** Requires a real MLX model load to confirm the failure mode. This is correctness/usability: the two new data files (`candidates.conf` labels + `settings.conf.example` "friendly labels" documentation) are inconsistent with what the stage scripts actually accept. The code reviewer (03-REVIEW.md WR-01) flagged this and proposed three fix options. A human decision is needed on whether to fix this in Phase 3 or defer to Phase 4.

### Gaps Summary

No automated-verification gaps. All five observable truths are verified at the structural level, both data files are correct and complete, and the behavioral spot-checks for precedence wiring passed live. The human verification items cover:

1. **CFG-03 runtime trigger** — structural wiring is confirmed, but runtime behavior requires a real failed model load.
2. **WR-01 label namespace** — the candidates.conf label set is broader than what stage scripts accept; a user following the documented workflow (copy a label into settings.conf) will hit "Unknown model" failures for 7 of 13 candidates. This is a correctness gap flagged by the code reviewer but does not block the core precedence/config feature from working when used correctly (with raw HF IDs or accepted labels).

---

_Verified: 2026-06-15_
_Verifier: Claude (gsd-verifier)_
