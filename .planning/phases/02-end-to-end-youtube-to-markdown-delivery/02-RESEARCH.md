# Phase 2: End-to-End YouTube-to-Markdown Delivery - Research

**Researched:** 2026-06-14
**Domain:** yt-dlp audio extraction, metadata capture, bash scripting patterns
**Confidence:** HIGH for yt-dlp flag behavior; MEDIUM for `after_move:filepath` reliability edge cases

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- URL vs local input is auto-detected: if the positional argument matches `http(s)://` / `youtu`(.be|be.com), run the new download stage; otherwise treat it as a local audio file (preserves Phase 1 behavior).
- Download + MP3 extraction uses `yt-dlp -x --audio-format mp3` (yt-dlp drives ffmpeg internally) — single tool, satisfies DL-02 and DL-03 together.
- Working location: downloaded MP3 and all intermediates go in a working directory under the CWD named from the sanitized video title (e.g., `./<sanitized-title>/`); the final `.md` is written at the CWD root. Predictable, avoids clutter, and keeps Phase 1's "intermediates beside the input MP3" invariant.
- `yt-dlp` is preflight-checked only when the input is a URL, failing with an actionable `brew install yt-dlp` hint (extends the ROB-01 preflight). `ffmpeg` remains required (already checked).
- Metadata capture uses `yt-dlp --print` field templates (`%(title)s`, `%(channel)s`/`%(uploader)s`, `%(webpage_url)s`, `%(duration_string)s`, `%(upload_date)s`) — captures all DL-04 fields in the same invocation, no second network hit.
- No `jq` dependency — rely on yt-dlp's own output templates so the only new tool introduced is `yt-dlp`.
- Header format (OUT-02): a top-level `#` title line followed by a bulleted metadata block (Title, Channel, Source URL, Duration, Upload date, Models used), then `## Summary`, then `## Transcript`. Plain, human-readable markdown. Upload date reformatted from yt-dlp's `YYYYMMDD` to `YYYY-MM-DD`.
- Transcript variant in the final file: the cleaned transcript when the cleanup stage ran, otherwise the raw transcript ("full transcript" = best available version, honoring `--no-cleanup`).
- Final filename (OUT-03): sanitized video title + `.md` at a predictable path (CWD root), using the same sanitization approach the existing sub-scripts use.
- Partial-output safety (ROB-03): assemble the final markdown into a temp file and `mv` it into place only after all stages succeed — never leave a partial final `.md`.
- Fail-fast (ROB-02): extend the existing `$CURRENT_STAGE` + ERR-trap pattern to name the new stages (`download`, `metadata`, `assemble`) so any failure aborts with the failing stage named.
- Intermediates are retained (transcript, cleaned, summary, downloaded MP3) for debuggability; only the final `.md` is gated on full success.
- Deferred to v2: browser-cookie auth (`--cookies-from-browser`) and playlist/batch URL support. If a playlist URL is supplied, error clearly rather than guessing.

### Claude's Discretion
- Exact sanitization regex, working-directory naming collisions handling, and precise yt-dlp flag ordering are at the planner/executor's discretion, consistent with codebase conventions.

### Deferred Ideas (OUT OF SCOPE)
- Browser-cookie auth passthrough (`--cookies-from-browser`) for bot-detection-restricted videos (v2).
- Playlist / batch URL support (v2) — error clearly on playlist URLs for now.
- Keep/discard intermediates toggle and a configurable output directory (`--output-dir`) (v2).
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DL-02 | Script downloads the video/audio from the URL using `yt-dlp` | yt-dlp `-x --audio-format mp3 --no-playlist` pattern documented; preflight check pattern established |
| DL-03 | Script exports audio to MP3 (via `yt-dlp -x --audio-format mp3`) | `-x --audio-format mp3` delegates to ffmpeg internally; ffmpeg already in preflight |
| DL-04 | Script captures video metadata (title, channel, URL, duration, upload date) | `--print` multi-field template in same invocation as download; field names and fallback syntax documented |
| OUT-01 | Script writes ONE markdown file containing, in order: rich header, summary, full transcript | Temp-file + atomic `mv` assembly pattern documented; transcript variant selection logic documented |
| OUT-02 | Rich header includes video title, channel, source URL, duration, upload date, and the models used | Header format and upload_date reformat (`YYYYMMDD` -> `YYYY-MM-DD`) documented |
| OUT-03 | Final markdown filename is derived from the video title (sanitized) at a predictable path | Title sanitization using same sed pattern as sub-scripts; predictable CWD-root path documented |
| ROB-02 | Script fails fast with an actionable message if any stage errors, naming the failing stage | `$CURRENT_STAGE` ERR-trap extension documented for download, metadata, assemble stages |
| ROB-03 | Intermediate artifacts are retained; the final markdown is only written on full success | Temp file + atomic `mv` pattern documented; existing `.gitignore` does NOT cover the working dir or final `.md` |
</phase_requirements>

---

## Summary

Phase 2 extends `transcribrr.sh` — the Phase 1 walking skeleton — with a download+metadata stage before the existing three-stage pipeline and an assemble stage after it. No new tools are introduced beyond `yt-dlp`. The Phase 1 architecture (stage chaining via `OUTPUT_FILE=`, `$CURRENT_STAGE` ERR trap, `set -euo pipefail`) is carried forward unchanged; Phase 2 adds four new named stages: `url-check`, `download`, `metadata`, and `assemble`.

