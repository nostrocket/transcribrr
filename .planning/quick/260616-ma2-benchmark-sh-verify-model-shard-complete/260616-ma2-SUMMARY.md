---
phase: quick-260616-ma2
plan: 01
subsystem: benchmark
tags: [benchmark, hf-cache, model-verification, bash-3.2]
requires:
  - benchmark.sh pre-fetch stage
  - config/candidates.conf [candidate] blocks
provides:
  - verify_model_complete() shard-completeness check
  - params_for_id() conf lookup
  - re-verify+re-download pre-fetch loop (continue-on-failure)
  - per-stage model inventory table
affects:
  - benchmark.sh
  - config/candidates.conf
tech-stack:
  added: []
  patterns:
    - "python3 (.venv) JSON weight_map parse for shard verification"
    - "continue-on-failure set +e / capture-rc / set -e bracket (D-16)"
    - "awk float math (bash 3.2 — no float in (( )))"
    - "tr 'A-Z' 'a-z' lowercasing (bash 3.2 — no ${var,,})"
key-files:
  created: []
  modified:
    - benchmark.sh
    - config/candidates.conf
decisions:
  - "Gate pre-fetch on verify_model_complete (real shard check), not presence-only is_model_cached"
  - "is_model_cached retained solely for the disk-space gate (intentional)"
  - "params fetched on demand via params_for_id — parse_candidates 3-field pipe contract untouched"
metrics:
  duration: ~12m
  completed: 2026-06-16
  tasks: 3 implementation + 1 verify
  files: 2
---

# Quick Task 260616-ma2: benchmark.sh verify model shard complete — Summary

Replaced benchmark.sh's presence-only `is_model_cached()` pre-fetch guard with real shard-completeness verification (`verify_model_complete`), so partially-downloaded models (e.g. `Qwen/Qwen3-14B-MLX-4bit` with only an index file) are detected as incomplete, (re)downloaded, re-verified, and skipped on persistent failure — plus a per-stage model inventory table and a `params=` key on every candidate.

## What Was Built

1. **`config/candidates.conf`** — added a `params=` line to all 13 `[candidate]` blocks (canonical source, parse-not-source, same idiom as `size_gb`); bumped the `# Last updated:` header to 2026-06-16.

2. **`verify_model_complete <model_id>`** (benchmark.sh) — resolves the active snapshot; if `model.safetensors.index.json` is present, parses its `weight_map` with `$PYTHON` and requires every unique shard to exist as a non-zero resolved blob (`os.path.getsize` follows the symlink into the blobs store); single-file fallback (`*.safetensors` / `weights.npz` / `*.npz` with `-s`); returns 1 when no snapshot. Python runs under a `set +e` / capture-rc / `set -e` bracket and defaults to incomplete on any error (D-16).

3. **`params_for_id <model_id>`** (benchmark.sh) — block-aware `params=` scan of `candidates.conf` using the same while-read/case idiom as `parse_candidates`, including the mandatory emit-last-block stanza (Pitfall E); echoes `?` for unknown ids; never trips `set -e`.

4. **Pre-fetch loop rewrite** (benchmark.sh) — gates on `verify_model_complete` instead of `is_model_cached`; incomplete models print `Downloading …`, run `hf download` under a continue-on-failure bracket, then re-verify; persistent failures emit a clear per-model error, append to `INCOMPLETE_IDS`, and are skipped (no abort). Success message changed from `Cached:` to `Verified complete:`.

5. **Model inventory table** (benchmark.sh) — printed after pre-fetch under a `stage_banner "Model inventory"`, grouped by stage (whisper → cleanup → summarize). Columns: full HF repo id | params | quantization | on-disk size | approx memory. Quant via `tr` lowercase + `case` (4-bit/8-bit/fp16); on-disk via `du -sh` (`—` if missing); approx memory via `awk` (`size_gb + BENCH_OVERHEAD_BUFFER_GB`). A trailing warning lists any still-incomplete models.

## Verification (static — checkpoint Task 4)

Per task constraints, the new functions were statically validated against the live HF cache via a throwaway harness (sourcing the helper definitions only — no full interactive benchmark, no multi-GB downloads). The harness was deleted after running.

`verify_model_complete` results:

| Model | Result | Notes |
|-------|--------|-------|
| `Qwen/Qwen3-14B-MLX-4bit` | **INCOMPLETE (rc=1)** | index-only snapshot (~15M on disk vs 7.85 GB expected) — the previously FALSE-"Cached" case, now correctly caught |
| `mlx-community/Qwen3-32B-4bit` | complete (rc=0) | known-good multi-shard model (~17G on disk) |
| `mlx-community/whisper-small-mlx` | complete (rc=0) | single-file fallback path |
| `mlx-community/this-does-not-exist` | INCOMPLETE (rc=1) | no snapshot dir |

`params_for_id` results: `mlx-community/Qwen3-8B-4bit` → `8B`; `Qwen/Qwen3-14B-MLX-4bit` → `14B`; `mlx-community/Llama-3.3-70B-Instruct-4bit` (last block) → `70B`; unknown id → `?`.

Inventory table render (simulated fitting set) produced correct alignment, per-stage grouping, params lookup, `4-bit` quant detection, `du` sizes, and awk approx-memory — with the broken `Qwen/Qwen3-14B-MLX-4bit` showing only 15M on-disk, visibly distinguishing it from complete models.

Note on plan's known-broken list: only `Qwen/Qwen3-14B-MLX-4bit` is index-only in the current cache. `mlx-community/Qwen2.5-14B-Instruct-4bit` and `mlx-community/Qwen2.5-32B-Instruct-4bit` were present and fully complete at verify time (no partial-download state to reproduce), so they verified as complete — consistent with the logic. The interactive re-download path was not exercised against a real partial download (would require corrupting/removing shards and re-fetching multi-GB models), but the re-verify-after-download branch is statically exercised by the same `verify_model_complete` calls.

Automated gate checks:
- `bash -n benchmark.sh` clean after every edit.
- `grep -c '^params=' == grep -c '^\[candidate\]'` → 13 == 13.
- All Task 2/Task 3 grep markers present (`verify_model_complete()`, `params_for_id()`, `weight_map`, literal `verify_model_complete "$model_id"` ×2, `du -sh`, `INCOMPLETE_IDS`, `Verified complete`).

## Bash 3.2 Compliance

No `declare -A`, no `mapfile`, no float in `(( ))` (all float math via `awk`), no `${var,,}` (lowercasing via `tr 'A-Z' 'a-z'`). Indexed parallel arrays only. `parse_candidates` 3-field pipe contract (`id|label|size_gb`) untouched — all seven read sites unaffected.

## Deviations from Plan

None — plan executed exactly as written. Rules 1–4 not triggered.

## Known Stubs

None.

## Commits

- `f154965` feat(quick-260616-ma2): add params= key to every candidate block
- `baee866` feat(quick-260616-ma2): add verify_model_complete + params_for_id helpers
- `29a3763` feat(quick-260616-ma2): re-verify+re-download pre-fetch loop + model detail table

## Self-Check: PASSED

- benchmark.sh exists and parses clean.
- config/candidates.conf exists with 13 params= lines.
- All three commits present in git log.
- Throwaway test harnesses removed (no stray files).
