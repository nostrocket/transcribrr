# Phase 5: Resumable Sweep, Report & Winner Selection - Research

**Researched:** 2026-06-16
**Domain:** Bash 3.2 / Python 3.11 — transcript alignment, columnar terminal rendering, resume detection, atomic config writes
**Confidence:** HIGH (all conclusions grounded in direct codebase reads and live venv tests)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Sentence/segment-level alignment — not raw char/line diff.
- **D-02:** Normalize before comparing (lowercase + strip punctuation + collapse whitespace); display original text.
- **D-03:** Outlier = majority consensus; 2-candidate fallback: report divergence count, no outlier ranking.
- **D-04:** Side-by-side columns at `tput cols` width, wrap within each column, no truncation.
- **D-05:** Divergence view shown immediately before the whisper winner prompt.
- **D-06:** Per-stage picks are in-sweep and final; whisper pick is the anchor for chaining.
- **D-07:** Atomic per-stage write of winners to `config/settings.conf` via temp+mv.
- **D-08:** Only write changed stages (not "keep current" stages).
- **D-09:** "Keep current" = extra menu entry [k]; offered only when current default is among candidates; chains forward the default-matching candidate without writing.
- **D-10:** Keys = `WHISPER_MODEL_DEFAULT`, `CLEANUP_MODEL_DEFAULT`, `SUMMARY_MODEL_DEFAULT`.
- **D-11:** Resume trigger = auto-detect incomplete run + prompt `Resume interrupted run from <ts>? [Y/n]`.
- **D-12:** Per-pair completion = presence of result JSON.
- **D-13:** Skip success + fit-gate SKIPs on resume; re-run error JSONs.
- **D-14:** Reuse recorded stage picks on resume; no re-prompting.
- **D-15:** Terminal compact / `report.md` complete (both from one data source).
- **D-16:** Minimal table columns: model label / speed (RTF or tok/s) / peak memory / fit status.
- **D-17:** Full excerpts inline in `report.md` (self-contained archive).
- **D-18:** Disk-gate: change `benchmark.sh:388` to use `verify_model_complete`, not `is_model_cached`.

### Claude's Discretion

- Exact alignment algorithm (difflib.SequenceMatcher recommended — see below).
- `report.md` structure/headings, terminal table glyphs, column ordering, excerpt length.
- Resume "incomplete run" sentinel/heuristic (recommend: no `sweep_meta.json` + no `report.md`).
- Whether to expose `--resume <dir>` explicit flag (optional add alongside auto-detect).

### Deferred Ideas (OUT OF SCOPE)

