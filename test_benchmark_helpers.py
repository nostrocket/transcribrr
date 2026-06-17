"""
Tests for benchmark_helpers.py — divergence and report subcommands.
RED phase: these tests should FAIL before implementation.
"""
import subprocess
import sys
import os
import json
import tempfile

PYTHON = "/Users/gareth/git/transcribrr/.venv/bin/python"
HELPER = os.path.join(os.path.dirname(__file__), "benchmark_helpers.py")


def run_helper(*args, input_stdin=None):
    """Run benchmark_helpers.py with given args. Returns (returncode, stdout, stderr)."""
    cmd = [PYTHON, HELPER] + list(args)
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        input=input_stdin,
    )
    return result.returncode, result.stdout, result.stderr


# ── Task 1: divergence subcommand tests ──────────────────────────────────────

def test_divergence_3cand_fully_agree():
    """3 transcripts that fully agree → zero divergent positions, outlier summary all-zero."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat. The dog ran. The bird flew.\n")
        p1 = f.name
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat. The dog ran. The bird flew.\n")
        p2 = f.name
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat. The dog ran. The bird flew.\n")
        p3 = f.name
    try:
        rc, stdout, stderr = run_helper(
            "divergence", "--transcripts",
            f"a:{p1}", f"b:{p2}", f"c:{p3}",
            "--term-width", "80"
        )
        assert rc == 0, f"Expected exit 0, got {rc}\nstderr: {stderr}"
        assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"
        # With 3 candidates and no divergence, outlier summary should show 0s
        assert "outlier" in stderr.lower(), f"Expected 'outlier' in stderr, got: {stderr}"
    finally:
        os.unlink(p1)
        os.unlink(p2)
        os.unlink(p3)


def test_divergence_3cand_one_differs():
    """3 transcripts where one differs at one sentence → side-by-side shown; differing model gets +1 outlier."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat. The dog ran. The bird flew.\n")
        p1 = f.name
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat. The dog walked. The bird flew.\n")
        p2 = f.name
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat. The dog ran. The bird flew.\n")
        p3 = f.name
    try:
        rc, stdout, stderr = run_helper(
            "divergence", "--transcripts",
            f"a:{p1}", f"b:{p2}", f"c:{p3}",
            "--term-width", "80"
        )
        assert rc == 0, f"Expected exit 0, got {rc}\nstderr: {stderr}"
        assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"
        assert "outlier" in stderr.lower(), f"Expected outlier count in stderr, got: {stderr}"
        # b should have 1 outlier
        assert "b" in stderr, f"Expected candidate 'b' mentioned in stderr"
    finally:
        os.unlink(p1)
        os.unlink(p2)
        os.unlink(p3)


def test_divergence_2cand_no_outlier_ranking():
    """2 transcripts that differ → divergence count reported, NO outlier ranking."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat. The dog ran. The bird flew.\n")
        p1 = f.name
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat. The dog walked. The bird flew.\n")
        p2 = f.name
    try:
        rc, stdout, stderr = run_helper(
            "divergence", "--transcripts",
            f"a:{p1}", f"b:{p2}",
            "--term-width", "80"
        )
        assert rc == 0, f"Expected exit 0, got {rc}\nstderr: {stderr}"
        assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"
        # Should report divergence but NOT rank outliers
        assert "no outlier ranking" in stderr.lower(), \
            f"Expected 'no outlier ranking' in stderr for 2-candidate case, got: {stderr}"
        assert "divergen" in stderr.lower(), f"Expected divergence count in stderr, got: {stderr}"
    finally:
        os.unlink(p1)
        os.unlink(p2)


def test_divergence_strips_header():
    """Header lines (Model:/Source:/Date:) never appear as divergent units."""
    content_a = "Model: foo/bar\nSource: yt\nDate: 2026-01-01\n\nThe cat sat. The dog ran.\n"
    content_b = "Model: foo/bar\nSource: yt\nDate: 2026-01-01\n\nThe cat sat. The dog ran.\n"
    content_c = "Model: foo/bar\nSource: yt\nDate: 2026-01-01\n\nThe cat sat. The dog ran.\n"
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write(content_a)
        p1 = f.name
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write(content_b)
        p2 = f.name
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write(content_c)
        p3 = f.name
    try:
        rc, stdout, stderr = run_helper(
            "divergence", "--transcripts",
            f"a:{p1}", f"b:{p2}", f"c:{p3}",
            "--term-width", "80"
        )
        assert rc == 0, f"Expected exit 0, got {rc}\nstderr: {stderr}"
        assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"
        # Header fields must NOT appear as divergent content
        assert "Model: foo" not in stderr, f"Header line appeared as divergence: {stderr}"
        assert "Source: yt" not in stderr, f"Header line appeared as divergence: {stderr}"
    finally:
        os.unlink(p1)
        os.unlink(p2)
        os.unlink(p3)


def test_divergence_missing_file_exit1():
    """A transcript path that does not exist → stderr warning, exit 1 if <2 readable."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat.\n")
        p1 = f.name
    try:
        rc, stdout, stderr = run_helper(
            "divergence", "--transcripts",
            f"a:{p1}", "b:/nonexistent/path/file.txt",
            "--term-width", "80"
        )
        assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"
        assert rc == 1, f"Expected exit 1 when <2 readable, got {rc}\nstderr: {stderr}"
    finally:
        os.unlink(p1)