The two technically interesting problems are: (1) capturing the downloaded MP3 path deterministically — `--print after_move:filepath` is the intended mechanism but has a known reliability edge case requiring a verification guard; (2) single-pass metadata capture requires careful multi-line parsing because each `--print` flag emits one line in order, and this must be separated from the filepath emission of the same run.

The working directory approach (`./<sanitized-title>/`) is the key structural change: the script computes the sanitized title, creates the working dir, passes an explicit `-o` template rooted in that dir to yt-dlp, then feeds the resulting MP3 path to `transcribe.sh`. All intermediates land beside the MP3 (existing sub-script behavior preserved). The final `.md` is assembled in a temp file and atomically moved to CWD root on full success.

**Primary recommendation:** Use a two-invocation yt-dlp strategy — one `--simulate --print` call for all metadata fields, then one real download call with `--print after_move:filepath` — to cleanly separate the concerns of metadata capture and filepath capture. This avoids parsing interleaved stdout lines and sidesteps the reliability edge case.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| URL vs local path detection | Orchestrator (`transcribrr.sh`) | — | Simple string match in flag parsing; no external tool needed |
| Playlist URL rejection | Orchestrator (preflight / url-check stage) | — | Pattern match on URL string before any yt-dlp invocation |
| yt-dlp preflight check | Orchestrator (preflight function) | — | URL-conditional; accumulates with existing errors |
| Audio download + MP3 extraction | yt-dlp (drives ffmpeg) | — | `-x --audio-format mp3` delegates to ffmpeg internally |
| Metadata capture | yt-dlp `--print` | Orchestrator (parses stdout) | yt-dlp owns the data; orchestrator captures and stores in shell vars |
| Working directory management | Orchestrator | — | `mkdir -p` before yt-dlp invocation; path computed from sanitized title |
| MP3 path capture | yt-dlp `--print after_move:filepath` | Orchestrator guard | yt-dlp prints final path; orchestrator verifies the file exists |
| Stage chaining | Orchestrator (existing pattern) | — | `OUTPUT_FILE=` capture extended to feed transcribe.sh |
| Transcript variant selection | Orchestrator | — | `$NO_CLEANUP` flag determines which file feeds the assemble stage |
| Markdown assembly | Orchestrator | — | bash heredoc/cat into temp file; atomic `mv` on success |
| Upload date reformatting | Orchestrator | — | `sed 's/\(.\{4\}\)\(.\{2\}\)\(.\{2\}\)/\1-\2-\3/'` on yt-dlp YYYYMMDD output |
| Title sanitization | Orchestrator | — | `sed 's/[^a-zA-Z0-9._-]/_/g'` consistent with sub-scripts |
| Fail-fast error naming | Orchestrator (`$CURRENT_STAGE` ERR trap) | — | Extended with download, metadata, assemble stages |

---

## Standard Stack

### Core
| Library / Tool | Version | Purpose | Why Standard |
|---------------|---------|---------|--------------|
| yt-dlp | Latest via `brew upgrade yt-dlp` | YouTube audio download + MP3 extraction + metadata | Project decision; most resilient to YouTube 2026 changes |
| ffmpeg | Already installed (verified on machine) | Audio conversion (driven by yt-dlp -x) | Already in preflight; no new dependency |
| bash | 5.x (macOS system) | Orchestration, string manipulation, file I/O | Project constraint: bash only |

No new packages are installed. The phase is purely bash scripting on top of yt-dlp (already required) and ffmpeg (already required).

**No Package Legitimacy Audit required** — no new packages are added by this phase.

---

## Architecture Patterns

### System Architecture Diagram

```
transcribrr.sh (URL input)
        |
        v
[preflight] ──── URL detected? ──no──> treat as local MP3 (Phase 1 path)
        |                                        |
       yes                                       v
        |                             [Stage 1: transcribe.sh]
        v
[url-check stage]
  - playlist URL? → error + exit
        |
        v
[metadata stage]
  yt-dlp --simulate --print "%(title)s"
                    --print "%(channel|uploader)s"
                    --print "%(webpage_url)s"
                    --print "%(duration_string)s"
                    --print "%(upload_date)s"
  captures 5 lines from stdout → shell vars
        |
        v
[download stage]
  sanitize title → WORK_DIR="./<sanitized>/"
  mkdir -p "$WORK_DIR"
  yt-dlp -x --audio-format mp3 \
    --no-playlist \
    -o "$WORK_DIR/%(title)s.%(ext)s" \
    --print after_move:filepath \
    "$URL"
  MP3_FILE = captured filepath (verified file exists)
        |
        v
[Stage 1/3: transcribe.sh "$MP3_FILE" --model "$WHISPER_MODEL"]
  OUTPUT_FILE= → TRANSCRIPT_FILE
        |
        v
[Stage 2/3: cleanup-transcript.sh (if !NO_CLEANUP)]
  OUTPUT_FILE= → CLEANED_FILE
        |
        v
[Stage 3/3: summarize-transcript.sh]
  OUTPUT_FILE= → SUMMARY_FILE
        |
        v
[assemble stage]
  FINAL_MD_TITLE = sanitize_for_filename("$VIDEO_TITLE")
  TEMP_MD = mktemp
  write header + summary content + transcript content → TEMP_MD
  mv TEMP_MD → "./${FINAL_MD_TITLE}.md"
        |
        v
  [Done] → print path to final .md
```

### Recommended File Structure
No new files are created. All changes are to `transcribrr.sh` at the repo root.

