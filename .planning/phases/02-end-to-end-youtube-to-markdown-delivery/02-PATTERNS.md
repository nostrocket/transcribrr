# Phase 2: End-to-End YouTube-to-Markdown Delivery - Pattern Map

**Mapped:** 2026-06-14
**Files analyzed:** 1 (transcribrr.sh — the only file modified by this phase)
**Analogs found:** 4 / 4 (all four existing bash scripts serve as analogs for the five new code sections)

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `transcribrr.sh` (URL detection + url-check stage) | orchestrator | request-response | `transcribrr.sh` flag-parsing case loop (self-referential — existing pattern extended) | exact |
| `transcribrr.sh` (preflight yt-dlp check) | orchestrator / utility | request-response | `transcribrr.sh` `preflight_check()` function lines 121–152 | exact |
| `transcribrr.sh` (metadata stage) | orchestrator | request-response | none (new yt-dlp pattern) — use RESEARCH.md Pattern 3 | no-analog |
| `transcribrr.sh` (download stage + MP3 path capture) | orchestrator | file-I/O | `transcribrr.sh` `STAGE_OUT=` capture pattern lines 172–180 | role-match |
| `transcribrr.sh` (CURRENT_STAGE extension for new stages) | orchestrator | request-response | `transcribrr.sh` ERR trap + `CURRENT_STAGE=` assignments lines 22–23, 169, 185, 204 | exact |
| `transcribrr.sh` (assemble stage) | orchestrator | file-I/O | `summarize-transcript.sh` output-write pattern lines 428–450 (strips its own header) | partial-match |
| `.gitignore` (new artifact patterns) | config | — | `.gitignore` existing glob patterns lines 7–12 | exact |

---

## Pattern Assignments

### Section: Flag Parsing — URL vs Local Path Detection

**Analog:** `transcribrr.sh` lines 78–116 (positional arg catch-all in the case loop)

**Existing positional-arg catch** (lines 109–113):
```bash
        *)
            MP3_FILE="$1"
            shift
            ;;
```

**New pattern — detect URL at flag-parse time, set IS_URL and INPUT_ARG:**
The `*)` arm currently assigns `MP3_FILE` directly. Phase 2 replaces this with an IS_URL detection before assigning; the positional arg should be captured as `INPUT_ARG` and then URL vs local determined once:
```bash
        *)
            INPUT_ARG="$1"
            shift
            ;;
```
After the while loop, before `preflight_check()`, add:
```bash
IS_URL=false
if [[ "$INPUT_ARG" =~ ^https?:// ]] || [[ "$INPUT_ARG" =~ youtu\.?be ]]; then
    IS_URL=true
    URL="$INPUT_ARG"
else
    MP3_FILE="$INPUT_ARG"
fi
```
**Key constraint:** `IS_URL` must be set before `preflight_check()` because the yt-dlp conditional check lives inside that function.

---

### Section: Preflight Check — Conditional yt-dlp Check

**Analog:** `transcribrr.sh` lines 121–152 (`preflight_check()` function) — exact match.

**Existing preflight structure** (lines 121–152):
```bash
preflight_check() {
    local errors=0

    # Validate input file
    if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
        echo "Error: Input file not found: ${MP3_FILE:-<not specified>}" >&2
        errors=$((errors + 1))
    fi

    # Validate each required sub-script exists and is executable
    for script in transcribe.sh cleanup-transcript.sh summarize-transcript.sh; do
        local path="$SCRIPT_DIR/$script"
        if [ ! -f "$path" ]; then
            echo "Error: Required script not found: $path" >&2
            errors=$((errors + 1))
        elif [ ! -x "$path" ]; then
            echo "Error: Script is not executable: $path" >&2
            errors=$((errors + 1))
        fi
    done

    # Validate ffmpeg is available (transcribe.sh uses it for duration)
    if ! command -v ffmpeg &>/dev/null; then
        echo "Error: ffmpeg not found on PATH. Install with: brew install ffmpeg" >&2
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        echo "Aborting: $errors preflight check(s) failed." >&2
        exit 1
    fi
}
```

