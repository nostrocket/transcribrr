---
phase: 02-end-to-end-youtube-to-markdown-delivery
verified: 2026-06-14T20:30:00Z
status: human_needed
score: 4/4 roadmap success criteria verified (all statically checkable truths pass)
overrides_applied: 0
human_verification:
  - test: "Run ./transcribrr.sh with a real YouTube single-video URL on stock macOS /bin/bash"
    expected: "Script downloads audio to MP3, captures metadata, transcribes via whisper, cleans, summarizes, and writes one markdown file at CWD root named <sanitized-title>.md containing rich header then summary then transcript. Exit 0."
    why_human: "Requires yt-dlp installed, network access, and MLX models on Apple Silicon — not available in the verification environment."
  - test: "Run ./transcribrr.sh with a playlist URL (e.g. ?list=PLxxx appended)"
    expected: "Script exits non-zero before any download with 'Error: Playlist URLs are not supported in v1.' message naming the url-check stage via the ERR trap."
    why_human: "Requires yt-dlp present so preflight passes and the url-check stage is reached; yt-dlp not installed in this environment."
  - test: "Run ./transcribrr.sh with a local MP3 end-to-end with --no-cleanup"
    expected: "Final markdown header shows 'cleanup=skipped'; embedded transcript is the raw transcript (not a cleaned file); no yt-dlp invocation occurs."
    why_human: "Requires MLX models (transcribe.sh, summarize-transcript.sh) to be installed and runnable."
  - test: "Run ./transcribrr.sh twice with the same local MP3"
    expected: "Second run exits with 'Error: <path>.md already exists; refusing to overwrite.' — no data loss."
    why_human: "Requires a first successful run to produce the .md, which requires MLX models."
---

# Phase 02: End-to-End YouTube-to-Markdown Delivery — Verification Report

**Phase Goal:** From a single command with a YouTube URL, the script downloads audio to MP3, captures video metadata, runs the full pipeline from Phase 1, and assembles one markdown file (rich header → summary → full transcript) — failing fast with a named stage on any error and only writing the final file on full success.
**Verified:** 2026-06-14T20:30:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Roadmap Success Criteria

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC-1 | Given a YouTube URL, the script downloads and exports MP3 audio via yt-dlp/ffmpeg and captures title, channel, source URL, duration, and upload date | ✓ VERIFIED (static) + ? HUMAN (runtime) | `yt-dlp -x --audio-format mp3` at line 316–321; `--simulate --print` metadata loop lines 253–262; VIDEO_TITLE/CHANNEL/URL/DURATION/UPLOAD_DATE_RAW/VIDEO_ID assigned lines 283–288. Runtime execution needs human (yt-dlp not installed). |
| SC-2 | The script produces exactly one markdown file containing, in order, a rich header (title, channel, URL, duration, upload date, models used), the summary, and the full transcript | ✓ VERIFIED (static) + ? HUMAN (runtime) | Assemble block lines 454–474: `printf "# ..."`, bulleted metadata fields, `printf "## Summary\n\n"`, `sed '1,/^---/d' "$SUMMARY_FILE"`, `printf "\n## Transcript\n\n"`, `cat "$EMBED_TRANSCRIPT"`. Atomic `mv "$TEMP_MD" "$FINAL_MD_PATH"` line 477; EXIT trap line 443 removes temp on premature exit. Runtime execution needs human. |
| SC-3 | The final markdown filename is derived from the sanitized video title at a predictable path | ✓ VERIFIED | `SAFE_TITLE` set on URL path (line 299) via allow-list `sed 's/[^a-zA-Z0-9._-]/_/g'`; set on local path (lines 145–147) via `basename … ${SAFE_TITLE%.*}` + same sanitizer. `FINAL_MD_PATH="$(pwd)/${SAFE_TITLE}.md"` line 431. Both paths covered. Empty-title fallback line 150/303. |
| SC-4 | If any stage fails, the script aborts with a message naming the failing stage and does not write a partial final markdown file | ✓ VERIFIED | ERR trap at line 27 prints `$CURRENT_STAGE`; all eight stage names set (preflight/url-check/metadata/download/transcribe/cleanup/summarize/assemble — lines 26,225,237,311,336,357,382,403). `TEMP_MD=$(mktemp)` + `trap 'rm -f "$TEMP_MD"' EXIT` ensures no partial final file; `FINAL_MD_PATH` only written via atomic `mv` after full success. |