```
transcribrr.sh          # Extended orchestrator (the only file changed)
./<sanitized-title>/    # Working dir created per-run (gitignored by *.mp3 or new pattern)
  ├── <title>.mp3       # Downloaded audio
  ├── <title>_transcript_<model>.txt
  ├── <title>_transcription_<model>.log
  ├── <title>_whisper_<model>.pid
  ├── <title>_cleaned_<model>.txt (if cleanup ran)
  └── <title>_summary_<model>_<style>.md
<sanitized-title>.md    # Final output at CWD root (written only on full success)
```

**Note:** The working directory itself and the final `.md` at CWD root are NOT currently covered by `.gitignore`. The planner should include a task to add patterns for `*/` (or more specific `*_work/`) and `*.md` (or the specific output pattern) if the user wants them gitignored.

---

## Key Technical Patterns

### Pattern 1: URL vs Local Path Detection

**What:** Check the positional argument before any stage runs.
**When to use:** At flag parsing time; drives whether yt-dlp preflight runs.

```bash
# [ASSUMED] — standard bash pattern; not specific to yt-dlp docs
IS_URL=false
if [[ "$INPUT_ARG" =~ ^https?:// ]] || [[ "$INPUT_ARG" =~ youtu\.?be ]]; then
    IS_URL=true
fi
```

The pattern `^https?://` catches all standard URLs. Adding `youtu\.?be` catches shortlinks. The condition must be checked before `preflight_check()` so that yt-dlp is only validated when actually needed.

### Pattern 2: Playlist URL Rejection (url-check stage)

**What:** Detect playlist URLs by pattern matching before any download starts.
**When to use:** Immediately after URL is confirmed, in a `url-check` stage that sets `$CURRENT_STAGE`.

YouTube playlist URL signatures [CITED: yt-dlp GitHub README + community patterns]:
- `youtube.com/playlist?list=` — pure playlist page
- `watch?v=...&list=` — video+playlist combo URL
- Shortlink with `?list=` parameter

```bash
# [ASSUMED] — derived from YouTube URL structure, not yt-dlp docs
CURRENT_STAGE="url-check"
if [[ "$URL" =~ [?&]list= ]] || [[ "$URL" =~ youtube\.com/playlist ]]; then
    echo "Error: Playlist URLs are not supported in v1." >&2
    echo "  To download a single video from a playlist URL, remove the '&list=...' parameter." >&2
    exit 1
fi
```

**Alternative (yt-dlp-level enforcement):** `--no-playlist` prevents yt-dlp from downloading all entries when a URL references both a video and a playlist. However, it does NOT error on a pure playlist URL — it would attempt to download the first video only. For clear user-facing errors on playlist URLs, bash-level pattern matching before invocation is more reliable.

### Pattern 3: Single-Pass Metadata Capture (metadata stage)

**What:** Run yt-dlp in simulate mode to extract metadata without downloading.
**When to use:** Before the download stage; populates shell variables for the header.

Multiple `--print` flags each emit one line on stdout in the order specified [CITED: yt-dlp man page — Arch Linux]. Use `--simulate` to skip the download entirely for the metadata pass.

```bash
# [CITED: yt-dlp man page (Arch Linux) — --print, --simulate]
CURRENT_STAGE="metadata"
stage_banner "Fetching video metadata..."

mapfile -t META < <(yt-dlp \
    --simulate \
    --no-playlist \
    --print "%(title)s" \
    --print "%(channel|uploader)s" \
    --print "%(webpage_url)s" \
    --print "%(duration_string)s" \
    --print "%(upload_date)s" \
    "$URL" 2>/dev/null)

VIDEO_TITLE="${META[0]}"
VIDEO_CHANNEL="${META[1]}"
VIDEO_URL="${META[2]}"
VIDEO_DURATION="${META[3]}"
VIDEO_UPLOAD_DATE_RAW="${META[4]}"   # YYYYMMDD
```

**Rationale for `--simulate` separation from download:** Mixing `--print` metadata fields with `--print after_move:filepath` in a single invocation intermingles metadata lines with the filepath line on stdout. The download invocation's `after_move:` timing fires after post-processing, but the other fields fire at `video` timing (before download). The order of output lines in a mixed invocation may not be deterministic across yt-dlp versions. Separating concerns is safer.

**`channel` vs `uploader`:** `channel` is "the full name of the channel" (the YouTube channel display name); `uploader` is "the full name of the video uploader" (account name). For YouTube, `channel` is more likely to be populated reliably. The `%(channel|uploader)s` fallback template returns `uploader` if `channel` is absent [CITED: yt-dlp man page].

**Missing field fallback:** If a field is not available, yt-dlp outputs the string `"NA"` by default (configurable via `--output-na-placeholder`). The planner should account for this: if `VIDEO_UPLOAD_DATE_RAW == "NA"`, skip the date reformat.

### Pattern 4: Upload Date Reformatting (YYYYMMDD → YYYY-MM-DD)

**What:** yt-dlp emits `upload_date` as `YYYYMMDD` (e.g., `20241115`). The header requires `YYYY-MM-DD`.
**When to use:** In the assemble stage, when building the header.

```bash
# [ASSUMED] — standard bash sed pattern
if [[ "$VIDEO_UPLOAD_DATE_RAW" =~ ^[0-9]{8}$ ]]; then
    VIDEO_UPLOAD_DATE=$(echo "$VIDEO_UPLOAD_DATE_RAW" | \
        sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
else
    VIDEO_UPLOAD_DATE="$VIDEO_UPLOAD_DATE_RAW"  # "NA" passes through unchanged
fi
```

