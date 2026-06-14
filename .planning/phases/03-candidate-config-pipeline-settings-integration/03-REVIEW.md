---
phase: 03-candidate-config-pipeline-settings-integration
reviewed: 2026-06-15T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - transcribrr.sh
  - config/candidates.conf
  - config/settings.conf.example
  - .gitignore
findings:
  critical: 0
  warning: 4
  info: 4
  total: 8
status: issues_found
---

# Phase 03: Code Review Report

**Reviewed:** 2026-06-15
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

Reviewed the candidate-config / pipeline-settings integration: the three-tier
model precedence wiring (flag > settings.conf > built-in), the parse-not-source
settings reader, the provenance summary, the CFG-03 catch-and-translate wrappers,
and the new `config/candidates.conf` + `config/settings.conf.example` data files
plus the `.gitignore` rule.

**The security posture of this phase is sound.** I verified empirically:

- Parse-not-source is respected — `_read_setting` uses anchored `grep | cut`, never
  `source`/`eval`/`.`. A malicious `WHISPER_MODEL_DEFAULT=$(rm -rf x)` line is read
  as the literal 12-char string, not executed.
- `candidates.conf` contains no shell-evaluable syntax (no `$(...)`, backticks,
  `export`, or `;rm`).
- The CFG-03 wrappers correctly detect stage failure: I confirmed `set -o pipefail`
  propagates the stage script's nonzero exit through the `... | tee /dev/stderr |
  { grep ... || true; }` pipeline, so `if ! STAGE_OUT=$(_run_*)` fires on a failed
  model load while still working on the success path.
- `set -u` safety holds: every `*_SOURCE` var is initialized before the provenance
  print, and `VIDEO_*` vars are `${VAR:-default}`-guarded on the local-input path.

No BLOCKER-class defects found. However, there is one **cross-file correctness/
usability defect** (WR-01): a large fraction of the labels shipped in
`candidates.conf` are NOT accepted by the stage scripts, so copying them into
`settings.conf` produces an "Unknown model" failure — undermining the precedence
feature this phase exists to deliver. Three further robustness gaps in the config
parser (WR-02/03/04) cause silent fall-through or corrupted model names on
realistically hand-edited config files.

## Warnings

### WR-01: candidates.conf advertises labels the stage scripts reject

**File:** `config/candidates.conf:18-22, 24-28, 48-52, 66-82` (and the stage-script
case statements they must match: `transcribe.sh:107-115`, `cleanup-transcript.sh:53-58`,
`summarize-transcript.sh:102-105`)

**Issue:** `candidates.conf` is the user-facing menu of selectable models, and
`settings.conf.example` tells the user values may be "friendly labels". But the
stage scripts only translate a fixed hard-coded label set. The following candidate
labels have no match in any stage `case` and will fail when used as a label:

- whisper: `turbo-4bit`, `distil-large-v3` (transcribe.sh knows only tiny/base/small/medium/large-v3/turbo)
- cleanup: `qwen3-8b-4bit` (cleanup-transcript.sh knows only llama3.2-1b/3b-4bit, llama3.1-8b-4bit/8bit)
- summarize: `Qwen3-14B-4bit`, `Qwen3-32B-4bit`, `Llama3.3-70B-4bit` (summarize-transcript.sh knows only Qwen2.5-7B/14B/32B-4bit, Qwen2.5-32B-8bit)

A user who does the obvious thing — copy a `label=` value from candidates.conf
into `WHISPER_MODEL_DEFAULT=turbo-4bit` — gets an unattended-pipeline abort. The
labels only work if the user instead copies the raw `id=` (which contains `/` and
hits the passthrough branch). The plan confirmed MODEL-03 (raw-ID passthrough)
but never reconciled the label namespace, so the two new data files contradict the
existing stage scripts.

**Fix:** Make the contract explicit and consistent. Either (a) restrict
`candidates.conf` to only labels the stage scripts accept, or (b) have
`settings.conf.example` / docs state that only raw HF `id=` values from
candidates.conf are guaranteed and labels are limited to the stage-script set, or
(c) preferred long-term: resolve labels against `candidates.conf` in transcribrr.sh
and pass the resolved `id` (containing `/`) to the stage scripts so any candidate
label works:

```bash
# resolve a candidates.conf label -> id for a given stage, before invoking stage
_resolve_label() {  # _resolve_label <stage> <label-or-id>
    case "$2" in */*) printf '%s' "$2"; return 0 ;; esac  # already an id
    awk -v st="$1" -v lb="$2" '
        /^\[candidate\]/{s=""; i=""; l=""}
        /^stage=/{s=substr($0,7)} /^id=/{i=substr($0,4)} /^label=/{l=substr($0,7)}
        (s==st && l==lb){print i; exit}' "$SCRIPT_DIR/config/candidates.conf"
}
```

### WR-02: settings.conf values with trailing whitespace silently corrupt the model name

**File:** `transcribrr.sh:162` (`_read_setting`)

**Issue:** `cut -d= -f2-` preserves trailing whitespace. A hand-edited line such as
`SUMMARY_MODEL_DEFAULT=Qwen2.5-32B-4bit ` (trailing space, easy to introduce) yields
the value `"Qwen2.5-32B-4bit "` which is then passed verbatim as `--model` to the
stage script, where the `case` match fails on the trailing space → "Unknown model"
abort. I reproduced this. The provenance summary even prints the trailing space,
which is invisible to the user, making it hard to diagnose.

**Fix:** Strip surrounding whitespace after extraction:

```bash
_read_setting() {
    grep "^${1}=" "$SETTINGS_FILE" 2>/dev/null | tail -1 | cut -d= -f2- \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}
```

### WR-03: CRLF line endings in settings.conf inject a carriage return into the model name

**File:** `transcribrr.sh:162` (`_read_setting`)

**Issue:** If `settings.conf` is saved with Windows/CRLF line endings (plausible for
a per-user file edited on a synced/shared machine), `grep "^KEY="` matches and the
value carries a trailing `\r`. I confirmed `WHISPER_MODEL_DEFAULT=turbo\r\n` produces
the 6-char value `turbo\r`, which fails the stage `case` match and prints garbled
provenance. Same failure class as WR-02 but with an invisible character.

**Fix:** Strip `\r` (and other whitespace) in `_read_setting`, e.g. add
`tr -d '\r'` to the pipeline or extend the WR-02 `sed` to `sed 's/\r$//;...'`.

### WR-04: settings.conf keys with spaces around '=' are silently ignored

**File:** `transcribrr.sh:162` (`_read_setting`), `config/settings.conf.example:9-11`

**Issue:** The anchored grep `^KEY=` does not match `KEY = value` (spaces around the
equals sign). I confirmed `CLEANUP_MODEL_DEFAULT = spaced` returns an empty value and
silently falls through to the built-in default — the user believes they configured a
model but the pipeline quietly uses a different one. Per D-04/D-05 silent fall-through
is intended for a *missing file*, but here a *present, intentionally-set* key is
ignored with no warning. The `.example` uses the no-space form, so this only bites
hand edits, but the format is forgiving-looking enough that users will write spaces.

**Fix:** Either document strictly "no spaces around =", or tolerate optional spaces:

```bash
grep -E "^${1}[[:space:]]*=" "$SETTINGS_FILE" 2>/dev/null | tail -1 \
    | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
```

## Info

### IN-01: Local filenames containing "youtube" are misdetected as URLs

**File:** `transcribrr.sh:197`

**Issue:** The input detection `[[ "$INPUT_ARG" =~ youtu\.?be ]]` is an unanchored
substring match, so a local file named `my-youtube-notes.mp3` or `youtube_clip.mp3`
is classified as a URL and handed to `yt-dlp` (which then fails). I reproduced both.
This is pre-existing (outside this phase's diff) but is in the reviewed file. Low
likelihood, so Info rather than Warning.

**Fix:** Anchor URL detection to a scheme or known host form, e.g. require
`^https?://` OR a host-anchored youtube/youtu.be match
(`(^|//|\.)(youtube\.com|youtu\.be)/`), and treat anything else as a local path.

### IN-02: Provenance label width comment vs. code drift

**File:** `transcribrr.sh:190-192` vs `.planning/.../03-02-PLAN.md:71`

**Issue:** The plan describes the provenance format as `"  %-7s = %-24s (%s)"`, but
the implementation hard-codes the literal labels (`whisper`, `cleanup`, `summary`)
in the format string instead of using a `%-7s` field. Functionally fine and the
output is aligned, but it diverges from the documented pattern, which can confuse a
future maintainer reconciling code to plan. Purely cosmetic.

**Fix:** None required; optionally align the comment/plan with the actual approach.

### IN-03: Upload-date reformat logic is duplicated

**File:** `transcribrr.sh:384-389` and `transcribrr.sh:546-554`

**Issue:** The `YYYYMMDD -> YYYY-MM-DD` sed reformat appears twice. The assemble-stage
copy is defensively guarded (`_VID_UPLOAD_DATE="${VIDEO_UPLOAD_DATE:-$_VID_DATE}"`
prefers the already-reformatted value) so it is *correct*, but the duplication is a
maintenance hazard: a future change to the date format must be made in two places.

**Fix:** Extract a `reformat_date()` helper and call it from both sites.

### IN-04: `config/settings.conf.example` lists keys, not all supported labels

**File:** `config/settings.conf.example:7-11`

**Issue:** The example says values may be "friendly labels (e.g. turbo,
llama3.1-8b-4bit)" but gives no pointer to which labels are actually accepted, and
(per WR-01) some candidates.conf labels are not accepted. A user has no in-file way
to know the valid label set.

**Fix:** Add a comment pointing to `candidates.conf` and clarify the label-vs-id
guarantee once WR-01 is resolved.

---

_Reviewed: 2026-06-15_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
