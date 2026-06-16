# Phase 5: Resumable Sweep, Report & Winner Selection — Pattern Map

**Mapped:** 2026-06-16
**Files analyzed:** 8 functional units (7 new bash functions/blocks in `benchmark.sh` + 1 new Python helper file)
**Analogs found:** 8 / 8 (all units have close analogs in the codebase)

---

## File Classification

| New/Modified Unit | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `benchmark.sh`: `detect_incomplete_run()` + RUN_DIR wrap | utility/control | request-response | `benchmark.sh:335–341` `is_incomplete()` + `benchmark.sh:872–874` RUN_DIR assignment | role-match |
| `benchmark.sh`: `should_skip_pair()` | utility/control | request-response | `benchmark.sh:335–341` `is_incomplete()` membership test | role-match |
| `benchmark.sh`: `persist_pick()` / `load_picks()` | utility | CRUD | `benchmark.sh:580–601` `write_success_json()` Python-inline JSON writer | exact |
| `benchmark.sh`: `write_settings_key()` | utility | file-I/O | `transcribrr.sh:610–647` atomic temp+mv write | exact |
| `benchmark.sh`: `select_best()` extension (keep-current + D-09) | utility | request-response | `benchmark.sh:893–948` `select_best()` itself | exact (self-extension) |
| `benchmark.sh`: divergence-view invocation block | control | event-driven | `benchmark.sh:1030–1061` Python inline read block (whisper JSON extraction) | role-match |
| `benchmark.sh`: BENCH-09 disk-gate one-line fix (line 388) | utility | request-response | `benchmark.sh:244–298` `verify_model_complete()` (the target function) | exact |
| `benchmark_helpers.py` (new file) | utility | transform/batch | `benchmark.sh:580–656` Python-inline JSON writers (same `$PYTHON` invocation model) | role-match |

---

## Pattern Assignments

### `benchmark.sh`: `detect_incomplete_run()` — resume detection, RUN_DIR wrapping

**Analog:** `benchmark.sh:335–341` `is_incomplete()` — same "scan a collection, return boolean/value" pattern. Also `benchmark.sh:872–874` for the RUN_DIR assignment being wrapped.

**Existing RUN_DIR assignment** (`benchmark.sh:870–875`):
```bash
CURRENT_STAGE="run-dir-setup"

RUN_TS=$(date '+%Y%m%dT%H%M%S')
RUN_DIR="$RESULTS_DIR/benchmark_${RUN_TS}"
mkdir -p "$RUN_DIR/whisper" "$RUN_DIR/cleanup" "$RUN_DIR/summarize"
echo "Results directory: $RUN_DIR"
```
This block is the insertion point. Resume detection runs before line 872; the `RUN_TS`/`RUN_DIR` assignment becomes conditional.

**Analog: `is_incomplete()` scan pattern** (`benchmark.sh:335–341`):
```bash
is_incomplete() {
    local want="$1" m
    for m in ${INCOMPLETE_IDS[@]+"${INCOMPLETE_IDS[@]}"}; do
        [ "$m" = "$want" ] && return 0
    done
    return 1
}
```
Note the `${ARRAY[@]+"${ARRAY[@]}"}` guard for bash 3.2 set -u safety — new arrays in Phase 5 must use the same pattern.

**Analog: `ls -td` / `find` pattern** (`benchmark.sh:420–447` pre-fetch loop uses `find`; `is_model_cached:230–235` uses `ls -A`):
```bash
is_model_cached() {
    local model_id="$1"
    local cache_name="models--$(echo "$model_id" | sed 's|/|--|g')"
    local snapshots_dir="$HF_CACHE/$cache_name/snapshots"
    [ -d "$snapshots_dir" ] && [ -n "$(ls -A "$snapshots_dir" 2>/dev/null)" ]
}
```
The `ls -A` existence check idiom is the codebase's standard for "directory has content"; adapt to `ls -td results/benchmark_*/` for run-dir detection.

**RESUMING variable + `mkdir -p` guard:** The existing `mkdir -p "$RUN_DIR/whisper" …` at line 874 must only run when NOT resuming. The new `RESUMING=false` / `RESUMING=true` variable follows the existing boolean-variable convention (`NO_CLEANUP`, `BENCHMARK_MODE` etc. in `transcribrr.sh`).

---

### `benchmark.sh`: `should_skip_pair()` — per-pair resume skip/re-run decision

