---
type: quick
quick_id: 260614-uhd
slug: auto-install-deps
created: 2026-06-14
files_modified: [transcribrr.sh]
---

# Quick Task: Auto-install missing dependencies via Homebrew

## Objective

`transcribrr.sh` preflight currently fails with a `brew install <dep>` hint when `ffmpeg`
or `yt-dlp` is missing. Change it to **auto-install** missing deps via Homebrew (no prompt,
unattended), with a `--no-install` opt-out that preserves the current fail-with-hint behavior.

## Decisions (locked)

- Auto-install via `brew install <dep>`, **no prompt** (honors the unattended core value).
- `--no-install` flag opts out → keep current behavior (accumulate errors, fail with hint).
- `yt-dlp` is only required/installed for **URL** input (`IS_URL=true`); `ffmpeg` always required.
- Fail fast with a clear, named message if: Homebrew (`brew`) itself is missing, a `brew install`
  fails, or a dep is still missing after the install attempt.
- Preserve bash 3.2.57 compatibility and the existing preflight error-accumulation style.

## Tasks

### Task 1 — Add --no-install flag + auto-install logic to preflight

<read_first>
- transcribrr.sh (flag-parsing `while` loop ~line 100-120; defaults block ~line 16-21; `print_help` ~line 40-90; `preflight_check()` ~line 158-205)
</read_first>

<action>
1. Add a default `NO_INSTALL=false` in the defaults block (near `NO_CLEANUP=false`).
2. Add a `--no-install)` case to the flag-parsing `while` loop that sets `NO_INSTALL=true; shift`.
3. Document `--no-install` in `print_help` (under Options): "Do not auto-install missing
   dependencies; fail with an install hint instead (default: auto-install via Homebrew)."
4. Add a helper `ensure_dep <command> <brew-formula>` used by `preflight_check`:
   - If `command -v <command>` succeeds → return 0 (nothing to do).
   - If missing AND `NO_INSTALL=true` → print `Error: <command> not found on PATH. Install with: brew install <formula> (or drop --no-install to auto-install).` and return 1 (caller increments errors — preserves current behavior).
   - If missing AND `NO_INSTALL=false`:
     - If `command -v brew` is missing → print `Error: <command> not found and Homebrew (brew) is not installed; cannot auto-install. Install Homebrew (https://brew.sh) or install <command> manually.` and return 1.
     - Else print a progress line `Installing missing dependency: <command> (brew install <formula>)...` to stderr, run `brew install <formula>` (let its output show), then re-check `command -v <command>`. If still missing → print `Error: auto-install of <command> via 'brew install <formula>' did not produce a working '<command>' on PATH.` and return 1. If now present → print `Installed <command>.` and return 0.
5. In `preflight_check`, replace the inline `ffmpeg` check with `ensure_dep ffmpeg ffmpeg || errors=$((errors + 1))`, and the URL-conditional `yt-dlp` check with `ensure_dep yt-dlp yt-dlp || errors=$((errors + 1))` (keep it inside the `if [ "$IS_URL" = true ]` block).
6. Keep all other preflight checks (input file/URL, sub-scripts) and the final `errors`-accumulation abort unchanged.
</action>

<acceptance_criteria>
- `bash -n transcribrr.sh` passes AND `/bin/bash -n transcribrr.sh` (3.2.57) passes.
- `transcribrr.sh` contains a `--no-install)` case and `NO_INSTALL` default.
- `print_help` output (`./transcribrr.sh --help`) documents `--no-install`.
- `preflight_check` calls a single auto-install code path for both `ffmpeg` and `yt-dlp` (no duplicated literal `brew install` hint blocks left as the only handling).
- With `--no-install`, a missing dep still aborts with the hint message (current behavior preserved) and does NOT attempt `brew install`.
- Auto-install path attempts `brew install`, re-checks, and fails with a named message if brew is absent / install fails / dep still missing.
- No `mapfile`/bash-5-only constructs introduced.
</acceptance_criteria>

## Verification

- `./transcribrr.sh --help | grep -- --no-install` shows the new flag.
- `./transcribrr.sh --no-install /tmp/nope.mp3` fails on the input-file check without attempting any install.
- (Manual / hands-on) On a machine without yt-dlp, `./transcribrr.sh "<url>"` triggers `brew install yt-dlp` automatically; with `--no-install` it fails with the hint.
