---
slug: silent-exit-after-models
status: resolved
resolved_commit: c344e08
trigger: "./transcribrr.sh \"https://www.youtube.com/watch?v=CyM6DjJ1TYg\" prints the Models: block then returns to the shell prompt instantly with no further output — no stage banner, no error. Worked before this version."
created: 2026-06-17
updated: 2026-06-17
---

# Debug Session: silent-exit-after-models

## Symptoms

- **Expected behavior:** After the `Models:` block, the script should print the
  "Stage 1/5: Fetching metadata and downloading audio (yt-dlp)..." banner
  (transcribrr.sh:415) and proceed through metadata → download → transcribe →
  cleanup → summarize → write a markdown file.
- **Actual behavior:** Script prints only the `Models:` block (lines 250–253),
  then the shell prompt returns. No Stage banner, no error message.
- **Error messages:** NONE reported by user (selected "Nothing at all").
- **Timing:** Prompt returned instantly (<1s) — far too fast for the metadata
  `yt-dlp --simulate` network call to have run.
- **Timeline:** Has worked before for YouTube URLs → this is a REGRESSION.
- **Reproduction:** `./transcribrr.sh "https://www.youtube.com/watch?v=CyM6DjJ1TYg"`

## Current Focus

- hypothesis: CONFIRMED. transcribrr.sh:366
  (`js_runtime_line=$(yt-dlp -v --simulate 2>&1 | grep -i "JS runtimes:" | head -1)`)
  aborts the script under `set -euo pipefail`, and the ERR trap fails to fire
  because the abort occurs inside a function (preflight_check) without
  `set -E`/errtrace on bash 3.2 — producing a SILENT exit.
- status: root cause confirmed; applying fix.
- next_action: Make the deno probe robust (guard pipeline so it cannot abort the
  script) per fix_constraints.
- reasoning_checkpoint: |
    hypothesis: transcribrr.sh:366 aborts the script because (1) `yt-dlp -v
      --simulate` with NO URL exits 2 ("You must provide at least one URL"),
      (2) `set -o pipefail` propagates that 2 as the pipeline's exit status (the
      trailing `| head -1` exits 0 but pipefail picks up yt-dlp's 2), (3) `set -e`
      aborts at the command-substitution assignment. The user saw NO error because
      the abort happens inside the preflight_check FUNCTION and the script does
      not enable `set -E` (errtrace), so on stock macOS /bin/bash 3.2 the ERR trap
      is NOT triggered for the failing command substitution inside the function.
    confirming_evidence:
      - "`/bin/bash --version` = 3.2.57(1) (stock macOS) — matches deploy env."
      - "`yt-dlp -v --simulate` (no URL) exits 2; output DOES contain `JS runtimes: deno-2.8.3` (so grep succeeds, not the SIGPIPE/no-match theory)."
      - "Pipeline exit: 0 without pipefail, 2 WITH pipefail — pipefail is the propagator."
      - "Running the REAL script with the URL: exit code 2, Models: block on stdout, STDERR COMPLETELY EMPTY — reproduces user's 'Nothing at all' exactly."
      - "Standalone repro: failing command-subst at TOP LEVEL fires ERR trap; the SAME failing command-subst INSIDE A FUNCTION does NOT fire it (bash 3.2, no set -E)."
      - "Adding `set -E` makes the ERR trap fire from inside the function — confirms errtrace is the missing differentiator."
    falsification_test: "If the script printed an error to stderr when run with the URL, or exited 0, the hypothesis would be wrong. Observed: exit 2, empty stderr — consistent."
    fix_rationale: "The deno probe is a best-effort WARNING, not a hard requirement; it must never abort the pipeline. Guarding the command substitution so it always succeeds (|| true / isolate pipefail) removes the silent-abort mechanism at its source. Earlier (line 207) the same || true guard is used for the same set -euo pipefail reason."
    blind_spots: "Have not verified behavior with an actually-unsupported deno (cannot easily install an old deno); the warning branch (line 367) is only exercised when JS runtime line contains '(unsupported)'. Fix must preserve that warning path while never aborting."

## Evidence

