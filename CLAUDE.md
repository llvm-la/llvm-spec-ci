# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Automated SPEC CPU 2017 & 2006 benchmark CI on a self-hosted LoongArch (龙芯) machine, orchestrated locally by `scripts/ci.sh` (no GitHub Actions). Every 15 days (local cron), it builds clang/flang from LLVM main, runs the full SPEC suite, and publishes score reports served by a local web server.

## Repository Structure

```
scripts/
  setup-env.sh       # Pre-flight: repos symlinks, license, disk space, build deps
  build-llvm.sh       # git pull repos/llvm-project, ninja Release build (clang + flang, LoongArch)
  run-spec2017.sh     # Discover cfg/*2017*.cfg, run each with SPEC 2017
  run-spec2006.sh     # Discover cfg/*2006*.cfg, run each with SPEC 2006
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
- All configs use `@@BUILD_DIR@@` as a placeholder for the LLVM build path (binaries are in `$BUILD_DIR/bin`). Run scripts `sed` this at runtime.
- Naming convention: `*-2017*.cfg` for SPEC 2017, `*-2006*.cfg` for SPEC 2006.
- Run scripts auto-discover matching configs (`cfg/*2017*.cfg` / `cfg/*2006*.cfg`) and run each sequentially.
- Results are namespaced per config under `results/spec{2017,2006}/<config-name>/`.
- Run scripts pass `--define build_ncpus=$(nproc)` to use all available CPUs for make parallelism.
- **SPEC 2017 format**: Uses preprocessor directives (`%define`, `%if`, `%endif`, `%{variable}`), sections `default:` / `default=base:` / `default=peak:`, and per-benchmark overrides like `500.perlbench_r,600.perlbench_s:`. Optimization vars: `OPTIMIZE`, `EXTRA_COPTIMIZE`, `EXTRA_CXXOPTIMIZE`, `EXTRA_FOPTIMIZE`. Portability: `PORTABILITY`, `CPORTABILITY`, `CXXPORTABILITY`, `FPORTABILITY`.
- **SPEC 2006 format**: Uses four-field section headers `default=default=default=default:` (benchmark=tune=ext=default), and per-benchmark overrides like `400.perlbench=default=default=default:`. Optimization vars: `COPTIMIZE`, `CXXOPTIMIZE`, `FOPTIMIZE`. Portability: `CPORTABILITY`, `CXXPORTABILITY`, `FPORTABILITY`, `FPPPORTABILITY`.
- Reference configs (on this system): `/home/user/code/llvm-spec-ci/clang-opt-before-lsx.cfg` (SPEC 2017 clang/flang), `/home/user/code/llvm-spec-ci/clang-loongarch-backcost-lsx.cfg` (SPEC 2006 clang/flang). SPEC upstream examples at `$SPEC/cpu2017/config/Example-*.cfg` and `$SPEC/cpu2006/config/`.

### Run Scripts
- `run-spec2017.sh` / `run-spec2006.sh`: loop over all matching configs in `cfg/`, set a unique RUNGUID per config, invoke `runspec`, and copy results to `results/spec{2017,2006}/<config-name>/`.
- Use `--norerun` to prevent infinite rerun loops. Use `--size=ref` for reference dataset.
- SPEC license is pre-activated on the runner (no config needed).

### Build Script
- `build-llvm.sh`: git pull repos/llvm-project → cmake (Release, LoongArch, clang+flang only) → ninja `clang flang`. No install step; binaries are used directly from `build-llvm/bin/`.
- Outputs `build-info/info.json` with commit hash, versions, paths. Used by downstream jobs and report generation.

### Report Script
- `generate-report.sh`: reads `build-info/info.json` + finds SPEC HTML results → generates `results/latest/index.html`.
- Uses `grep -oP` to extract SPECrate/SPECspeed scores from SPEC HTML output. Depends on `jq` for build info.
- Copies detailed SPEC reports into `results/latest/spec2017-detail/<config-name>/` and `results/latest/spec2006-detail/<config-name>/`.
- Appends scores to `results/latest/history.json` for online comparison (handles missing benchmarks as null).

### Online Comparison (`results/compare.html`)
- Static HTML page served by the local web server (see Local CI) for comparing scores across runs.
- Loads `history.json` via fetch, populates two dropdown selectors.
- Displays side-by-side comparison table with absolute diff and percentage change.
- Missing benchmarks (null scores) show N/A and are excluded from diff calculation.
- Pure client-side JavaScript, no build step or dependencies.

## Local CI (`scripts/ci.sh`)

Orchestration runs on the runner itself (no GitHub Actions). `scripts/ci.sh` is the
single entry point; it runs the existing step scripts under a global `flock` so two
runs (each using all cores) never overlap.

```bash
./scripts/ci.sh <command> [--config NAME]
```

Commands:
- `full` — setup-env → build → spec2017 → spec2006 → report
- `build` / `spec2017` / `spec2006` / `report` — run a single step
- `status` — show whether a run is in progress (read-only)
- `list-configs` — list available `cfg/*.cfg` (read-only)
- `help`

`--config NAME` runs only configs whose name contains NAME (substring match).

Behavior:
- A global lock (`.ci.lock`) is held for the duration of any run command; a second
  concurrent invocation is refused (exit 1), not queued or cancelled.
- `full` aborts if `setup-env` or `build` fails; a `spec2017`/`spec2006` failure is
  recorded but the remaining steps and `report` still run (partial results); the exit
  code reflects any step failure.
- Each run tees its output to `logs/<timestamp>-<command>/run.log`.
- `ci.sh` prepends `/usr/local/bin` to PATH (cron's default PATH lacks the build tools).

Scheduling (cron, replaces the old GitHub cron; edit the schedule as needed):
```
0 0 1,16 * * cd /home/user/code/llvm-spec-ci && mkdir -p logs && ./scripts/ci.sh full >> logs/cron.log 2>&1
```
Install via `crontab -e`. If a manual run is in progress when cron fires, the lock
makes cron skip safely.

Report web server (systemd; change the port in the unit if needed):
```
sudo cp systemd/spec-report-web.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now spec-report-web
```
Serves `results/latest/` at `http://<host>:8080/` (`index.html`, `compare.html`,
`history.json`, detail reports).

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LLVM_BUILD_DIR` | `build-llvm` | LLVM build output directory (under project root) |
| `LLVM_SRC_DIR` | `repos/llvm-project` | LLVM source directory (updated via git pull, not checkout) |
| `SPEC_RUNGUID` | auto-generated | SPEC run GUID prefix |
| `CFG_FILTER` | (unset) | Run only configs whose name contains this substring (set by `ci.sh --config`) |

## Common Commands

```bash
# Check runner environment
./scripts/setup-env.sh

# Full local CI run (build + both SPEC suites + report)
./scripts/ci.sh full

# Single steps
./scripts/ci.sh build
./scripts/ci.sh spec2017 --config clang
./scripts/ci.sh report

# Inspect state / available configs
./scripts/ci.sh status
./scripts/ci.sh list-configs
```

## Constraints

- **Repos safety**: `repos/` content is gitignored (llvm-project, cpu2017, cpu2006). Never touch with `actions/checkout` (clean: false on the setup-env checkout). llvm-project updated via `git pull`, not clone.
- **Single runner**: self-hosted, fully serial execution (SPEC 2017 → SPEC 2006 → report).
- **Build size**: LLVM build uses ~50G disk. SPEC runs may take 24+ hours for full suite.
- **Architecture**: LoongArch (loongarch64), kernel 4.19.0-19-loongson-3.
