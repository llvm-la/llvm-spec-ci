#!/usr/bin/env bash
set -euo pipefail

# Run SPEC CPU 2017 full suite (SPECint + SPECfp) with LLVM clang/flang
# Discovers and runs all cfg/*2017*.cfg configs sequentially.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$(readlink -f "${LLVM_BUILD_DIR:-$PROJECT_DIR/build-llvm}")"
SPEC_DIR="$(readlink -f "$PROJECT_DIR/repos/cpu2017")"
CFG_DIR="$PROJECT_DIR/cfg"

echo "=== SPEC CPU 2017 Run Configuration ==="
echo "SPEC Dir:    $SPEC_DIR"
echo "Build Dir:   $BUILD_DIR"
echo "Config dir:  $CFG_DIR"

# Discover matching configs
shopt -s nullglob
CFG_FILES=( "$CFG_DIR"/*2017*.cfg )
shopt -u nullglob

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

  # Substitute LLVM install path in config
  sed "s|@@BUILD_DIR@@|$BUILD_DIR|g" "$CFG_FILE" > "$SPEC_DIR/config/clang-loongarch.cfg"

  cd "$SPEC_DIR"
  source shrc

  # Run full SPECint + SPECfp
  # Note: runcpu v6612 (SPEC 2017 v1.0.5) uses different option names:
  #   --run_guid (not --runguid), no --norerun, --action=run (not compile,run)
  ./bin/runcpu \
    --config=config/clang-loongarch.cfg \
    --run_guid="$RUNGUID" \
    --action=run \
    --size=ref \
    SPECint SPECfp \
    --output_format=html

  # Copy results to project directory, namespaced per config
  RESULTS_DIR=$(ls -td result/*clang-loongarch*${RUNGUID}* 2>/dev/null | head -1)
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
