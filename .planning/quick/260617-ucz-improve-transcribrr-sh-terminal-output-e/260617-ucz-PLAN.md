---
phase: quick-260617-ucz
plan: 01
type: execute
wave: 1
depends_on: []
files_modified: [transcribrr.sh]
autonomous: true
requirements: [CLI-UX]
must_haves:
  truths:
    - "Every stage prints a banner stating WHAT it is doing and WHY in plain language"
    - "ffmpeg/yt-dlp audio extraction is explicitly narrated (the user's named complaint)"
    - "Captured video metadata (title, channel, duration) is surfaced after the metadata stage"
    - "All progress/diagnostic narration goes to stderr and never pollutes the ^OUTPUT_FILE= stdout capture"
    - "ANSI color is emitted only when stderr is a TTY and NO_COLOR is unset; redirected/unattended runs stay plain text"
    - "The final completion summary recaps the produced markdown path plus a short pipeline recap"
    - "Script remains bash 3.2-safe and runs unattended with no prompts or TTY dependence"
  artifacts:
    - path: "transcribrr.sh"
      provides: "Improved stage narration + color/TTY-aware banner helper"
      contains: "stage_banner"
  key_links:
    - from: "stage_banner"
      to: "stderr"
      via: "echo redirected to >&2"
      pattern: "stage_banner"
---

<objective>
Improve transcribrr.sh terminal output so each stage clearly narrates WHAT it is
doing and WHY, with consistent, clean, redirect-safe, bash 3.2-safe banners.

Purpose: Today the operator cannot tell what the script is doing mid-run (the user
explicitly called out the silent ffmpeg audio-extraction step). This makes
unattended runs and log files far more legible.

Output: A revised transcribrr.sh with a color/TTY-aware banner helper, narrated
sub-steps, surfaced video context, and a richer completion summary.

SCOPE GUARD (output-only): Do NOT change pipeline logic, control flow, exit codes,
the `set -euo pipefail` discipline, the `^OUTPUT_FILE=` stdout capture contract,
or the deno JS-runtime probe pipeline (lines ~363-393). This is purely about what
text is printed, to which stream, and when.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@CLAUDE.md
@transcribrr.sh
</context>

<tasks>

<task type="auto">
  <name>Task 1: Color/TTY-aware banner helper + narration helpers (stderr-routed)</name>
  <files>transcribrr.sh</files>
  <action>
Replace the existing stage_banner() (lines ~408-415) with an upgraded, redirect-safe,
bash 3.2-safe version, and add a lightweight narration helper.

1. Add a color-setup block placed BEFORE stage_banner() is defined (near the top of
   the helper region, e.g. just above the existing stage_banner definition). Detect
   color support once: emit ANSI codes ONLY when stderr is a TTY AND NO_COLOR is
   unset. Use `[ -t 2 ]` for the TTY test (stderr, fd 2 — banners route to stderr per
   below) and `[ -z "${NO_COLOR:-}" ]` (set -u safe). When color is enabled set
   plain string vars C_BOLD, C_DIM, C_RESET to the literal escape sequences via
   `printf '\033[...m'`; otherwise set all three to empty strings. Use simple scalar
   string variables only — NO associative arrays, NO ${var^^}, NO mapfile. Keep the
   escape sequences as $'...' or printf-built strings (bash 3.2 supports $'\033').

2. Rewrite stage_banner() so:
   - It takes two args: a short title ($1, e.g. "Stage 2/5: Transcribe") and an
     optional "why" line ($2). If $2 is empty, print only the title line(s).
   - ALL output goes to stderr (append `>&2` to each echo, or wrap the body in a
     `{ ...; } >&2` group). This is the load-bearing change: the per-stage runner
     functions (_run_transcribe/_run_cleanup/_run_summarize) execute inside
     `STAGE_OUT=$(...)` command substitution and the ^OUTPUT_FILE= capture filters
     stdout — stage_banner is currently called outside that substitution so stdout
     is technically safe, but routing ALL narration to stderr is the consistent,
     redirect-safe contract for the whole script and avoids any future regression.
   - Wrap the title in ${C_BOLD}...${C_RESET} and the why-line in ${C_DIM}...${C_RESET}.
   - Keep a clean visual style: a blank line, a rule line, bold title, optional dim
     "why" line, rule line, blank line. Keep the rule made of plain ASCII (`=`)
     so it survives non-UTF8 / piped logs.

