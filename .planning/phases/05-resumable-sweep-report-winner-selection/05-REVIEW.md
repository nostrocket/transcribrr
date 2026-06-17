---
phase: 05-resumable-sweep-report-winner-selection
reviewed: 2026-06-17T00:00:00Z
depth: standard
files_reviewed: 3
files_reviewed_list:
  - benchmark.sh
  - benchmark_helpers.py
  - test_benchmark_helpers.py
findings:
  critical: 0
  warning: 7
  info: 4
  total: 11
  resolved:
    - CR-01 (4b1682c)
    - CR-02 (20b2773)
    - CR-03 (095d84e)
status: issues_found
---

> **Update 2026-06-17:** All 3 CRITICAL blockers fixed and committed —
> CR-01 `4b1682c` (speed field contract), CR-02 `20b2773` (JSON writer injection),
> CR-03 `095d84e` (resume winner persistence). 7 Warning + 4 Info findings remain
> open for a later pass. CR-03's resume-path behavior should be re-tested on a real TTY.

# Phase 5: Code Review Report

**Reviewed:** 2026-06-17
**Depth:** standard
**Files Reviewed:** 3
**Status:** issues_found

## Summary

Phase 5 adds resume detection, a divergence view, a comparison report, atomic
settings writes, and winner persistence/keep-current to the benchmark sweep.
The atomic-write path (`write_settings_key`) and the parse-not-source pattern
are well executed, and the keep-current sentinel-file design correctly works
around the subshell variable-loss problem.

However, the report subcommand reads the **wrong JSON field** for speed, so the
comparison table that the entire phase exists to produce shows `n/a` for every
candidate's speed on real sweep output — the tests miss this because their
fixtures fabricate a field the real writer never emits. There are also genuine
JSON-injection / heredoc-corruption vectors in the result writers (which
explicitly claim to be injection-safe but are not), and a resume-correctness gap
where the keep-current settings write is silently lost on resume.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: Report reads non-existent speed field → every speed shows `n/a`

**File:** `benchmark_helpers.py:373-392` (consumer) vs `benchmark.sh:746-768` (producer)
**Issue:**
`write_success_json` writes the speed as two fields:
```
"speed_metric": "$speed_metric",   # "rtf" or "tok_per_s"
"speed_value":  $speed_value,
```
But `_format_speed()` never looks at `speed_value`/`speed_metric`. For whisper
it reads `candidate.get('rtf')`; for cleanup/summarize it tries
`('tok_per_s','toks_per_s','tokens_per_s','speed')`. None of those keys exist in
the real result JSON, so the function falls through to `return 'n/a'` for **every
candidate** in both the terminal table and `report.md`.

Reproduced with a realistic result JSON (`speed_value: 0.123, speed_metric: "rtf"`):
```
whisper     turbo     Speed: n/a     Mem: 2.0GB     fit
| turbo | n/a | 2.0GB | fit |
```
The existing tests pass only because `test_report_3whisper_jsons` fabricates an
`rtf` key that the production writer never produces — the test fixture does not
match the real on-disk contract. This defeats the core purpose of the report
(comparing speeds to choose a winner).

**Fix:** Read the canonical fields written by `write_success_json`:
```python
def _format_speed(candidate, stage):
    metric = candidate.get('speed_metric')
    val = candidate.get('speed_value')
    if val is None:
        return 'n/a'
    try:
        fval = float(val)
    except (ValueError, TypeError):
        return str(val)
    if metric == 'rtf':
        return f"RTF={fval:.3f}"
    return f"{fval:.1f} tok/s"
```
Update `test_report_3whisper_jsons` to emit `speed_metric`/`speed_value` so the
fixture matches the real contract and would have caught this.

### CR-02: Result-JSON writers interpolate untrusted values into Python source (injection / corruption)