### Pattern 5: Working Directory + Download Stage

**What:** Compute the sanitized title, create the working dir, run yt-dlp with an explicit `-o` template, capture the resulting MP3 path.
**When to use:** After metadata stage (title is now known); before Stage 1.

```bash
# [CITED: yt-dlp man page — -o template, --restrict-filenames, after_move:filepath]
# [CITED: Issue #7889 — after_move:filepath correctly tracks the post-extraction .mp3 path]

CURRENT_STAGE="download"

# Sanitize title for safe directory name (same sed approach as sub-scripts)
# [ASSUMED] — consistent with cleanup-transcript.sh MODEL_LABEL sanitizer
SAFE_TITLE=$(echo "$VIDEO_TITLE" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
WORK_DIR="$(pwd)/${SAFE_TITLE}"

mkdir -p "$WORK_DIR"

stage_banner "Stage 0/4: Downloading audio..."

MP3_FILE=$(yt-dlp \
    -x --audio-format mp3 \
    --no-playlist \
    -o "${WORK_DIR}/%(title)s.%(ext)s" \
    --print "after_move:filepath" \
    "$URL")

# Guard: verify the file exists (handles after_move:filepath reliability edge case)
if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
    # Fallback: find the most recently modified .mp3 in WORK_DIR
    MP3_FILE=$(find "$WORK_DIR" -name "*.mp3" -newer "$WORK_DIR" 2>/dev/null | sort -t_ -k1 | tail -1)
    if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
        echo "Error: download stage did not produce a valid MP3 file in $WORK_DIR" >&2
        exit 1
    fi
fi
```

**Why the guard:** Issue #13394 documents that `after_move:filepath` occasionally outputs a stale or intermediate name (e.g., `.f251.webm`) instead of the final `.mp3` — particularly when yt-dlp selects a format code-named stream before post-processing. The guard catches this by falling back to the newest `.mp3` in the working dir.

**`-o` template approach vs pre-computing filename:** We cannot reliably pre-compute the exact filesystem name yt-dlp will produce (the sanitization logic is complex, platform-specific, and handles Unicode differently from `--restrict-filenames`). Providing an explicit `-o` template with our own sanitized directory and `%(title)s.%(ext)s` means yt-dlp's sanitization applies only to the title within a known directory. Combining this with `--print after_move:filepath` gives the actual name. The file-existence guard handles the reliability edge case.

### Pattern 6: Stage Count Update

**What:** Phase 1 uses `Stage 1/3`, `Stage 2/3`, `Stage 3/3`. Phase 2 adds a download/metadata stage before and an assemble stage after.
**Recommendation:** Renumber banners to reflect the full pipeline. Suggest: Stage 1/5 (download), Stage 2/5 (transcribe), Stage 3/5 (cleanup), Stage 4/5 (summarize), Stage 5/5 (assemble). Or keep the existing sub-script banners unchanged and add wrapper banners in `transcribrr.sh` only.

### Pattern 7: Final Markdown Assembly (assemble stage)

**What:** Concatenate header, summary content, and transcript content into a temp file; atomic move on success.
**When to use:** After Stage 3 completes and all files are verified.

```bash
# [ASSUMED] — standard bash temp file + atomic mv pattern
CURRENT_STAGE="assemble"
stage_banner "Stage 5/5: Assembling final markdown..."

FINAL_MD_NAME="${SAFE_TITLE}.md"
FINAL_MD_PATH="$(pwd)/${FINAL_MD_NAME}"
TEMP_MD=$(mktemp)

# Determine which transcript to embed
if [ "$NO_CLEANUP" = false ] && [ -n "$CLEANED_FILE" ] && [ -f "$CLEANED_FILE" ]; then
    EMBED_TRANSCRIPT="$CLEANED_FILE"
else
    EMBED_TRANSCRIPT="$TRANSCRIPT_FILE"
fi

# Write header
{
    echo "# ${VIDEO_TITLE}"
    echo ""
    echo "- **Title:** ${VIDEO_TITLE}"
    echo "- **Channel:** ${VIDEO_CHANNEL}"
    echo "- **Source URL:** ${VIDEO_URL}"
    echo "- **Duration:** ${VIDEO_DURATION}"
    echo "- **Upload date:** ${VIDEO_UPLOAD_DATE}"
    echo "- **Models used:** whisper=${WHISPER_MODEL}, cleanup=${CLEANUP_MODEL}, summary=${SUMMARY_MODEL} (${SUMMARY_STYLE})"
    echo ""
    echo "## Summary"
    echo ""
    # Strip the summary file's own header (it includes a # heading and metadata block)
    # summarize-transcript.sh produces: "# <source_name>\n\n*Originally from: ...*\n\n---\n\n<content>"
    # We want just <content> — skip lines until we pass the "---" separator
    sed '1,/^---/d' "$SUMMARY_FILE"
    echo ""
    echo "## Transcript"
    echo ""
    cat "$EMBED_TRANSCRIPT"
} > "$TEMP_MD"

mv "$TEMP_MD" "$FINAL_MD_PATH"
```

**Summary file header stripping:** `summarize-transcript.sh` writes its own `#` heading, `*Originally from:*` line, and `---` separator at the top of every output file (for both blog and non-blog styles). When embedding into the final markdown, these must be stripped so the assembled document has a single `#` title at the top. Use `sed '1,/^---/d'` to skip everything up to and including the `---` line.

