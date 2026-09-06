#!/usr/bin/env bash
# Package the SPEC build directory into a tarball.
# Usage: package-build.sh [build-dir] [output-dir]
#
#   build-dir:  directory to package (default: $SPEC_BUILD_DIR)
#   output-dir: where to write the tarball (default: $WORKSPACE or cwd)
#
# The archive name is spec-build-<timestamp>.tar.gz.
# Paths (SPEC_BUILD_DIR, ...) come from the repo-root .env.
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

BUILD_DIR="${1:-${SPEC_BUILD_DIR:-}}"
OUTPUT_DIR="${2:-${WORKSPACE:-$(pwd)}}"

if [ -z "$BUILD_DIR" ]; then
    echo "ERROR: build-dir not specified and SPEC_BUILD_DIR not set"
    exit 1
fi
if [ ! -d "$BUILD_DIR" ]; then
    echo "ERROR: build directory not found: $BUILD_DIR"
    exit 1
fi

BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
mkdir -p "$OUTPUT_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE="spec-build-${TIMESTAMP}.tar.gz"

echo "========================================"
echo "Packaging SPEC Build Artifacts"
echo "========================================"
echo "Source:  $BUILD_DIR"
echo "Output:  $OUTPUT_DIR/$ARCHIVE"
echo

# Create archive with the directory contents, using a stable internal path.
tar -czf "$OUTPUT_DIR/$ARCHIVE" -C "$(dirname "$BUILD_DIR")" "$(basename "$BUILD_DIR")"

SIZE="$(du -h "$OUTPUT_DIR/$ARCHIVE" | cut -f1)"
echo "Archive size: $SIZE"
echo
echo "========================================"
echo "Package: $OUTPUT_DIR/$ARCHIVE"
echo "========================================"