**Score:** 4/4 roadmap success criteria — all statically verifiable aspects confirmed.

### Deferred Items

None. All phase success criteria are addressed in Phase 2.

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `transcribrr.sh` | URL auto-detection, metadata/download/assemble stages, bash-3.2 compatible | ✓ VERIFIED | 485 lines; `bash -n` passes; no `mapfile`/`readarray` executable calls (only a comment at line 244); bash-3.2 read loop lines 251–252. |
| `.gitignore` | Per-video working directory ignore pattern `*_*/` | ✓ VERIFIED | Pattern present at line 22; comment at line 20–21 explains scope; all prior intermediate patterns preserved. |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| URL detection block | Assemble stage `FINAL_MD_PATH` | `SAFE_TITLE` set on both URL (line 299) and local-MP3 (line 145) paths | ✓ WIRED | `FINAL_MD_PATH="$(pwd)/${SAFE_TITLE}.md"` line 431; `set -u` safe on both paths |
| Download stage | Transcribe stage | `MP3_FILE` populated by `yt-dlp` output (line 316), consumed by `transcribe.sh "$MP3_FILE"` (line 343) | ✓ WIRED | Fallback `find "$WORK_DIR" -name "*.mp3"` line 325 handles stale path |
| Metadata stage | Downstream header variables | `META[]` array from yt-dlp read loop assigned to `VIDEO_TITLE/CHANNEL/URL/DURATION/UPLOAD_DATE_RAW/VIDEO_ID` lines 283–288 | ✓ WIRED | Exact field-count guard (`-ne 6`) line 271; `META_ERR` surfaces yt-dlp stderr on failure |
| Assemble stage | `SUMMARY_FILE` and `EMBED_TRANSCRIPT` | `sed '1,/^---/d'` strips summary header (line 471); transcript variant selected by `NO_CLEANUP` + `CLEANED_FILE` (lines 446–449) | ✓ WIRED | Cleaned/raw transcript selection logic correct |
| Assemble stage | `${SAFE_TITLE}.md` at CWD root | `mktemp` → write → atomic `mv` (lines 441–477); EXIT trap removes temp on premature exit | ✓ WIRED | `trap - EXIT` cleared after successful mv (line 478) |

---

## Bash-3.2 Compatibility (Platform Target: stock macOS /bin/bash 3.2.57)

| Check | Result | Evidence |
|-------|--------|---------|
| `mapfile`/`readarray` — CR-01 fix confirmed | ✓ PASS | `grep -n 'mapfile\|readarray' transcribrr.sh` finds ONLY line 244 (a comment); no executable `mapfile`/`readarray` call exists |
| Metadata populated via bash-3.2 read loop | ✓ PASS | `while IFS= read -r line; do META+=("$line"); done < <(yt-dlp ...)` lines 251–262 |
| Exact field-count guard — CR-02 fix confirmed | ✓ PASS | `[ "${#META[@]}" -ne "$EXPECTED_META_FIELDS" ]` line 271 (was `-lt 6`; now `-ne 6`) |
| `EXPECTED_META_FIELDS=6` named constant | ✓ PASS | Line 242 |
| Process substitution `< <(...)` available in bash 3.2 | ✓ PASS | Process substitution is available in bash 3.2; only `mapfile` was the blocker |

---

## Code Review Fixes Verification (02-REVIEW.md)

All 2 critical and 5 warnings from the code review are confirmed fixed at commits 4c5df19, 5902661, 8b25447, 51f7127.

| Issue | Severity | Fix Status | Evidence in Code |
|-------|----------|------------|-----------------|
| CR-01: `mapfile` on bash 3.2 — aborts every URL run | Critical | ✓ FIXED (4c5df19) | Read loop lines 251–252; only comment reference at line 244 |
| CR-02: Field-count guard `-lt 6` accepts misaligned fields | Critical | ✓ FIXED (4c5df19) | `-ne "$EXPECTED_META_FIELDS"` line 271 with named constant line 242 |
| WR-01: Empty `SAFE_TITLE` yields hidden `.md` | Warning | ✓ FIXED (5902661) | Fallback `SAFE_TITLE="transcribrr_output"` lines 150–151 (local) and 303–304 (URL) |
| WR-02: `grep "^OUTPUT_FILE="` aborts before friendly guard | Warning | ✓ FIXED (8b25447) | `{ grep "^OUTPUT_FILE=" \|\| true; }` at lines 345, 366, 393 |
| WR-03: `2>/dev/null` swallows actionable yt-dlp errors | Warning | ✓ FIXED (4c5df19) | `META_ERR=$(mktemp)`; `2>"$META_ERR"`; surfaced via `sed 's/^/    /' "$META_ERR"` lines 249–281 |
| WR-04: `basename "$MP3_FILE" .mp3` leaks non-mp3 extensions | Warning | ✓ FIXED (5902661) | `SAFE_TITLE="${SAFE_TITLE%.*}"` line 146 strips any extension |
| WR-05: Final file clobbered silently | Warning | ✓ FIXED (51f7127) | `if [ -e "$FINAL_MD_PATH" ]; then … exit 1` lines 436–440 |

