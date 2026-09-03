#!/bin/bash
# Run SPEC benchmarks: build the runspec command from spec-ci.yaml.
# Usage: run-spec.sh <spec-ci.yaml> <cfg-dir> [spec...]
# If no specs given, runs all suites present in the YAML.
set -euo pipefail

YAML="${1:?spec-ci.yaml path required}"
CFG_DIR="${2:?cfg directory required}"
shift 2
SPECS=("$@")
if [ "${#SPECS[@]}" -eq 0 ]; then
  SPECS=(cpu2006 cpu2017)
fi

run_for_spec() {
  local spec="$1" cfg="$CFG_DIR/$1.cfg"
  local size iterations benchmarks
  read -r size iterations <<< "$(python3 - "$YAML" "$spec" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
blk = d.get(sys.argv[2]) or {}
run = blk.get("run") or {}
print(run.get("size", "ref"), run.get("iterations", 1))
PY
)"
  benchmarks="$(python3 - "$YAML" "$spec" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
blk = d.get(sys.argv[2]) or {}
for name, opts in (blk.get("benchmarks") or {}).items():
    if opts.get("enabled"):
        print(name)
PY
)"
  if [ -z "$benchmarks" ]; then
    echo "no enabled benchmarks for $spec, skipping"
    return 0
  fi
  # shellcheck disable=SC2086
  runspec --config "$cfg" --size "$size" --iterations "$iterations" \
    --tune base $benchmarks
}

for spec in "${SPECS[@]}"; do
  run_for_spec "$spec"
done