**File:** `benchmark.sh:746-768`, `770-800`, `802-822`, and `1598-1615` (sweep_meta)
**Issue:**
`write_success_json`, `write_error_json`, `write_skip_json`, and the
`sweep_meta.json` writer all use an **unquoted** heredoc (`"$PYTHON" - << PYEOF`,
no quotes around `PYEOF`) and embed shell values directly into the Python source:
```python
"output_file": "$output_file",
"candidate_id": "$model_id",
"label": "$label",
```
The file's own header (lines 727-730) claims: *"ALL JSON is generated via Python
json module — NEVER shell string concatenation … Model output (transcript text,
file paths) may contain quotes/newlines/backslashes."* The implementation
violates that contract — the **values** are concatenated into source text before
Python ever runs. Any `"`, newline, or backslash in `output_file`, `label`,
`model_id`, or `BENCH_SAMPLE_URL` either crashes the writer (`SyntaxError`,
verified) or, with a crafted value, executes arbitrary Python.

`output_file` comes from the stage scripts' `OUTPUT_FILE=` line, derived from a
basename + model label; `model_id`/`label` come from `candidates.conf`;
`sample_url` comes from `--sample`. None is hard-locked — a label with a quote in
`candidates.conf`, or a `--sample` URL containing a quote, corrupts or injects.
Contrast with `persist_pick` (line 412) and `write_settings_key` (line 483),
which correctly pass values via `sys.argv` — that pattern should be used here too.

**Fix:** Pass every interpolated value as a `sys.argv` argument and read it inside
the quoted heredoc, e.g.:
```bash
"$PYTHON" - "$model_id" "$label" "$stage" "$speed_metric" "$speed_value" \
            "$peak_bytes" "$peak_gb" "$wall_time" "$audio_duration_sec" \
            "$output_file" "$result_json_path" "$warmup_wall" << 'PYEOF'
import json, datetime, sys
(model_id,label,stage,metric,val,pb,pg,wt,ad,of,rjp,ww) = sys.argv[1:13]
data = {
    "format_version": 1, "candidate_id": model_id, "label": label,
    "stage": stage, "run_ts": datetime.datetime.now().isoformat(timespec='seconds'),
    "fit_status": "fit", "error": None,
    "speed_metric": metric, "speed_value": float(val),
    "peak_mem_bytes": int(pb), "peak_mem_gb": float(pg),
    "wall_time_sec": int(wt),
    "audio_duration_sec": (None if ad == "None" else float(ad)),
    "output_file": of, "warmup_wall_sec": int(ww),
}
with open(rjp, "w") as f: json.dump(data, f, indent=2)
PYEOF
```
Apply the same `'PYEOF'` + `sys.argv` conversion to `write_error_json`,
`write_skip_json`, and the `sweep_meta.json` writer (lines 1598-1615).

### CR-03: Keep-current on resume silently fails to persist the winner to settings.conf

