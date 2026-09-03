#!/usr/bin/env bash
# Build LLVM/Clang/Flang from source for the SPEC performance CI.
# Usage: build-llvm.sh [build-type] [jobs] [mode]
#   build-type: Release (default) | Debug | RelWithDebInfo
#   jobs:       parallel build jobs (default 32)
#   mode:       incremental (default) | clean
#
# Paths (LLVM_SOURCE_DIR, LLVM_BUILD_DIR, ...) come from the repo-root .env.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

if [ ! -f "$ROOT/.env" ]; then
    echo "ERROR: $ROOT/.env not found. Copy .env.example to .env and adjust paths."
    exit 1
fi
set -a
# shellcheck source=../.env
. "$ROOT/.env"
set +a

BUILD_TYPE="${1:-Release}"
BUILD_JOBS="${2:-32}"
LLVM_BUILD_MODE="${3:-incremental}"

echo "========================================"
echo "LLVM Build"
echo "========================================"
echo
echo "Source Directory: $LLVM_SOURCE_DIR"
echo "Build Directory:  $LLVM_BUILD_DIR"
echo "Build Type:       $BUILD_TYPE"
echo "Build Jobs:       $BUILD_JOBS"
echo "Build Mode:       $LLVM_BUILD_MODE"
echo

if [ ! -d "$LLVM_SOURCE_DIR/.git" ]; then
    echo "ERROR: LLVM source directory not found: $LLVM_SOURCE_DIR"
    exit 1
fi
if [ ! -f "$LLVM_SOURCE_DIR/llvm/CMakeLists.txt" ]; then
    echo "ERROR: Invalid llvm-project source tree: $LLVM_SOURCE_DIR"
    exit 1
fi
if [ "$LLVM_BUILD_MODE" != "clean" ] && [ "$LLVM_BUILD_MODE" != "incremental" ]; then
    echo "ERROR: Unknown build mode '$LLVM_BUILD_MODE' (expected clean|incremental)"
    exit 1
fi

if [ "$LLVM_BUILD_MODE" == "clean" ]; then
    echo
    echo "===== CLEAN LLVM BUILD ====="
    rm -rf "$LLVM_BUILD_DIR"
fi

mkdir -p "$LLVM_BUILD_DIR"

echo
echo "===== CONFIGURE LLVM ====="
cmake \
    -B "$LLVM_BUILD_DIR" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_C_COMPILER=clang \
    -DLLVM_USE_LINKER=lld \
    -DLLVM_TARGETS_TO_BUILD=LoongArch \
    -DLLVM_ENABLE_PROJECTS="clang;flang" \
    -DLLVM_ENABLE_RUNTIMES="flang-rt;openmp" \
    "$LLVM_SOURCE_DIR/llvm"

echo
echo "===== BUILD LLVM ====="
cmake --build "$LLVM_BUILD_DIR" --parallel "$BUILD_JOBS"

echo
echo "===== VERIFY LLVM ====="
CLANG="$LLVM_BUILD_DIR/bin/clang"
CLANGXX="$LLVM_BUILD_DIR/bin/clang++"

if [ ! -x "$CLANG" ]; then
    echo "ERROR: clang was not built: $CLANG"
    exit 1
fi
if [ ! -x "$CLANGXX" ]; then
    echo "ERROR: clang++ was not built: $CLANGXX"
    exit 1
fi

echo
echo "===== CLANG VERSION ====="
"$CLANG" --version
echo
echo "===== CLANG++ VERSION ====="
"$CLANGXX" --version

echo
echo "========================================"
echo "LLVM BUILD SUCCESS"
echo "========================================"