- timestamp: 2026-06-17 — transcribrr.sh:3 confirms `set -euo pipefail` active.
- timestamp: 2026-06-17 — transcribrr.sh:36 ERR trap prints stage on failure; CURRENT_STAGE="preflight" at this point (line 35).
- timestamp: 2026-06-17 — transcribrr.sh:250-253 print the Models: block (last visible output).
- timestamp: 2026-06-17 — transcribrr.sh:394 calls preflight_check; first Stage banner is at line 415 (NOT reached).
- timestamp: 2026-06-17 — transcribrr.sh:356-371 is the deno block; line 366 pipeline added in commit 4103514 ("fix: warn when yt-dlp considers installed deno too old"), matching the regression timeline.
- timestamp: 2026-06-17 — Recent commits c245d32/4103514/d8e2839/6742705 all touch deno/yt-dlp preflight logic.
- timestamp: 2026-06-17 — `/bin/bash --version` = 3.2.57(1)-release (stock macOS). deno present at ~/.deno/bin/deno (2.8.3), yt-dlp at /opt/homebrew/bin/yt-dlp.
- timestamp: 2026-06-17 — `yt-dlp -v --simulate` with NO URL exits 2 ("You must provide at least one URL"). Its -v output DOES include "JS runtimes: deno-2.8.3" — so grep matches; the no-match/empty-grep theory is wrong.
- timestamp: 2026-06-17 — Pipeline `yt-dlp -v --simulate 2>&1 | grep -i "JS runtimes:" | head -1` exits 0 WITHOUT pipefail, exits 2 WITH pipefail. pipefail propagates yt-dlp's exit 2. (Not SIGPIPE 141.)
- timestamp: 2026-06-17 — Ran the REAL ./transcribrr.sh with the reported URL: exit code 2, "Models:" block on stdout, STDERR EMPTY. Reproduces user's "Nothing at all" exactly.
- timestamp: 2026-06-17 — Standalone bash 3.2 test: failing command-subst at TOP LEVEL fires ERR trap; identical failing command-subst INSIDE A FUNCTION does NOT fire ERR trap (no set -E). Adding `set -E` makes it fire. This explains why the trap (line 36) stayed silent — preflight_check is a function.

## Eliminated

- hypothesis: grep finds no "JS runtimes:" line (exits 1) causing the failure.
  evidence: yt-dlp -v output contains "JS runtimes: deno-2.8.3"; grep matches and exits 0.
  timestamp: 2026-06-17
- hypothesis: `head -1` closes the pipe early causing SIGPIPE (141) to abort the pipeline.
  evidence: PIPESTATUS / measured pipeline exit with pipefail is 2 (yt-dlp's no-URL error), not 141.
  timestamp: 2026-06-17
- hypothesis: The real exit point is elsewhere and exits 0 cleanly (so no error expected).
  evidence: Real-script run exits 2 (non-zero), not 0; abort is genuine and at the preflight deno probe.
  timestamp: 2026-06-17

## Resolution

root_cause: |
  The deno-version probe at transcribrr.sh:366 (added in commit 4103514) aborts
  the script during preflight_check, and the abort is SILENT. Mechanism:
    1. `yt-dlp -v --simulate` is run with NO URL, so yt-dlp exits 2
       ("You must provide at least one URL").
    2. The script runs under `set -o pipefail`, so that exit-2 (and/or a SIGPIPE
       to yt-dlp when `head -1` closes the pipe early) becomes the pipeline's
       exit status.
    3. `set -e` aborts the script at the command-substitution assignment.
    4. The abort happens inside the preflight_check FUNCTION. The script enables
       `set -euo pipefail` but NOT `set -E` (errtrace), so on stock macOS
       /bin/bash 3.2 the ERR trap (line 36) is NOT triggered for the failing
       command substitution inside a function — hence "Nothing at all".
  Net effect: only the Models: block prints, then the script exits 2 with empty
  stderr, before the Stage 1 banner. This explains the open reasoning_checkpoint
  tension (why the ERR trap stayed silent): function context + no errtrace on bash 3.2.
fix: |
  transcribrr.sh:366 — isolate the best-effort probe from set -e/pipefail so it
  can never abort the pipeline:
    js_runtime_line=""
    js_runtime_line=$(set +o pipefail; yt-dlp -v --simulate 2>&1 | grep -i "JS runtimes:" | tail -1 || true)
  - `set +o pipefail` is scoped to the command-substitution subshell (parent
    pipefail untouched), so the pipeline exit reflects the last command.
  - grep reads to EOF (removed `-m1`/`head -1`) so yt-dlp never receives SIGPIPE.
  - `tail -1` is the last command and exits 0 on a match (there is only one
    JS-runtimes line); `|| true` covers the no-match case.
  The unsupported-deno warning branch (line ~378) still fires when the line is
  captured. Added an explanatory comment block documenting all three hazards.
verification: |
  - `bash -n transcribrr.sh` passes.
  - Isolated repro of the failing construct inside a function under
    `set -euo pipefail` on bash 3.2: before fix → silent exit 2, no trap; after
    fix → exit 0, value captured, deterministic across 5 runs.
  - Real run `./transcribrr.sh "https://www.youtube.com/watch?v=CyM6DjJ1TYg"`:
    before → exit 2, only Models: block, empty stderr. After → prints the
    "Stage 1/5: Fetching metadata and downloading audio (yt-dlp)..." banner and
    proceeds into download (timed out at 25s in network work, exit 124).
  - Regression: --help (exit 0), unknown option (exit 1), no-arg help (exit 0)
    all unchanged. Local-MP3 path skips the deno probe entirely (IS_URL guard).
files_changed:
  - transcribrr.sh: lines ~352-378, hardened the deno JS-runtime probe.