**Analog:** `benchmark.sh:1030–1061` JSON read block (whisper stage result extraction). This is the exact pattern for reading a per-candidate result JSON via an inline `"$PYTHON" -c`.

**Existing JSON field extraction pattern** (`benchmark.sh:1031–1055`):
```bash
CAND_ERROR=$("$PYTHON" -c "
import json
with open('$RUN_DIR/whisper/${label}_result.json') as f:
    d = json.load(f)
print(d.get('error') or '')
" 2>/dev/null || echo "read_error")
```
`should_skip_pair` reads `fit_status` and `error` from the same JSON schema. Use the same `"$PYTHON" -c` inline pattern with `2>/dev/null || echo ""` fallback.

**JSON schema confirmed from real data** (fit_status / error fields):
- Success JSON: `fit_status="fit"`, `error=null`
- Error JSON: `fit_status="fit"`, `error="subprocess_nonzero"`
- Skip JSON: `fit_status="skip"`, no `error` key (or absent)

The `should_skip_pair` function reads `fit_status` first (skip → always skip) then `error` (null → skip; non-null → re-run). Use `2>/dev/null || echo ""` on the Python call to avoid `set -e` abort when the JSON is malformed.

---

### `benchmark.sh`: `persist_pick()` / `load_picks()` — stage pick persistence for resume

**Analog:** `benchmark.sh:580–601` `write_success_json()` — the canonical pattern for "write structured data to a JSON file via `$PYTHON` heredoc".

**Analog pattern** (`benchmark.sh:580–601`):
```bash
write_success_json() {
    local model_id="$1"
    # ...
    "$PYTHON" - << PYEOF
import json, datetime
data = {
    "format_version":      1,
    "candidate_id":        "$model_id",
    # ...
}
with open("$result_json_path", "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}
```
`persist_pick` writes one key to a `picks.json` dict (read-modify-write). `load_picks` reads with `"$PYTHON" -c` (same inline pattern as the JSON read blocks at lines 1031–1055).

**Important:** `persist_pick` uses read-modify-write (not truncate-write) because multiple stages write to the same `picks.json`. The `write_success_json` analog is truncate-write; adapt by wrapping with a try/except read of the existing file first — exactly as RESEARCH Pattern 4 shows.

**Key difference from write_success_json:** `persist_pick` takes `sys.argv` for the mutable values to avoid heredoc shell injection. See RESEARCH Assumption A1 note — test the `"$PYTHON" - arg1 arg2 << 'PYEOF'` bash 3.2 argument-passing explicitly before relying on it; fallback is a temp arg file.

---

### `benchmark.sh`: `write_settings_key()` — atomic settings.conf write

**Analog:** `transcribrr.sh:610–647` — the atomic temp+mv markdown write. This is the exact pattern to copy.

**Atomic write pattern** (`transcribrr.sh:610–647`):
```bash
TEMP_MD=$(mktemp)
# EXIT trap removes the temp file on premature exit; cleared after successful mv (ROB-03).
trap 'rm -f "$TEMP_MD"' EXIT

# ... write content to TEMP_MD ...
{
    printf "# %s\n\n" "$_VID_TITLE"
    # ...
} > "$TEMP_MD"

# Atomic move: FINAL_MD_PATH exists only after full success (T-02-05 / ROB-03).
mv "$TEMP_MD" "$FINAL_MD_PATH"
trap - EXIT  # temp file safely moved; remove cleanup trap
```

**Critical adaptation for `write_settings_key`:**

1. `mktemp` MUST use a path within `$SCRIPT_DIR/config/` — not the default `/tmp/`. macOS `/tmp` is a separate tmpfs; `mv` across filesystems is not atomic. Use `mktemp "$SCRIPT_DIR/config/.settings_tmp_XXXXXX"`.

2. Register the temp file in `_BENCH_TMPFILES` (the benchmark.sh EXIT-trap array at line 50–52) instead of a local trap, to align with benchmark.sh's cleanup discipline:
```bash
_BENCH_TMPFILES=()
_bench_cleanup() { [ ${#_BENCH_TMPFILES[@]} -gt 0 ] && rm -f "${_BENCH_TMPFILES[@]}" 2>/dev/null; return 0; }
trap '_bench_cleanup' EXIT
```

3. The `transcribrr.sh` analog writes a fresh file. `write_settings_key` must read-modify-write (preserve other keys). Use Python for the merge (see RESEARCH Pattern 5 and "Don't Hand-Roll" table — `sed -i` has macOS/GNU flag incompatibility).

