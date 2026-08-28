#!/usr/bin/env bash
set -euo pipefail

# Run SPEC CPU 2017 full suite (SPECint + SPECfp) with LLVM clang/flang
# Discovers and runs all cfg/*2017*.cfg configs sequentially.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$(readlink -f "${LLVM_BUILD_DIR:-$PROJECT_DIR/build-llvm}")"
SPEC_DIR="$(readlink -f "$PROJECT_DIR/repos/cpu2017")"
CFG_DIR="$PROJECT_DIR/cfg"
CFG_FILTER="${CFG_FILTER:-}"

# Some benchmarks crash with memory overflow unless stack and core
# limits are unlimited; must be set before invoking runcpu.
if ! ulimit -s unlimited; then
  echo "[ERROR] Failed to set 'ulimit -s unlimited' (soft: $(ulimit -s), hard: $(ulimit -Hs))"
  exit 1
fi
if ! ulimit -c unlimited; then
  echo "[ERROR] Failed to set 'ulimit -c unlimited' (soft: $(ulimit -c), hard: $(ulimit -Hc))"
  exit 1
fi
echo "[INFO] Limits set: stack=$(ulimit -s), core=$(ulimit -c)"

echo "=== SPEC CPU 2017 Run Configuration ==="
echo "SPEC Dir:    $SPEC_DIR"
echo "Build Dir:   $BUILD_DIR"
echo "Config dir:  $CFG_DIR"

# Discover matching configs
shopt -s nullglob
CFG_FILES=( "$CFG_DIR"/*2017*.cfg )
shopt -u nullglob

# Optional substring filter on config names (set via CFG_FILTER by ci.sh).
if [ -n "$CFG_FILTER" ] && [ ${#CFG_FILES[@]} -gt 0 ]; then
  FILTERED=()
  for f in "${CFG_FILES[@]}"; do
    base=$(basename "$f" .cfg)
    if [[ "$base" == *"$CFG_FILTER"* ]]; then FILTERED+=( "$f" ); fi
  done
  CFG_FILES=( ${FILTERED[@]+"${FILTERED[@]}"} )   # safe under set -u when empty
fi

if [ ${#CFG_FILES[@]} -eq 0 ]; then
  echo "[ERROR] No config files matching $CFG_DIR/*2017*.cfg found"
  exit 1
fi

echo "[INFO] Found ${#CFG_FILES[@]} config(s) to run"

for CFG_FILE in "${CFG_FILES[@]}"; do
  CFG_NAME=$(basename "$CFG_FILE" .cfg)
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  RUNGUID="${SPEC_RUNGUID:-${TIMESTAMP}-clang-loongarch-${CFG_NAME}}"

  echo ""
  echo "--- Running config: $CFG_NAME ---"
  echo "Config file: $CFG_FILE"
  echo "Run GUID:    $RUNGUID"

  # Substitute LLVM install path in config, write to temp location
  # runcpu looks for --config path relative to SPEC_DIR/config/,
  # so we must use an absolute path to the substituted file.
  TMP_CFG=$(mktemp /tmp/spec-cfg-XXXXXX)
  sed "s|@@BUILD_DIR@@|$BUILD_DIR|g" "$CFG_FILE" > "$TMP_CFG"

  cd "$SPEC_DIR"
  source shrc

  # Run full intrate + fprate
  # Note: runcpu uses 'intrate'/'fprate' (not SPECint/SPECfp).
  # --define build_ncpus sets make -j parallelism at runtime.
  NCPUS=$(nproc)
  ./bin/runcpu \
    --config="$TMP_CFG" \
    --define build_ncpus="$NCPUS" \
    --action=run \
    --size=ref \
    intrate fprate

  rm -f "$TMP_CFG"

  # Copy results to project directory, namespaced per config
  # Result dir pattern: result/<date>-<config>-<benchmark_set>
  RESULTS_DIR=$(ls -td result/*clang-loongarch* 2>/dev/null | head -1)
  if [ -n "$RESULTS_DIR" ] && [ -d "$RESULTS_DIR" ]; then
    echo "[INFO] Results in: $RESULTS_DIR"
    mkdir -p "$PROJECT_DIR/results/spec2017/$CFG_NAME"
    cp -r "$RESULTS_DIR" "$PROJECT_DIR/results/spec2017/$CFG_NAME/"
    echo "[OK] SPEC CPU 2017 ($CFG_NAME) complete"
  else
    echo "[WARN] Could not find SPEC result directory for $CFG_NAME"
    ls -la result/ 2>/dev/null || true
  fi
done

echo ""
echo "[OK] All SPEC CPU 2017 configs complete"