**New yt-dlp block to INSERT inside `preflight_check()` after the ffmpeg check, URL-conditional:**
```bash
    # Validate yt-dlp is available when processing a URL (DL-02, ROB-01)
    if [ "$IS_URL" = true ]; then
        if ! command -v yt-dlp &>/dev/null; then
            echo "Error: yt-dlp not found on PATH. Install with: brew install yt-dlp" >&2
            errors=$((errors + 1))
        fi
    fi
```

**Input validation change for URL mode** — replace the `MP3_FILE` check with a branch:
```bash
    # Validate input
    if [ "$IS_URL" = true ]; then
        if [ -z "$URL" ]; then
            echo "Error: URL argument is empty." >&2
            errors=$((errors + 1))
        fi
    else
        if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
            echo "Error: Input file not found: ${MP3_FILE:-<not specified>}" >&2
            errors=$((errors + 1))
        fi
    fi
```

---

### Section: CURRENT_STAGE ERR Trap (existing) + New Stage Names

**Analog:** `transcribrr.sh` lines 22–23 (trap declaration) and lines 169, 185, 204 (stage assignments) — exact match.

**Existing trap** (lines 22–23):
```bash
CURRENT_STAGE="preflight"
trap 'echo "Error: transcribrr.sh failed during stage: $CURRENT_STAGE" >&2' ERR
```

**Existing stage assignments** (lines 169, 185, 204):
```bash
CURRENT_STAGE="transcribe"
# ...
CURRENT_STAGE="cleanup"
# ...
CURRENT_STAGE="summarize"
```

**New stage names to add** — insert `url-check`, `metadata`, `download` before Stage 1; insert `assemble` after Stage 3. Copy the exact `CURRENT_STAGE="<name>"` assignment pattern:
```bash
CURRENT_STAGE="url-check"
# ... playlist check ...

CURRENT_STAGE="metadata"
# ... yt-dlp --simulate --print ...

CURRENT_STAGE="download"
# ... yt-dlp -x --audio-format mp3 ...

# existing: CURRENT_STAGE="transcribe"
# existing: CURRENT_STAGE="cleanup"
# existing: CURRENT_STAGE="summarize"

CURRENT_STAGE="assemble"
# ... mktemp + heredoc + mv ...
```
No changes to the trap declaration itself.

---

### Section: url-check Stage (Playlist URL Rejection)

**Analog:** `transcribrr.sh` lines 172–180 (file-existence guard after STAGE_OUT capture) — structural match; the guard pattern (check, print error, exit 1) is reused.

**Existing guard pattern** (lines 177–180):
```bash
if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Error: transcribe stage did not produce a valid output file." >&2
    exit 1
fi
```

**New url-check block** — same structure: condition check → stderr message → exit 1:
```bash
CURRENT_STAGE="url-check"
if [[ "$URL" =~ [?&]list= ]] || [[ "$URL" =~ youtube\.com/playlist ]]; then
    echo "Error: Playlist URLs are not supported in v1." >&2
    echo "  To download a single video, remove the '&list=...' parameter from the URL." >&2
    exit 1
fi
```

---

### Section: metadata Stage (yt-dlp --simulate --print)

**Analog:** None in the codebase. Use RESEARCH.md Pattern 3 directly.

**No existing analog** — `mapfile` + yt-dlp `--print` has no precedent in the repo. Follow RESEARCH.md Pattern 3 verbatim:
```bash
CURRENT_STAGE="metadata"
stage_banner "Stage 1/5: Fetching video metadata..."

mapfile -t META < <(yt-dlp \
    --simulate \
    --no-playlist \
    --print "%(title)s" \
    --print "%(channel|uploader)s" \
    --print "%(webpage_url)s" \
    --print "%(duration_string)s" \
    --print "%(upload_date)s" \
    --print "%(id)s" \
    "$URL" 2>/dev/null)

# Explicit exit-code guard (SC2311: set -e not inherited in $() / process substitution)
if [ "${#META[@]}" -lt 6 ]; then
    echo "Error: metadata stage returned fewer fields than expected (got ${#META[@]}, need 6)." >&2
    exit 1
fi

VIDEO_TITLE="${META[0]}"
VIDEO_CHANNEL="${META[1]}"
VIDEO_URL="${META[2]}"
VIDEO_DURATION="${META[3]}"
VIDEO_UPLOAD_DATE_RAW="${META[4]}"
VIDEO_ID="${META[5]}"
```

