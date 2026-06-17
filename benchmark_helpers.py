#!/usr/bin/env python3
"""
benchmark_helpers.py — Python helper for benchmark.sh.

Exposes two argparse subcommands (stdlib only, no pip installs):

  divergence  --transcripts label:filepath ...  [--term-width INT]
              Aligns transcripts at sentence level, renders divergent positions
              side-by-side in stderr columns, prints per-model outlier counts
              (majority consensus, 3+ candidates) or divergence count only
              (2-candidate fallback, no outlier ranking).

  report      --run-dir DIR  [--term-width INT]
              Reads all *_result.json files from DIR/whisper/, DIR/cleanup/,
              DIR/summarize/; prints a compact ASCII table to stderr; writes
              DIR/report.md with full excerpts and a Selected Winners table.

Exit codes: 0 success, 1 non-fatal read error, 2 bad arguments.
All terminal output to stderr. report.md is the only file written.
"""

import argparse
import collections
import difflib
import json
import os
import re
import sys
import textwrap

# ── Control character stripping ──────────────────────────────────────────────

# Strip all C0/C1 control characters except newline (\x0a) and tab (\x09).
# This prevents terminal escape-sequence injection from untrusted transcript
# content (threat T-05-04).
_CTRL_RE = re.compile(r'[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f-\x9f]')


def strip_control_chars(text):
    """Remove control characters (except newline/tab) from text."""
    return _CTRL_RE.sub('', text)


# ── Header stripping ─────────────────────────────────────────────────────────

_HEADER_PREFIXES = ('Model:', 'Source:', 'Date:')


def strip_header(text):
    """
    Drop leading lines starting with Model:/Source:/Date: and the following
    blank line (Pitfall 1 — prevents spurious divergences from metadata lines).
    """
    lines = text.split('\n')
    body_start = 0
    i = 0
    # Skip header prefix lines
    while i < len(lines):
        line = lines[i]
        if any(line.startswith(k) for k in _HEADER_PREFIXES):
            i += 1
        elif line.strip() == '' and i > 0:
            # Skip one blank line following headers
            i += 1
            break
        else:
            break
    body_start = i
    return '\n'.join(lines[body_start:])


# ── Normalization ────────────────────────────────────────────────────────────

def normalize(text):
    """
    Lowercase + strip non-word/non-space chars + collapse whitespace.
    Used ONLY to decide divergence; display uses the original text (D-02).
    """
    return re.sub(r'\s+', ' ', re.sub(r'[^\w\s]', '', text.lower())).strip()


# ── Sentence splitting ───────────────────────────────────────────────────────

_SENT_RE = re.compile(r'(?<=[.!?])\s+')


def split_sentences(text):
    """
    Split body text into sentence units.
    Uses lookbehind on sentence-ending punctuation.
    Falls back to newline split if fewer than 5 units result.
    """
    units = _SENT_RE.split(text.strip())
    units = [u.strip() for u in units if u.strip()]
    if len(units) < 5:
        # Fallback: newline split
        units = [line.strip() for line in text.split('\n') if line.strip()]
    return units


# ── Alignment ───────────────────────────────────────────────────────────────

def align_to_anchor(anchor_sents, cand_sents):
    """
    Align candidate sentences to anchor using SequenceMatcher on normalized text.
    Returns dict: anchor_pos -> original_candidate_sentence.
    """
    mapping = {}
    sm = difflib.SequenceMatcher(
        None,
        [normalize(s) for s in anchor_sents],
        [normalize(s) for s in cand_sents],
        autojunk=False,
    )
    for op, a1, a2, b1, b2 in sm.get_opcodes():
        if op == 'equal':
            for k in range(a2 - a1):
                mapping[a1 + k] = cand_sents[b1 + k]
        elif op == 'replace':
            for k in range(a2 - a1):
                if b1 + k < len(cand_sents):
                    mapping[a1 + k] = cand_sents[b1 + k]
        # 'insert' / 'delete': positions absent from mapping → treated as missing
    return mapping


# ── Outlier counting ─────────────────────────────────────────────────────────

