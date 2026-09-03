#!/usr/bin/env python3
"""spec-ci configuration tool.

Manage the spec-ci.yaml file that drives the LLVM performance CI pipeline.
Users author one YAML that may describe both SPEC CPU2006 and CPU2017 runs.
This CLI validates and initializes the config; it does NOT generate SPEC .cfg
files (that is generator.py on the Jenkins side).
"""
import argparse
import os
import sys
from pathlib import Path

import yaml
from dotenv import load_dotenv

load_dotenv()
# .env values may reference other vars ($CI_ROOT/...); expand them like the
# shell scripts do when sourcing .env.
for _k, _v in os.environ.items():
    if _v and "$" in _v:
        os.environ[_k] = os.path.expandvars(_v)
DEFAULT_FILE = os.environ.get("SPEC_CI_FILE", "spec-ci.yaml")

SPECS = ("cpu2006", "cpu2017")

# Variables allowed in spec-ci.yaml.  CC/CXX/FC are not stored in YAML;
# generator.py derives them from the LLVM build directory.
# - OPTIMIZE_* : global optimization flags (compiler.default level)
# - PORTABILITY_* : per-benchmark portability flags (benchmark level)
ALLOWED_CFG_VARS = {
    "COPTIMIZE", "CXXOPTIMIZE", "FOPTIMIZE", "OPTIMIZE",
    "PORTABILITY", "CPORTABILITY", "CXXPORTABILITY", "FPORTABILITY",
}

TEMPLATE_DIR = Path(__file__).resolve().parent.parent / "templates"
TEMPLATE_FILE = TEMPLATE_DIR / "spec-ci.template.yaml"

# SPEC CPU2006 benchmarks, split into its two groups (CINT2006/CFP2006).
CPU2006_BENCHMARKS = {
    "cint": [
        "400.perlbench", "401.bzip2", "403.gcc", "429.mcf", "445.gobmk",
        "456.hmmer", "458.sjeng", "462.libquantum", "464.h264ref",
        "471.omnetpp", "473.astar", "483.xalancbmk",
    ],
    "cfp": [
        "410.bwaves", "416.gamess", "433.milc", "434.zeusmp", "435.gromacs",
        "436.cactusADM", "437.leslie3d", "444.namd", "447.dealII", "450.soplex",
        "453.povray", "454.calculix", "459.GemsFDTD", "465.tonto", "470.lbm",
        "481.wrf", "482.sphinx3",
    ],
}

# SPEC CPU2017 benchmarks, split into its four groups (rate/speed x int/fp).
CPU2017_BENCHMARKS = {
    "intrate": [
        "500.perlbench_r", "502.gcc_r", "505.mcf_r", "520.omnetpp_r",
        "523.xalancbmk_r", "525.x264_r", "531.deepsjeng_r", "541.leela_r",
        "548.exchange2_r", "557.xz_r",
    ],
    "intspeed": [
        "600.perlbench_s", "602.gcc_s", "605.mcf_s", "620.omnetpp_s",
        "623.xalancbmk_s", "625.x264_s", "631.deepsjeng_s", "641.leela_s",
        "648.exchange2_s", "657.xz_s",
    ],
    "fprate": [
        "503.bwaves_r", "507.cactuBSSN_r", "508.namd_r", "510.parest_r",
        "511.povray_r", "519.lbm_r", "521.wrf_r", "526.blender_r",
        "527.cam4_r", "538.imagick_r", "544.nab_r", "549.fotonik3d_r",
        "554.roms_r",
    ],
    "fpspeed": [
        "603.bwaves_s", "607.cactuBSSN_s", "619.lbm_s", "621.wrf_s",
        "627.cam4_s", "638.imagick_s", "644.nab_s", "649.fotonik3d_s",
        "654.roms_s", "628.pop2_s",
    ],
}

# suite -> (group -> member list); flat KNOWN_BENCHMARKS[suite] is the union.
SUITE_GROUPS = {
    "cpu2006": CPU2006_BENCHMARKS,
    "cpu2017": CPU2017_BENCHMARKS,
}

# Display order of groups within each suite in show output.
GROUP_ORDER = {
    "cpu2006": ("cint", "cfp"),
    "cpu2017": ("intrate", "intspeed", "fprate", "fpspeed"),
}

KNOWN_BENCHMARKS = {
    suite: [b for g in GROUP_ORDER[suite] for b in SUITE_GROUPS[suite][g]]
    for suite in SPECS
}

# Non-numeric enable/disable targets -> the suite they select. Group names are
# static-expanded to their member benchmarks; "2006"/"2017" select whole suites.
GROUPS = {name: suite
          for suite in SPECS
          for name in list(SUITE_GROUPS[suite]) + [suite[3:]]}


