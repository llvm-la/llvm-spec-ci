#!/usr/bin/env bash
set -euo pipefail

# Run SPEC CPU 2017 full suite (SPECint + SPECfp) with LLVM clang/flang

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${LLVM_BUILD_DIR:-/tmp/llvm-spec-build}"
SPEC_DIR="repos/cpu2017"
CFG_FILE="$PROJECT_DIR/cfg/clang-2017.cfg"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUNGUID="${SPEC_RUNGUID:-$(date +%Y%m%d)-clang-loongarch-$TIMESTAMP"}

echo "=== SPEC CPU 2017 Run Configuration ==="
echo "SPEC Dir:    $(readlink -f "$SPEC_DIR")"
echo "Config:      $CFG_FILE"
echo "Run GUID:    $RUNGUID"
echo "Build Dir:   $BUILD_DIR"

# Substitute LLVM install path in config
sed "s|@@BUILD_DIR@@|$BUILD_DIR|g" "$CFG_FILE" > "$SPEC_DIR/config/clang-loongarch.cfg"

cd "$SPEC_DIR"
source shrc

# Run full SPECint + SPECfp
./bin/runcpu \
  --config=config/clang-loongarch.cfg \
  --runguid="$RUNGUID" \
  --norerun \
  --action=compile,run \
  --size=ref \
  SPECint SPECfp \
  --output_format=html

# Copy results to project directory
RESULTS_DIR=$(ls -td result/*clang-loongarch*${RUNGUID}* 2>/dev/null | head -1)
if [ -n "$RESULTS_DIR" ] && [ -d "$RESULTS_DIR" ]; then
  echo "[INFO] Results in: $RESULTS_DIR"
  mkdir -p "$PROJECT_DIR/results/spec2017"
  cp -r "$RESULTS_DIR" "$PROJECT_DIR/results/spec2017/"
  echo "[OK] SPEC CPU 2017 complete"
else
  echo "[WARN] Could not find SPEC result directory"
  # Try to find any recent result
  ls -la result/ 2>/dev/null || true
fi