4. `mkdir -p "$SCRIPT_DIR/config"` guard before the write (the `config/` dir exists here, but `settings.conf` may not).

**settings.conf format** (`config/settings.conf.example:9–11`):
```
WHISPER_MODEL_DEFAULT=turbo
CLEANUP_MODEL_DEFAULT=llama3.1-8b-4bit
SUMMARY_MODEL_DEFAULT=Qwen2.5-32B-4bit
```
The parse-not-source reader in `transcribrr.sh:184–210` uses `grep "^${1}=" | tail -1 | cut -d= -f2-`. The writer must produce lines in the same `KEY=value` format (no spaces around `=`, no quotes).

---

### `benchmark.sh`: `select_best()` extension — "keep current" menu entry (D-09)

**Analog:** `benchmark.sh:893–948` `select_best()` itself — this is a self-extension.

**Existing `select_best` function** (`benchmark.sh:893–948`):
```bash
select_best() {
    local stage="$1"
    local list_file="$2"

    local count
    count=$(wc -l < "$list_file" | tr -d ' ')

    if [ "$count" -eq 0 ]; then
        echo "" >&2
        echo "Error: No successful candidates in stage '$stage' — cannot continue." >&2
        exit 1
    fi

    # Menu + prompt go to STDERR — STDOUT is captured by caller's $(...)
    echo "" >&2
    echo "  ── ${stage} stage: ${count} transcript(s) ──..." >&2

    local i=0
    while IFS='|' read -r cand_label cand_output cand_speed cand_peak; do
        i=$((i + 1))
        printf "  [%d] %-22s  %s   peak %s GB\n" "$i" "$cand_label" "$cand_speed" "$cand_peak" >&2
        printf "      %s\n" "$cand_output" >&2
    done < "$list_file"

    echo "" >&2

    local selection
    while true; do
        printf "  Select the best [1-%d]: " "$count" >&2
        read -r selection

        if ! echo "$selection" | grep -qE '^[0-9]+$'; then
            echo "  Invalid input: ..." >&2
            continue
        fi
        if [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ]; then
            echo "  Out of range: ..." >&2
            continue
        fi
        break
    done

    # Return selected output_file (field 2) to stdout — ONLY output on stdout
    sed -n "${selection}p" "$list_file" | cut -d'|' -f2
}
```

**Key patterns to preserve on extension:**
- All menu/prompt output goes to stderr (`>&2`). The divergence view invocation inserted before this call MUST also write only to stderr (Pitfall 2).
- Only the selected file path goes to stdout (line 947: `sed -n "${selection}p" … | cut -d'|' -f2`).
- Validation loop re-prompts on invalid input — extend the valid-input set to include `k`/`K` for keep-current.
- The function receives a 3rd argument for the current default label (RESEARCH open question 2): `select_best "whisper" "$WHISPER_RESULTS_LIST" "$CURRENT_WHISPER_DEFAULT"`.

**"Keep current" addition points:**
- After the numbered list, conditionally print `  [k] Keep current ($CURRENT_DEFAULT_LABEL)` >&2.
- In the validation loop: add `k|K)` branch. Find matching candidate line by label grep on `$list_file`; return that candidate's `output_file` on stdout. If no match → the `[k]` entry was not offered (D-09 guard).
- `grep -m1 "^${CURRENT_DEFAULT_LABEL}|"` on the list file to find the matching output_file.

---

### `benchmark.sh`: divergence-view invocation block (before whisper `select_best`)

**Analog:** `benchmark.sh:1030–1061` — the whisper JSON extraction block that builds `WHISPER_RESULTS_LIST`. This block already iterates the per-candidate JSONs and extracts `output_file` paths; the divergence-view invocation reads those same paths.

**Existing pattern for building the transcript list** (`benchmark.sh:1030–1061`, excerpt):
```bash
if [ -f "$RUN_DIR/whisper/${label}_result.json" ]; then
    CAND_ERROR=$("$PYTHON" -c "
import json
with open('$RUN_DIR/whisper/${label}_result.json') as f:
    d = json.load(f)
print(d.get('error') or '')
" 2>/dev/null || echo "read_error")
    if [ -z "$CAND_ERROR" ]; then
        CAND_OUTPUT=$("$PYTHON" -c "
import json
with open('$RUN_DIR/whisper/${label}_result.json') as f:
    d = json.load(f)
print(d.get('output_file',''))
" 2>/dev/null || echo "")
        # ...
        if [ -n "$CAND_OUTPUT" ] && [ -f "$CAND_OUTPUT" ]; then
            printf '%s|%s|%s|%s\n' "$label" "$CAND_OUTPUT" "$CAND_SPEED" "$CAND_PEAK" \
                >> "$WHISPER_RESULTS_LIST"
        fi
    fi
fi
```