def load(path):
    with open(path) as f:
        d = yaml.safe_load(f)
    if d is None:
        raise ValueError(f"{path}: empty YAML file")
    if not isinstance(d, dict):
        raise ValueError(f"{path}: expected a mapping at top level")
    return d


def save(path, d):
    with open(path, "w") as f:
        yaml.dump(d, f, sort_keys=False)


def _load_template():
    """Load and return the parsed spec-ci.template.yaml."""
    if not TEMPLATE_FILE.exists():
        raise SystemExit(f"error: template file not found: {TEMPLATE_FILE}")
    with open(TEMPLATE_FILE) as f:
        return yaml.safe_load(f)


def _spec_block_from_template(tpl, suite):
    """Extract one suite's spec block from the loaded template."""
    block = tpl.get(suite)
    if block is None:
        raise SystemExit(f"error: template has no '{suite}' block")
    return block


def init(args):
    tpl = _load_template()
    d = {
        "version": 1,
        "name": args.name,
    }
    for s in args.specs:
        d[s] = _spec_block_from_template(tpl, s)
    if Path(args.file).exists():
        raise SystemExit(f"error: {args.file} already exists, refusing to overwrite")
    save(args.file, d)
    print(f"created {args.file} with specs: {', '.join(args.specs)}")


def _schema_checks(d):
    """Validate against spec-ci.schema.json required keys / enums manually."""
    problems = []

    if "version" not in d:
        problems.append("missing required key: version")
    if "name" not in d:
        problems.append("missing required key: name")

    for spec, block in d.items():
        if spec in ("version", "name"):
            continue
        if spec not in SPECS:
            problems.append(f"unknown key '{spec}'; expected one of version/name/{', '.join(SPECS)}")
            continue
        if not isinstance(block, dict):
            problems.append(f"spec '{spec}': expected a mapping")
            continue
        comp = block.get("compiler", {}).get("default", {})
        if not isinstance(comp, dict):
            problems.append(f"spec '{spec}': compiler.default must be a mapping")
        else:
            for var in comp:
                if var not in ALLOWED_CFG_VARS:
                    problems.append(f"spec '{spec}': compiler.default has disallowed var '{var}'")

        benchmarks = block.get("benchmarks", {})
        if not isinstance(benchmarks, dict):
            problems.append(f"spec '{spec}': benchmarks must be a mapping")
        else:
            for name, opts in benchmarks.items():
                if name not in KNOWN_BENCHMARKS[spec]:
                    problems.append(f"spec '{spec}': unknown benchmark '{name}'")
                if not isinstance(opts, dict):
                    problems.append(f"spec '{spec}': benchmark '{name}' options must be a mapping")
                    continue
                for var in opts:
                    if var == "enabled":
                        continue
                    if var not in ALLOWED_CFG_VARS:
                        problems.append(
                            f"spec '{spec}': benchmark '{name}' has disallowed var '{var}'")

        run = block.get("run", {})
        if "size" in run and run["size"] not in ("test", "train", "ref"):
            problems.append(f"spec '{spec}': run.size must be test/train/ref")
        if "iterations" in run and (not isinstance(run["iterations"], int) or run["iterations"] < 1):
            problems.append(f"spec '{spec}': run.iterations must be a positive integer")

    return problems


def validate(args):
    d = load(args.file)
    problems = _schema_checks(d)
    if problems:
        for p in problems:
            print(f"[ERROR] {p}")
        raise SystemExit(1)
    print("CONFIG OK")


def _group_members(suite, group):
    """Return the benchmarks of a group within a suite (static expansion)."""
    if group in ("2006", "2017"):  # whole-suite keyword
        return KNOWN_BENCHMARKS[suite]
    return SUITE_GROUPS[suite][group]


def _resolve_targets(targets):
    """Resolve CLI targets to (suite, benchmark) pairs.

    Accepts: exact 3-digit benchmark prefix, full benchmark name, group name
    (cint/cfp/intrate/intspeed/fprate/fpspeed), or whole-suite keyword
    (2006/2017). Unknown targets are warned and skipped.
    """
    resolved = []
    for t in targets:
        if t in GROUPS:
            suite = GROUPS[t]
            resolved.extend((suite, b) for b in _group_members(suite, t))
            continue
        if t in KNOWN_BENCHMARKS["cpu2006"]:
            resolved.append(("cpu2006", t))
            continue
        if t in KNOWN_BENCHMARKS["cpu2017"]:
            resolved.append(("cpu2017", t))
            continue
        if len(t) == 3 and t.isdigit():
            for suite, benchs in KNOWN_BENCHMARKS.items():
                match = [b for b in benchs if b.startswith(t)]
                if match:
                    resolved.append((suite, match[0]))
                    break
            else:
                print(f"[WARN] target '{t}' matches no benchmark; ignored")
            continue
        print(f"[WARN] target '{t}' is not a valid benchmark, group, or suite; ignored")
    return resolved


