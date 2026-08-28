#!/usr/bin/env bash
set -euo pipefail

# Local CI orchestrator for SPEC CPU 2017/2006 benchmark runs.
# Replaces GitHub Actions orchestration: subcommands + --config filter +
# a global flock so two runs (each using all cores) never overlap.

# cron has a minimal PATH (/usr/bin:/bin) that lacks the build tools in
# /usr/local/bin (cmake/ninja/clang). Prepend idempotently.
case ":$PATH:" in
  *:/usr/local/bin:*) ;;
  *) export PATH="/usr/local/bin:$PATH" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOCK_FILE="$PROJECT_DIR/.ci.lock"
LOCK_INFO="$PROJECT_DIR/.ci.lock.info"
LOG_DIR="$PROJECT_DIR/logs"

usage() {
  cat <<'USAGE'
Usage: ci.sh <command> [options]

Commands:
  full           Full chain: setup-env -> build -> spec2017 -> spec2006 -> report
  build          Build LLVM only
  spec2017       Run SPEC CPU 2017 only
  spec2006       Run SPEC CPU 2006 only
  report         Generate report only
  status         Show current run state (lock/PID/command/start) -- read-only
  list-configs   List available configs under cfg/ -- read-only
  help           Show this help

Options:
  --config NAME  Only run configs whose name contains NAME
                 (applies to spec2017/spec2006/full)

Exit codes:
  0  success
  1  step failed / no matching config / usage error / lock busy
USAGE
}

list_configs() {
  shopt -s nullglob
  local files=( "$PROJECT_DIR"/cfg/*.cfg )
  shopt -u nullglob
  if [ ${#files[@]} -eq 0 ]; then
    echo "[WARN] No config files found in $PROJECT_DIR/cfg/"
    return 0
  fi
  echo "Available configs in $PROJECT_DIR/cfg/:"
  local f
  for f in "${files[@]}"; do
    echo "  $(basename "$f")"
  done
}

show_status() {
  if [ -f "$LOCK_INFO" ]; then
    echo "A run is in progress:"
    cat "$LOCK_INFO"
  else
    echo "Idle (no run in progress)."
  fi
}

# ---------- argument parsing ----------
COMMAND="${1:-}"
if [ -z "$COMMAND" ]; then
  usage
  exit 1
fi

case "$COMMAND" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

shift  # drop the command word; remaining args are options

CFG_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      if [ $# -lt 2 ]; then
        echo "[ERROR] --config requires a value" >&2
        usage
        exit 1
      fi
      CFG_FILTER="$2"
      shift 2
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# ---------- read-only commands (no lock, no log) ----------
case "$COMMAND" in
  list-configs)
    list_configs
    exit 0
    ;;
  status)
    show_status
    exit 0
    ;;
esac

# ---------- validate run command ----------
case "$COMMAND" in
  full|build|spec2017|spec2006|report) ;;
  *)
    echo "[ERROR] Unknown command: $COMMAND" >&2
    usage
    exit 1
    ;;
esac

# ---------- acquire global lock (non-blocking) ----------
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "[ERROR] Another run is already in progress; refusing to start." >&2
  if [ -f "$LOCK_INFO" ]; then
    echo "Current holder:" >&2
    cat "$LOCK_INFO" >&2
  fi
  exit 1
fi

{
  echo "pid=$$"
  echo "command=$COMMAND"
  echo "config=${CFG_FILTER:-none}"
  echo "started=$(date '+%Y-%m-%dT%H:%M:%S%z')"
} > "$LOCK_INFO"
trap 'rm -f "$LOCK_INFO"' EXIT

# ---------- per-run logging ----------
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_LOG_DIR="$LOG_DIR/$RUN_STAMP-$COMMAND"
mkdir -p "$RUN_LOG_DIR"
RUN_LOG="$RUN_LOG_DIR/run.log"
exec > >(tee "$RUN_LOG") 2>&1

echo "=== ci.sh $COMMAND ==="
echo "Started: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "Config filter: ${CFG_FILTER:-<all>}"
echo "Log: $RUN_LOG"
echo ""

# ---------- step runners ----------
run_setup_env() { "$SCRIPT_DIR/setup-env.sh"; }
run_build()     { "$SCRIPT_DIR/build-llvm.sh"; }
run_spec2017()  { CFG_FILTER="$CFG_FILTER" "$SCRIPT_DIR/run-spec2017.sh"; }
run_spec2006()  { CFG_FILTER="$CFG_FILTER" "$SCRIPT_DIR/run-spec2006.sh"; }
run_report()    { "$SCRIPT_DIR/generate-report.sh"; }

# ---------- dispatch ----------
OVERALL=0
case "$COMMAND" in
  full)
    echo "--- [1/5] setup-env ---"
    run_setup_env || exit 1
    echo "--- [2/5] build ---"
    run_build || exit 1
    echo "--- [3/5] spec2017 ---"
    run_spec2017 || OVERALL=1
    echo "--- [4/5] spec2006 ---"
    run_spec2006 || OVERALL=1
    echo "--- [5/5] report ---"
    run_report || OVERALL=1
    ;;
  build)    run_build ;;
  spec2017) run_spec2017 ;;
  spec2006) run_spec2006 ;;
  report)   run_report ;;
esac

if [ "$OVERALL" -ne 0 ]; then
  echo "[WARN] ci.sh $COMMAND finished with one or more step failures."
else
  echo "[OK] ci.sh $COMMAND complete."
fi
exit "$OVERALL"