def find_outliers(aligned_variants):
    """
    aligned_variants: dict label -> (original_text, normalized_text)
    Returns: (consensus_norm, outlier_labels) or (None, []) if all agree.
    """
    norms = [norm for _, norm in aligned_variants.values() if norm]
    if len(set(norms)) <= 1:
        return None, []  # all agree
    norm_counts = collections.Counter(norms)
    consensus_norm = norm_counts.most_common(1)[0][0]
    outliers = [
        lbl for lbl, (_, norm) in aligned_variants.items()
        if norm and norm != consensus_norm
    ]
    return consensus_norm, outliers


# ── Column rendering ─────────────────────────────────────────────────────────

def render_side_by_side(columns, labels, term_width, gap=2):
    """
    Render N text columns side-by-side to stderr.
    columns: list of text strings (one per candidate).
    labels: list of label strings.
    No truncation — wraps within each column.
    """
    n = len(columns)
    col_w = max(20, (term_width - gap * (n - 1)) // n)

    def wrap_col(text):
        lines_out = []
        for para in text.split('\n'):
            if not para.strip():
                lines_out.append('')
            else:
                lines_out.extend(textwrap.wrap(para, width=col_w) or [''])
        return lines_out

    wrapped = [wrap_col(c) for c in columns]
    max_h = max((len(c) for c in wrapped), default=0)
    for c in wrapped:
        c += [''] * (max_h - len(c))

    sep = (' ' * gap).join('-' * col_w for _ in labels)
    hdr = (' ' * gap).join(f'{lb:<{col_w}}' for lb in labels)
    print(hdr, file=sys.stderr)
    print(sep, file=sys.stderr)
    for row in zip(*wrapped):
        print((' ' * gap).join(f'{cell:<{col_w}}' for cell in row), file=sys.stderr)


# ── Divergence subcommand ────────────────────────────────────────────────────

def run_divergence(args):
    """
    Main logic for the `divergence` subcommand.
    Exit codes: 0 success, 1 read failure leaving <2 readable, 2 bad args.
    """
    # Parse label:filepath pairs
    label_re = re.compile(r'^[A-Za-z0-9._-]+$')
    pairs = []
    for item in args.transcripts or []:
        # Split on FIRST ':' only (filepaths may contain none; labels never contain ':')
        colon_idx = item.find(':')
        if colon_idx == -1:
            print(f"ERROR: transcript argument must be 'label:filepath', got: {item!r}", file=sys.stderr)
            sys.exit(2)
        label = item[:colon_idx]
        filepath = item[colon_idx + 1:]
        # Validate label (V5 input validation — reject control-char/escape injection)
        if not label_re.match(label):
            print(f"ERROR: label {label!r} contains invalid characters (allowed: [A-Za-z0-9._-])", file=sys.stderr)
            sys.exit(2)
        pairs.append((label, filepath))

    if len(pairs) < 2:
        print("ERROR: at least 2 transcript files required", file=sys.stderr)
        sys.exit(2)

    term_width = args.term_width
    had_read_error = False

    # Read transcripts
    transcripts = {}  # label -> raw text
    for label, filepath in pairs:
        if not os.path.isfile(filepath):
            print(f"WARNING: transcript file not found, skipping: {filepath}", file=sys.stderr)
            had_read_error = True
            continue
        try:
            with open(filepath, 'r', errors='replace') as f:
                raw = f.read()
            transcripts[label] = raw
        except Exception as exc:
            print(f"WARNING: could not read {filepath!r}: {exc}", file=sys.stderr)
            had_read_error = True

    if len(transcripts) < 2:
        print("ERROR: fewer than 2 transcripts could be read; cannot compute divergence", file=sys.stderr)
        sys.exit(1)

    labels = list(transcripts.keys())
    n_cands = len(labels)

    # Strip headers and split into sentence units
    sentences = {}  # label -> list of original sentence strings
    for label, raw in transcripts.items():
        body = strip_header(raw)
        sentences[label] = split_sentences(body)

    anchor_label = labels[0]
    anchor_sents = sentences[anchor_label]

    # Align all candidates to anchor
    alignments = {}  # label -> {anchor_pos -> original_text}
    alignments[anchor_label] = {i: s for i, s in enumerate(anchor_sents)}
    for label in labels[1:]:
        alignments[label] = align_to_anchor(anchor_sents, sentences[label])

    # Find divergent positions
    outlier_counts = {label: 0 for label in labels}
    divergent_positions = []

    for pos in range(len(anchor_sents)):
        variants = {}
        for label in labels:
            orig = alignments[label].get(pos, '')
            norm = normalize(orig) if orig else ''
            variants[label] = (orig, norm)

        if n_cands >= 3:
            _, outlier_labels = find_outliers(variants)
            if outlier_labels:
                divergent_positions.append((pos, variants, outlier_labels))
                for lbl in outlier_labels:
                    outlier_counts[lbl] += 1
        else:
            # 2-candidate: detect any difference
            norms = [normalize(orig) for orig, _ in variants.values() if orig]
            if len(set(norms)) > 1:
                divergent_positions.append((pos, variants, []))

    n_divergent = len(divergent_positions)

    # Render divergent positions
    if n_divergent == 0:
        print(f"No divergent positions found across {n_cands} transcripts.", file=sys.stderr)
    else:
        print(f"\n=== Divergence View ({n_divergent} divergent position(s)) ===\n", file=sys.stderr)
        for pos, variants, outlier_labels in divergent_positions:
            print(f"--- Position {pos + 1} ---", file=sys.stderr)
            # Build columns from original text, stripping control chars (T-05-04)
            cols = [strip_control_chars(variants[lbl][0]) for lbl in labels]
            render_side_by_side(cols, labels, term_width)
            print('', file=sys.stderr)

    # Outlier summary
    if n_cands >= 3:
        print("\n=== Outlier Summary (majority-consensus) ===", file=sys.stderr)
        if n_divergent == 0:
            for lbl in labels:
                print(f"  {lbl}: 0 outliers (0.0% of 0 divergent positions)", file=sys.stderr)
        else:
            for lbl in labels:
                count = outlier_counts[lbl]
                pct = 100.0 * count / n_divergent if n_divergent > 0 else 0.0
                print(f"  {lbl}: {count} outlier(s) ({pct:.1f}% of {n_divergent} divergent position(s))", file=sys.stderr)
    else:
        # 2-candidate fallback: report count, no ranking (D-03)
        print(f"\n=== Divergence Summary ===", file=sys.stderr)
        print(f"  Divergent positions: {n_divergent}", file=sys.stderr)
        print("  (no outlier ranking with 2 candidates)", file=sys.stderr)

    # NOTE: tool NEVER auto-picks or recommends a winning model.

    if had_read_error:
        sys.exit(1)
    sys.exit(0)


# ── Report subcommand ────────────────────────────────────────────────────────

_STAGE_DIRS = ['whisper', 'cleanup', 'summarize']
_STAGE_SPEED_LABEL = {
    'whisper': 'RTF',
    'cleanup': 'tok/s',
    'summarize': 'tok/s',
}
_STAGE_SPEED_FIELD = {
    'whisper': 'rtf',
    'cleanup': 'tok_per_s',
    'summarize': 'tok_per_s',
}


def _load_result_jsons(run_dir):
    """
    Load all *_result.json files under run_dir/whisper, cleanup, summarize.
    Returns: dict stage -> list of dicts (one per candidate result).
    """
    stage_results = {stage: [] for stage in _STAGE_DIRS}
    for stage in _STAGE_DIRS:
        stage_dir = os.path.join(run_dir, stage)
        if not os.path.isdir(stage_dir):
            continue
        for fname in sorted(os.listdir(stage_dir)):
            if not fname.endswith('_result.json'):
                continue
            fpath = os.path.join(stage_dir, fname)
            try:
                with open(fpath, 'r') as f:
                    data = json.load(f)
                data['_label'] = data.get('candidate_id') or fname.replace('_result.json', '')
                data['_stage'] = stage
                stage_results[stage].append(data)
            except Exception as exc:
                print(f"WARNING: could not read {fpath!r}: {exc}", file=sys.stderr)
    return stage_results


def _load_meta(run_dir):
    """Load sweep_meta.json if present. Returns dict or {}."""
    meta_path = os.path.join(run_dir, 'sweep_meta.json')
    if os.path.isfile(meta_path):
        try:
            with open(meta_path) as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def _load_picks(run_dir):
    """Load picks.json if present. Returns dict or {}."""
    picks_path = os.path.join(run_dir, 'picks.json')
    if os.path.isfile(picks_path):
        try:
            with open(picks_path) as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def _format_speed(candidate, stage):
    """
    Format speed metric for display.

    Reads the canonical on-disk contract written by write_success_json in
    benchmark.sh: `speed_metric` ("rtf" or "tok_per_s") + numeric `speed_value`.
    The `stage` argument is retained for signature compatibility but the metric
    type is taken from the result JSON itself, not inferred from the stage.
    """
    metric = candidate.get('speed_metric')
    val = candidate.get('speed_value')
    if val is None:
        return 'n/a'
    try:
        fval = float(val)
    except (ValueError, TypeError):
        return str(val)
    if metric == 'rtf':
        return f"RTF={fval:.3f}"
    return f"{fval:.1f} tok/s"


def _format_mem(candidate):
    """Format peak memory for display."""
    val = candidate.get('peak_mem_gb')
    if val is not None:
        try:
            return f"{float(val):.1f}GB"
        except (ValueError, TypeError):
            return str(val)
    return 'n/a'


def _read_output_file(output_file):
    """
    Read content from output_file. Returns (content, found).
    Validates file exists (Pitfall 7 / T-05-06 isfile guard).
    """
    if not output_file:
        return None, False
    if not os.path.isfile(output_file):
        return None, False
    try:
        with open(output_file, 'r', errors='replace') as f:
            return f.read(), True
    except Exception:
        return None, False


def _render_terminal_table(stage_results, picks, term_width):
    """Render compact ASCII terminal table to stderr."""
    col_widths = [10, 25, 14, 8, 6]  # Stage, Model, Speed, Mem, Fit
    header = (
        f"{'Stage':<{col_widths[0]}}  "
        f"{'Model':<{col_widths[1]}}  "
        f"{'Speed':<{col_widths[2]}}  "
        f"{'Mem':<{col_widths[3]}}  "
        f"{'Fit':<{col_widths[4]}}"
    )
    rule = '-' * min(term_width, sum(col_widths) + 10)

    print(f"\n-- Benchmark Results {'-' * max(0, term_width - 21)}", file=sys.stderr)
    print(header, file=sys.stderr)
    print(rule, file=sys.stderr)

    for stage in _STAGE_DIRS:
        for cand in stage_results.get(stage, []):
            label = cand.get('_label', '?')
            speed = _format_speed(cand, stage)
            mem = _format_mem(cand)
            fit = cand.get('fit_status', 'n/a')
            error = cand.get('error')
            if error:
                fit = 'error'
            row = (
                f"{stage:<{col_widths[0]}}  "
                f"{label:<{col_widths[1]}}  "
                f"{speed:<{col_widths[2]}}  "
                f"{mem:<{col_widths[3]}}  "
                f"{fit:<{col_widths[4]}}"
            )
            print(row, file=sys.stderr)

    print(rule, file=sys.stderr)

    # Selected winners line
    w_sel = picks.get('whisper', 'n/a')
    c_sel = picks.get('cleanup', 'n/a')
    s_sel = picks.get('summarize', 'n/a')
    # Extract just the label if a full path was stored
    if os.sep in str(w_sel):
        w_sel = os.path.basename(w_sel)
    if os.sep in str(c_sel):
        c_sel = os.path.basename(c_sel)
    if os.sep in str(s_sel):
        s_sel = os.path.basename(s_sel)
    print(f"Selected:  whisper={w_sel}  cleanup={c_sel}  summary={s_sel}", file=sys.stderr)


def _compute_divergence_summary(stage_results):
    """
    Compute a per-model outlier table for whisper transcripts (if 2+ transcripts).
    Returns list of (label, outlier_count, pct, n_divergent) or None if not enough data.
    """
    whisper_cands = stage_results.get('whisper', [])
    readable = []
    for cand in whisper_cands:
        output_file = cand.get('output_file', '')
        content, found = _read_output_file(output_file)
        if found and content:
            readable.append((cand.get('_label', '?'), content))

    if len(readable) < 2:
        return None

    labels = [lbl for lbl, _ in readable]
    n_cands = len(labels)

    sentences = {}
    for lbl, content in readable:
        body = strip_header(content)
        sentences[lbl] = split_sentences(body)

    anchor_label = labels[0]
    anchor_sents = sentences[anchor_label]

    alignments = {}
    alignments[anchor_label] = {i: s for i, s in enumerate(anchor_sents)}
    for lbl in labels[1:]:
        alignments[lbl] = align_to_anchor(anchor_sents, sentences[lbl])

    outlier_counts = {lbl: 0 for lbl in labels}
    n_divergent = 0

    if n_cands >= 3:
        for pos in range(len(anchor_sents)):
            variants = {}
            for lbl in labels:
                orig = alignments[lbl].get(pos, '')
                norm = normalize(orig) if orig else ''
                variants[lbl] = (orig, norm)
            _, outlier_labels = find_outliers(variants)
            if outlier_labels:
                n_divergent += 1
                for ol in outlier_labels:
                    outlier_counts[ol] += 1

        result = []
        for lbl in labels:
            count = outlier_counts[lbl]
            pct = 100.0 * count / n_divergent if n_divergent > 0 else 0.0
            result.append((lbl, count, pct, n_divergent))
        return result
    else:
        # 2-candidate: count divergences
        for pos in range(len(anchor_sents)):
            variants = {}
            for lbl in labels:
                orig = alignments[lbl].get(pos, '')
                variants[lbl] = normalize(orig) if orig else ''
            vals = list(variants.values())
            if len(set(vals)) > 1:
                n_divergent += 1
        return None  # no outlier ranking for 2 candidates


def _write_report_md(run_dir, stage_results, meta, picks, md_width=120):
    """Write report.md to run_dir."""
    report_path = os.path.join(run_dir, 'report.md')
    lines = []

    # Header
    run_ts = meta.get('run_ts', os.path.basename(run_dir))
    lines.append(f"# Benchmark Report — {run_ts}\n")

    if meta:
        run_date = meta.get('run_ts', 'n/a')
        total_ram = meta.get('total_ram_gb', 'n/a')
        usable = meta.get('usable_gb', 'n/a')
        audio_s = meta.get('audio_duration_s')
        if audio_s is not None:
            try:
                audio_min = float(audio_s) / 60.0
                audio_str = f"{audio_min:.1f} minutes ({audio_s} seconds)"
            except (ValueError, TypeError):
                audio_str = str(audio_s)
        else:
            audio_str = 'n/a'
        lines.append(f"**Run date:** {run_date}  ")
        lines.append(f"**Audio duration:** {audio_str}  ")
        lines.append(f"**Hardware:** {total_ram} GB RAM | usable: {usable} GB\n")

    # Per-stage results tables
    for stage in _STAGE_DIRS:
        cands = stage_results.get(stage, [])
        if not cands:
            continue
        stage_label = stage.capitalize()
        if stage == 'whisper':
            stage_label = 'Whisper (Transcription)'
        elif stage == 'cleanup':
            stage_label = 'Cleanup'
        elif stage == 'summarize':
            stage_label = 'Summarize'

        lines.append(f"\n## Results: {stage_label}\n")
        speed_col = 'Speed (RTF)' if stage == 'whisper' else 'Speed (tok/s)'
        lines.append(f"| Model | {speed_col} | Peak Mem | Fit |")
        lines.append("|-------|-------------|----------|-----|")
        for cand in cands:
            label = cand.get('_label', '?')
            speed = _format_speed(cand, stage)
            mem = _format_mem(cand)
            fit = cand.get('fit_status', 'n/a')
            error = cand.get('error')
            if error:
                fit = f"error: {error}"
            lines.append(f"| {label} | {speed} | {mem} | {fit} |")

        # Selected winner for this stage
        sel = picks.get(stage)
        if sel:
            if os.sep in str(sel):
                sel = os.path.basename(sel)
            lines.append(f"\n**Selected:** {sel}\n")

        # Full excerpts
        lines.append(f"\n### Excerpts\n")
        for cand in cands:
            label = cand.get('_label', '?')
            output_file = cand.get('output_file', '')
            content, found = _read_output_file(output_file)
            lines.append(f"\n#### {label}\n")
            if found and content:
                # Strip control chars (T-05-04)
                safe_content = strip_control_chars(content)
                lines.append(safe_content)
            else:
                lines.append(f"(output file not found: {output_file})\n")

    # Divergence summary for whisper (if computable)
    div_data = _compute_divergence_summary(stage_results)
    if div_data:
        n_divergent = div_data[0][3] if div_data else 0
        lines.append(f"\n## Divergence Summary\n")
        lines.append(f"| Model | Outlier count | % of {n_divergent} divergent positions |")
        lines.append("|-------|---------------|-------------------------------|")
        for lbl, count, pct, _ in div_data:
            lines.append(f"| {lbl} | {count} | {pct:.1f}% |")

    # Selected Winners table
    lines.append(f"\n## Selected Winners\n")
    lines.append("| Stage | Winner |")
    lines.append("|-------|--------|")
    for stage in _STAGE_DIRS:
        sel = picks.get(stage, 'n/a')
        if sel and os.sep in str(sel):
            sel = os.path.basename(sel)
        lines.append(f"| {stage.capitalize()} | {sel} |")

    # Write file
    content_str = '\n'.join(lines) + '\n'
    with open(report_path, 'w') as f:
        f.write(content_str)


def run_report(args):
    """Main logic for the `report` subcommand."""
    run_dir = args.run_dir
    term_width = args.term_width

    if not os.path.isdir(run_dir):
        print(f"ERROR: run-dir does not exist: {run_dir!r}", file=sys.stderr)
        sys.exit(2)

    # Load data
    stage_results = _load_result_jsons(run_dir)
    meta = _load_meta(run_dir)
    picks = _load_picks(run_dir)

    # Also check sweep_meta for selected files
    if meta:
        for stage, key in [('whisper', 'selected_transcript'),
                            ('cleanup', 'selected_cleaned'),
                            ('summarize', 'selected_summary')]:
            if key in meta and stage not in picks:
                picks[stage] = meta[key]

    # Terminal table to stderr
    _render_terminal_table(stage_results, picks, term_width)

    # Write report.md
    _write_report_md(run_dir, stage_results, meta, picks)

    sys.exit(0)


# ── Entry point ──────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        prog='benchmark_helpers.py',
        description='Text-heavy benchmark helper: divergence view and comparison report.',
    )
    sub = parser.add_subparsers(dest='cmd', required=True)

    # divergence subcommand
    div = sub.add_parser(
        'divergence',
        help='Cross-model transcript divergence view (alignment + outlier counting)',
    )
    div.add_argument(
        '--transcripts',
        nargs='+',
        metavar='LABEL:FILEPATH',
        help='label:filepath pairs (one per candidate transcript)',
    )
    div.add_argument(
        '--term-width',
        type=int,
        default=80,
        metavar='INT',
        help='Terminal width for column rendering (default: 80)',
    )

    # report subcommand
    rep = sub.add_parser(
        'report',
        help='Generate terminal ASCII table and report.md from run dir JSONs',
    )
    rep.add_argument(
        '--run-dir',
        required=True,
        metavar='DIR',
        help='Path to benchmark run directory (contains whisper/, cleanup/, summarize/)',
    )
    rep.add_argument(
        '--term-width',
        type=int,
        default=80,
        metavar='INT',
        help='Terminal width for table rendering (default: 80)',
    )

    args = parser.parse_args()
    if args.cmd == 'divergence':
        run_divergence(args)
    elif args.cmd == 'report':
        run_report(args)


if __name__ == '__main__':
    main()