3. Add a small `narrate()` helper (one-line sub-step messages, e.g. "→ Extracting
   MP3 audio with ffmpeg…"). It must `echo` its single argument to stderr (`>&2`),
   wrapped in ${C_DIM}...${C_RESET}. This is used by Task 2 for sub-step narration.

Do not touch the deno probe (lines ~363-393), flag parsing, settings.conf reading,
or any non-output logic. Do not alter the "Models:" provenance printf block
(lines 250-253) other than — optionally — routing it to stderr for consistency
(safe: it runs before any command substitution).
  </action>
  <verify>
    <automated>bash -n /Users/gareth/git/transcribrr/transcribrr.sh && grep -q 'stage_banner' /Users/gareth/git/transcribrr/transcribrr.sh && /bin/bash -c 'NO_COLOR=1 bash -n /Users/gareth/git/transcribrr/transcribrr.sh'</automated>
  </verify>
  <done>
stage_banner() routes all output to stderr, accepts an optional "why" arg, and
emits ANSI color only when stderr is a TTY and NO_COLOR is unset. A narrate()
helper exists. `bash -n transcribrr.sh` parses cleanly. No bash 4+ constructs
introduced (no `declare -A`, `mapfile`, `${var^^}`, `readarray`).
  </done>
</task>

<task type="auto">
  <name>Task 2: Narrate each stage with WHAT + WHY and surface video context</name>
  <files>transcribrr.sh</files>
  <action>
Update each existing stage_banner call site to pass a plain-language "why" line, add
narration for currently-silent sub-steps, and surface captured metadata. Use the
two-arg stage_banner() and narrate() from Task 1. All additions print to stderr.

Call sites to update (line numbers approximate — locate by the existing banner text):

1. Metadata stage (~line 438): change banner to a metadata-only title with a why,
   e.g. title "Stage 1/5: Fetch video metadata" / why "Asking yt-dlp for the title,
   channel, duration and ID so the output header and filenames are accurate (no
   download yet)." Remove the misleading "and downloading audio" wording here since
   the actual download is a separate stage below.

2. After metadata is parsed and validated (after line ~505, where SAFE_TITLE/WORK_DIR
   are finalized): surface the captured context with narrate() lines, e.g.:
     - "Title:    $VIDEO_TITLE"
     - "Channel:  $VIDEO_CHANNEL"
     - "Duration: $VIDEO_DURATION"
     - "Work dir: $WORK_DIR"
   Use $VIDEO_DURATION (already populated). Do NOT add logic — just print existing vars.

3. Download stage (~line 512): banner title "Stage 1/5: Download & extract audio" /
   why "Downloading the best audio stream and extracting it to MP3 with ffmpeg via
   yt-dlp so whisper can transcribe it." Immediately BEFORE the `MP3_FILE=$(yt-dlp …)`
   call (line ~516) add a narrate() line that names the ffmpeg step explicitly, e.g.
   "→ yt-dlp is fetching audio and ffmpeg is transcoding it to MP3 (this is the step
   that was previously silent)…". This satisfies the user's explicit ffmpeg complaint.

4. Transcribe stage (~lines 537-541): keep the 2/5 vs 1/3 split but add a why line,
   e.g. why "Running MLX Whisper ($WHISPER_MODEL) locally on Apple Silicon to turn
   the audio into a raw text transcript." Just before STAGE_OUT=$(_run_transcribe)
   (line ~549) add narrate() "→ Starting whisper transcription; this is the longest
   step for long audio…". (narrate prints to stderr — safe, it is OUTSIDE the
   _run_transcribe stdout capture.)

5. Cleanup stage (~lines 569-573): add why "Using $CLEANUP_MODEL to fix punctuation,
   remove filler and repair obvious transcription errors before summarizing." The
   existing "Skipping cleanup stage (--no-cleanup specified)." echo at line 598 —
   route it to stderr (`>&2`) and reword to a narrate() call for consistency.

6. Summarize stage (~lines 605-609): add why "Using $SUMMARY_MODEL to produce a
   '$SUMMARY_STYLE' summary of the cleaned transcript."

7. Assemble stage (~lines 637-641): add why "Combining the metadata header, summary
   and full transcript into a single markdown file."

CRITICAL stream rule: narrate() and stage_banner() write to stderr. Do NOT add any
bare `echo` to stdout inside or before the _run_* command substitutions — the
`^OUTPUT_FILE=` grep capture must stay clean. The _run_* functions themselves are
UNCHANGED (their `tee /dev/stderr | grep "^OUTPUT_FILE="` plumbing stays exactly
as-is).
  </action>
  <verify>
    <automated>bash -n /Users/gareth/git/transcribrr/transcribrr.sh && grep -c 'stage_banner ' /Users/gareth/git/transcribrr/transcribrr.sh | grep -qE '[5-9]|[0-9]{2}' && grep -q 'ffmpeg' /Users/gareth/git/transcribrr/transcribrr.sh</automated>
  </verify>
  <done>
