#!/usr/bin/env bash
# Check out a Gerrit patchset on top of the base commit in the LLVM source tree.
# Usage: checkout-patch.sh <change> <patchset>
#
# Paths (LLVM_SOURCE_DIR, BASE_FILE, ...) come from the repo-root .env.
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

CHANGE="${1:?Missing Gerrit Change}"
PATCHSET="${2:?Missing Gerrit Patchset}"

if [[ ! -d "$LLVM_SOURCE_DIR/.git" ]]; then
    echo "ERROR: llvm-project not found at $LLVM_SOURCE_DIR"
    exit 1
fi
if [[ ! -f "$BASE_FILE" ]]; then
    echo "ERROR: Base Commit file not found: $BASE_FILE"
    exit 1
fi

BASE_COMMIT=$(cat "$BASE_FILE")

echo "======================================"
echo "Base Commit: $BASE_COMMIT"
echo "Gerrit Change: $CHANGE"
echo "Patchset: $PATCHSET"
echo "======================================"

cd "$LLVM_SOURCE_DIR"

echo
echo "===== CLEAN SOURCE ====="
git reset --hard
git clean -fdx

echo
echo "===== FETCH ORIGIN ====="
git fetch origin

echo
echo "===== CHECKOUT BASE ====="
git checkout --detach "$BASE_COMMIT"
git reset --hard "$BASE_COMMIT"

echo
echo "Current Base:"
git rev-parse HEAD

echo
echo "===== FETCH GERRIT PATCHSET ====="
SUFFIX=$(printf "%02d" $((CHANGE % 100)))
GERRIT_REF="refs/changes/$SUFFIX/$CHANGE/$PATCHSET"
echo "Gerrit Ref: $GERRIT_REF"
git fetch origin "$GERRIT_REF"

PATCH_COMMIT=$(git rev-parse FETCH_HEAD)

echo
echo "===== PATCH INFO ====="
git show --stat --oneline "$PATCH_COMMIT"

echo
echo "===== VALIDATE BASE ====="
if ! git merge-base --is-ancestor "$BASE_COMMIT" "$PATCH_COMMIT"; then
    echo "ERROR: Patchset is not based on Base Commit."
    exit 1
fi
echo "Patchset is based on Base Commit."

echo
echo "===== CHECKOUT PATCHSET ====="
git checkout --detach "$PATCH_COMMIT"

echo
echo "===== FINAL HEAD ====="
git log --oneline -5

echo
echo "===== GIT STATUS ====="
git status --short