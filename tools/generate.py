#!/usr/bin/env python3
"""Generate SPEC .cfg files and run scripts from a spec-ci.yaml.

For each suite (cpu2006/cpu2017) present in the YAML:
  1. fill the @VAR@ placeholders in the matching .cfg template
  2. emit a run-cpu20NN.sh that sources shrc and invokes runspec/runcpu

Usage:
    python3 tools/generate.py --yaml spec-ci.yaml --llvm-dir ./build --out ./spec-build
    python3 tools/generate.py --yaml spec-ci.yaml --llvm-dir ./build --out ./spec-build --spec cpu2017

If --spec is given, only that suite is generated.  Otherwise every suite
present in the YAML is generated, one .cfg + one .sh each, written to the
output directory.
"""

import argparse
import os
import stat
import sys
from pathlib import Path

import yaml
from dotenv import load_dotenv

load_dotenv()

TEMPLATE_DIR = Path(__file__).resolve().parent.parent / "templates" / "cfg"

OPTIMIZE_VARS = ("COPTIMIZE", "CXXOPTIMIZE", "FOPTIMIZE", "OPTIMIZE")
PORTABILITY_VARS = ("PORTABILITY", "CPORTABILITY", "CXXPORTABILITY", "FPORTABILITY",
                    "EXTRA_CXXFLAGS", "EXTRA_CFLAGS", "EXTRA_FFLAGS")

ALL_SPECS = ("cpu2006", "cpu2017")

# SPEC command per suite: cpu2006 uses runspec, cpu2017 uses runcpu.
SPEC_CMD = {"cpu2006": "runspec", "cpu2017": "runcpu"}


def _emit_bench_block_cpu2006(name, opts):
    """Render one benchmark's portability block for CPU2006.

    CPU2006 templates use fully-qualified section headers
    (e.g. default=base=default=default:), so per-benchmark blocks
    follow the same style.
    """
    lines = []
    for var in PORTABILITY_VARS:
        value = opts.get(var)
        if value:
            lines.append(f"   {var} = {value}")
    if not lines:
        return None
    return f"{name}=base=default=default:\n" + "\n".join(lines)


def _emit_bench_block_cpu2017(name, opts):
    """Render one benchmark's portability block for CPU2017.

    CPU2017 templates use bare section headers (e.g. default:), so
    per-benchmark blocks follow the same style.
    """
    lines = []
    for var in PORTABILITY_VARS:
        value = opts.get(var)
        if value:
            lines.append(f"   {var} = {value}")
    if not lines:
        return None
    return f"{name}:\n" + "\n".join(lines)


def generate_cfg(spec, yaml_block, llvm_dir, template_text):
    """Return the cfg text for one spec block."""
    comp = yaml_block.get("compiler", {}).get("default", {})
    run = yaml_block.get("run", {})
    repl = {"LLVM_DIR": llvm_dir, "ITERATIONS": run.get("iterations", 1)}
    for var in OPTIMIZE_VARS:
        repl[var] = comp.get(var, "")

    out = template_text
    for var, value in repl.items():
        out = out.replace(f"@{var}@", str(value))

    # Append per-benchmark portability blocks from YAML.  Each suite has
    # its own block emitter because their template header styles differ.
    if spec == "cpu2006":
        emit = _emit_bench_block_cpu2006
    else:
        emit = _emit_bench_block_cpu2017

    bench_blocks = []
    for name, opts in (yaml_block.get("benchmarks") or {}).items():
        if isinstance(opts, dict) and not opts.get("enabled", True):
            continue
        block = emit(name, opts or {})
        if block:
            bench_blocks.append(block)
    if bench_blocks:
        out = out.rstrip() + "\n\n" + "\n\n".join(bench_blocks) + "\n"
    return out


def _enabled_benchmarks(yaml_block):
    """Return list of enabled benchmark names from a YAML spec block."""
    out = []
    for name, opts in (yaml_block.get("benchmarks") or {}).items():
        if isinstance(opts, dict) and not opts.get("enabled", True):
            continue
        out.append(name)
    return out