---

## Data-Flow Trace (Level 4)

The assemble stage is the key rendering artifact. Data flow traced for both paths:

**URL path:**
- `VIDEO_TITLE/CHANNEL/URL/DURATION/UPLOAD_DATE` ← `META[]` array ← `yt-dlp --simulate --print` (real network call, field-count-guarded)
- `SUMMARY_FILE` ← `STAGE_OUT` ← `summarize-transcript.sh` ← `SUMMARIZE_INPUT` ← `CLEANED_FILE` or `TRANSCRIPT_FILE` ← prior stages
- `EMBED_TRANSCRIPT` ← `CLEANED_FILE` (cleanup ran) or `TRANSCRIPT_FILE` (--no-cleanup)
- All three paths produce real data, not hardcoded stubs
- Status: ✓ FLOWING (statically — runtime requires MLX models)

**Local-MP3 path:**
- `VIDEO_*` fields defaulted via `${VAR:-NA}` at lines 412–428; correct and safe under `set -u`
- `SAFE_TITLE` ← `basename "$MP3_FILE"` + `${SAFE_TITLE%.*}` + sanitizer (lines 145–151)
- Status: ✓ FLOWING (defaults are correct placeholders, not corruption)

---

## Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `--help` contains URL examples | `/bin/bash transcribrr.sh --help \| grep 'https://'` | Found `https://www.youtube.com/...` and `https://youtu.be/...` | ✓ PASS |
| `--help` documents youtube-url argument | `/bin/bash transcribrr.sh --help \| grep 'youtube-url'` | Found in usage line and argument description | ✓ PASS |
| URL input with missing yt-dlp → named error + exit 1 | `/bin/bash transcribrr.sh "https://..."` | `Error: yt-dlp not found on PATH. Install with: brew install yt-dlp` + exit 1 | ✓ PASS |
| Local path with missing file → error WITHOUT yt-dlp check | `/bin/bash transcribrr.sh /tmp/test.mp3` | `Error: Input file not found: /tmp/test.mp3` — no yt-dlp message | ✓ PASS |
| Unknown flag → actionable error | `/bin/bash transcribrr.sh --invalid-flag` | `Unknown option: --invalid-flag` + exit 1 | ✓ PASS |
| Playlist rejection (requires yt-dlp at preflight) | Not runnable (yt-dlp absent) | SKIP — yt-dlp not installed | ? SKIP → human |
| Full URL-to-markdown pipeline | Not runnable (yt-dlp + MLX absent) | SKIP — network + MLX required | ? SKIP → human |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| DL-02 | 02-01-PLAN.md | Script downloads video/audio from URL using yt-dlp | ✓ SATISFIED | `yt-dlp -x` line 316; conditional on `IS_URL=true` |
| DL-03 | 02-01-PLAN.md | Script exports audio to MP3 via yt-dlp -x --audio-format mp3 | ✓ SATISFIED | `--audio-format mp3` line 318 |
| DL-04 | 02-01-PLAN.md | Script captures video metadata (title, channel, URL, duration, upload date) | ✓ SATISFIED | 6-field `--simulate --print` capture; all five DL-04 fields assigned lines 283–288 |
| OUT-01 | 02-02-PLAN.md | Script writes ONE markdown file in order: rich header, summary, full transcript | ✓ SATISFIED | Assemble block writes exactly one file via temp+mv; order confirmed (lines 454–474) |
| OUT-02 | 02-02-PLAN.md | Rich header includes title, channel, source URL, duration, upload date, and models used | ✓ SATISFIED | All six fields present (lines 455–465); `cleanup=skipped` branch for --no-cleanup |
| OUT-03 | 02-02-PLAN.md | Final markdown filename derived from sanitized video title at predictable path | ✓ SATISFIED | `FINAL_MD_PATH="$(pwd)/${SAFE_TITLE}.md"` line 431; SAFE_TITLE set on both paths |
| ROB-02 | 02-01-PLAN.md + 02-02-PLAN.md | Fails fast with actionable message naming the failing stage | ✓ SATISFIED | ERR trap line 27; all 8 stage names set in script |
| ROB-03 | 02-02-PLAN.md | Intermediates retained predictably; final file only written on full success | ✓ SATISFIED | No `rm` of `TRANSCRIPT_FILE/CLEANED_FILE/SUMMARY_FILE/MP3_FILE`; atomic temp+mv line 477; EXIT trap line 443 |

