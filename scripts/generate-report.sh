#!/usr/bin/env bash
set -euo pipefail

# Generate summary HTML report from SPEC results

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/results/latest"
BUILD_INFO="$PROJECT_DIR/build-info"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$OUTPUT_DIR"

# Read build info
if [ -f "$BUILD_INFO/info.json" ]; then
  LLVM_COMMIT=$(jq -r '.commit' "$BUILD_INFO/info.json")
  LLVM_SHORT=$(jq -r '.short_commit' "$BUILD_INFO/info.json")
  LLVM_DATE=$(jq -r '.date' "$BUILD_INFO/info.json")
  CLANG_VER=$(jq -r '.clang_version' "$BUILD_INFO/info.json")
  FLANG_VER=$(jq -r '.flang_version' "$BUILD_INFO/info.json")
else
  LLVM_COMMIT="N/A"
  LLVM_SHORT="N/A"
  LLVM_DATE="N/A"
  CLANG_VER="N/A"
  FLANG_VER="N/A"
fi

# Extract scores from SPEC HTML results
extract_spec_rate() {
  local result_dir="$1"
  local index_html="$result_dir/index.html"

  if [ ! -f "$index_html" ]; then
    echo "N/A"
    return
  fi

  # Try to extract SPECrate value from the summary table
  # SPEC HTML reports have a summary section with rate values
  local rate_val
  rate_val=$(grep -oP 'SPECrate\d+[^<]*\K[\d.]+' "$index_html" 2>/dev/null | head -1 || echo "N/A")
  echo "${rate_val:-N/A}"
}

# Find latest result directories
SPEC2017_RESULT=$(find "$PROJECT_DIR/results/spec2017" -maxdepth 2 -name "index.html" 2>/dev/null | head -1 || echo "")
SPEC2006_RESULT=$(find "$PROJECT_DIR/results/spec2006" -maxdepth 2 -name "index.html" 2>/dev/null | head -1 || echo "")

SPEC2017_DIR=""
SPEC2006_DIR=""
SPEC2017_RATE="N/A"
SPEC2006_RATE="N/A"
SPEC2017_LINK=""
SPEC2006_LINK=""

if [ -n "$SPEC2017_RESULT" ]; then
  SPEC2017_DIR=$(dirname "$SPEC2017_RESULT")
  SPEC2017_RATE=$(extract_spec_rate "$SPEC2017_DIR")
  CFG_NAME=$(basename "$(dirname "$SPEC2017_DIR")")
  SPEC2017_LINK="spec2017-detail/$CFG_NAME/index.html"
fi

if [ -n "$SPEC2006_RESULT" ]; then
  SPEC2006_DIR=$(dirname "$SPEC2006_RESULT")
  SPEC2006_RATE=$(extract_spec_rate "$SPEC2006_DIR")
  CFG_NAME=$(basename "$(dirname "$SPEC2006_DIR")")
  SPEC2006_LINK="spec2006-detail/$CFG_NAME/index.html"
fi

# Get hardware info
CPU_MODEL=$(lscpu 2>/dev/null | grep "Model name" | cut -d: -f2 | xargs || echo "N/A")
CPU_CORES=$(nproc || echo "N/A")
MEMORY_TOTAL=$(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo "N/A")

