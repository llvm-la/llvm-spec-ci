#!/bin/bash
# Generate a SPEC .cfg for each suite (cpu2006/cpu2017) present in spec-ci.yaml.
# Usage: generate-spec-cfg.sh <spec-ci.yaml> <llvm-dir> <output-dir>
set -euo pipefail

YAML="${1:?spec-ci.yaml path required}"
LLVM_DIR="${2:?llvm build directory required}"
OUT_DIR="${3:?output directory required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="$HERE/../tools/generator.py"

mkdir -p "$OUT_DIR"

for spec in cpu2006 cpu2017; do
  if python3 - "$YAML" "$spec" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if sys.argv[2] in d else 1)
PY
  then
    python3 "$GENERATOR" --yaml "$YAML" --spec "$spec" \
      --llvm-dir "$LLVM_DIR" --output "$OUT_DIR/$spec.cfg"
    echo "generated $OUT_DIR/$spec.cfg"
  else
    echo "spec $spec not in $YAML, skipping"
  fi
done