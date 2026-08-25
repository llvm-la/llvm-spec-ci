#!/usr/bin/env bash
set -euo pipefail

# Run SPEC CPU 2006 full suite (specint + specfp) with LLVM clang/flang
# Discovers and runs all cfg/*2006*.cfg configs sequentially.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$(readlink -f "${LLVM_BUILD_DIR:-$PROJECT_DIR/build-llvm}")"
SPEC_DIR="$(readlink -f "$PROJECT_DIR/repos/cpu2006")"
CFG_DIR="$PROJECT_DIR/cfg"

echo "=== SPEC CPU 2006 Run Configuration ==="
echo "SPEC Dir:    $SPEC_DIR"
echo "Build Dir:   $BUILD_DIR"
echo "Config dir:  $CFG_DIR"

# Discover matching configs
shopt -s nullglob
CFG_FILES=( "$CFG_DIR"/*2006*.cfg )
shopt -u nullglob

if [ ${#CFG_FILES[@]} -eq 0 ]; then
  echo "[ERROR] No config files matching $CFG_DIR/*2006*.cfg found"
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
  # runspec looks for --config path relative to SPEC_DIR/config/,
  # so we must use an absolute path to the substituted file.
  TMP_CFG=$(mktemp /tmp/spec-cfg-XXXXXX)
  sed "s|@@BUILD_DIR@@|$BUILD_DIR|g" "$CFG_FILE" > "$TMP_CFG"

  cd "$SPEC_DIR"
  source shrc
  relocate

  # Run full specint + specfp
  # Note: runspec uses 'specint'/'specfp' for the benchmark sets.
  NCPUS=$(nproc)
  ./bin/runspec \
    --config="$TMP_CFG" \
    --define build_ncpus="$NCPUS" \
    --action=run \
    --size=ref \
    specint specfp

  rm -f "$TMP_CFG"

  # Copy results to project directory, namespaced per config
  # Result dir pattern: result/<date>-<config>-<benchmark_set>
  RESULTS_DIR=$(ls -td result/*clang-loongarch* 2>/dev/null | head -1)
  if [ -n "$RESULTS_DIR" ] && [ -d "$RESULTS_DIR" ]; then
    echo "[INFO] Results in: $RESULTS_DIR"
    mkdir -p "$PROJECT_DIR/results/spec2006/$CFG_NAME"
    cp -r "$RESULTS_DIR" "$PROJECT_DIR/results/spec2006/$CFG_NAME/"
    echo "[OK] SPEC CPU 2006 ($CFG_NAME) complete"
  else
    echo "[WARN] Could not find SPEC result directory for $CFG_NAME"
    ls -la result/ 2>/dev/null || true
  fi
done

echo ""
echo "[OK] All SPEC CPU 2006 configs complete"