**Upload date reformat** (follows immediately):
```bash
if [[ "$VIDEO_UPLOAD_DATE_RAW" =~ ^[0-9]{8}$ ]]; then
    VIDEO_UPLOAD_DATE=$(echo "$VIDEO_UPLOAD_DATE_RAW" | \
        sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
else
    VIDEO_UPLOAD_DATE="$VIDEO_UPLOAD_DATE_RAW"
fi
```

**Title sanitization** — copy from `cleanup-transcript.sh` MODEL_LABEL pattern (lines 50):
```bash
# cleanup-transcript.sh line 50 analog (sanitize for safe filesystem use)
SAFE_TITLE=$(echo "$VIDEO_TITLE" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
WORK_DIR="$(pwd)/${SAFE_TITLE}_${VIDEO_ID}"
```
Note: append `_${VIDEO_ID}` to handle working-directory collision (Pitfall 5 in RESEARCH.md; within Claude's discretion per CONTEXT.md).

---

### Section: download Stage (yt-dlp -x + MP3 path capture)

**Analog:** `transcribrr.sh` lines 172–180 (`STAGE_OUT=` capture + file-existence guard) — role-match.

**Existing STAGE_OUT capture pattern** (lines 172–180):
```bash
STAGE_OUT=$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
    | tee /dev/stderr \
    | grep "^OUTPUT_FILE=")
TRANSCRIPT_FILE="${STAGE_OUT#OUTPUT_FILE=}"

if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Error: transcribe stage did not produce a valid output file." >&2
    exit 1
fi
```

**New download stage** — same guard pattern; yt-dlp replaces the sub-script invocation:
```bash
CURRENT_STAGE="download"
stage_banner "Stage 2/5: Downloading audio (yt-dlp)..."

mkdir -p "$WORK_DIR"

MP3_FILE=$(yt-dlp \
    -x --audio-format mp3 \
    --no-playlist \
    -o "${WORK_DIR}/%(title)s.%(ext)s" \
    --print "after_move:filepath" \
    "$URL")

# Guard: verify file exists (after_move:filepath reliability edge case — RESEARCH.md Pitfall 1)
if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
    MP3_FILE=$(find "$WORK_DIR" -name "*.mp3" | sort | tail -1)
    if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
        echo "Error: download stage did not produce a valid MP3 file in $WORK_DIR" >&2
        exit 1
    fi
fi
```

**Feeding downstream** — `MP3_FILE` is now set and feeds the existing Stage 1 invocation unchanged:
```bash
# Existing line 172 — MP3_FILE variable is now populated from download stage, not CLI arg
STAGE_OUT=$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
    | tee /dev/stderr \
    | grep "^OUTPUT_FILE=")
```

---

### Section: Stage Banner Renumbering

**Analog:** `transcribrr.sh` lines 154–163 (`stage_banner()` function) + lines 170, 186, 207 (call sites) — exact match.

**Existing `stage_banner()` function** (lines 154–163):
```bash
stage_banner() {
    local msg="$1"
    echo ""
    echo "=========================================="
    echo "  $msg"
    echo "=========================================="
    echo ""
}
```
Function is unchanged. Only the call sites change to reflect 5-stage numbering:

| Old call (Phase 1) | New call (Phase 2) |
|---|---|
| `stage_banner "Stage 1/3: Transcribing..."` | `stage_banner "Stage 3/5: Transcribing..."` |
| `stage_banner "Stage 2/3: Cleaning transcript..."` | `stage_banner "Stage 4/5: Cleaning transcript..."` |
| `stage_banner "Stage 3/3: Summarizing..."` | `stage_banner "Stage 5/5: Summarizing..."` |

New banners:
```bash
stage_banner "Stage 1/5: Fetching video metadata (yt-dlp)..."
stage_banner "Stage 2/5: Downloading audio (yt-dlp)..."
# existing 3, 4, 5 above
stage_banner "Stage 6/5: Assembling final markdown..."   # wait — see note
```
**Correction:** With url-check as a stage, the pipeline is: url-check → metadata → download → transcribe → [cleanup] → summarize → assemble. The user-visible numbered stages should be 1/5 through 5/5 covering the major work stages (metadata counts as part of download, or url-check is silent). Use the count from RESEARCH.md: Stage 1/5 (download/metadata), Stage 2/5 (transcribe), Stage 3/5 (cleanup), Stage 4/5 (summarize), Stage 5/5 (assemble) — with url-check as a silent guard before Stage 1.

---

### Section: assemble Stage (Temp File + Atomic mv)

**Analog 1:** `transcribrr.sh` lines 221–228 (Done block with `echo "Summary written to:"`) — structural end-of-pipeline match.
**Analog 2:** `summarize-transcript.sh` lines 434–450 (header write + `---` separator) — the file whose header MUST be stripped.

**Summary file header structure** (`summarize-transcript.sh` lines 434–445):
```python
# blog style:
header = f"# {source_name...}\n\n"
header += f"*Originally from: {source_name}*\n\n"
header += f"---\n\n"

# non-blog style:
header = f"# Summary: {source_name}\n\n"
header += f"| | |\n|---|---|\n"
header += f"| **Source** | {source_name} |\n"
header += f"| **Words** | ... |\n"
header += f"| **Model** | ... |\n"
header += f"| **Style** | ... |\n"
header += f"\n---\n\n"
```
Both styles end with `---\n\n`. The strip command `sed '1,/^---/d'` removes everything up to and including the first bare `---` line — verified correct for both styles.

**assemble stage pattern:**
```bash
CURRENT_STAGE="assemble"
stage_banner "Stage 5/5: Assembling final markdown..."

FINAL_MD_NAME="${SAFE_TITLE}.md"
FINAL_MD_PATH="$(pwd)/${FINAL_MD_NAME}"
TEMP_MD=$(mktemp)
trap 'rm -f "$TEMP_MD"' EXIT

# Select transcript variant (cleaned when available, raw when --no-cleanup)
if [ "$NO_CLEANUP" = false ] && [ -n "${CLEANED_FILE:-}" ] && [ -f "$CLEANED_FILE" ]; then
    EMBED_TRANSCRIPT="$CLEANED_FILE"
else
    EMBED_TRANSCRIPT="$TRANSCRIPT_FILE"
fi

{
    printf "# %s\n\n" "$VIDEO_TITLE"
    printf -- "- **Title:** %s\n" "$VIDEO_TITLE"
    printf -- "- **Channel:** %s\n" "$VIDEO_CHANNEL"
    printf -- "- **Source URL:** %s\n" "$VIDEO_URL"
    printf -- "- **Duration:** %s\n" "$VIDEO_DURATION"
    printf -- "- **Upload date:** %s\n" "$VIDEO_UPLOAD_DATE"
    if [ "$NO_CLEANUP" = false ]; then
        printf -- "- **Models used:** whisper=%s, cleanup=%s, summary=%s (%s)\n\n" \
            "$WHISPER_MODEL" "$CLEANUP_MODEL" "$SUMMARY_MODEL" "$SUMMARY_STYLE"
    else
        printf -- "- **Models used:** whisper=%s, cleanup=skipped, summary=%s (%s)\n\n" \
            "$WHISPER_MODEL" "$SUMMARY_MODEL" "$SUMMARY_STYLE"
    fi
    printf "## Summary\n\n"
    sed '1,/^---/d' "$SUMMARY_FILE"
    printf "\n## Transcript\n\n"
    cat "$EMBED_TRANSCRIPT"
} > "$TEMP_MD"

mv "$TEMP_MD" "$FINAL_MD_PATH"
trap - EXIT
```

**Done block** — replaces the existing `echo "Summary written to:"` block (lines 221–228):
```bash
echo ""
echo "=========================================="
echo "  Pipeline complete!"
echo "=========================================="
echo "Markdown: $FINAL_MD_PATH"
```

---

### Section: .gitignore New Patterns

**Analog:** `.gitignore` lines 7–12 (existing glob patterns for intermediates) — exact match.

**Existing patterns** (lines 7–12):
```gitignore
*_transcript_*.txt
*_transcription_*.log
*_whisper_*.pid
*_cleaned_*.txt
*_summary_*.md
```

**New patterns to append** — follow the same `#` comment + glob style:
```gitignore
# Working directories (per-video intermediate dirs created by URL mode)
*_*/

# Note: the final *.md at repo root is intentionally NOT gitignored — user may want to keep it.
```
The pattern `*_*/` matches `My_Video_Title_dQw4w9WgXcQ/` (safe-title + underscore + video-id) but not bare top-level dirs without underscores. If a broader pattern is preferred, use `*/` (ignores all directories), but that may be too aggressive for a repo with legitimate subdirectories.

---

## Shared Patterns

### CURRENT_STAGE + ERR Trap
**Source:** `transcribrr.sh` lines 22–23
**Apply to:** Every new stage block (`url-check`, `metadata`, `download`, `assemble`)
```bash
CURRENT_STAGE="preflight"
trap 'echo "Error: transcribrr.sh failed during stage: $CURRENT_STAGE" >&2' ERR
```
Set `CURRENT_STAGE="<stagename>"` as the first line of each stage block. The trap fires automatically on any `set -e` exit.

### File-Existence Guard After Capture
**Source:** `transcribrr.sh` lines 177–180 (and repeated at lines 193–196, 216–219)
**Apply to:** Every `$()` capture that produces a file path (`MP3_FILE`, `TRANSCRIPT_FILE`, `CLEANED_FILE`, `SUMMARY_FILE`)
```bash
if [ -z "$OUTPUT_VAR" ] || [ ! -f "$OUTPUT_VAR" ]; then
    echo "Error: <stage> stage did not produce a valid output file." >&2
    exit 1
fi
```
Note: RESEARCH.md Pitfall 2 documents that `set -e` is NOT inherited inside `$(...)`. This guard is the only mechanism that catches a silent yt-dlp failure in `MP3_FILE=$(yt-dlp ...)`.

### Model Label Sanitizer
**Source:** `cleanup-transcript.sh` line 50 / `summarize-transcript.sh` line 99
**Apply to:** Title sanitization in the download/metadata stage
```bash
MODEL_LABEL=$(echo "$MODEL" | sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]')
```
For the video title, the same character-class allow-list applies but without the `mlx-community/` strip:
```bash
SAFE_TITLE=$(echo "$VIDEO_TITLE" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
```

### stage_banner() Function
**Source:** `transcribrr.sh` lines 154–163
**Apply to:** All five numbered stage entry points
```bash
stage_banner() {
    local msg="$1"
    echo ""
    echo "=========================================="
    echo "  $msg"
    echo "=========================================="
    echo ""
}
```
Function is unchanged; only the string argument changes per stage.

### OUTPUT_FILE= Emission + tee/grep Capture
**Source:** `transcribrr.sh` lines 172–175 (and 188–191, 209–213)
**Apply to:** Existing three sub-script invocations — pattern unchanged in Phase 2
```bash
STAGE_OUT=$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
    | tee /dev/stderr \
    | grep "^OUTPUT_FILE=")
TRANSCRIPT_FILE="${STAGE_OUT#OUTPUT_FILE=}"
```
The only Phase 2 change: `$MP3_FILE` is now populated from the download stage rather than the CLI arg. The capture pattern itself is copied verbatim.

---

## No Analog Found

| Code Section | Role | Data Flow | Reason |
|---|---|---|---|
| `metadata` stage (`mapfile -t META < <(yt-dlp --simulate --print ...)`) | orchestrator | request-response | No yt-dlp invocation exists in the codebase; `mapfile` is not used anywhere. Use RESEARCH.md Pattern 3 directly. |
| `TEMP_MD=$(mktemp)` + `trap 'rm -f "$TEMP_MD"' EXIT` | orchestrator | file-I/O | No temp-file + atomic-mv pattern in the existing scripts. Use RESEARCH.md Pattern 7 / code example directly. |

---

## Metadata

**Analog search scope:** `/Users/gareth/git/transcribrr/` repo root (all `.sh` files, `.gitignore`)
**Files scanned:** `transcribrr.sh` (228 lines), `transcribe.sh` (272 lines), `cleanup-transcript.sh` (221 lines), `summarize-transcript.sh` (464 lines, targeted reads at lines 95–147 and 420–464), `.gitignore` (18 lines)
**Pattern extraction date:** 2026-06-14