def _set_enabled(d, resolved, enabled):
    for suite, bench in resolved:
        block = d.setdefault(suite, {})
        bench_map = block.setdefault("benchmarks", {})
        bench_map[bench] = bench_map.get(bench, {})
        bench_map[bench]["enabled"] = enabled


# ANSI styling for the show output. Highlight = bright green; disabled = red strike.
_GREEN = "\033[1;32m"
_STRIKE = "\033[9;31m"
_RESET = "\033[0m"

def _fmt_member(bench, highlighted, struck):
    if struck:
        return f"{_STRIKE}{bench}{_RESET}"
    if highlighted:
        return f"{_GREEN}{bench}{_RESET}"
    return bench


def _show(d, highlighted=(), struck=()):
    """Print enabled benchmarks grouped by suite then group, 5 per row.

    highlighted: iterable of (suite, benchmark) to render in bright green.
    struck:      iterable of (suite, benchmark) to render in red strikethrough.
    """
    highlighted = set(highlighted)
    struck = set(struck)
    for suite in SPECS:
        block = d.get(suite) or {}
        benches = block.get("benchmarks") or {}
        rendered = []
        for group in GROUP_ORDER[suite]:
            members = _group_members(suite, group)
            formatted = []
            for b in members:  # keep numeric order; style each member
                if benches.get(b, {}).get("enabled"):
                    formatted.append(_fmt_member(b, (suite, b) in highlighted, (suite, b) in struck))
                elif (suite, b) in struck:
                    formatted.append(_fmt_member(b, False, True))
            if not formatted:
                continue  # nothing shown in this group
            rendered.append((group, formatted))
        if not rendered:
            continue
        print(f"{suite}")
        for group, formatted in rendered:
            print(f"  {group}")
            width = max(len(_strip_ansi(m)) for m in formatted)
            for i in range(0, len(formatted), 5):
                row = [m + " " * (width - len(_strip_ansi(m)) + 1) for m in formatted[i:i + 5]]
                print("    " + "".join(row).rstrip())


def _strip_ansi(s):
    import re
    return re.sub(r"\x1b\[[0-9;]*m", "", s)


def cmd_show(args):
    d = load(args.file)
    _show(d)


def cmd_list(args):
    """Print every benchmark, grouped by suite then group, 5 per row."""
    for suite in SPECS:
        print(f"{suite}")
        for group in GROUP_ORDER[suite]:
            members = _group_members(suite, group)
            print(f"  {group}")
            width = max(len(b) for b in members)
            for i in range(0, len(members), 5):
                print("    " + " ".join(b.ljust(width) for b in members[i:i + 5]))


def _cmd_set(args, enabled):
    d = load(args.file)
    resolved = _resolve_targets(args.targets)
    _set_enabled(d, resolved, enabled)
    save(args.file, d)
    print()
    _show(d, highlighted=resolved if enabled else (), struck=() if enabled else resolved)


def cmd_enable(args):
    _cmd_set(args, True)


def cmd_disable(args):
    _cmd_set(args, False)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    s = p.add_subparsers(required=True, dest="command")

    x = s.add_parser("init", help="create a new spec-ci.yaml")
    x.add_argument("--file", default=DEFAULT_FILE)
    x.add_argument("--name", default="example")
    x.add_argument("--specs", nargs="+", default=SPECS, choices=SPECS,
                   help=f"which SPEC suites to scaffold (default: all: {', '.join(SPECS)})")
    x.set_defaults(func=init)

    x = s.add_parser("validate", help="validate a config against the schema")
    x.add_argument("file", nargs="?", default=DEFAULT_FILE)
    x.set_defaults(func=validate)

    x = s.add_parser("show", help="show enabled benchmarks in spec-ci.yaml")
    x.add_argument("--file", default=DEFAULT_FILE)
    x.set_defaults(func=cmd_show)

    x = s.add_parser("list", help="list all benchmarks, grouped by suite and group")
    x.set_defaults(func=cmd_list)

    for name, func, desc in (
        ("enable", cmd_enable, "enable benchmarks/groups/suites in spec-ci.yaml"),
        ("disable", cmd_disable, "disable benchmarks/groups/suites in spec-ci.yaml"),
    ):
        x = s.add_parser(name, help=desc)
        x.add_argument("--file", default=DEFAULT_FILE)
        x.add_argument("targets", nargs="+",
                       help="benchmark (400 / 400.perlbench), group (cint/cfp/"
                            "intrate/intspeed/fprate/fpspeed), or suite (2006/2017)")
        x.set_defaults(func=func)

    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()