def test_divergence_bad_label_exit2():
    """A label containing `;` or `$(...)` → exit 2."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat.\n")
        p1 = f.name
    try:
        rc, stdout, stderr = run_helper(
            "divergence", "--transcripts",
            f"a;bad:{p1}", "b:/nonexistent.txt",
            "--term-width", "80"
        )
        assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"
        assert rc == 2, f"Expected exit 2 for bad label, got {rc}\nstderr: {stderr}"
    finally:
        os.unlink(p1)


def test_divergence_nothing_to_stdout():
    """Nothing is ever written to stdout."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat. The dog ran.\n")
        p1 = f.name
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("The cat sat. The dog walked.\n")
        p2 = f.name
    try:
        rc, stdout, stderr = run_helper(
            "divergence", "--transcripts",
            f"a:{p1}", f"b:{p2}",
            "--term-width", "80"
        )
        assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"
    finally:
        os.unlink(p1)
        os.unlink(p2)


# ── Task 2: report subcommand tests ──────────────────────────────────────────

def test_report_3whisper_jsons():
    """run dir with 3 whisper JSONs → terminal table lists 3 rows; report.md exists."""
    with tempfile.TemporaryDirectory() as rd:
        os.makedirs(os.path.join(rd, "whisper"))
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            f.write("transcript body one.\n")
            out_file = f.name
        try:
            for label in ["turbo", "small", "distil"]:
                j = {
                    "format_version": 1,
                    "candidate_id": label,
                    "fit_status": "fit",
                    "error": None,
                    # Real on-disk contract emitted by write_success_json in
                    # benchmark.sh: speed_metric + numeric speed_value (NOT `rtf`).
                    "speed_metric": "rtf",
                    "speed_value": 0.02,
                    "peak_mem_gb": 2.0,
                    "output_file": out_file
                }
                with open(os.path.join(rd, "whisper", f"{label}_result.json"), "w") as jf:
                    json.dump(j, jf)
            rc, stdout, stderr = run_helper(
                "report", "--run-dir", rd, "--term-width", "80"
            )
            assert rc == 0, f"Expected exit 0, got {rc}\nstderr: {stderr}"
            assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"
            assert os.path.isfile(os.path.join(rd, "report.md")), "report.md not created"
            with open(os.path.join(rd, "report.md")) as mf:
                md_content = mf.read()
            assert "turbo" in md_content, f"Expected 'turbo' in report.md"
            # Terminal table to stderr
            assert "turbo" in stderr, f"Expected 'turbo' in terminal table stderr"
            # The speed must render from speed_metric/speed_value, NOT show n/a
            # (regression guard for CR-01 — fixture now matches the real writer).
            assert "RTF=0.020" in stderr, \
                f"Expected formatted RTF speed in terminal table, got: {stderr}"
            assert "RTF=0.020" in md_content, \
                f"Expected formatted RTF speed in report.md, got: {md_content}"
        finally:
            os.unlink(out_file)


def test_report_empty_run_dir():
    """Empty run dir (no JSONs) → exit 0, minimal report.md written."""
    with tempfile.TemporaryDirectory() as rd:
        rc, stdout, stderr = run_helper(
            "report", "--run-dir", rd, "--term-width", "80"
        )
        assert rc == 0, f"Expected exit 0, got {rc}\nstderr: {stderr}"
        assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"
        assert os.path.isfile(os.path.join(rd, "report.md")), "report.md not created for empty dir"


def test_report_missing_output_file():
    """output_file path that does not exist → report.md notes it, no crash."""
    with tempfile.TemporaryDirectory() as rd:
        os.makedirs(os.path.join(rd, "whisper"))
        j = {
            "format_version": 1,
            "candidate_id": "turbo",
            "fit_status": "fit",
            "error": None,
            # Real on-disk contract (CR-01): speed_metric + speed_value.
            "speed_metric": "rtf",
            "speed_value": 0.02,
            "peak_mem_gb": 2.0,
            "output_file": "/nonexistent/path/transcript.txt"
        }
        with open(os.path.join(rd, "whisper", "turbo_result.json"), "w") as jf:
            json.dump(j, jf)
        rc, stdout, stderr = run_helper(
            "report", "--run-dir", rd, "--term-width", "80"
        )
        assert rc == 0, f"Expected exit 0, got {rc}\nstderr: {stderr}"
        assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"
        with open(os.path.join(rd, "report.md")) as mf:
            md_content = mf.read()
        assert "output file not found" in md_content.lower() or "not found" in md_content.lower(), \
            f"Expected 'not found' note in report.md, got: {md_content}"


def test_report_stdout_empty():
    """Terminal table printed to stderr only; stdout empty."""
    with tempfile.TemporaryDirectory() as rd:
        rc, stdout, stderr = run_helper(
            "report", "--run-dir", rd, "--term-width", "80"
        )
        assert stdout == "", f"Expected empty stdout, got: {repr(stdout)}"


if __name__ == "__main__":
    tests = [
        test_divergence_3cand_fully_agree,
        test_divergence_3cand_one_differs,
        test_divergence_2cand_no_outlier_ranking,
        test_divergence_strips_header,
        test_divergence_missing_file_exit1,
        test_divergence_bad_label_exit2,
        test_divergence_nothing_to_stdout,
        test_report_3whisper_jsons,
        test_report_empty_run_dir,
        test_report_missing_output_file,
        test_report_stdout_empty,
    ]
    failed = []
    passed = []
    for t in tests:
        try:
            t()
            passed.append(t.__name__)
            print(f"PASS: {t.__name__}")
        except Exception as e:
            failed.append((t.__name__, str(e)))
            print(f"FAIL: {t.__name__}: {e}")
    print(f"\n{len(passed)} passed, {len(failed)} failed")
    if failed:
        sys.exit(1)