**`--no-cleanup` and models-used line:** When `--no-cleanup` is true, `CLEANUP_MODEL` is still defined (it has a default) but was never used. The header should reflect this: either omit cleanup from the models line or annotate it as `(skipped)`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| YouTube audio download | Custom HTTP fetcher | `yt-dlp -x --audio-format mp3` | yt-dlp handles format negotiation, bot detection, cookies, rate limiting, format changes |
| MP3 conversion from video | Direct ffmpeg invocation | `yt-dlp -x --audio-format mp3` (drives ffmpeg) | yt-dlp selects the correct codec flags and handles container extraction |
| Metadata extraction | YouTube API or HTML scraping | `yt-dlp --print` field templates | yt-dlp normalizes fields across YouTube changes; no API key needed |
| JSON parsing of metadata | `jq` or custom parser | `--print` multi-field template (one field per line) | Eliminates `jq` dependency; each `--print` emits one line in order |
| Atomic file write | In-place assembly | `mktemp` + `mv` | Ensures final `.md` is never partial if a stage errors mid-write |

**Key insight:** yt-dlp's `--print` template system eliminates the need for JSON parsing entirely. Capture one field per `--print` flag, read into a bash array with `mapfile`, and assign to named variables.

---

## Common Pitfalls

### Pitfall 1: `after_move:filepath` Output Reliability
**What goes wrong:** `--print after_move:filepath` occasionally prints an intermediate path (e.g., `.f251.webm`) instead of the final `.mp3` path, especially when yt-dlp internally selects a format-code-named stream [CITED: Issue #13394].
**Why it happens:** The `after_move` hook fires after the file move, but in some format selection paths the intermediate file object that carries the path may reference the pre-conversion name.
**How to avoid:** Always verify `[ -f "$MP3_FILE" ]` after capturing the path. If the file doesn't exist (or is not `.mp3`), fall back to `find "$WORK_DIR" -name "*.mp3" -newer ... | tail -1`.
**Warning signs:** `MP3_FILE` contains `.webm` or `.f251.` in the name, or `[ ! -f "$MP3_FILE" ]` is true.

### Pitfall 2: `set -euo pipefail` + Command Substitution Disables `set -e` in Subshell
**What goes wrong:** Within `$(...)`, bash disables `set -e` by default. A failing yt-dlp invocation inside `$()` will NOT trigger the ERR trap — the substitution returns an empty string and execution continues [CITED: koalaman/shellcheck SC2311; ecmwf.int shell guidelines].
**Why it happens:** POSIX requirement: `set -e` is inherited by subshells invoked with `bash -c` but NOT by `$(...)` command substitution in bash < 4.4 without `shopt -s inherit_errexit`.
**How to avoid:** After every `$()` that captures yt-dlp output, add an explicit exit-code check or `|| exit 1`. The existing `transcribrr.sh` already uses this pattern (it checks `if [ -z "$STAGE_OUT" ]`). Apply the same guard after the metadata `mapfile` call.
**Warning signs:** Metadata variables are empty but the script continues without error.

### Pitfall 3: Interleaved stdout/stderr in yt-dlp Capture
**What goes wrong:** yt-dlp progress messages, warnings, and `[download]` status lines go to stderr, but some informational messages go to stdout. If you redirect stderr to stdout (`2>&1`) before capturing, you capture progress noise mixed with the `--print` output.
**Why it happens:** The existing `transcribrr.sh` pattern (`| tee /dev/stderr | grep "^OUTPUT_FILE="`) works because the sub-scripts emit `OUTPUT_FILE=` on stdout. yt-dlp's `--print` output also goes to stdout. Redirecting `2>/dev/null` suppresses yt-dlp's progress on stderr while keeping `--print` output clean on stdout.
**How to avoid:** Use `2>/dev/null` when capturing `--print` output. Display yt-dlp download progress by NOT redirecting stderr (or redirecting stderr to fd 2 / the terminal). For the metadata `--simulate` call, `2>/dev/null` is appropriate since no download occurs.
**Warning signs:** Metadata variable contains `[youtube]` or `[download]` prefixed lines.

### Pitfall 4: Missing Metadata Fields ("NA") Causing Broken Markdown
**What goes wrong:** Private videos, age-gated videos, or videos with incomplete metadata may have `upload_date`, `channel`, or `duration_string` return `"NA"`. Writing `"NA"` directly into the header without checks produces valid but misleading markdown.
**Why it happens:** yt-dlp uses `"NA"` as the default placeholder for missing/unavailable fields (configurable via `--output-na-placeholder`) [CITED: yt-dlp man page].
**How to avoid:** For `upload_date`: guard the reformat with `[[ "$VAR" =~ ^[0-9]{8}$ ]]`. For other fields: `NA` passes through literally — this is acceptable behavior for v1. Document in `--help` that some fields may show "NA" for private/age-gated content.
**Warning signs:** Date reformat produces `N-A-` or similar malformed string.

### Pitfall 5: Working Directory Name Collision
**What goes wrong:** If two different YouTube videos sanitize to the same title (e.g., two videos titled "Introduction"), the second run would reuse the same working directory and potentially overwrite the MP3 before transcription completes.
**Why it happens:** Title sanitization is lossy; `sed 's/[^a-zA-Z0-9._-]/_/g'` collapses many distinct titles to the same string.
**How to avoid (Claude's discretion):** Append the video ID to the working directory name, or append a timestamp suffix. The simplest collision-safe approach: `WORK_DIR="${SAFE_TITLE}_${VIDEO_ID}"` (video ID from `%(id)s` in the metadata pass). This is within Claude's discretion per CONTEXT.md.
**Warning signs:** Script finds an MP3 in the working directory that pre-dates the current run.

### Pitfall 6: Summary File Header Contamination in Final Markdown
**What goes wrong:** `summarize-transcript.sh` writes its own `#` heading and metadata block at the top of every output file. If the orchestrator does `cat "$SUMMARY_FILE"` directly into the final `.md`, the final document will have two `#` headings and a confusing metadata table from the summarizer.
**Why it happens:** `summarize-transcript.sh` was designed as a standalone tool with its own output header.
**How to avoid:** Strip the summary file's header before embedding. Use `sed '1,/^---/d'` to skip everything up to and including the `---` divider line that separates the header from the generated content.
**Warning signs:** Final `.md` has duplicate `#` headings or a `| **Source** |` table immediately after the metadata block.

### Pitfall 7: Stage Count Banner Inconsistency
**What goes wrong:** Phase 1 hardcodes `Stage 1/3`, `Stage 2/3`, `Stage 3/3` banners in `transcribrr.sh`. Phase 2 adds stages but the sub-scripts also print their own progress.
**Why it happens:** The banners are cosmetic and hardcoded; Phase 1 had 3 stages; Phase 2 has 5.
**How to avoid:** Update the stage banners in `transcribrr.sh` to reflect the full 5-stage pipeline. Sub-script internal messages cannot be changed (they are standalone tools).

### Pitfall 8: `.gitignore` Does Not Cover New Artifacts
**What goes wrong:** The final `.md` file at CWD root and the working directory (e.g., `My_Video_Title/`) are not covered by the existing `.gitignore`. Accidental `git add .` would commit them.
**Why it happens:** `.gitignore` was written for Phase 1 which had no working directory concept and no CWD-root `.md` output.
**How to avoid:** Add patterns to `.gitignore` for the new artifact types. Suggested additions:
- `*_work/` or directory-level patterns for working dirs
- Possibly a note in README about the output `.md`; the user may intentionally want to commit or keep the final output.
**Warning signs:** `git status` shows untracked directories and `.md` files after a run.

---

## Code Examples

### Metadata capture with mapfile
```bash
# [CITED: yt-dlp man page — multiple --print flags, --simulate; mapfile is bash built-in]
mapfile -t META < <(yt-dlp \
    --simulate \
    --no-playlist \
    --print "%(title)s" \
    --print "%(channel|uploader)s" \
    --print "%(webpage_url)s" \
    --print "%(duration_string)s" \
    --print "%(upload_date)s" \
    "$URL" 2>/dev/null)

# Validate we got 5 lines
if [ "${#META[@]}" -lt 5 ]; then
    echo "Error: metadata stage returned fewer fields than expected." >&2
    exit 1
fi
```

### Upload date reformat
```bash
# [ASSUMED] — standard bash/sed pattern
if [[ "${META[4]}" =~ ^[0-9]{8}$ ]]; then
    VIDEO_UPLOAD_DATE=$(echo "${META[4]}" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
else
    VIDEO_UPLOAD_DATE="${META[4]}"  # "NA" or unexpected format passes through
fi
```

### Atomic markdown assembly
```bash
# [ASSUMED] — standard temp file + mv pattern
TEMP_MD=$(mktemp)
trap 'rm -f "$TEMP_MD"' EXIT  # Clean up temp on any exit

{
    printf "# %s\n\n" "$VIDEO_TITLE"
    printf -- "- **Title:** %s\n" "$VIDEO_TITLE"
    printf -- "- **Channel:** %s\n" "$VIDEO_CHANNEL"
    printf -- "- **Source URL:** %s\n" "$VIDEO_URL"
    printf -- "- **Duration:** %s\n" "$VIDEO_DURATION"
    printf -- "- **Upload date:** %s\n" "$VIDEO_UPLOAD_DATE"
    printf -- "- **Models used:** whisper=%s" "$WHISPER_MODEL"
    if [ "$NO_CLEANUP" = false ]; then
        printf ", cleanup=%s" "$CLEANUP_MODEL"
    else
        printf ", cleanup=skipped"
    fi
    printf ", summary=%s (%s)\n\n" "$SUMMARY_MODEL" "$SUMMARY_STYLE"
    printf "## Summary\n\n"
    sed '1,/^---/d' "$SUMMARY_FILE"
    printf "\n## Transcript\n\n"
    cat "$EMBED_TRANSCRIPT"
} > "$TEMP_MD"

mv "$TEMP_MD" "$FINAL_MD_PATH"
trap - EXIT  # Remove temp cleanup trap after successful mv
```

**Note on `trap 'rm -f "$TEMP_MD"' EXIT`:** This interacts with the existing `trap ... ERR`. Bash supports only one trap per signal; setting a new `EXIT` trap will replace any existing one. Review whether `transcribrr.sh` already uses an `EXIT` trap. If not, add the temp-cleanup trap, but use a function that both cleans up the temp file AND honors the original trap behavior.

### Stage banner count update
```bash
# Phase 2 replaces Phase 1's 3-stage banners with 5-stage
stage_banner "Stage 1/5: Downloading audio (yt-dlp)"
# ... download ...
stage_banner "Stage 2/5: Transcribing (whisper model: $WHISPER_MODEL)"
# ... transcribe ...
stage_banner "Stage 3/5: Cleaning transcript (model: $CLEANUP_MODEL)"
# ... cleanup ...
stage_banner "Stage 4/5: Summarizing (model: $SUMMARY_MODEL, style: $SUMMARY_STYLE)"
# ... summarize ...
stage_banner "Stage 5/5: Assembling final markdown"
# ... assemble ...
```

---

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|-----------------|--------|
| youtube-dl | yt-dlp (active fork, 2021+) | yt-dlp maintained against YouTube's 2026 API changes; youtube-dl largely stale |
| Separate download + metadata calls | Single `--print` multi-field in simulate mode | One network hit for all metadata |
| Parsing `--get-title`, `--get-id` etc. | `--print "%(field)s"` templates | `--get-*` flags are deprecated in yt-dlp; `--print` is the current API |
| `--get-filename` for path prediction | `--print after_move:filepath` | `--get-filename` is deprecated; `after_move:filepath` is the current path-capture mechanism |

**Deprecated/outdated:**
- `--get-title`, `--get-id`, `--get-filename`, `--get-format`: all deprecated in yt-dlp in favor of `--print "%(field)s"` templates. [ASSUMED — based on training knowledge; verify with `yt-dlp --help` at execution time]
- `youtube-dl`: project is largely unmaintained; yt-dlp is the maintained fork [CITED: yt-dlp GitHub README]

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `[[ "$INPUT" =~ ^https?:// ]]` reliably distinguishes URLs from local paths | Pattern 1 | Low — any path that starts with `http://` or `https://` is a URL; local paths never do |
| A2 | `sed '1,/^---/d'` strips the summarizer's header correctly | Pattern 7, Pitfall 6 | Medium — if `summarize-transcript.sh` changes its `---` separator position, the strip logic breaks. Verify against actual summarizer output during implementation |
| A3 | `--print` flags in `--simulate` mode do not trigger a network download | Pattern 3 | Low — `--simulate` is documented to bypass downloading [CITED: yt-dlp man page]; confirmed by flag description |
| A4 | `%(channel\|uploader)s` fallback syntax works in yt-dlp `--print` | Pattern 3 | Low — yt-dlp template fallback `\|` syntax is documented in man page [CITED] |
| A5 | `--get-title`, `--get-filename` etc. are deprecated (use `--print` instead) | State of the Art | Low — verify with `yt-dlp --help` at execution time; worst case, both options work |
| A6 | Title sanitization via `sed 's/[^a-zA-Z0-9._-]/_/g'` produces safe directory names on macOS | Pattern 5 | Low — macOS allows all characters except `/` and null; this regex is conservative enough |
| A7 | The summary file always contains a `---` separator line that can be used to strip its header | Pitfall 6, Pattern 7 | Medium — depends on `summarize-transcript.sh` output format. Confirmed by reading the script: both `blog` and non-blog styles write `---\n\n` (lines 434–445 of summarize-transcript.sh). VERIFIED by code inspection |
| A8 | `mapfile -t META < <(...)` correctly captures multi-line yt-dlp `--print` output | Pattern 3 | Low — `mapfile` is a bash built-in; confirmed behavior for line-at-a-time capture |

---

## Open Questions (RESOLVED)

1. **Working directory `.gitignore` coverage**
   - What we know: The final `.md` and `<title>/` working dir are not covered by existing `.gitignore`.
   - What's unclear: Does the user want to commit or keep the final `.md`? The intermediate working directory is clearly unwanted.
   - Recommendation: Add `*/` (or a more specific pattern) to `.gitignore` for the working dirs, and add a note in the plan; leave the final `.md` decision to the user.
   - RESOLVED: 02-02 Task 2 adds the directory glob `*_*/` (matching the `<SAFE_TITLE>_<VIDEO_ID>/` working dirs) to `.gitignore`, with a comment that the root `*.md` output is intentionally NOT ignored so the user may keep it. Existing intermediate patterns are preserved.

2. **Working directory naming collision**
   - What we know: CONTEXT.md assigns this to Claude's discretion.
   - What's unclear: Should the video ID be appended (guaranteed unique) or a timestamp (easier to read)?
   - Recommendation: Append the video ID from `%(id)s` in the metadata pass: `WORK_DIR="${SAFE_TITLE}_${VIDEO_ID}"`. One extra line in the metadata mapfile (6 fields instead of 5).
   - RESOLVED: 02-01 Task 2 captures `%(id)s` as the 6th metadata field (`VIDEO_ID`) and sets `WORK_DIR="$(pwd)/${SAFE_TITLE}_${VIDEO_ID}"` — the `_${VIDEO_ID}` suffix guarantees collision-free per-video directories.

3. **`EXIT` trap interaction with temp file cleanup**
   - What we know: `transcribrr.sh` currently has only an ERR trap, not an EXIT trap.
   - What's unclear: Will adding an EXIT trap for temp file cleanup interfere with the ERR trap behavior?
   - Recommendation: Bash ERR and EXIT traps coexist (different signals). The temp-file cleanup EXIT trap is safe to add. Use a cleanup function and `trap cleanup EXIT` to allow the function to handle both scenarios.
   - RESOLVED: ERR and EXIT are distinct trap signals and coexist safely. 02-02 Task 1 adds an EXIT trap that removes `$TEMP_MD` on premature exit and clears it (`trap - EXIT`) immediately after the successful atomic `mv`, leaving the existing `$CURRENT_STAGE` ERR trap untouched.

4. **yt-dlp version on the user's machine**
   - What we know: yt-dlp is NOT currently installed on the developer's machine (verified: `yt-dlp --version` returns NOT_INSTALLED).
   - What's unclear: Which version will be installed? The `--print after_move:filepath` behavior has minor version drift.
   - Recommendation: The preflight check should include a `brew upgrade yt-dlp` recommendation in the hint message, and execution should work with any yt-dlp version supporting `--print` (2021+).
   - RESOLVED: Any yt-dlp version supporting `--print` (2021+) is acceptable; 02-01 Task 1's preflight enforces presence with the `brew install yt-dlp` hint, and 02-01 Task 2's download-stage file-existence guard (find-newest-`*.mp3` fallback) absorbs the `after_move:filepath` version drift.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| yt-dlp | DL-02, DL-03, DL-04 | NOT INSTALLED | — | `brew install yt-dlp` (user must install; preflight enforces) |
| ffmpeg | DL-03 (MP3 conversion) | Installed | N-102648 (evermeet build) | — |
| bash | Orchestration | Installed | System (macOS) | — |
| mktemp | Atomic assembly | Installed | BSD mktemp | — |
| mapfile | Metadata capture | Installed | bash 4+ built-in | fallback: `while IFS= read -r line; do ...` |

**Missing dependencies with no fallback:**
- `yt-dlp` — must be installed before Phase 2 can run. The preflight check gates this with an actionable message.

**Missing dependencies with fallback:**
- `mapfile` — if bash version < 4 (unlikely on macOS 10.15+), use a `while read` loop instead.

---

## Security Domain

Security enforcement is enabled. This phase introduces `yt-dlp` URL execution and file I/O.

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | No user auth in this tool |
| V3 Session Management | No | Stateless CLI tool |
| V4 Access Control | No | Single-user local tool |
| V5 Input Validation | Yes | URL validation before yt-dlp invocation; playlist URL rejection |
| V6 Cryptography | No | No crypto in this phase |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| URL injection via positional arg | Tampering | yt-dlp treats the URL as a literal argument (no shell eval); bash `"$URL"` double-quoting prevents word splitting |
| Working directory traversal | Elevation of privilege | `SAFE_TITLE` sanitization removes `/` and other path chars; `$(pwd)/` prefix makes path absolute |
| Partial/corrupt output file being read as complete | Tampering | Atomic `mv` from temp file; final `.md` only exists if all stages succeed |
| yt-dlp downloading malicious content | Spoofing | Out of scope for v1; yt-dlp's own security posture applies |

**Note on double-quoting:** All shell variables that incorporate user-supplied input (`$URL`, `$SAFE_TITLE`, `$VIDEO_TITLE`, etc.) must be double-quoted in every bash expansion to prevent word splitting and glob expansion. This is enforced by `set -u` (catches unset variables) but quoting must be done manually.

---

## Sources

### Primary (HIGH confidence)
- yt-dlp man page (Arch Linux) — `--print`, timing values, `--simulate`, `--no-playlist`, field names, fallback syntax: https://man.archlinux.org/man/extra/yt-dlp/yt-dlp.1.en
- yt-dlp README (GitHub, raw) — OUTPUT TEMPLATE fields, `after_move:filepath` semantics, `--restrict-filenames`: https://raw.githubusercontent.com/yt-dlp/yt-dlp/master/README.md
- koalaman/shellcheck SC2311 — `set -e` not inherited in `$()`: https://github.com/koalaman/shellcheck/wiki/SC2311

### Secondary (MEDIUM confidence)
- Issue #7889 (`after_move:filename` vs `after_move:filepath`) — confirmed `filepath` is correct for MP3 after `-x`: https://github.com/yt-dlp/yt-dlp/issues/7889
- Issue #13394 (`after_move:filepath` reliability edge case) — documents the need for a file-existence guard: https://github.com/yt-dlp/yt-dlp/issues/13394
- deepwiki.com yt-dlp sanitization — `--restrict-filenames` behavior vs default Unicode sanitization: https://deepwiki.com/yt-dlp/yt-dlp/5.3-sanitization-and-formatting

### Tertiary (LOW confidence)
- Issue #12469 — community workarounds for reliable filename capture (no official solution documented)
- ecmwf shell guidelines — `inherit_errexit` and command substitution `set -e` behavior

### Codebase (VERIFIED by direct inspection)
- `transcribrr.sh` — ERR trap pattern, `$CURRENT_STAGE`, `OUTPUT_FILE=` capture via `grep`, stage structure
- `summarize-transcript.sh` — confirms `---` separator at line 445 (blog and non-blog styles both write it)
- `cleanup-transcript.sh` — MODEL_LABEL sanitizer: `sed 's/mlx-community\///' | sed 's/[^a-zA-Z0-9.-]/_/g' | tr '[:upper:]' '[:lower:]'`
- `.gitignore` — confirms existing patterns; working dir and CWD-root `.md` are NOT covered

---

## Metadata

**Confidence breakdown:**
- yt-dlp flag behavior: HIGH — documented in man page and verified via GitHub issues
- `after_move:filepath` reliability: MEDIUM — documented edge case (Issue #13394); mitigation pattern is LOW-confidence (file-existence guard is common sense, not officially prescribed)
- bash patterns (URL detection, sed, mapfile): HIGH — standard bash idioms
- Summary file header stripping: HIGH — verified by reading `summarize-transcript.sh` directly
- `.gitignore` gaps: HIGH — verified by reading `.gitignore` directly

**Research date:** 2026-06-14
**Valid until:** 2026-08-01 (yt-dlp changes frequently; re-verify `--print` flag behavior if yt-dlp is upgraded)