def generate_run_script(spec, yaml_block, cfg_path, output_root):
    """Return the run-cpu20NN.sh text for one spec suite.

    The script:
      - raises ulimit -s/-c unlimited
      - cds into the SPEC installation and sources shrc
      - runs runspec/runcpu with the generated cfg, size, enabled
        benchmarks, iterations and --output_root
    """
    dir_ = os.environ.get(f"SPEC_{spec.upper()}_DIR", "")
    size = yaml_block.get("run", {}).get("size", "ref")
    iterations = yaml_block.get("run", {}).get("iterations", 1)
    benchmarks = _enabled_benchmarks(yaml_block)
    bench_args = " ".join(benchmarks)
    cmd = SPEC_CMD[spec]

    return (
        f"#!/bin/bash\n"
        f"ulimit -s unlimited\n"
        f"ulimit -c unlimited\n"
        f"\n"
        f"cd {dir_}\n"
        f"source shrc\n"
        f"\n"
        f"{cmd} -c {cfg_path} -i {size} {bench_args} -n {iterations}"
        f" --output_root={output_root}\n"
    )


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--yaml", required=True,
                   help="path to spec-ci.yaml")
    p.add_argument("--spec", choices=ALL_SPECS, default=None,
                   help="generate only this suite (default: all present in YAML)")
    p.add_argument("--llvm-dir", default=None,
                   help="LLVM build directory (default: $LLVM_BUILD_DIR from .env)")
    p.add_argument("--out", "--output", default=None, dest="out",
                   help="output directory for the generated .cfg/.sh files")
    p.add_argument("--output-root", default=None,
                   help="SPEC output_root (default: $SPEC_BUILD_DIR or $SPEC_RESULT_DIR)")
    a = p.parse_args()

    if a.out is None:
        p.error("--out is required")

    if a.llvm_dir is None:
        a.llvm_dir = os.environ.get("LLVM_BUILD_DIR")
    if not a.llvm_dir:
        raise SystemExit("error: --llvm-dir required (or set LLVM_BUILD_DIR in .env)")

    if a.output_root is None:
        a.output_root = os.environ.get("SPEC_BUILD_DIR",
                                       os.environ.get("SPEC_RESULT_DIR", ""))
    if not a.output_root:
        raise SystemExit(
            "error: --output-root required (or set SPEC_BUILD_DIR / SPEC_RESULT_DIR in .env)")

    # Resolve to absolute paths so the generated cfg/sh work regardless of $PWD.
    a.llvm_dir = str(Path(a.llvm_dir).resolve())
    a.output_root = str(Path(a.output_root).resolve())

    out_dir = Path(a.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    d = yaml.safe_load(Path(a.yaml).read_text())

    # cfg / script filenames are prefixed with author + name so multiple
    # runs / users can share one output directory without colliding.
    author = d.get("author", "anonymous")
    name = d.get("name", "run")
    prefix = f"{author}-{name}"

    if a.spec:
        specs = (a.spec,)
    else:
        specs = [s for s in ALL_SPECS if s in d]

    for spec in specs:
        block = d.get(spec)
        if block is None:
            print(f"spec {spec} not in {a.yaml}, skipping")
            continue

        template = TEMPLATE_DIR / f"{spec}.cfg"
        cfg = generate_cfg(spec, block, a.llvm_dir, template.read_text())

        cfg_dest = out_dir / f"{prefix}-{spec}.cfg"
        cfg_dest.write_text(cfg)
        print(f"generated {cfg_dest}")

        script = generate_run_script(spec, block, str(cfg_dest), a.output_root)
        sh_dest = out_dir / f"run-{spec}.sh"
        sh_dest.write_text(script)
        sh_dest.chmod(sh_dest.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        print(f"generated {sh_dest}")


if __name__ == "__main__":
    main()
