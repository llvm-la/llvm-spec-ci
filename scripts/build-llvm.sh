#!/usr/bin/env bash
set -euo pipefail

# Build LLVM clang + flang from main branch (Release, LoongArch target)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$(readlink -f "${LLVM_BUILD_DIR:-$PROJECT_DIR/build-llvm}")"
SRC_DIR="$(readlink -f "${LLVM_SRC_DIR:-$PROJECT_DIR/repos/llvm-project}")"
OUTPUT_DIR="$PROJECT_DIR/build-info"
CORES=$(nproc)

echo "=== LLVM Build Configuration ==="
echo "Source: $SRC_DIR"
echo "Build:  $BUILD_DIR"
echo "Cores:  $CORES"

# Step 1: Checkout or update LLVM main branch
if [ -d "$SRC_DIR/.git" ]; then
  echo "[INFO] Updating existing LLVM checkout..."
  cd "$SRC_DIR"
  # Ensure we are on the main branch (handles detached HEAD)
  git symbolic-ref --quiet HEAD 2>/dev/null || git checkout main
  git pull origin main
else
  echo "[INFO] Cloning LLVM project (main branch, single branch)..."
  rm -rf "$SRC_DIR"
  git clone --branch=main https://github.com/llvm/llvm-project.git "$SRC_DIR"
  cd "$SRC_DIR"
fi

# Record commit info
LLVM_COMMIT=$(git log -1 --format='%H')
LLVM_SHORT=$(git log -1 --format='%h')
LLVM_DATE=$(git log -1 --format='%ci' | cut -d' ' -f1)
echo "[INFO] LLVM commit: $LLVM_COMMIT ($LLVM_DATE)"

# Step 2: Configure
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake -G Ninja "$SRC_DIR/llvm" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DLLVM_TARGETS_TO_BUILD=LoongArch \
  -DLLVM_ENABLE_PROJECTS="clang;flang" \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_OPTIMIZED_TABLEGEN=ON \
  -DLLVM_PARALLEL_LINK_JOBS=2 \
  -DLLVM_ENABLE_SHARED_LIBS=true

echo "[INFO] CMake configuration complete"

# Step 3: Build clang and flang only (minimal)
echo "[INFO] Building clang and flang with $CORES jobs..."
ninja clang flang

# Step 4: Verify build
CLANG_BIN="$BUILD_DIR/bin/clang"
FLANG_BIN="$BUILD_DIR/bin/flang"

if [ ! -x "$CLANG_BIN" ]; then
  echo "[FAIL] clang binary not found at $CLANG_BIN"
  exit 1
fi
if [ ! -x "$FLANG_BIN" ]; then
  echo "[FAIL] flang binary not found at $FLANG_BIN"
  exit 1
fi

echo "[OK] clang version: $($CLANG_BIN --version | head -1)"
echo "[OK] flang version: $($FLANG_BIN --version | head -1)"

# Step 6: Write build info for report and downstream jobs
mkdir -p "$OUTPUT_DIR"

cat > "$OUTPUT_DIR/commit.txt" <<EOF
$LLVM_COMMIT
EOF

cat > "$OUTPUT_DIR/info.json" <<EOF
{
  "commit": "$LLVM_COMMIT",
  "short_commit": "$LLVM_SHORT",
  "date": "$LLVM_DATE",
  "branch": "main",
  "build_type": "Release",
  "targets": "LoongArch",
  "projects": "clang;flang",
  "clang_version": "$($CLANG_BIN --version | head -1)",
  "flang_version": "$($FLANG_BIN --version | head -1)",
  "build_dir": "$BUILD_DIR",
  "build_date": "$(date +%Y-%m-%d)"
}
EOF

echo "[INFO] Build info written to $OUTPUT_DIR/"
echo "[OK] LLVM build complete"