**Important note — output_file paths are absolute and outside RUN_DIR** (RESEARCH Pitfall 7, verified from real data):
The `output_file` field points to e.g. `/Users/gareth/git/transcribrr/results/sample_EWo7-azGHic_transcript_whisper-large-v3-turbo.txt` — NOT inside `results/benchmark_<ts>/whisper/`. The divergence view must read from `output_file` in each JSON, not from paths constructed relative to `RUN_DIR`.

**Divergence invocation pattern:**
```bash
# Build args from WHISPER_RESULTS_LIST (already populated at this point)
DIVERG_ARGS=()
while IFS='|' read -r cand_label cand_output _rest; do
    [ -f "$cand_output" ] && DIVERG_ARGS+=("${cand_label}:${cand_output}")
done < "$WHISPER_RESULTS_LIST"

if [ ${#DIVERG_ARGS[@]} -ge 2 ]; then
    "$PYTHON" "$SCRIPT_DIR/benchmark_helpers.py" divergence \
        --transcripts "${DIVERG_ARGS[@]}" \
        --term-width "$(tput cols 2>/dev/null || echo 80)" >&2
fi
# Then existing select_best call:
SELECTED_TRANSCRIPT=$(select_best "whisper" "$WHISPER_RESULTS_LIST")
```

Note the `${#DIVERG_ARGS[@]}` array-length check uses `#` not direct expansion — consistent with the empty-array guard pattern (`${INCOMPLETE_IDS[@]+"${INCOMPLETE_IDS[@]}"}` at line 337).

---

### `benchmark.sh`: BENCH-09 disk-gate one-line fix (line 388)

**The change:** `benchmark.sh:388` — change `is_model_cached` to `verify_model_complete`.

**Current code** (`benchmark.sh:385–391`):
```bash
NEEDED_GB_F="0"
for i in "${!FITTING_IDS[@]}"; do
    model_id="${FITTING_IDS[$i]}"
    size_gb="${FITTING_SIZES[$i]}"
    if ! is_model_cached "$model_id"; then
        NEEDED_GB_F=$(awk "BEGIN{printf \"%.3f\", $NEEDED_GB_F + $size_gb}")
    fi
done
```

**Change:** Line 388: `if ! is_model_cached "$model_id"; then` → `if ! verify_model_complete "$model_id"; then`

Both functions have identical signature: `function_name "$model_id"`, return 0 (present/complete) or 1 (absent/incomplete). `is_model_cached` is at line 230–235; `verify_model_complete` is at line 244–298. No other change needed. The pre-fetch loop at line 411+ already uses `verify_model_complete` — this fix makes the disk gate consistent with it.

---

### `benchmark_helpers.py` (new file) — Python helper for alignment, rendering, report

**Analog:** `benchmark.sh:580–656` Python-inline JSON writers — establishes the `$PYTHON` invocation convention and `json.dump` for all structured output. Also `benchmark.sh:244–298` `verify_model_complete()` inline Python block — establishes the pattern for reading JSON + `os.path` operations from inline Python.

**Existing inline Python invocation model** (`benchmark.sh:260–283`):
```bash
probe=$("$PYTHON" - "$snap" <<'PY' 2>/dev/null
import json, os, sys
snap = sys.argv[1]
try:
    with open(os.path.join(snap, "model.safetensors.index.json")) as f:
        idx = json.load(f)
    # ...
    print("complete")
except Exception as e:
    sys.stderr.write("verify error: %s\n" % e)
    print("incomplete")
PY
)
```
Key pattern: `"$PYTHON" - "$arg" << 'PYEOF'` (single-quote heredoc = no shell expansion inside) + `sys.argv[1]` for the argument. Note RESEARCH Assumption A1: this bash 3.2 arg-passing pattern needs an explicit test before relying on it in `write_settings_key`; for `benchmark_helpers.py` (a standalone file invoked via `"$PYTHON" "$SCRIPT_DIR/benchmark_helpers.py" subcommand --args`), there is no heredoc ambiguity.

