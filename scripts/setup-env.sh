#!/usr/bin/env bash
set -euo pipefail

# Environment check script for SPEC CI runner

FAIL=0

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "[OK] $desc"
  else
    echo "[FAIL] $desc"
    FAIL=1
  fi
}

# Check SPEC symlink targets exist
for suite in cpu2017 cpu2006; do
  link="repos/$suite"
  if [ -L "$link" ]; then
    target=$(readlink -f "$link")
    if [ -d "$target" ]; then
      echo "[OK] $suite symlink valid -> $target"
    else
      echo "[FAIL] $suite symlink broken -> $target"
      FAIL=1
    fi
  else
    echo "[FAIL] $suite not found (repos/$suite)"
    FAIL=1
  fi
done

# Check SPEC runspec exists
for suite in cpu2017 cpu2006; do
  path="repos/$suite/runspec"
  if [ -f "$path" ] && [ -x "$path" ]; then
    echo "[OK] $suite/runspec executable"
  else
    echo "[FAIL] $suite/runspec missing or not executable"
    FAIL=1
  fi
done

# Check SPEC license
if command -v lmstat &>/dev/null; then
  check "SPEC license server reachable" lmstat -a -c /usr/local/flexlm/license.dat 2>/dev/null || true
elif [ -n "${LM_LICENSE_FILE:-}" ]; then
  echo "[OK] LM_LICENSE_FILE set: $LM_LICENSE_FILE"
else
  echo "[WARN] No lmstat or LM_LICENSE_FILE found - license may still work via SPEC config"
fi

# Check disk space (require at least 50G free)
avail=$(df --output=avail / | tail -1 | tr -d ' ')
if [ "$avail" -gt 51200 ]; then
  echo "[OK] Disk space: $((avail / 1024))G available"
else
  echo "[FAIL] Disk space insufficient: $((avail / 1024))G available (need >50G)"
  FAIL=1
fi

# Check build dependencies
for dep in cmake ninja python3 clang clang++; do
  check "$dep available" command -v "$dep"
done

# Check git
check "git available" command -v git

# Check nproc
cores=$(nproc)
echo "[INFO] Available cores: $cores"

if [ "$FAIL" -ne 0 ]; then
  echo "[ERROR] Environment check failed"
  exit 1
fi

echo "[OK] All checks passed"