**File:** `benchmark.sh:1337-1370` (and the identical cleanup 1459-1478 / summarize 1568-1587 blocks)
**Issue:**
On resume, when a stage pick was already recorded in `picks.json`, the code takes
the early branch:
```bash
if [ "$RESUMING" = true ] && [ -n "$SELECTED_TRANSCRIPT" ]; then
    echo "  (Resume) whisper pick already recorded: $SELECTED_TRANSCRIPT" >&2
    rm -f "$WHISPER_RESULTS_LIST"
else
    ... persist_pick + write_settings_key ...
fi
```
`picks.json` records the *output_file path*, but `write_settings_key` (the durable
winner persistence into `config/settings.conf`) only runs in the `else` branch.
If the run was interrupted **after** `persist_pick` but **before**
`write_settings_key` — or simply across any resume — the resumed run skips
`write_settings_key` entirely. The settings default for that stage is therefore
never written, even though the user picked a winner. The phase goal ("winner
persistence") is not met on the resume path. There is also no way on resume to
re-derive `_WHISPER_WINNER_LABEL` (the friendly label), because the results list
file is deleted without being consulted.

**Fix:** On the resume-skip branch, still reconcile `settings.conf`. Re-derive the
winner label from the per-candidate result JSONs (or store the label, not just the
path, in `picks.json`) and call `write_settings_key` unless a keep-current
sentinel/marker indicates the user kept the current default. Persisting the
*label* in `picks.json` (e.g. `picks[stage] = {"output": ..., "label": ...}`)
removes the need to keep the deleted list file alive.

## Warnings

### WR-01: `should_skip_pair` reads JSON via shell-interpolated path (set -e / quote fragility)

**File:** `benchmark.sh:385-386`, and the inline readers at `1301-1325`, `1424-1448`, `1533-1557`, `429-431`
**Issue:** Numerous helpers build Python one-liners by interpolating a path into
`open('$json_path')`. A run directory or label containing a single quote breaks
the Python literal. `RUN_DIR` derives from a timestamp (safe today) and `label`
from `candidates.conf`, but this is the same class of defect as CR-02 and is
fragile against future config changes. The `|| echo "..."` guards also mean a
genuine JSON read failure is silently treated as "no error" → a failed candidate
can be misclassified as successful.
**Fix:** Use `sys.argv` for the path (`"$PYTHON" -c 'import json,sys; ...' "$json_path"`),
and distinguish "file unreadable" from "error field empty" rather than collapsing
both to empty string.

### WR-02: Divergence/outlier result depends on file argument order (anchor bias)

**File:** `benchmark_helpers.py:239-246`, `496-502`
**Issue:** The alignment anchor is always `labels[0]` (the first transcript). All
other candidates are aligned to it, and outlier counts are computed relative to
that anchor's sentence positions. A different ordering of `--transcripts` can
yield different divergent positions and different outlier counts for the same set
of files. The "majority consensus" claim in the docstring is therefore only
partly true — consensus is computed per anchor-position, and positions only
present in non-anchor transcripts (difflib `insert` ops) are dropped entirely
(line 123 comment confirms `insert`/`delete` positions are treated as missing),
so content unique to non-anchor models is invisible.
**Fix:** Document the anchor-bias limitation explicitly in user-facing output, or
choose the anchor deterministically (e.g. the longest transcript) and account for
`insert` opcodes so non-anchor-only content is not silently dropped.

### WR-03: `_compute_divergence_summary` 2-candidate branch computes then discards work

**File:** `benchmark_helpers.py:526-536`
**Issue:** The `else` (2-candidate) branch loops over all positions accumulating
`n_divergent`, then unconditionally `return None`. The entire loop is dead — its
result is never used. This is wasted work and misleading (a reader assumes the
count is reported somewhere). It also means `report.md` shows no divergence info
at all for the common 2-transcript case.
**Fix:** Either delete the dead loop, or surface the 2-candidate divergence count
in `report.md` (consistent with the `run_divergence` 2-candidate summary at
lines 296-300).

### WR-04: `write_settings_key` is non-atomic against concurrent writers / leaves no fsync

**File:** `benchmark.sh:477-506`
**Issue:** `mktemp` + `mv` gives atomic *replacement* on the same filesystem
(correct), but the temp file is removed from `_BENCH_TMPFILES` via
`"${_BENCH_TMPFILES[@]/$tmp_conf/}"` which replaces the matching element with an
**empty string** rather than removing it. The array retains an empty-string
element; a later `_bench_cleanup` calls `rm -f "" ...` (harmless but sloppy), and
if two stages both wrote, stale empty entries accumulate. More importantly there
is no `os.fsync`/`f.flush` before `mv`, so a crash between write and rename can
leave a zero-length temp (mitigated by mv atomicity, but the new content may not
be durable).
**Fix:** Rebuild the array excluding the matched element:
```bash
local _kept=(); local _f
for _f in "${_BENCH_TMPFILES[@]}"; do [ "$_f" = "$tmp_conf" ] || _kept+=("$_f"); done
_BENCH_TMPFILES=("${_kept[@]+"${_kept[@]}"}")
```
and add `f.flush(); os.fsync(f.fileno())` before closing the temp file in the
Python writer.

### WR-05: `detect_incomplete_run` find-without-`-print` relies on grep of default output

**File:** `benchmark.sh:369`
**Issue:** `find "$most_recent" -name '*_result.json' -maxdepth 2 | grep -q .`
places `-maxdepth` after `-name`; GNU find warns and BSD/macOS find accepts it,
but ordering `-maxdepth` after a test is non-portable and on some `find`
implementations changes evaluation. Functionally works on macOS BSD find today,
but is brittle.
**Fix:** Put options before tests: `find "$most_recent" -maxdepth 2 -name '*_result.json' | grep -q .`

### WR-06: Resume completeness gate keys only on `sweep_meta.json`, ignoring partial picks

**File:** `benchmark.sh:356-373`
**Issue:** A run that completed the full sweep but crashed during report generation
(after `sweep_meta.json` was written at line 1612 but the report failed) is
treated as **complete** and is never offered for resume — even though the user may
want to regenerate the report. Conversely a run interrupted mid-`write_settings_key`
(CR-03) is resumable but won't re-persist settings. The completeness contract and
the persistence path are not aligned.
**Fix:** Gate resumability on a more precise completion marker (e.g. existence of
`report.md` AND `sweep_meta.json`), and make the resume path idempotently
re-run report generation + settings reconciliation.

### WR-07: `read -r selection` in `select_best` can consume the candidate's stdin / EOF loops forever

**File:** `benchmark.sh:1174-1205`
**Issue:** The validation loop has no EOF guard. If stdin reaches EOF while the
loop is active (e.g. the TTY is closed, or the earlier `</dev/null` redirections
on `run_candidate` leave the prompt reading from an exhausted stream), `read -r`
returns non-zero with an empty `selection`; the regex check fails, prints
"Invalid input", and `continue`s — an **infinite loop** printing the error with no
way to break. The TTY guard at line 90 only checks at startup.
**Fix:** Break out on `read` failure:
```bash
if ! read -r selection; then
    echo "  Error: end of input while awaiting selection." >&2
    exit 1
fi
```

## Info

### IN-01: Inline Python JSON readers duplicated 12+ times

**File:** `benchmark.sh:1301-1325`, `1424-1448`, `1533-1557`
**Issue:** The three stage loops each repeat four nearly identical `"$PYTHON" -c`
blocks to extract `error`/`output_file`/`speed_value`/`peak_mem_gb`. ~150 lines of
duplicated logic that must be kept in sync.
**Fix:** Factor into a helper (`_read_result_field <json_path> <key>`) or a single
Python invocation returning a pipe-delimited line, and reuse across stages.

### IN-02: `_format_mem` / report fields not validated against writer contract

**File:** `benchmark_helpers.py:395-403`
**Issue:** Like CR-01, `_format_mem` reads `peak_mem_gb` which the writer does
produce (correct here), but there is no shared schema/constant between writer and
reader. A single source of truth for field names would prevent CR-01-class drift.
**Fix:** Define the result-JSON field names as module constants shared (in spirit)
with the bash writers; add an assertion test that round-trips a real
`write_success_json` output through `_format_speed`/`_format_mem`.

### IN-03: `strip_header` skips only one blank line and only if `i > 0`

**File:** `benchmark_helpers.py:62-65`
**Issue:** If a transcript has no header lines but starts with a blank line, the
`i > 0` guard means the leading blank is not skipped; if there are multiple blank
lines after the header only one is removed. Minor — affects sentence splitting
edge cases, not correctness of the divergence verdict in practice.
**Fix:** Skip all consecutive leading blank lines after the header block.

### IN-04: `_RESUME_ANSWER` default differs from displayed prompt semantics

**File:** `benchmark.sh:1057-1059`
**Issue:** Prompt shows `[Y/n]` and `${_RESUME_ANSWER:-Y}` defaults empty input to
resume — correct. But a stray non-empty, non-Y/n answer (e.g. "yes\n more")
falls through to the `*)` case and starts a fresh run, silently discarding the
in-progress run the user may have wanted to resume. Low impact; worth a re-prompt.
**Fix:** Loop on unrecognized input instead of defaulting to fresh-run.

---

_Reviewed: 2026-06-17_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