**Python helper invocation pattern** (from RESEARCH Pattern 3):
```bash
"$PYTHON" "$SCRIPT_DIR/benchmark_helpers.py" divergence \
    --transcripts "${DIVERG_ARGS[@]}" \
    --term-width "$(tput cols 2>/dev/null || echo 80)" >&2

"$PYTHON" "$SCRIPT_DIR/benchmark_helpers.py" report \
    --run-dir "$RUN_DIR" \
    --term-width "$(tput cols 2>/dev/null || echo 80)"
```

**Python path convention:** `$PYTHON` is already defined as `"$VENV_DIR/bin/python"` at `benchmark.sh:19`. `benchmark_helpers.py` is at `$SCRIPT_DIR/benchmark_helpers.py` (repo root, same level as `benchmark.sh`).

**stderr discipline:** The divergence view and terminal table MUST write to `sys.stderr`, not `sys.stdout`. `select_best` captures stdout of its subprocess chain — any stdout pollution corrupts `SELECTED_TRANSCRIPT`. The bash invocation has an explicit `>&2` redirect as belt-and-suspenders.

**report.md write target:** `$RUN_DIR/report.md` — passed via `--run-dir`. The Python helper constructs the path as `os.path.join(run_dir, 'report.md')`. No atomic temp+mv needed for `report.md` (it is written last, after the interactive sweep; the run is already functionally complete when it is written; atomic semantics apply only to `settings.conf` per D-07).

---

## Shared Patterns

### `$PYTHON` invocation discipline
**Source:** `benchmark.sh:19` (`PYTHON="$VENV_DIR/bin/python"`) + `benchmark.sh:580–656` (all JSON writers)
**Apply to:** All new bash functions that invoke Python (`persist_pick`, `load_picks`, `write_settings_key`, divergence-view block, report invocation)
```bash
PYTHON="$VENV_DIR/bin/python"
# Always: "$PYTHON" — never bare python3 or python
# Inline heredoc (no shell expansion): "$PYTHON" - << 'PYEOF' ... PYEOF
# Inline with args: "$PYTHON" - "$arg1" "$arg2" << 'PYEOF' ... PYEOF  (test A1 first)
# Standalone file: "$PYTHON" "$SCRIPT_DIR/benchmark_helpers.py" subcommand --flags
```

### Bash 3.2 array safety (`set -u` guard)
**Source:** `benchmark.sh:337`
**Apply to:** All new arrays that may be empty (`DIVERG_ARGS`, any resume-phase arrays)
```bash
# WRONG under set -u when array is empty:
"${MY_ARRAY[@]}"
# CORRECT:
${MY_ARRAY[@]+"${MY_ARRAY[@]}"}
```

### `_BENCH_TMPFILES` EXIT-trap registration
**Source:** `benchmark.sh:50–53`
**Apply to:** `write_settings_key` temp file; any other mktemp allocations in new functions
```bash
_BENCH_TMPFILES=()
_bench_cleanup() { [ ${#_BENCH_TMPFILES[@]} -gt 0 ] && rm -f "${_BENCH_TMPFILES[@]}" 2>/dev/null; return 0; }
trap '_bench_cleanup' EXIT
# Registration pattern:
local tmp_file
tmp_file=$(mktemp "$SCRIPT_DIR/config/.settings_tmp_XXXXXX")
_BENCH_TMPFILES+=("$tmp_file")
```

