#!/usr/bin/env python3
"""SPEC result parser.

Parses one or more runspec .rsf raw summary files and writes result.json
with the shape: {gerrit, config, suites}.

Suites are determined by benchmark classification:
  cpu2006:  cint (int), cfp (float)
  cpu2017:  intrate (_r int), fprate (_r float), intspeed (_s int), fpspeed (_s float)

Usage: collect-result.py --rsf <a.rsf> --rsf <b.rsf> [--spec-ci <yaml>] [--output-dir <dir>] [--output <name>]
       collect-result.py --results-dir <dir> [--spec-ci <yaml>] [--output-dir <dir>] [--output <name>]

  --output-dir: directory for the result JSON (default: $SPEC_RESULT_DIR)
  --output:     filename (default: auto-generated as result-{name}-{author}-{change}-{patchset}-{build}.json)
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv()

RSF_RESULT_RE = re.compile(
    r"^spec\.cpu20(?P<year>06|17)\.results\."
    r"(?P<bm>[^.]+)\.base\.(?P<iter>\d+)\.(?P<field>\S+):\s*(?P<val>.*)$"
)

# Failure codes: negative values for non-S runs / missing data.
FAILURE_CODES = {
    "CE": -1,   # Compilation Error
    "RE": -2,   # Runtime Error (crashed, non-zero exit)
}
NOT_RUN = -3    # Benchmark enabled but did not appear in RSF

# SPEC integer benchmark classification (by name). Float = complement.
_INT_BENCHMARKS = {
    "06": {
        "400.perlbench", "401.bzip2", "403.gcc", "429.mcf", "445.gobmk",
        "456.hmmer", "458.sjeng", "462.libquantum", "464.h264ref", "471.omnetpp",
        "473.astar", "483.xalancbmk",
    },
    "17": {
        # rate (_r)
        "500.perlbench_r", "502.gcc_r", "505.mcf_r", "520.omnetpp_r",
        "523.xalancbmk_r", "525.x264_r", "531.deepsjeng_r", "541.leela_r",
        "548.exchange2_r", "557.xz_r",
        # speed (_s)
        "600.perlbench_s", "602.gcc_s", "605.mcf_s", "620.omnetpp_s",
        "623.xalancbmk_s", "625.x264_s", "631.deepsjeng_s", "641.leela_s",
        "648.exchange2_s", "657.xz_s",
    },
}


def suite_for_benchmark(year, name):
    """Map (year, benchmark) -> suite name.

    cpu2006: cint / cfp
    cpu2017: intrate (_r int) / fprate (_r float) / intspeed (_s int) / fpspeed (_s float)
    """
    is_int = name in _INT_BENCHMARKS[year]
    if year == "06":
        return "cint" if is_int else "cfp"
    # cpu2017: distinguish rate (_r) vs speed (_s)
    if name.endswith("_r"):
        return "intrate" if is_int else "fprate"
    if name.endswith("_s"):
        return "intspeed" if is_int else "fpspeed"
    # fallback: treat unknown suffix by int/float
    return "intrate" if is_int else "fprate"


def parse_rsf(path):
    """Parse a runspec .rsf raw summary file.

    Returns {suite: {benchmark: score}}.  Each benchmark is placed in its
    correct suite via suite_for_benchmark(), so a single RSF may contribute
    to multiple suites.

    Format is flat key:value pairs, one per line::

        spec.cpu2006.results.400_perlbench.base.000.benchmark: 400.perlbench
        spec.cpu2006.results.400_perlbench.base.000.ratio: 11.14
        spec.cpu2006.results.400_perlbench.base.000.valid: S

    Each benchmark may have multiple iterations (000, 001, ...).
    - Successful iterations (valid: S) with a numeric ratio are collected
      into a list (one entry per iteration), e.g. [11.1, 11.2, 11.0].
    - Failed iterations output a negative failure code from FAILURE_CODES.
    """
    lines = Path(path).read_text().splitlines()

    # Collect per-year runs.
    runs_by_year = {}  # year -> bm_key -> iter -> field -> val
    for line in lines:
        m = RSF_RESULT_RE.match(line)
        if not m:
            continue
        year = m.group("year")
        bm_key = m.group("bm")
        itr = m.group("iter")
        field = m.group("field")
        val = m.group("val").strip()
        runs_by_year.setdefault(year, {}).setdefault(bm_key, {}).setdefault(itr, {})[field] = val

    suites = {}
    for year, runs in runs_by_year.items():
        for bm_key, iters in runs.items():
            # Canonical name from .benchmark field, else derive from key.
            # RSF encodes the benchmark name with underscores (554_roms_r);
            # the first one separates the number from the name and must be
            # turned back into a dot.  Later underscores (e.g. h264ref) stay.
            names = [it.get("benchmark", "") for it in iters.values() if it.get("benchmark")]
            name = names[0] if names else re.sub(r"^(\d+)_", r"\1.", bm_key)

            ratios = []
            times = []
            for fields in iters.values():
                valid = fields.get("valid", "").upper()
                if valid != "S":
                    continue
                val = fields.get("ratio", "--")
                if val == "--":
                    continue
                try:
                    ratios.append(float(val))
                except ValueError:
                    pass
                t = fields.get("reported_time", "")
                if t:
                    try:
                        times.append(float(t))
                    except ValueError:
                        pass

            if ratios:
                score = ratios          # keep every iteration, not the average
                runtime = times if times else None
            else:
                first_valid = list(iters.values())[0].get("valid", "").upper()
                score = FAILURE_CODES.get(first_valid, -9)
                runtime = None

            suite = suite_for_benchmark(year, name)
            entry = {"ratio": score}
            if runtime is not None:
                entry["time"] = runtime
            suites.setdefault(suite, {})[name] = entry

    return suites


def _expected_benchmarks(spec_ci):
    """Return {suite: set(benchmark)} from spec-ci.yaml enabled benchmarks."""
    suites = {}
    for top, year in [("cpu2006", "06"), ("cpu2017", "17")]:
        cfg = spec_ci.get(top) or {}
        bms = cfg.get("benchmarks") or {}
        for name, v in bms.items():
            if isinstance(v, dict) and not v.get("enabled", True):
                continue
            suite = suite_for_benchmark(year, name)
            suites.setdefault(suite, set()).add(name)
    return suites


def _default_result_name(spec_ci):
    """Build a descriptive result filename from metadata.

    Uses spec-ci.yaml fields (name, author) plus CI environment
    (change, patchset, build number).

    Format: result-{name}-{author}-{change}-{patchset}-{build}.json
    Falls back to 'result-unknown.json' when metadata is missing.
    """
    if spec_ci:
        name = spec_ci.get("name", "run")
        author = spec_ci.get("author", "anonymous")
    else:
        name = "run"
        author = "anonymous"
    change = os.environ.get("GERRIT_CHANGE_NUMBER", "")
    patchset = os.environ.get("GERRIT_PATCHSET_NUMBER", "")
    build = os.environ.get("BUILD_NUMBER", "")

    parts = [p for p in (change, patchset, build) if p]
    if parts:
        tag = "-".join(parts)
        return f"result-{name}-{author}-{tag}.json"
    return f"result-{name}-{author}.json"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--results-dir", default=os.environ.get("SPEC_BUILD_DIR"),
                   help="directory of runspec .rsf files (default: $SPEC_BUILD_DIR)")
    p.add_argument("--rsf", action="append", default=[],
                   help="runspec .rsf raw summary file (repeatable)")
    p.add_argument("--spec-ci", default=os.environ.get("SPEC_CI_FILE"),
                   help="spec-ci.yaml (expected benchmarks per suite)")
    p.add_argument("--output-dir", default=os.environ.get("SPEC_RESULT_DIR"),
                   help="directory for the result JSON (default: $SPEC_RESULT_DIR)")
    p.add_argument("--output", default=None,
                   help="output filename (default: auto-generated from metadata)")
    a = p.parse_args()

    # Collect all RSF files: from --rsf and --results-dir.
    rsf_files = list(a.rsf)
    if a.results_dir:
        rsf_files.extend(sorted(Path(a.results_dir).glob("*.rsf")))

    if not rsf_files:
        print("error: no input .rsf files (use --rsf or --results-dir)", file=sys.stderr)
        sys.exit(1)

    spec_ci = {}

    # Parse each RSF and merge into suites.
    suites = {}
    for f in rsf_files:
        for suite, results in parse_rsf(f).items():
            suites.setdefault(suite, {}).update(results)

    # Fill in expected-but-missing benchmarks from spec-ci.yaml.
    if a.spec_ci:
        import yaml
        spec_ci = yaml.safe_load(open(a.spec_ci))
        expected = _expected_benchmarks(spec_ci)
        for suite, bms in expected.items():
            if suite not in suites:
                suites[suite] = {}
            for bm in bms:
                if bm not in suites[suite]:
                    suites[suite][bm] = {"ratio": NOT_RUN}

    # Warn if every suite is empty / all failures.
    if all(not v or all(not isinstance(vv.get("ratio"), list) for vv in v.values())
           for v in suites.values()):
        print("warning: no successful benchmark results parsed", file=sys.stderr)

    result = {
        "gerrit": {
            "change": os.environ.get("GERRIT_CHANGE_NUMBER", ""),
            "revision": os.environ.get("GERRIT_PATCHSET_REVISION", ""),
            "patchset": os.environ.get("GERRIT_PATCHSET_NUMBER", ""),
            "build_number": os.environ.get("BUILD_NUMBER", ""),
        },
        "config": spec_ci,
        "suites": suites,
    }

    # Resolve output directory and filename.
    out_dir = Path(a.output_dir) if a.output_dir else Path.cwd()
    out_dir.mkdir(parents=True, exist_ok=True)
    out_name = a.output if a.output else _default_result_name(spec_ci)
    out_path = out_dir / out_name

    out_path.write_text(json.dumps(result, indent=2))
    print(str(out_path))


if __name__ == "__main__":
    main()
