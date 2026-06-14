# Milestones

## v1.0 MVP (Shipped: 2026-06-14)

**Phases completed:** 2 phases, 4 plans, 3 tasks

**Key accomplishments:**

- Flag-driven model/style selection with silent defaults and `OUTPUT_FILE=` emission replacing interactive `read -p` menus in all three MLX pipeline scripts.
- Single-command `transcribrr.sh` orchestrator wiring transcribe -> cleanup -> summarize via `OUTPUT_FILE=` capture with preflight checks, `--no-cleanup`, per-stage banners, and a `--help` covering all flags.
- Fixed bash ERE character-class tokenization of `&` in `[[ =~ ]]`; replaced a bash-5-only `mapfile` with a bash-3.2-safe read loop (caught by code review on the real macOS target).

**Known deferred items at close:** 4 (2 UAT, 2 verification) — see STATE.md → Deferred Items. All 22 requirements implemented + statically verified; deferred items are hands-on UAT requiring yt-dlp/MLX/network.

---