Each stage banner carries a plain-language "why"; the ffmpeg/yt-dlp extraction
step is explicitly narrated before it runs; video title/channel/duration/work-dir
are surfaced after metadata. The `^OUTPUT_FILE=` capture is untouched (no new
stdout writes inside/around _run_* substitutions). `bash -n` parses cleanly.
  </done>
</task>

<task type="auto">
  <name>Task 3: Richer completion summary + redirect-safe smoke test</name>
  <files>transcribrr.sh</files>
  <action>
1. Upgrade the final completion block (lines ~713-717). Keep it on stderr for
   consistency with the rest of the narration (route the block `>&2`), wrap the
   "Pipeline complete!" title in ${C_BOLD}...${C_RESET}, and add a short recap below
   the markdown path using only already-set vars:
     - "Markdown: $FINAL_MD_PATH"  (keep — this is the load-bearing line)
     - "Source:   $_VID_URL"  (NA for local input — fine)
     - "Title:    $_VID_TITLE"
     - "Duration: $_VID_DURATION"
     - A models recap line, e.g. "Models:   whisper=$WHISPER_MODEL cleanup=$CLEANUP_MODEL summary=$SUMMARY_MODEL ($SUMMARY_STYLE)" — when NO_CLEANUP=true show cleanup=skipped, mirroring the markdown header logic already at lines 694-700 (read those vars; do not re-derive).
   Do NOT change FINAL_MD_PATH derivation, the clobber guard, the mktemp/trap, the
   atomic mv, or any logic. Output only.

2. Decision note for the executor: keep ALL human-facing narration on stderr and
   leave stdout reserved for the machine-readable `^OUTPUT_FILE=` lines the sub-stage
   scripts emit and the script captures. Record this stream convention as a short
   comment near stage_banner() so future edits do not regress it.

3. Add a redirect-safety smoke check as the executor's manual confidence step
   (no pipeline run required): confirm that with stdout redirected to a file and
   stderr to the terminal, the narration still appears — conceptually verified by
   the fact that all narration is on stderr. The automated verify below proves the
   color guard degrades correctly under non-TTY.
  </action>
  <verify>
    <automated>bash -n /Users/gareth/git/transcribrr/transcribrr.sh && /bin/bash -c 'out=$(NO_COLOR=1 /bin/bash /Users/gareth/git/transcribrr/transcribrr.sh --help 2>/dev/null | cat -v); echo "$out" | grep -qv "\^\[" && echo NOCOLOR_OK' | grep -q NOCOLOR_OK && grep -q 'Pipeline complete' /Users/gareth/git/transcribrr/transcribrr.sh</automated>
  </verify>
  <done>
The completion block prints (on stderr) the markdown path plus a recap of source,
title, duration and models, with the cleanup=skipped variant handled. A comment
documents the stdout=machine / stderr=human stream convention. `--help` output
contains no raw escape sequences when NO_COLOR is set (color guard degrades safely).
`bash -n` parses cleanly.
  </done>
</task>

</tasks>

<verification>
- `bash -n transcribrr.sh` parses with no syntax errors (bash 3.2-safe; no bash 4+ constructs).
- All narration (banners, sub-steps, completion recap) goes to stderr; stdout carries only the `^OUTPUT_FILE=` machine lines the sub-scripts emit/capture.
- Running under `NO_COLOR=1` or with stderr not a TTY emits plain text (no raw `\033[` escapes in captured output).
- The ffmpeg/yt-dlp audio-extraction step is explicitly narrated before it runs (user's named complaint resolved).
- Pipeline logic, control flow, exit codes, `set -euo pipefail`, the deno probe, and the `^OUTPUT_FILE=` capture contract are all unchanged.
</verification>

<success_criteria>
- Each of the five stages (metadata, download/extract, transcribe, cleanup, summarize) plus assemble prints a banner that states WHAT and WHY in plain language.
- ffmpeg audio extraction, yt-dlp metadata vs download, whisper start, cleanup, and summarize are each narrated.
- Video title/channel/duration/work-dir surfaced after metadata; final summary recaps markdown path + source + title + duration + models.
- Color only on interactive stderr; unattended/redirected runs are clean plain text with no prompts.
- bash 3.2-safe; no logic/exit-code/stream-contract changes.
</success_criteria>

<output>
Create `.planning/quick/260617-ucz-improve-transcribrr-sh-terminal-output-e/260617-ucz-SUMMARY.md` when done.
</output>
