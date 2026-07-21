# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Automated SPEC CPU 2017 & 2006 benchmark CI on a self-hosted LoongArch (龙芯) GitHub Actions runner. Every 15 days, it builds clang/flang from LLVM main, runs the full SPEC suite, and publishes score reports as artifacts and GitHub Pages.

## Repository Structure

```
scripts/
  setup-env.sh       # Pre-flight: repos symlinks, license, disk space, build deps
  build-llvm.sh       # git pull repos/llvm-project, ninja Release build (clang + flang, LoongArch)
  run-spec2017.sh     # Iterate cfg files matching *2017*, run each with SPEC 2017
  run-spec2006.sh     # Iterate cfg files matching *2006*, run each with SPEC 2006
  generate-report.sh  # Parse SPEC HTML output, produce summary index.html
cfg/
  *2017*.cfg          # SPEC 2017 compiler configs (naming convention: 2017-<name>.cfg)
  *2006*.cfg          # SPEC 2006 compiler configs (naming convention: 2006-<name>.cfg)
repos/
  llvm-project -> <local>  # LLVM source, updated via git pull (NOT actions/checkout)
  cpu2017 -> <local>       # Symlink to SPEC CPU 2017 installation (NOT in git)
  cpu2006 -> <local>       # Symlink to SPEC CPU 2006 installation (NOT in git)
```

## Key Design Details

### Config Files (`cfg/`)
- All configs use `@@BUILD_DIR@@` as a placeholder for the LLVM install path. Run scripts `sed` this at runtime.
- Naming convention: `2017-<name>.cfg` for SPEC 2017, `2006-<name>.cfg` for SPEC 2006.
- Run scripts auto-discover matching configs (`cfg/*2017*.cfg` / `cfg/*2006*.cfg`) and run each sequentially.
- Configs vary by optimization flags (O2, O3, Ofast, -mlasx, -nolsx, etc.).

### Run Scripts
- `run-spec2017.sh` / `run-spec2006.sh`: loop over all matching configs in `cfg/`, set a unique RUNGUID per config, invoke `runspec`, and copy results to `results/spec{2017,2006}/`.
- Use `--norerun` to prevent infinite rerun loops. Use `--size=ref` for reference dataset.
- SPEC license is pre-activated on the runner (no config needed).

### Build Script
- `build-llvm.sh`: git pull repos/llvm-project → cmake (Release, LoongArch, clang+flang only) → ninja `clang flang` → `ninja install-cli`.
- Outputs `build-info/info.json` with commit hash, versions, paths. Used by downstream jobs and report generation.
- Uses ccache via `CMAKE_*_COMPILER_LAUNCHER` for incremental speedup.

### Report Script
- `generate-report.sh`: reads `build-info/info.json` + finds SPEC HTML results → generates `results/latest/index.html`.
- Uses `grep -oP` to extract SPECrate/SPECspeed scores from SPEC HTML output. Depends on `jq` for build info.

### Workflow (`.github/workflows/spec-benchmark.yml`)
- Chain: `setup-env` → `build-llvm` → `run-spec2017` + `run-spec2006` (parallel on same runner) → `generate-report`.
- Timeouts: 10m (env check), 480m (LLVM build), 1440m per SPEC run, 30m (report).
- `generate-report` uses `if: always()` to run even if SPEC jobs fail (partial results).
- Artifacts retained 90 days. Deployed to GitHub Pages on `main` branch.
- Trigger: cron `0 0 1,16 * *` + `workflow_dispatch`.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LLVM_BUILD_DIR` | `/tmp/llvm-spec-build` | LLVM build output directory |
| `LLVM_SRC_DIR` | `repos/llvm-project` | LLVM source directory (updated via git pull, not checkout) |
| `SPEC_RUNGUID` | auto-generated | SPEC run GUID prefix |

## Common Commands

```bash
# Check runner environment
./scripts/setup-env.sh

# Build LLVM locally
./scripts/build-llvm.sh

# Run SPEC suite with a single config (test)
SPEC2017_ONLY=602.gcc_r ./scripts/run-spec2017.sh

# Generate report from existing results
./scripts/generate-report.sh
```

## Constraints

- **Repos safety**: `repos/` content is gitignored (llvm-project, cpu2017, cpu2006). Never touch with `actions/checkout` (clean: false on the setup-env checkout). llvm-project updated via `git pull`, not clone.
- **Single runner**: self-hosted, serial execution despite parallel job definitions.
- **Build size**: LLVM build uses ~50G disk. SPEC runs may take 24+ hours for full suite.
- **Architecture**: LoongArch (loongarch64), kernel 4.19.0-19-loongson-3.