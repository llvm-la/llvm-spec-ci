#!/usr/bin/env python3
"""Generate a SPEC .cfg file from a spec-ci.yaml spec block and a template.

Reads the YAML spec block (cpu2006 or cpu2017), fills the @VAR@ placeholders in
the matching template with values derived from the LLVM build directory and the
optimization flags in the YAML.  Output goes to a file or stdout.
"""
import argparse
import os
from pathlib import Path

import yaml
from dotenv import load_dotenv

load_dotenv()
for _k, _v in os.environ.items():
    if _v and "$" in _v:
        os.environ[_k] = os.path.expandvars(_v)

TEMPLATE_DIR = Path(__file__).resolve().parent.parent / "templates"

OPTIMIZE_VARS = ("COPTIMIZE", "CXXOPTIMIZE", "FOPTIMIZE", "OPTIMIZE")
PORTABILITY_VARS = ("PORTABILITY", "CPORTABILITY", "CXXPORTABILITY", "FPORTABILITY")


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


def generate(spec, yaml_block, llvm_dir, template_text):
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
        if not opts.get("enabled"):
            continue
        block = emit(name, opts)
        if block:
            bench_blocks.append(block)
    if bench_blocks:
        out = out.rstrip() + "\n\n" + "\n\n".join(bench_blocks) + "\n"
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--yaml", required=True)
    p.add_argument("--spec", required=True, choices=("cpu2006", "cpu2017"))
    p.add_argument("--llvm-dir", default=None,
                   help="LLVM build directory (default: $LLVM_BUILD_DIR from .env)")
    p.add_argument("--output", default="-")
    a = p.parse_args()

    if a.llvm_dir is None:
        a.llvm_dir = os.environ.get("LLVM_BUILD_DIR")
        if not a.llvm_dir:
            raise SystemExit("error: --llvm-dir required (or set LLVM_BUILD_DIR in .env)")

    d = yaml.safe_load(open(a.yaml))
    block = d.get(a.spec)
    if block is None:
        raise SystemExit(f"error: spec '{a.spec}' not present in {a.yaml}")

    template = TEMPLATE_DIR / a.spec / "llvm.cfg.template"
    cfg = generate(a.spec, block, a.llvm_dir, template.read_text())

    if a.output == "-":
        print(cfg)
    else:
        Path(a.output).write_text(cfg)
        print(a.output)


if __name__ == "__main__":
    main()