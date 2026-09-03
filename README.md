# llvm-performance-ci

LLVM + Gerrit + Jenkins + SPEC CPU2006/CPU2017 performance CI.

Flow:

```
Gerrit Patch
 -> Save spec-ci.yaml
 -> Validate spec-ci.yaml (tools/spec-ci.py validate)
 -> Checkout Gerrit patch
 -> Build LLVM (exports LLVM_DIR)
 -> Generate SPEC cfg (scripts/generate-spec-cfg.sh, per suite present in YAML)
 -> Build SPEC (scripts/build-spec.sh)
 -> Run SPEC (scripts/run-spec.sh, runspec from YAML enabled/size/iterations)
 -> Collect result (tools/collect-result.py) -> result.json
```

The SPEC configuration is generated from a single human-readable YAML file
(`spec-ci.yaml`) plus the LLVM build directory. The YAML only holds what
changes per run: optimization flags (`COPTIMIZE`/`CXXOPTIMIZE`/`FOPTIMIZE`),
which benchmarks are enabled, and run parameters (`size`, `iterations`).
Compiler paths, hardware descriptions, and per-benchmark portability rules
live in the templates (`templates/cpu2006|cpu2017/llvm.cfg.template`) and are
filled in by `tools/generator.py`.

## spec-ci.yaml layout

```yaml
version: 1
name: example
cpu2006:            # present => cpu2006.cfg generated
  compiler:
    default:
      COPTIMIZE: -O3
      CXXOPTIMIZE: -O3
      FOPTIMIZE: -O3
  benchmarks:
    400.perlbench: { enabled: true }
  run:
    size: ref        # test/train/ref, passed to runspec
    iterations: 3    # passed to runspec
cpu2017:            # present => cpu2017.cfg generated
  ...
```

## CLI

```sh
python3 tools/spec-ci.py init --specs cpu2006 cpu2017   # scaffold a YAML
python3 tools/spec-ci.py validate spec-ci.yaml          # validate
```

Path configuration (`LLVM_BUILD_DIR`, `SPEC_CI_FILE`, ...) is read from the
repo-root `.env` by the `tools/*.py` scripts via `python-dotenv`. Copy
`.env.example` to `.env` and adjust for the machine.