### `SCRIPT_DIR`-relative paths
**Source:** `benchmark.sh:14–24`
**Apply to:** All new file paths (`benchmark_helpers.py`, `config/settings.conf`, `results/`)
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANDIDATES_CONF="$SCRIPT_DIR/config/candidates.conf"
RESULTS_DIR="$SCRIPT_DIR/results"
# New additions follow the same pattern:
# "$SCRIPT_DIR/benchmark_helpers.py"
# "$SCRIPT_DIR/config/settings.conf"
```

### Stderr-only output from interactive functions
**Source:** `benchmark.sh:893–948` `select_best` — all prompts/display to stderr; only the selected path on stdout
**Apply to:** Divergence view Python call, terminal table Python call, "keep current" menu extension
```bash
# All display:
echo "..." >&2
printf "..." >&2
"$PYTHON" "$SCRIPT_DIR/benchmark_helpers.py" divergence ... >&2
# Return value only on stdout (captured by caller)
```

### Parse-not-source for `settings.conf`
**Source:** `transcribrr.sh:184–210`
**Apply to:** Reading current defaults in `select_best` extension and resume (`load_picks`)
```bash
_read_setting() {
    grep "^${1}=" "$SETTINGS_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
```
Use this pattern (or a direct equivalent) to read `WHISPER_MODEL_DEFAULT` / `CLEANUP_MODEL_DEFAULT` / `SUMMARY_MODEL_DEFAULT` at sweep start for the "keep current" detection. Never `source` the file.

### Continue-on-failure (set +e / set -e bracket)
**Source:** `benchmark.sh:730–845` `run_candidate()` — `set +e` around subprocess invocations
**Apply to:** Python helper calls that are non-fatal (`should_skip_pair` JSON read, divergence view, `persist_pick`)
```bash
set +e
"$PYTHON" "$SCRIPT_DIR/benchmark_helpers.py" divergence ... >&2
HELPER_EXIT=$?
set -e
if [ "$HELPER_EXIT" -ne 0 ]; then
    echo "  Warning: divergence view failed (exit $HELPER_EXIT) — continuing." >&2
fi
```

### Float arithmetic via awk (bash 3.2 — no floats in `(( ))`)
**Source:** `benchmark.sh:358–362`, `benchmark.sh:393`
**Apply to:** Any numeric comparisons in the report/table (RTF, tok/s, peak_mem_gb are floats)
```bash
FIT=$(awk "BEGIN {
    estimate = $size_gb + $BENCH_OVERHEAD_BUFFER_GB
    if (estimate <= $USABLE_GB) print \"fit\"
    else print \"skip\"
}")
```

---

## No Analog Found

All Phase 5 functional units have close analogs in the existing codebase. No unit requires falling back to RESEARCH.md patterns alone.

| Unit | Closest analog gap |
|------|-------------------|
| `benchmark_helpers.py` divergence alignment logic | No Python source files exist in repo; algorithm patterns are from RESEARCH Pattern 1 (difflib.SequenceMatcher — stdlib, no install). The invocation contract (stdin/stderr discipline, `sys.argv`) is fully analogized from inline Python blocks in `benchmark.sh`. |
| `benchmark_helpers.py` column rendering | Same as above — `textwrap.fill` is stdlib; the rendering contract is analogized from the stderr discipline of `select_best`. |

---

## Verified Line Numbers (as of 2026-06-16, benchmark.sh at 1267 lines)

| Landmark | Verified Line |
|----------|--------------|
| `SCRIPT_DIR` + `PYTHON` path constants | 14, 19 |
| `_BENCH_TMPFILES` init + `_bench_cleanup` trap | 50–53 |
| `is_model_cached()` | 230–235 |
| `verify_model_complete()` | 244–298 |
| `is_incomplete()` | 335–341 |
| Disk-gate loop, `is_model_cached` call to fix (BENCH-09) | 385–391, specifically line 388 |
| `write_success_json()` | 566–602 |
| `write_error_json()` | 604–634 |
| `write_skip_json()` | 636–656 |
| `RUN_TS` / `RUN_DIR` assignment (resume wrapping point) | 872–875 |
| `select_best()` | 893–948 |
| Whisper stage loop + JSON extraction block | 1002–1063 |
| `SELECTED_TRANSCRIPT=$(select_best …)` (divergence insertion point) | 1065 |
| Cleanup stage loop | 1076–1150 |
| Summarize stage loop | 1162–1235 |
| `sweep_meta.json` writer | 1246–1263 |

**`transcribrr.sh` atomic write analog:**
| Landmark | Verified Line |
|----------|--------------|
| `TEMP_MD=$(mktemp)` | 610 |
| EXIT trap for temp file | 612 |
| Content write to temp file | 623–643 |
| `mv "$TEMP_MD" "$FINAL_MD_PATH"` (atomic rename) | 646 |
| `trap - EXIT` (clear trap after success) | 647 |

**`transcribrr.sh` settings.conf parse-not-source pattern:**
| Landmark | Verified Line |
|----------|--------------|
| `_read_setting()` function | 184–190 |
| `WHISPER_MODEL_DEFAULT` read | 191–196 |
| `CLEANUP_MODEL_DEFAULT` read | 198–203 |
| `SUMMARY_MODEL_DEFAULT` read | 205–210 |

---

## Metadata

**Analog search scope:** `/Users/gareth/git/transcribrr/benchmark.sh` (1267 lines, read in full across all key sections), `/Users/gareth/git/transcribrr/transcribrr.sh` (lines 178–213, 600–654), `config/settings.conf.example`
**Files scanned:** 3 source files
**Pattern extraction date:** 2026-06-16
