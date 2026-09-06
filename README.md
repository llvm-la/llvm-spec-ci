# llvm-performance-ci

LLVM + Gerrit + Jenkins + SPEC CPU2006/CPU2017 performance CI.

Flow:

```
Gerrit Patch
 -> Save spec-ci.yaml
 -> Validate spec-ci.yaml (spec-ci.py validate)
 -> Validate Parameters (GERRIT_CHANGE, GERRIT_PATCHSET)
 -> Cleanup (rm $SPEC_BUILD_DIR; keep $LLVM_BUILD_DIR, $SPEC_RESULT_DIR, workspace)
 -> Verify Upload (spec-ci.yaml exists)
 -> Checkout Gerrit patch
 -> Build LLVM (exports LLVM_DIR)
 -> Generate SPEC cfg + run scripts (tools/generate.py, per suite present in YAML)
 -> Run SPEC (generated run-cpu2006.sh / run-cpu2017.sh: source shrc, ulimit, runspec/runcpu)
 -> Collect result (tools/collect-result.py) -> $SPEC_RESULT_DIR/result-{name}-{author}-{change}-{patchset}-{build}.json
 -> Package results (scripts/package-build.sh + archiveArtifacts) -> spec-build-<timestamp>.tar.gz (Jenkins artifact)
 -> Cleanup Workspace (rm spec-ci.yaml, tarball; keep $SPEC_RESULT_DIR for comparison)
```

The SPEC configuration is generated from a single human-readable YAML file
(`spec-ci.yaml`) plus the LLVM build directory. The YAML only holds what
changes per run: optimization flags (`COPTIMIZE`/`CXXOPTIMIZE`/`FOPTIMIZE`),
which benchmarks are enabled, and run parameters (`size`, `iterations`).
Compiler paths, hardware descriptions, and per-benchmark portability rules
live in the templates (`templates/cfg/cpu2006.cfg`, `templates/cfg/cpu2017.cfg`) and are
filled in by `tools/generate.py`, which also emits `run-cpu2006.sh` /
`run-cpu2017.sh` to invoke runspec/runcpu with the generated cfg.

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
python3 spec-ci.py init --specs cpu2006 cpu2017   # scaffold a YAML
python3 spec-ci.py validate spec-ci.yaml          # validate
```

Path configuration (`LLVM_BUILD_DIR`, `SPEC_CI_FILE`, ...) is read from the
repo-root `.env` by the Python scripts via `python-dotenv`. Copy
`.env.example` to `.env` and adjust for the machine.