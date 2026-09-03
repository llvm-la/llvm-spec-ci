#!/usr/bin/env python3
"""SPEC result parser.

Parses runspec asc/csv output files and writes result.json with the shape
described by schemas/result.schema.json: {gerrit, config, benchmarks}.

Usage: collect-result.py --results-dir <dir> [--spec-ci <yaml>] [--output result.json]
       collect-result.py --asc <file.asc> [--spec-ci <yaml>] [--output result.json]
"""
import argparse
import csv
import json
import os
import re
import sys
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv()
for _k, _v in os.environ.items():
    if _v and "$" in _v:
        os.environ[_k] = os.path.expandvars(_v)

ASC_RE = re.compile(r"^(?P<name>\S+):\s*(?P<val>\S+).*$")


def parse_asc(path):
    """Parse a runspec .asc file: 'benchmark: result' lines."""
    out = {}
    for line in Path(path).read_text().splitlines():
        m = ASC_RE.match(line)
        if m and m.group("name").startswith(("4", "5", "6")):
            try:
                out[m.group("name")] = float(m.group("val"))
            except ValueError:
                pass
    return out


def parse_csv(path):
    """Parse a runspec .csv with columns like Benchmark,Base Ratio,etc."""
    out = {}
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        return out
    keys = rows[0].keys()
    base_col = next((k for k in keys if k.lower().startswith("base") and "ratio" in k.lower()), None)
    if base_col is None:
        base_col = next((k for k in keys if "ratio" in k.lower()), None)
    for row in rows:
        name = row.get("Benchmark") or row.get("benchmark")
        if not name or not base_col or base_col not in row:
            continue
        try:
            out[name] = float(row[base_col])
        except ValueError:
            pass
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--results-dir", default=os.environ.get("SPEC_RESULT_DIR"),
                   help="directory of runspec .asc/.csv files (default: $SPEC_RESULT_DIR)")
    p.add_argument("--asc", help="single .asc file")
    p.add_argument("--spec-ci", default=os.environ.get("SPEC_CI_FILE"),
                   help="spec-ci.yaml (optional, for config/context)")
    p.add_argument("--output", default=os.environ.get("SPEC_RESULT_FILE", "result.json"),
                   help="output json (default: $SPEC_RESULT_FILE or result.json)")
    a = p.parse_args()

    benchmarks = {}
    if a.results_dir:
        for f in sorted(Path(a.results_dir).glob("*.asc")):
            benchmarks.update(parse_asc(f))
        for f in sorted(Path(a.results_dir).glob("*.csv")):
            benchmarks.update(parse_csv(f))
    if a.asc:
        benchmarks.update(parse_asc(a.asc))

    if not benchmarks:
        print("warning: no benchmark results parsed", file=sys.stderr)

    config = {}
    if a.spec_ci:
        import yaml
        config = yaml.safe_load(open(a.spec_ci))

    result = {
        "gerrit": {
            "change": os.environ.get("GERRIT_CHANGE_NUMBER", ""),
            "revision": os.environ.get("GERRIT_PATCHSET_REVISION", ""),
            "patchset": os.environ.get("GERRIT_PATCHSET_NUMBER", ""),
        },
        "config": config,
        "benchmarks": benchmarks,
    }

    Path(a.output).write_text(json.dumps(result, indent=2))
    print(a.output)


if __name__ == "__main__":
    main()