**Orphaned requirements:** None. All 8 Phase 2 requirement IDs are claimed by a plan and mapped.

---

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `transcribrr.sh` | 238, 312 | Two banners both read "Stage 1/5" (metadata banner at 238, download banner at 312) | INFO | Minor UX confusion — the metadata and download stages each emit a "Stage 1/5" banner. Functionally harmless: metadata fetching and download are sequential in the same `if IS_URL` block and the user sees one then the other. Not a correctness defect. |

No debt markers (TBD/FIXME/XXX/TODO/HACK/PLACEHOLDER) found in either `transcribrr.sh` or `.gitignore`.

No stub patterns found. No empty return values, hardcoded empty data, or placeholder strings found in modified files.

---

## Human Verification Required

### 1. Full URL-to-Markdown Pipeline

**Test:** Run `./transcribrr.sh https://www.youtube.com/watch?v=<short-video-id>` on stock macOS with yt-dlp and MLX models installed.
**Expected:** Script completes all 5 stages (url-check → metadata → download → transcribe → cleanup → summarize → assemble), produces exactly one `<sanitized-title>.md` at CWD root. File contains `# Title`, bulleted metadata block with all 5 fields, `## Summary`, summary content, `## Transcript`, full transcript. Exit 0.
**Why human:** Requires yt-dlp, network access, Apple Silicon, and MLX models. Not available in the verification environment.

### 2. Playlist URL Rejection

**Test:** Run `./transcribrr.sh "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLxxx"` with yt-dlp installed.
**Expected:** Exits non-zero before any download with "Error: Playlist URLs are not supported in v1." The ERR trap message should name "url-check" as the failing stage. No files created.
**Why human:** Requires yt-dlp present so preflight passes and the url-check stage is reached. yt-dlp absent in verification environment.

### 3. --no-cleanup Flag Produces Correct Header and Transcript

**Test:** Run `./transcribrr.sh <local.mp3> --no-cleanup` end-to-end.
**Expected:** Final markdown header shows `cleanup=skipped`; the `## Transcript` section contains the raw (not cleaned) transcript. No cleaned-transcript file referenced.
**Why human:** Requires a local MP3 plus MLX whisper and summarize models installed and runnable.

### 4. Second Run on Same Input Refuses to Overwrite

**Test:** Run `./transcribrr.sh <local.mp3>` twice in the same directory.
**Expected:** Second run exits non-zero with "Error: <path>.md already exists; refusing to overwrite." and the ERR trap names "assemble" as the failing stage. Original .md file is intact.
**Why human:** Requires a first successful full run to produce the .md output file.

### 5. Bash 3.2 Runtime Compatibility (Stock macOS)

**Test:** Invoke the script explicitly via `/bin/bash ./transcribrr.sh --help` on a stock macOS system (not Homebrew bash).
**Expected:** Help prints and exits 0 with no "command not found" or "syntax error" output.
**Why human:** The verification environment may have a different bash. The static `bash -n` check passed, but runtime execution on the exact target interpreter is a human confirmation. (Low risk — `bash -n` passed and no `mapfile`/`readarray` executable calls remain.)

---

## Gaps Summary

No gaps. All must-haves are VERIFIED by static inspection. The phase goal is achieved in the codebase. Human verification items are required only for runtime behaviors that depend on yt-dlp, network access, and MLX models unavailable in this environment.

The two code review criticals (CR-01 mapfile, CR-02 field-count guard) and all five warnings are confirmed fixed in the actual source code. The bash-3.2 compatibility requirement is the most important — confirmed: `mapfile`/`readarray` appear only in a comment; the actual implementation uses a portable `while IFS= read -r line` loop.

---

_Verified: 2026-06-14T20:30:00Z_
_Verifier: Claude (gsd-verifier)_