# Generate HTML report
cat > "$OUTPUT_DIR/index.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SPEC CPU Benchmark Report - ${TIMESTAMP}</title>
  <style>
    body { font-family: monospace; margin: 40px; background: #1e1e1e; color: #d4d4d4; }
    h1 { color: #569cd6; border-bottom: 1px solid #3c3c3c; padding-bottom: 10px; }
    h2 { color: #4ec9b0; margin-top: 30px; }
    table { border-collapse: collapse; width: 100%; margin: 15px 0; }
    th, td { border: 1px solid #3c3c3c; padding: 8px 12px; text-align: left; }
    th { background: #2d2d30; color: #569cd6; }
    tr:nth-child(even) { background: #252526; }
    .score { font-size: 1.2em; font-weight: bold; color: #4ec9b0; }
    .meta { color: #808080; }
    .section { background: #252526; padding: 15px; border-radius: 5px; margin: 15px 0; }
    a { color: #569cd6; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .status-ok { color: #4ec9b0; }
    .status-fail { color: #f44747; }
    .footer { margin-top: 40px; padding-top: 15px; border-top: 1px solid #3c3c3c; font-size: 0.9em; }
  </style>
</head>
<body>
  <h1>SPEC CPU Benchmark Report</h1>
  <p class="meta">Generated: ${TIMESTAMP}</p>

  <div class="section">
    <h2>Build Information</h2>
    <table>
      <tr><th>LLVM Commit</th><td><a href="https://github.com/llvm/llvm-project/commit/${LLVM_COMMIT}">${LLVM_SHORT}</a></td></tr>
      <tr><th>Commit Date</th><td>${LLVM_DATE}</td></tr>
      <tr><th>Clang Version</th><td>${CLANG_VER}</td></tr>
      <tr><th>Flang Version</th><td>${FLANG_VER}</td></tr>
      <tr><th>Build Type</th><td>Release (LoongArch)</td></tr>
    </table>
  </div>

  <div class="section">
    <h2>Hardware</h2>
    <table>
      <tr><th>CPU</th><td>${CPU_MODEL}</td></tr>
      <tr><th>Cores</th><td>${CPU_CORES}</td></tr>
      <tr><th>Memory</th><td>${MEMORY_TOTAL}</td></tr>
      <tr><th>Architecture</th><td>LoongArch (loongarch64)</td></tr>
    </table>
  </div>

  <div class="section">
    <h2>SPEC CPU 2017 Results</h2>
    <table>
      <tr><th>Metric</th><th>Value</th></tr>
      <tr><td>SPECrate2017_int</td><td class="score">$(grep -oP 'SPECrate2017_int[^<]*\K[\d.]+' "$SPEC2017_RESULT" 2>/dev/null || echo "N/A")</td></tr>
      <tr><td>SPECrate2017_fp</td><td class="score">$(grep -oP 'SPECrate2017_fp[^<]*\K[\d.]+' "$SPEC2017_RESULT" 2>/dev/null || echo "N/A")</td></tr>
      <tr><td>SPECspeed2017_int</td><td class="score">$(grep -oP 'SPECspeed2017_int[^<]*\K[\d.]+' "$SPEC2017_RESULT" 2>/dev/null || echo "N/A")</td></tr>
      <tr><td>SPECspeed2017_fp</td><td class="score">$(grep -oP 'SPECspeed2017_fp[^<]*\K[\d.]+' "$SPEC2017_RESULT" 2>/dev/null || echo "N/A")</td></tr>
    </table>
    ${SPEC2017_LINK:+<p><a href="$SPEC2017_LINK">View full SPEC 2017 HTML report</a></p>}
  </div>

  <div class="section">
    <h2>SPEC CPU 2006 Results</h2>
    <table>
      <tr><th>Metric</th><th>Value</th></tr>
      <tr><td>SPECint_rate2006</td><td class="score">$(grep -oP 'SPECint_rate2006[^<]*\K[\d.]+' "$SPEC2006_RESULT" 2>/dev/null || echo "N/A")</td></tr>
      <tr><td>SPECfp_rate2006</td><td class="score">$(grep -oP 'SPECfp_rate2006[^<]*\K[\d.]+' "$SPEC2006_RESULT" 2>/dev/null || echo "N/A")</td></tr>
      <tr><td>SPECint_speed2006</td><td class="score">$(grep -oP 'SPECint_speed2006[^<]*\K[\d.]+' "$SPEC2006_RESULT" 2>/dev/null || echo "N/A")</td></tr>
      <tr><td>SPECfp_speed2006</td><td class="score">$(grep -oP 'SPECfp_speed2006[^<]*\K[\d.]+' "$SPEC2006_RESULT" 2>/dev/null || echo "N/A")</td></tr>
    </table>
    ${SPEC2006_LINK:+<p><a href="$SPEC2006_LINK">View full SPEC 2006 HTML report</a></p>}
  </div>

  <div class="footer">
    <p class="meta">Report generated by llvm-spec-ci | LLVM main branch automated benchmark</p>
  </div>
</body>
</html>
HTMLEOF

echo "[OK] Summary report generated at $OUTPUT_DIR/index.html"

# Copy SPEC detailed reports as subdirectories if available.
# Results are namespaced per config, so copy each into its own subdirectory.
if [ -n "$SPEC2017_DIR" ] && [ -d "$SPEC2017_DIR" ]; then
  CFG_NAME=$(basename "$(dirname "$SPEC2017_DIR")")
  mkdir -p "$OUTPUT_DIR/spec2017-detail/$CFG_NAME"
  cp -r "$SPEC2017_DIR" "$OUTPUT_DIR/spec2017-detail/$CFG_NAME/" 2>/dev/null || true
fi
if [ -n "$SPEC2006_DIR" ] && [ -d "$SPEC2006_DIR" ]; then
  CFG_NAME=$(basename "$(dirname "$SPEC2006_DIR")")
  mkdir -p "$OUTPUT_DIR/spec2006-detail/$CFG_NAME"
  cp -r "$SPEC2006_DIR" "$OUTPUT_DIR/spec2006-detail/$CFG_NAME/" 2>/dev/null || true
fi

# Append scores to history.json for online comparison
HISTORY_FILE="$OUTPUT_DIR/history.json"
TODAY=$(date +%Y-%m-%d)

# Extract score value from SPEC result html by pattern
get_score() {
  local html_file="$1"
  local pattern="$2"
  if [ -f "$html_file" ]; then
    grep -oP "${pattern}[^<]*\K[\d.]+" "$html_file" 2>/dev/null | head -1 || echo "null"
  else
    echo "null"
  fi
}

# Build scores object (null if not available, allowing missing benchmarks)
SCORES_2017=""
if [ -n "$SPEC2017_RESULT" ] && [ -f "$SPEC2017_RESULT" ]; then
  S_IR=$(get_score "$SPEC2017_RESULT" 'SPECrate2017_int')
  S_FR=$(get_score "$SPEC2017_RESULT" 'SPECrate2017_fp')
  S_IS=$(get_score "$SPEC2017_RESULT" 'SPECspeed2017_int')
  S_FS=$(get_score "$SPEC2017_RESULT" 'SPECspeed2017_fp')
  SCORES_2017="\"SPECrate2017_int\": $S_IR, \"SPECrate2017_fp\": $S_FR, \"SPECspeed2017_int\": $S_IS, \"SPECspeed2017_fp\": $S_FS"
fi

SCORES_2006=""
if [ -n "$SPEC2006_RESULT" ] && [ -f "$SPEC2006_RESULT" ]; then
  S_IR=$(get_score "$SPEC2006_RESULT" 'SPECint_rate2006')
  S_FR=$(get_score "$SPEC2006_RESULT" 'SPECfp_rate2006')
  S_IS=$(get_score "$SPEC2006_RESULT" 'SPECint_speed2006')
  S_FS=$(get_score "$SPEC2006_RESULT" 'SPECfp_speed2006')
  SCORES_2006="\"SPECint_rate2006\": $S_IR, \"SPECfp_rate2006\": $S_FR, \"SPECint_speed2006\": $S_IS, \"SPECfp_speed2006\": $S_FS"
fi

# Combine scores
ALL_SCORES=""
if [ -n "$SCORES_2017" ] && [ -n "$SCORES_2006" ]; then
  ALL_SCORES="$SCORES_2017, $SCORES_2006"
elif [ -n "$SCORES_2017" ]; then
  ALL_SCORES="$SCORES_2017"
elif [ -n "$SCORES_2006" ]; then
  ALL_SCORES="$SCORES_2006"
fi

# Config name (if available)
CFG_NAME_VAL="null"
if [ -n "$SPEC2017_DIR" ]; then
  CFG_NAME_VAL="\"$(basename "$(dirname "$SPEC2017_DIR")")\""
elif [ -n "$SPEC2006_DIR" ]; then
  CFG_NAME_VAL="\"$(basename "$(dirname "$SPEC2006_DIR")")\""
fi

# Build the new history entry
NEW_ENTRY=$(cat <<ENTRY
{
  "date": "$TODAY",
  "datetime": "$TIMESTAMP",
  "llvm_commit": "${LLVM_COMMIT:-null}",
  "llvm_short": "${LLVM_SHORT:-null}",
  "clang_version": "${CLANG_VER:-null}",
  "flang_version": "${FLANG_VER:-null}",
  "config": $CFG_NAME_VAL,
  "scores": { $ALL_SCORES }
}
ENTRY
)

# Initialize history file if it doesn't exist
if [ ! -f "$HISTORY_FILE" ]; then
  echo "[]" > "$HISTORY_FILE"
fi

# Append entry: read existing, remove trailing ], add comma + new entry, close ]
TMP_FILE=$(mktemp)
jq ". + [$NEW_ENTRY]" "$HISTORY_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$HISTORY_FILE"

echo "[OK] Score history updated at $HISTORY_FILE"