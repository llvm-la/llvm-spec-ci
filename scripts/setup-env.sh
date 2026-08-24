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
for suite in cpu2017 cpu2006 llvm-project; do
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

# Check SPEC CPU 2017 runcpu exists
if [ -f "repos/cpu2017/bin/runcpu" ] && [ -x "repos/cpu2017/bin/runcpu" ]; then
  echo "[OK] cpu2017/bin/runcpu executable"
else
  echo "[FAIL] cpu2017/bin/runcpu missing or not executable"
  FAIL=1
fi

# Check SPEC CPU 2006 runspec exists
if [ -f "repos/cpu2006/bin/runspec" ] && [ -x "repos/cpu2006/bin/runspec" ]; then
  echo "[OK] cpu2006/bin/runspec executable"
else
  echo "[FAIL] cpu2006/bin/runspec missing or not executable"
  FAIL=1
fi

# Check disk space (require at least 50G free)
# df --output=avail returns 1K blocks, so 50G = 52428800 blocks
avail=$(df --output=avail / | tail -1 | tr -d ' ')
if [ "$avail" -gt 52428800 ]; then
  echo "[OK] Disk space: $((avail / 1048576))G available"
else
  echo "[FAIL] Disk space insufficient: $((avail / 1048576))G available (need >50G)"
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