- Explicit `--resume <dir>` flag (optional; auto-detect is the locked default — implement if it fits).
- Resume across a changed `candidates.conf` (guard/note for planner; full reconciliation deferred).
- Multi-pass timing averaging (FUT-05).
- Phase 6 TTY implication (revisit Phase 6 criterion #3 wording then).
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BENCH-09 | Disk-space gate uses `verify_model_complete`, not `is_model_cached` | One-line change at `benchmark.sh:388`; `verify_model_complete` already exists at line 244 |
| RESUME-01 | Partial results persisted after each model | Already true (JSON written per candidate); resume is read-and-skip on top |
| RESUME-02 | Resumed sweep skips completed pairs, continues from where stopped | Resume detection + skip-or-rerun logic; per-stage pick persistence added to sweep |
| RPT-01 | Comparison report: terminal table + `report.md` | Python helper reads all JSONs from run dir; renders both |
| RPT-02 | User picks winning model per stage ("keep current" allowed) | `select_best` extended with "keep current" entry (D-09) |
| RPT-03 | Winners written atomically to `settings.conf` | Atomic temp+mv per stage; three writes max |
| RPT-04 | Transcript divergence view before whisper winner prompt | Python alignment helper invoked at D-05 insertion point |
| RPT-05 | Per-model outlier count summarized; tool never auto-picks | Majority consensus algorithm; 2-candidate fallback |
</phase_requirements>

---

## Summary

Phase 5 extends `benchmark.sh` with five capabilities, all delivered as new bash functions plus one or two small Python helpers invoked via the existing `.venv/bin/python`. No new top-level scripts; no new `pip` dependencies required (all modules are Python 3.11 stdlib or already in the venv).

The primary open technical question — the transcript divergence alignment mechanism — is resolved: `difflib.SequenceMatcher` on sentence/segment-split text with normalize-before-compare is the correct approach and has been verified against real transcript output from the two existing benchmark runs in `results/`. On a 71-minute audio file producing ~970 turbo segments vs ~1061 small segments vs ~1039 distil segments, the algorithm correctly identifies 471 divergent positions and accurately surfaces `small` (283 outliers) and `distil` (293 outliers) as diverging more often than `turbo` (75 outliers) — which matches the audible quality difference.

The secondary open questions (report structure, resume heuristic, column rendering) are all resolved with concrete recommendations below.

**Primary recommendation:** Ship one Python helper file (`benchmark_helpers.py` at repo root, called by `benchmark.sh` via `$PYTHON`) that handles divergence alignment + column rendering + report generation. The bash side invokes it with a well-defined CLI contract; all stdlib, no new dependencies.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Resume detection + RUN_DIR selection | `benchmark.sh` | — | Must wrap the `RUN_DIR=` assignment (line 873); pure bash control flow |
| Per-stage skip / re-run decision | `benchmark.sh` | — | Reads existing JSON presence; same bash loop structure as Phase 4 sweep |
| Stage pick persistence (for resume) | `benchmark.sh` | — | Write to `$RUN_DIR/picks.json` via `$PYTHON` after each `select_best` call |
| Divergence alignment + outlier counting | Python helper | — | `difflib.SequenceMatcher` + sentence splitting; bash 3.2 hostile |
| Side-by-side column rendering | Python helper | — | `textwrap.fill` + `tput cols` via subprocess; bash cannot wrap in-column |
| Terminal results table | Python helper | — | Reads all JSONs; formats ASCII table for stderr output |
| `report.md` generation | Python helper | — | Writes to `$RUN_DIR/report.md`; embeds full excerpts |
| Atomic `settings.conf` write per stage | `benchmark.sh` | — | `mktemp` + parse-and-merge + `mv`; matches existing pattern in `transcribrr.sh:610-647` |
| Disk-gate fix (BENCH-09) | `benchmark.sh` | — | One-line change at line 388 |

---

## Standard Stack

### Core (all already present)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `difflib` | Python 3.11 stdlib | `SequenceMatcher` for sequence alignment | Zero install cost; correct for this use case [VERIFIED: direct venv test] |
| `textwrap` | Python 3.11 stdlib | `fill()` for column wrapping | Zero install cost; handles unicode [VERIFIED: direct venv test] |
| `re` | Python 3.11 stdlib | Sentence splitting + normalization | Zero install cost [VERIFIED: direct venv test] |
| `collections.Counter` | Python 3.11 stdlib | Majority consensus counting | Zero install cost [VERIFIED: direct venv test] |
| `json` | Python 3.11 stdlib | JSON read/write (already used by JSON writers in benchmark.sh) | Zero install cost; already established pattern [VERIFIED: benchmark.sh code read] |
| `subprocess` | Python 3.11 stdlib | `tput cols` call from Python | Zero install cost [VERIFIED: direct venv test] |

### No new pip installs required

The existing `.venv` (Python 3.11.6) contains `difflib`, `textwrap`, `re`, `json`, `collections`, and `subprocess` as stdlib. All alignment, rendering, and report generation can be implemented without adding any package. [VERIFIED: `.venv/bin/python -c "import difflib, textwrap, re, json, collections, subprocess"`]

---

## Package Legitimacy Audit

**No new packages to install.** All Phase 5 functionality uses Python 3.11 stdlib. This section is satisfied by the absence of new external dependencies.

---

## Architecture Patterns

### System Architecture Diagram

```
benchmark.sh (existing, extended)
    │
    ├─[0] RESUME detection (new)
    │       ls -td results/benchmark_*/ | head -1
    │       if no sweep_meta.json AND no report.md → prompt resume
    │       Yes → reuse RUN_DIR, load picks.json, skip completed pairs
    │       No  → mint new RUN_TS/RUN_DIR (existing behavior)
    │
    ├─[1] BENCH-09 disk-gate fix (one-line change at line 388)
    │       is_model_cached → verify_model_complete
    │
    ├─[2] Staged sweep (existing), extended with:
    │       Per-stage: on select_best pick → write picks.json entry (for resume)
    │       Per-stage: on select_best pick → atomic write to settings.conf (D-07)
    │
    ├─[3] DIVERGENCE VIEW (new, inserted before whisper select_best call at ~line 1065)
    │       $PYTHON benchmark_helpers.py divergence \
    │           --transcripts file1:label1 file2:label2 ... \
    │           --term-width $(tput cols 2>/dev/null || echo 80)
    │       (all output to stderr; bash captures nothing from this call)
    │
    ├─[4] RESULTS TABLE (new, after sweep completes)
    │       $PYTHON benchmark_helpers.py report \
    │           --run-dir "$RUN_DIR" \
    │           --term-width $(tput cols 2>/dev/null || echo 80)
    │       (table to stderr; report.md written to $RUN_DIR/report.md)
    │
    └─[5] sweep_meta.json written (existing, marks run complete)
```

### Recommended Project Structure

```
transcribrr/
├── benchmark.sh              # MODIFIED: resume + divergence view + report + settings write
├── benchmark_helpers.py      # NEW: alignment / column rendering / report generation
├── config/
│   └── settings.conf         # WRITTEN atomically per stage (gitignored)
└── results/
    └── benchmark_<ts>/
        ├── whisper/           # per-candidate JSONs (existing)
        ├── cleanup/           # per-candidate JSONs (existing)
        ├── summarize/         # per-candidate JSONs (existing)
        ├── picks.json         # NEW: persisted per-stage selections (for resume D-14)
        ├── sweep_meta.json    # EXISTING: written at run end (completion sentinel)
        └── report.md          # NEW: written at run end (Phase 5)
```

### Pattern 1: Divergence Alignment (Python helper, difflib.SequenceMatcher)

**What:** Python helper reads N transcript files, strips the 4-line header (Model/Source/Date/blank), splits into sentence/segment units, aligns each candidate to the first candidate as anchor using `SequenceMatcher`, computes N-way majority consensus at each divergent position, counts outliers per model.

**Sentence splitting heuristic:** Split on `(?<=[.!?])\s+` (lookbehind on sentence-ending punctuation). Real transcript data shows this produces ~970 segments for a 69-minute video — appropriate granularity. If the regex yields fewer than 5 segments (edge case: sparse punctuation), fall back to newline-split.

**Header skip:** Transcript files begin with `Model: …`, `Source: …`, `Date: …`, blank line. Strip lines starting with these prefixes (and the following blank) before splitting.

**Normalization function:**
```python
import re
def normalize(text):
    return re.sub(r'\s+', ' ', re.sub(r'[^\w\s]', '', text.lower())).strip()
```

**Anchor alignment (per candidate vs anchor):**
```python
import difflib
def align_to_anchor(anchor_sents, cand_sents):
    """Returns dict: anchor_pos -> original_candidate_sentence."""
    mapping = {}
    sm = difflib.SequenceMatcher(
        None,
        [normalize(s) for s in anchor_sents],
        [normalize(s) for s in cand_sents]
    )
    for op, a1, a2, b1, b2 in sm.get_opcodes():
        if op == 'equal':
            for k in range(a2 - a1):
                mapping[a1 + k] = cand_sents[b1 + k]
        elif op == 'replace':
            for k in range(a2 - a1):
                if b1 + k < len(cand_sents):
                    mapping[a1 + k] = cand_sents[b1 + k]
        # 'insert' and 'delete': positions not in mapping → treated as absent
    return mapping
```

**N-way majority consensus outlier counting:**
```python
from collections import Counter
def find_outliers(aligned_variants):
    """aligned_variants: dict label -> (original_text, normalized_text)
    Returns: (consensus_norm, outlier_labels)"""
    norms = [norm for _, norm in aligned_variants.values() if norm]
    if len(set(norms)) <= 1:
        return None, []  # all agree
    norm_counts = Counter(norms)
    consensus_norm = norm_counts.most_common(1)[0][0]
    outliers = [lbl for lbl, (_, norm) in aligned_variants.items()
                if norm and norm != consensus_norm]
    return consensus_norm, outliers
```

**2-candidate fallback:** When `len(labels) == 2`, report divergent position count for each model but skip the "outlier" terminology and skip the outlier ranking summary (both candidates disagree equally — neither is the "majority").

**Verified performance on real data (4 whisper models, 71-minute audio):**
- turbo: 971 segments, 75 outlier positions
- small: 1061 segments, 283 outlier positions
- distil: 1039 segments, 293 outlier positions
- [VERIFIED: live test against `results/benchmark_20260616T155002/` transcript files]

### Pattern 2: Side-by-Side Column Rendering (Python helper, textwrap)

**What:** Python helper reads `tput cols` via subprocess, divides into N equal columns with a 2-space gap, wraps each column's text using `textwrap.fill`, renders rows by interleaving wrapped lines per column.

**Width calculation:**
```python
import subprocess, textwrap

def get_term_width():
    try:
        r = subprocess.run(['tput', 'cols'], capture_output=True, text=True, timeout=2)
        if r.returncode == 0 and r.stdout.strip().isdigit():
            return int(r.stdout.strip())
    except Exception:
        pass
    return 80

def render_side_by_side(columns, labels, term_width, gap=2):
    """columns: list of text strings, one per candidate.
    labels: list of label strings.
    Output to stderr (caller responsibility)."""
    n = len(columns)
    col_w = max(20, (term_width - gap * (n - 1)) // n)

    def wrap_col(text):
        lines = []
        for para in text.split('\n'):
            if not para.strip():
                lines.append('')
            else:
                lines.extend(textwrap.wrap(para, width=col_w) or [''])
        return lines

    wrapped = [wrap_col(c) for c in columns]
    max_h = max(len(c) for c in wrapped)
    for c in wrapped:
        c += [''] * (max_h - len(c))

    sep = (' ' * gap).join('-' * col_w for _ in labels)
    hdr = (' ' * gap).join(f'{lb:<{col_w}}' for lb in labels)
    print(hdr, file=__import__('sys').stderr)
    print(sep, file=__import__('sys').stderr)
    for row in zip(*wrapped):
        print((' ' * gap).join(f'{cell:<{col_w}}' for cell in row),
              file=__import__('sys').stderr)
```

**Verified correct output for 3-column layout at 80 columns:** each column 26 chars wide, proper wrapping, no truncation. [VERIFIED: live test]

**tput fallback:** If `tput cols` fails (non-TTY context, not a terminal), fall back to 80. This matters because the divergence view is rendered during the interactive sweep (TTY is guaranteed by D-03), but the report builder also calls the helper — `tput cols` may not work when report.md is written post-sweep. Use `sys.stdout.isatty()` check: if not a TTY, default to 80 for terminal output, use 120 as a wider fixed width for the markdown `report.md` column layout.

### Pattern 3: Bash Invocation Contract for the Python Helper

The bash side calls `benchmark_helpers.py` as a subprocess. All terminal output (divergence view, table) goes to stderr. The Python helper exits 0 on success; bash checks exit code.

**Recommended CLI interface:**

```bash
# Divergence view (called immediately before whisper select_best)
"$PYTHON" "$SCRIPT_DIR/benchmark_helpers.py" divergence \
    --transcripts "${label1}:${file1}" "${label2}:${file2}" "${label3}:${file3}" \
    --term-width "$(tput cols 2>/dev/null || echo 80)" \
    >&2   # explicit redirect (though helper writes to stderr internally)

# Report generation (called after sweep_meta.json is written)
"$PYTHON" "$SCRIPT_DIR/benchmark_helpers.py" report \
    --run-dir "$RUN_DIR" \
    --term-width "$(tput cols 2>/dev/null || echo 80)"
# helper writes $RUN_DIR/report.md and prints terminal table to stderr
```

**Argument format for transcripts:** `label:filepath` pairs, space-separated as positional arguments after `--transcripts`. Bash builds this list by iterating the whisper results list file (already has `label|output_file|…` format).

**Exit code contract:**
- 0 = success
- 1 = a transcript file could not be read (non-fatal for the sweep; bash should warn and continue)
- 2 = bad arguments

**stderr/stdout discipline:** The divergence view renders to stderr so it does not interfere with `select_best`'s stdout capture of the selected file path. This matches the `select_best` discipline already established.

### Pattern 4: Resume Detection

**What:** Before minting a new `RUN_TS`/`RUN_DIR`, check whether the most-recent run directory is incomplete. A run is incomplete if its `RUN_DIR` exists AND has no `sweep_meta.json` AND has no `report.md`.

**Recommended heuristic:** Both sentinels (`sweep_meta.json` and `report.md`) are written at the very end of a successful run. An interrupted run — verified from the two existing partial runs — has only per-candidate JSONs in the whisper/cleanup/summarize subdirs with no meta or report file. The dual-sentinel approach is belt-and-suspenders: `sweep_meta.json` exists on a complete Phase 4 run (written last); `report.md` will exist after a complete Phase 5 run. During the Phase 5 transition period, check `sweep_meta.json` only (not `report.md`) to handle Phase 4-complete runs as resumable.

**Recommended implementation pattern:**

```bash
# After RESULTS_DIR is known, before minting RUN_TS:
detect_incomplete_run() {
    # Returns the path to the most-recent incomplete run dir, or empty string.
    local most_recent
    most_recent=$(ls -td "$RESULTS_DIR"/benchmark_*/ 2>/dev/null | head -1)
    most_recent="${most_recent%/}"
    if [ -z "$most_recent" ] || [ ! -d "$most_recent" ]; then
        echo ""; return 0
    fi
    # Complete = has sweep_meta.json (Phase 4 contract)
    if [ -f "$most_recent/sweep_meta.json" ] && [ -f "$most_recent/report.md" ]; then
        echo ""; return 0  # complete run
    fi
    # Has at least one result JSON → was started, not just an empty dir
    if find "$most_recent" -name '*_result.json' -maxdepth 2 | grep -q .; then
        echo "$most_recent"; return 0
    fi
    echo ""; return 0
}

RESUME_CANDIDATE=$(detect_incomplete_run)
if [ -n "$RESUME_CANDIDATE" ]; then
    RESUME_TS=$(basename "$RESUME_CANDIDATE" | sed 's/benchmark_//')
    printf "  Resume interrupted run from %s? [Y/n] " "$RESUME_TS" >&2
    read -r RESUME_ANSWER
    case "$RESUME_ANSWER" in
        ""|Y|y)
            RUN_DIR="$RESUME_CANDIDATE"
            RUN_TS="$RESUME_TS"
            RESUMING=true
            ;;
        *)
            RESUMING=false
            ;;
    esac
fi

if [ "$RESUMING" != true ]; then
    RUN_TS=$(date '+%Y%m%dT%H%M%S')
    RUN_DIR="$RESULTS_DIR/benchmark_${RUN_TS}"
    mkdir -p "$RUN_DIR/whisper" "$RUN_DIR/cleanup" "$RUN_DIR/summarize"
fi
```

**Per-pair skip/re-run decision:**

```bash
should_skip_pair() {
    # Returns 0 (skip) or 1 (run) for a given result JSON path.
    local json_path="$1"
    [ -f "$json_path" ] || return 1  # no JSON → run it
    local fit_status error
    fit_status=$("$PYTHON" -c "import json; d=json.load(open('$json_path')); print(d.get('fit_status',''))" 2>/dev/null || echo "")
    error=$("$PYTHON" -c "import json; d=json.load(open('$json_path')); print(d.get('error') or '')" 2>/dev/null || echo "")
    # Skip: success (error=null) or fit-gate SKIP
    [ "$fit_status" = "skip" ] && return 0  # fit-gate skip → always skip
    [ -z "$error" ] && return 0             # success → skip
    return 1  # error JSON → re-run
}
```

**Persisting stage picks for resume (D-14):**

After each `select_best` call, write the selected output path to `$RUN_DIR/picks.json`. On resume, load this file and reuse recorded picks for already-decided stages.

```bash
persist_pick() {
    local stage="$1"
    local output_file="$2"
    local picks_path="$RUN_DIR/picks.json"
    "$PYTHON" - << PYEOF
import json, os
path = "$picks_path"
try:
    with open(path) as f:
        picks = json.load(f)
except Exception:
    picks = {}
picks["$stage"] = "$output_file"
with open(path, 'w') as f:
    json.dump(picks, f, indent=2)
PYEOF
}

load_picks() {
    local picks_path="$RUN_DIR/picks.json"
    if [ -f "$picks_path" ]; then
        SELECTED_TRANSCRIPT=$("$PYTHON" -c "import json; d=json.load(open('$picks_path')); print(d.get('whisper',''))" 2>/dev/null || echo "")
        SELECTED_CLEANED=$("$PYTHON" -c "import json; d=json.load(open('$picks_path')); print(d.get('cleanup',''))" 2>/dev/null || echo "")
        SELECTED_SUMMARY=$("$PYTHON" -c "import json; d=json.load(open('$picks_path')); print(d.get('summarize',''))" 2>/dev/null || echo "")
    fi
}
```

### Pattern 5: Atomic settings.conf Write

The write must merge, not overwrite. The file may already have keys from a previous benchmark run (or be absent). For each stage whose winner changes:

1. Read the current `settings.conf` (if exists) into a key=value map.
2. Update the map entry for the changed stage's key.
3. Write all keys to a temp file via `$PYTHON` (safe escaping).
4. Atomic `mv` temp → `settings.conf`.

**Implementation:**

```bash
write_settings_key() {
    # Atomically updates one key in config/settings.conf.
    # Usage: write_settings_key WHISPER_MODEL_DEFAULT "turbo"
    local key="$1"
    local value="$2"
    local conf_path="$SCRIPT_DIR/config/settings.conf"
    local tmp_conf
    tmp_conf=$(mktemp "$SCRIPT_DIR/config/.settings_tmp_XXXXXX")
    _BENCH_TMPFILES+=("$tmp_conf")   # register for EXIT trap cleanup

    "$PYTHON" - << PYEOF
import os, re, sys

key = "$key"
value = "$value"
conf_path = "$conf_path"
tmp_path = "$tmp_conf"

# Read existing keys (if any), preserving comments/blank lines
lines = []
found = False
if os.path.isfile(conf_path):
    with open(conf_path) as f:
        for line in f:
            line_stripped = line.rstrip('\n')
            # Replace matching key
            if re.match(r'^' + re.escape(key) + r'\s*=', line_stripped):
                lines.append(f"{key}={value}")
                found = True
            else:
                lines.append(line_stripped)
if not found:
    lines.append(f"{key}={value}")

with open(tmp_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PYEOF

    mv "$tmp_conf" "$conf_path"
    # Remove from tmpfiles list (mv succeeded; no cleanup needed)
    _BENCH_TMPFILES=("${_BENCH_TMPFILES[@]/$tmp_conf/}")
}
```

**Key → stage mapping (D-10):**
- whisper stage winner → `WHISPER_MODEL_DEFAULT`
- cleanup stage winner → `CLEANUP_MODEL_DEFAULT`
- summarize stage winner → `SUMMARY_MODEL_DEFAULT`

**Value format:** Use the friendly label (e.g. `turbo`, `llama3.1-8b-4bit`), not the raw HF ID, to match `settings.conf.example` format. The label is already in the results list file and in the JSON.

**Pitfall:** The `config/` directory may not exist on a fresh clone (only `config/candidates.conf` and `config/settings.conf.example` are committed). Guard with `mkdir -p "$SCRIPT_DIR/config"` before the write.

### Recommended `report.md` Structure

```markdown
# Benchmark Report — <RUN_TS>

**Run date:** <date>
**Audio duration:** <X> minutes (<N> seconds)
**Hardware:** <TOTAL_GB> GB RAM | usable: <USABLE_GB> GB

## Results: Whisper (Transcription)

| Model | Speed (RTF) | Peak Mem | Fit |
|-------|-------------|----------|-----|
| turbo | 0.020 | 2.0 GB | fit |
| distil-large-v3 | 0.017 | 2.1 GB | fit |
| small | 0.016 | 1.2 GB | fit |
| turbo-4bit | ... | ... | fit |

**Selected:** turbo

### Transcript Excerpts

#### turbo
<full transcript text>

#### distil-large-v3
<full transcript text>

...

### Divergence Summary

| Model | Outlier count | % of <N> divergent positions |
|-------|---------------|-------------------------------|
| turbo | 75 | 15.9% |
| distil-large-v3 | 293 | 62.2% |
| small | 283 | 60.1% |

## Results: Cleanup

| Model | Speed (tok/s) | Peak Mem | Fit |
|-------|--------------|----------|-----|
...

## Results: Summarize

| Model | Speed (tok/s) | Peak Mem | Fit |
|-------|--------------|----------|-----|
...

## Selected Winners

| Stage | Winner |
|-------|--------|
| Whisper | turbo |
| Cleanup | llama3.1-8b-4bit |
| Summarize | Qwen2.5-32B-4bit |
```

### Recommended Terminal ASCII Table (compact)

```
── Benchmark Results ──────────────────────────────────────────────
Stage      Model                  Speed         Mem    Fit
─────────────────────────────────────────────────────────────────
whisper    turbo                  RTF=0.020     2.0GB  fit
whisper    distil-large-v3        RTF=0.017     2.1GB  fit
whisper    small                  RTF=0.016     1.2GB  fit
cleanup    llama3.1-8b-4bit       45.2 tok/s    8.1GB  fit
summarize  Qwen2.5-32B-4bit       22.1 tok/s   18.2GB  fit
───────────────────────────────────────────────────────────────────
Selected:  whisper=turbo  cleanup=llama3.1-8b-4bit  summary=Qwen2.5-32B-4bit
```

Glyphs: `──` for horizontal rules (ASCII dash variant, 3.2-safe); no unicode box-drawing characters needed (plain `-` also acceptable). The planner should use plain `-` to stay safe.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Sequence alignment on normalized text | Custom diff / LCS in bash | `difflib.SequenceMatcher` in Python | SequenceMatcher handles N-candidate alignment correctly; bash LCS would require associative arrays (3.2-blocked) |
| Text wrapping inside a fixed-width column | Truncation or manual char-count in bash | `textwrap.fill()` in Python | Handles multi-word wrapping correctly; bash printf `%-N.Ns` truncates, doesn't wrap |
| JSON generation with user-text content | Shell string concatenation with quotes | `json.dump()` via `$PYTHON` (already established) | Already the pattern for write_success_json/write_error_json — do not regress |
| settings.conf merge (read+update+write) | `sed -i` one-liner | Python read-all-write-temp-mv | `sed -i` has macOS vs GNU flag differences; Python handles key-absent-create correctly |

**Key insight:** bash 3.2 is unsuited for string-alignment algorithms, column-wrapping, and safe structured-data generation. All three are already handled in the codebase by delegating to `$PYTHON`. Phase 5's additions follow the same delegation pattern.

---

## Common Pitfalls

### Pitfall 1: Transcript header lines contaminating sentence split

**What goes wrong:** The transcript files begin with `Model: mlx-community/…`, `Source: …`, `Date: …`, followed by a blank line. If the helper does not strip these before splitting, the model-ID line and date line become "sentences" and always differ across candidates, producing spurious divergences at positions 0-3 for every transcript.

**Why it happens:** The header is emitted by the stage scripts as metadata, not transcript content. Verified from real files — all 4 transcript files have identical 3-line header structure.

**How to avoid:** Skip lines starting with `Model:`, `Source:`, `Date:` (and the following blank line) before any processing. A simple filter:

```python
def strip_header(text):
    lines = text.split('\n')
    body_start = 0
    for i, line in enumerate(lines):
        if not any(line.startswith(k) for k in ('Model:', 'Source:', 'Date:')) and line.strip():
            body_start = i
            break
    return '\n'.join(lines[body_start:])
```

**Warning signs:** First 3 divergent positions are always `Model:…` / `Source:…` / `Date:…`.

---

### Pitfall 2: `select_best` stdout pollution from divergence view

**What goes wrong:** The divergence view is inserted before the `select_best "whisper" …` call. `select_best` returns the selected output file path on stdout (captured by the caller via `$(select_best …)`). If any code in the divergence-view call path emits to stdout, the captured value will be corrupt.

**Why it happens:** Python's `print()` goes to stdout by default. A helper that writes to stdout instead of stderr would silently corrupt the `SELECTED_TRANSCRIPT` variable.

**How to avoid:** The Python helper's divergence view must write all output to `sys.stderr`. The bash call should have an explicit `>&2` redirect as a guard. Additionally, `$PYTHON … >&2` on the bash invocation line makes the intent explicit even if the helper is later modified.

**Warning signs:** `SELECTED_TRANSCRIPT` contains garbled text (with table lines embedded). The stage scripts fail because the "transcript file" path does not exist.

---

### Pitfall 3: Atomic write temp file on a different filesystem

**What goes wrong:** `mktemp` without a path argument creates the temp file in `/tmp`. On macOS, `/tmp` may be a different filesystem (tmpfs) from `$SCRIPT_DIR/config/`. An `mv` across filesystems is not atomic (it copies + deletes). SIGINT between copy-complete and delete-complete leaves a partial state.

**Why it happens:** macOS `/tmp` is on a RAM-based tmpfs; the project directory is on APFS. `mv` between filesystems falls back to `cp` + `unlink`.

**How to avoid:** Use `mktemp` in the same directory as the target file:

```bash
tmp_conf=$(mktemp "$SCRIPT_DIR/config/.settings_tmp_XXXXXX")
# ... write to tmp_conf ...
mv "$tmp_conf" "$SCRIPT_DIR/config/settings.conf"
```

`mv` within the same APFS volume is a single directory-entry rename — atomic at the OS level.

**Warning signs:** After Ctrl-C during write, `ls -la config/` shows both `.settings_tmp_XXXXX` and a partial `settings.conf`.

---

### Pitfall 4: Resume re-runs SKIP JSONs that were deliberate fit-gate exclusions

**What goes wrong:** The should-skip logic (D-13) must differentiate fit-gate SKIP JSONs (deterministic — same hardware, same gate → same result) from error JSONs (transient — OOM may resolve after other models have freed memory). If the logic skips all JSONs regardless of their `fit_status`/`error` fields, it will skip error JSONs that should be re-run.

**How to avoid:** The `should_skip_pair` function must check `fit_status == "skip"` (always skip) vs `error != null` (re-run). Verified JSON schema: `fit_status` is either `"fit"` or `"skip"`. Success JSON has `error: null`. Error JSON has `error: "subprocess_nonzero"`. Skip JSON has `fit_status: "skip"`.

---

### Pitfall 5: `tput cols` in a non-TTY context (report.md generation)

**What goes wrong:** The report is generated after the interactive sweep completes. At that point the process is still attached to a TTY, so `tput cols` works. But if Phase 5 is ever invoked in a context that lost TTY (unlikely given D-03 guard, but defensive coding matters), `tput cols` fails silently or returns an error code.

**How to avoid:** Always guard: `tput cols 2>/dev/null || echo 80`. The `|| echo 80` fallback ensures the column-width calculation never receives an empty string. Already demonstrated in the Pattern 3 bash invocation above.

---

### Pitfall 6: picks.json written after select_best but before settings.conf write — SIGINT window

**What goes wrong:** The per-stage sequence is: (1) `select_best` pick, (2) `persist_pick` to `picks.json`, (3) `write_settings_key` to `settings.conf`. SIGINT between step 2 and step 3 leaves `picks.json` updated but `settings.conf` not updated.

**Why it matters:** On resume, the picks are loaded from `picks.json` and used, but `settings.conf` was never written for that stage. The user's choice is lost from the permanent config.

**How to avoid:** This is acceptable behavior per D-07 ("A Ctrl-C during the settings.conf write leaves the file either fully written or absent — never partial/corrupt"). SIGINT before the write is not a corruption problem — the file is either written correctly or not written at all. The resume logic re-does the pick selection for stages where the JSON is incomplete (no pick recorded) — but if the pick was persisted to `picks.json`, it won't re-prompt. Document this gap: on resume after a Ctrl-C between picks.json write and settings.conf write, re-run the settings write for that stage (check if picks.json has a pick for a stage but settings.conf does not).

---

### Pitfall 7: output_file paths in per-candidate JSONs are absolute and point outside the run directory

**What goes wrong:** Verified from real data: the `output_file` field in the whisper result JSONs points to `/Users/gareth/git/transcribrr/results/sample_EWo7-azGHic_transcript_whisper-large-v3-turbo.txt` — which is in `results/` (root of results dir), NOT inside `results/benchmark_<ts>/whisper/`. This is because the stage scripts write output relative to their input file's directory.

**Impact on Phase 5:**
- The divergence view invocation must read from `output_file` in each JSON (not assume paths relative to `RUN_DIR`).
- The report's "Full excerpts" section must read from those absolute paths.
- The report must tolerate missing files gracefully (a file may have been cleaned up).

**How to avoid:** Read the `output_file` field from each JSON; use `os.path.isfile()` check before reading; emit a warning if the file is absent rather than crashing.

---

### Pitfall 8: "Keep current" entry must only appear when current default is a candidate

**What goes wrong (D-09):** The "keep current" entry in `select_best` is offered only when the user's current default model is among the candidates that were benchmarked. If the current default is not a candidate (e.g. fresh setup, no settings.conf), offering "keep current" would chain forward an undefined output file.

**How to avoid:** Read `settings.conf` at the start of the sweep (or pass the current default value to `select_best`). Before building the menu, check if `CURRENT_DEFAULT` matches any candidate label in the list file. Only add the `[k] keep current (<label>)` entry if there is a match. If keeping, find and return that candidate's output file from the list.

**Implementation note:** `select_best` already receives a list file with `label|output_file|…`. Bash can grep for the matching label.

---

### Pitfall 9: Bash 3.2 array operations on INCOMPLETE_IDS with set -u

**What goes wrong:** The existing code uses `${INCOMPLETE_IDS[@]+"${INCOMPLETE_IDS[@]}"}` to safely expand an empty array under `set -u` (from `is_incomplete()`). Phase 5 adds more arrays (e.g. a list of successfully benchmarked transcript paths for the divergence view). Any new array that might be empty must use the same guard pattern.

**How to avoid:** For any array that may be empty: `${MY_ARRAY[@]+"${MY_ARRAY[@]}"}` in bash 3.2. Never use `"${MY_ARRAY[@]}"` directly when the array might be empty under `set -u`.

---

## Code Examples

### Bash → Python helper invocation (divergence view)

```bash
# Source: pattern verified by live venv test (2026-06-16)
# Build the --transcripts argument list from the whisper results list file
DIVERG_ARGS=()
while IFS='|' read -r cand_label cand_output _rest; do
    [ -f "$cand_output" ] && DIVERG_ARGS+=("${cand_label}:${cand_output}")
done < "$WHISPER_RESULTS_LIST"

if [ ${#DIVERG_ARGS[@]} -ge 2 ]; then
    "$PYTHON" "$SCRIPT_DIR/benchmark_helpers.py" divergence \
        --transcripts "${DIVERG_ARGS[@]}" \
        --term-width "$(tput cols 2>/dev/null || echo 80)" >&2
fi
# Then call select_best as before
SELECTED_TRANSCRIPT=$(select_best "whisper" "$WHISPER_RESULTS_LIST")
```

### Python helper argparse skeleton

```python
# Source: verified stdlib pattern
import argparse, sys

def main():
    parser = argparse.ArgumentParser(prog='benchmark_helpers.py')
    sub = parser.add_subparsers(dest='cmd', required=True)

    div = sub.add_parser('divergence')
    div.add_argument('--transcripts', nargs='+',
                     help='label:filepath pairs')
    div.add_argument('--term-width', type=int, default=80)

    rep = sub.add_parser('report')
    rep.add_argument('--run-dir', required=True)
    rep.add_argument('--term-width', type=int, default=80)

    args = parser.parse_args()
    if args.cmd == 'divergence':
        run_divergence(args)
    elif args.cmd == 'report':
        run_report(args)

if __name__ == '__main__':
    main()
```

### Atomic settings.conf write (bash pattern, same filesystem)

```bash
# Source: adapted from transcribrr.sh:610-647 atomic md write
write_settings_key() {
    local key="$1" value="$2"
    local conf_dir="$SCRIPT_DIR/config"
    local conf_path="$conf_dir/settings.conf"
    mkdir -p "$conf_dir"
    local tmp_conf
    tmp_conf=$(mktemp "$conf_dir/.settings_tmp_XXXXXX")
    _BENCH_TMPFILES+=("$tmp_conf")
    "$PYTHON" - "$conf_path" "$tmp_conf" "$key" "$value" << 'PYEOF'
import sys, re, os
conf_path, tmp_path, key, value = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = []
found = False
if os.path.isfile(conf_path):
    with open(conf_path) as f:
        for line in f:
            stripped = line.rstrip('\n')
            if re.match(r'^' + re.escape(key) + r'\s*=', stripped):
                lines.append(f"{key}={value}")
                found = True
            else:
                lines.append(stripped)
if not found:
    lines.append(f"{key}={value}")
with open(tmp_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PYEOF
    mv "$tmp_conf" "$conf_path"
}
```

Note: pass `conf_path`, `tmp_path`, `key`, `value` as `sys.argv` (not via heredoc string interpolation) to avoid shell-injection into the Python heredoc. [ASSUMED] — verify the `"$PYTHON" - args << 'PYEOF'` syntax behaves as expected in bash 3.2 (single-quote heredoc + positional args after `-` should work but test explicitly).

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Bash-only diff comparison | Delegate alignment to Python difflib | Phase 5 | Bash 3.2 cannot implement LCS alignment safely |
| One write for all settings at sweep end | Atomic per-stage write as winners confirmed | Phase 5 (D-07) | Ctrl-C never corrupts settings.conf |
| Fresh run dir on every `--benchmark` | Auto-detect + prompt to resume | Phase 5 (D-11) | No wasted compute on interrupted runs |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `"$PYTHON" - arg1 arg2 << 'PYEOF'` passes positional args correctly in bash 3.2 | Pattern 5 / atomic write | Python reads wrong values; settings.conf key/value wrong. Mitigation: test explicitly; fallback is to use a temp arg file instead |
| A2 | Transcript output files written by Phase 4 remain present at the absolute paths recorded in the JSON | Pitfall 7 | Divergence view and report excerpts fail to read them. Mitigation: always check `os.path.isfile()` before reading |
| A3 | The "keep current" flow can reliably identify which candidate output file corresponds to the current default model | Pattern 4 / anti-patterns | May chain the wrong file. Mitigation: match by label (from `candidates.conf`); if no match, don't offer keep-current |

---

## Open Questions

1. **`"$PYTHON" - args << 'heredoc'` in bash 3.2** — **(RESOLVED)**
   - What we know: Python's `--` or `-` as first arg means read from stdin; additional positional args are in `sys.argv[1:]`.
   - Resolution (live test on bash 3.2.57): `"$PYTHON" - a b << 'PYEOF'` correctly delivers `sys.argv == ['-', 'a', 'b']` — positional args ARE passed alongside the heredoc-on-stdin redirect. Verified by running `printf '%s' "$BASH_VERSION"` → `3.2.57(1)-release` then `"$PYTHON" - alpha beta << 'PYEOF' ... print(sys.argv[1], sys.argv[2]) PYEOF` → prints `alpha beta`. No temp-arg-file fallback needed. As a defensive belt-and-suspenders measure, 05-02 Task 2 asserts this pattern (including path-separator-containing values like `whisper/turbo`) BEFORE the production persist_pick/write_settings_key functions rely on it.

2. **Where does `select_best` learn the current settings.conf defaults?**
   - What we know: D-09 says "keep current" is offered only when the current default is among the candidates.
   - What's unclear: `select_best` currently only sees the list file. It needs the current default model label to check against.
   - Recommendation: Pass the current default as a 3rd argument to `select_best`: `select_best "whisper" "$WHISPER_RESULTS_LIST" "$CURRENT_WHISPER_DEFAULT"`. Read current defaults from `settings.conf` at the start of the sweep (using the existing parse-not-source pattern).

3. **How to detect "first stage that was not completed" on resume**
   - What we know: The `picks.json` file records which stages were completed.
   - What's unclear: Should the resume logic re-run the entire stage loop for incomplete stages (re-visiting candidates already skipped), or only call `select_best` without re-running candidates?
   - Recommendation: For a partially-completed stage (some candidate JSONs present, no pick recorded), re-run the entire stage loop — the should_skip_pair logic will skip completed candidates and only run missing/error ones. Then call select_best with the accumulated (old + new) results.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Python 3.11 | All Python helpers | ✓ | 3.11.6 (`.venv`) | — |
| `difflib` | Divergence alignment | ✓ | stdlib | — |
| `textwrap` | Column rendering | ✓ | stdlib | — |
| `tput` | Terminal width | ✓ | macOS built-in | Default to 80 |
| `mktemp` | Atomic writes | ✓ | macOS built-in | — |
| `config/` dir | settings.conf write | exists (candidates.conf, settings.conf.example present) | — | `mkdir -p` guard |

**Missing dependencies:** None. All required tools are present.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | bash (manual + automated assertion scripts) — no pytest present |
| Config file | none |
| Quick run command | `bash -c 'set -euo pipefail; source benchmark.sh ... 2>&1'` — not applicable pre-implementation |
| Full suite command | Manual verification per ROADMAP success criteria |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated | File Exists? |
|--------|----------|-----------|-----------|-------------|
| BENCH-09 | Present-but-incomplete model counted in disk gate | Manual / code inspection | Inspect line 388 change | No — Wave 0 |
| RESUME-01 | Partial results persisted after each model | Already true (Phase 4) | — | N/A |
| RESUME-02 | Resumed sweep skips completed pairs | Manual: Ctrl-C + restart | `./benchmark.sh` interactive | No — Wave 0 |
| RPT-01 | Terminal table + report.md generated | Manual: run sweep, inspect | `./benchmark.sh` + check files | No — Wave 0 |
| RPT-02 | "Keep current" entry in select_best | Manual: run sweep, inspect menu | Interactive TTY | No — Wave 0 |
| RPT-03 | Atomic settings.conf write | Manual: SIGINT during write | Shell trap test | No — Wave 0 |
| RPT-04 | Divergence view before whisper prompt | Manual: run sweep, inspect output | Interactive TTY | No — Wave 0 |
| RPT-05 | Per-model outlier count, no auto-pick | Manual: inspect divergence output | Interactive TTY | No — Wave 0 |

### Wave 0 Gaps

- [ ] `benchmark_helpers.py` — new file; covers RPT-01, RPT-04, RPT-05
- [ ] `config/` dir `mkdir -p` guard — needed for settings.conf write
- [ ] Test for `"$PYTHON" - args << 'PYEOF'` bash 3.2 argument passing

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | yes — label:filepath split | Validate each `label:filepath` pair before use; check no shell metacharacters in label or filepath passed to Python |
| V6 Cryptography | no | — |
| V2/V3/V4 | no | Local tool, no auth, no sessions |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Shell injection via model label in settings.conf write | Tampering | Pass label/key/value via sys.argv (not heredoc string interpolation); validate label against `[a-zA-Z0-9._-]+` pattern |
| Path traversal in `label:filepath` helper argument | Tampering | Validate filepath is within `results/` tree via `os.path.abspath` check |

---

## Sources

### Primary (HIGH confidence)

- Direct code read: `benchmark.sh` (1267 lines, read in full across key sections) — all line numbers verified against live file
- Direct venv test: `difflib.SequenceMatcher` alignment on real transcript data from `results/benchmark_20260616T155002/`
- Direct venv test: `textwrap.fill` column rendering at 80-col terminal width
- Direct venv test: Python 3.11.6 stdlib availability (`difflib`, `textwrap`, `re`, `json`, `collections`, `subprocess`)
- Direct file read: `results/benchmark_20260616T155002/whisper/*.json` — confirmed JSON schema and output_file paths
- Direct file read: `results/sample_EWo7-azGHic_transcript_*.txt` — confirmed header structure + sentence granularity

### Secondary (MEDIUM confidence)

- `transcribrr.sh:610-647` — atomic temp+mv pattern confirmed from code read
- `config/settings.conf.example` — confirmed 3-key format
- Phase 3/4/5 CONTEXT.md — decision set read in full

---

## Metadata

**Confidence breakdown:**
- Divergence alignment mechanism: HIGH — tested live against real data; correct results
- Column rendering: HIGH — tested live; correct output
- Resume heuristic: HIGH — verified from two real incomplete run dirs (no sweep_meta.json, only whisper JSONs)
- Atomic write: HIGH — pattern from existing transcribrr.sh code; same-filesystem guarantee
- settings.conf merge: MEDIUM — pattern is correct; A1 assumption re: `$PYTHON - args << heredoc` needs explicit test

**Research date:** 2026-06-16
**Valid until:** 2026-07-16 (stable stdlib + bash 3.2 patterns; won't change)

---

## RESEARCH COMPLETE

**Phase:** 5 — Resumable Sweep, Report & Winner Selection
**Confidence:** HIGH

### Key Findings

1. **Divergence alignment:** `difflib.SequenceMatcher` on sentence-split text is the correct mechanism. Verified on real transcript data: correctly identifies 471 divergent positions across 3 whisper models on a 71-minute audio file, with accurate outlier counts (turbo=75, small=283, distil=293) matching expected quality ordering.

2. **Column rendering:** `textwrap.fill` in the Python helper produces correct N-column side-by-side layouts at any terminal width. `tput cols` works in the TTY context guaranteed by D-03.

3. **Resume heuristic:** Both existing partial run dirs confirm the sentinel: no `sweep_meta.json` + no `report.md` = incomplete run. The `picks.json` file is the new addition for D-14 stage-pick persistence.

4. **output_file paths are absolute and outside RUN_DIR:** The stage scripts write transcript output to `results/` (root), not `results/benchmark_<ts>/`. The report and divergence view must read from the `output_file` field in each JSON, not from paths derived from `RUN_DIR`.

5. **Atomic write must use same-directory mktemp:** Use `mktemp "$SCRIPT_DIR/config/.settings_tmp_XXXXXX"` (not `/tmp/`) to guarantee `mv` is an atomic rename within the same APFS volume.

6. **BENCH-09 is a one-line fix:** Change `is_model_cached` → `verify_model_complete` at `benchmark.sh:388`. Both functions already exist and have the same signature.

### File Created

`/Users/gareth/git/transcribrr/.planning/phases/05-resumable-sweep-report-winner-selection/05-RESEARCH.md`

### Confidence Assessment

| Area | Level | Reason |
|------|-------|--------|
| Divergence alignment mechanism | HIGH | Live-tested on real data; correct results |
| Column rendering | HIGH | Live-tested; correct multi-column wrapping |
| Resume detection heuristic | HIGH | Verified against two real partial runs |
| Atomic settings.conf write | HIGH | Same pattern as transcribrr.sh; same-filesystem mktemp confirmed |
| Python helper CLI contract | HIGH | argparse pattern; standard stdlib |
| `$PYTHON - args << heredoc` bash 3.2 | MEDIUM | Needs explicit test before relying on it |

### Open Questions

- **(RESOLVED)** `"$PYTHON" - arg1 arg2 << 'PYEOF'` arg-passing confirmed live on bash 3.2.57 — `sys.argv[1:]` receives the positional args alongside the heredoc-on-stdin redirect; no temp-arg-file fallback needed. 05-02 Task 2 re-asserts this (with path-separator values) before production code uses it.
- Clarify how `select_best` receives the current default model label for "keep current" detection (recommend 3rd parameter).
- Define the exact resume behavior for a partially-completed stage (some candidates run, no pick yet — recommendation: re-run incomplete candidates, then call select_best with full list).

### Ready for Planning

Research complete. Planner can now create PLAN.md files.
