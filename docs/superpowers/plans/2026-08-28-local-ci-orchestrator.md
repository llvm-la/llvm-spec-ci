# Local CI Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace GitHub Actions orchestration of the SPEC CPU 2017/2006 benchmark CI with a local `ci.sh` orchestrator that supports on-demand/partial/config-filtered runs, a concurrency lock, cron scheduling, and a local web report server.

**Architecture:** A single bash entry script (`scripts/ci.sh`) dispatches to the existing step scripts under a global `flock` so two runs (each using all cores) never overlap. cron triggers the periodic full run; a systemd unit serves `results/latest/` over HTTP. The existing 5 step scripts are reused with minimal additions (a `CFG_FILTER` env var on the two SPEC run scripts; a `compare.html` copy in report generation).

**Tech Stack:** bash, `flock`, cron, systemd, `python3 -m http.server`.

## Global Constraints

- All bash scripts use `set -euo pipefail` (existing convention; `ci.sh` must too).
- Bash-only orchestration — do **not** introduce a new language or framework.
- Result layout is unchanged: `results/spec{2017,2006}/<cfg>/` and `results/latest/`.
- Build tools (`cmake`/`ninja`/`clang`/`clang++`/`python3`) live in `/usr/local/bin`; cron's default PATH is only `/usr/bin:/bin`. `ci.sh` must prepend `/usr/local/bin` to PATH idempotently.
- One **global** lock: `build` and both SPEC suites each use all cores, so no two run-commands may overlap (even `spec2017` vs `spec2006`).
- The two SPEC run scripts must keep working **without** `CFG_FILTER` set (backward compatible: run all matching configs).
- Web server: port `8080`, `--bind 0.0.0.0`, interpreter `/usr/local/bin/python3`, serving `results/latest/`.
- Work happens on the `main` branch of this repo (the user commits to main directly). A worktree is optional, not required.

---

### Task 1: Add `CFG_FILTER` to the SPEC 2017/2006 run scripts

**Files:**
- Modify: `scripts/run-spec2017.sh` (after line 11, and after line 33)
- Modify: `scripts/run-spec2006.sh` (after line 11, and after line 33)

**Interfaces:**
- Consumes: existing `cfg/*2017*.cfg` / `cfg/*2006*.cfg` files.
- Produces: both run scripts honor an optional `CFG_FILTER` env var — substring match against each cfg's basename (without `.cfg`); empty/unset `CFG_FILTER` = run all (current behavior). A non-matching filter yields the existing "No config files matching …" error and exit 1.

- [ ] **Step 1: Add `CFG_FILTER` read to `run-spec2017.sh`**

In `scripts/run-spec2017.sh`, immediately after the line `CFG_DIR="$PROJECT_DIR/cfg"` (line 11), add:

```bash
CFG_FILTER="${CFG_FILTER:-}"
```

- [ ] **Step 2: Add the filter block to `run-spec2017.sh`**

In `scripts/run-spec2017.sh`, after the line `shopt -u nullglob` (line 33) and before the `if [ ${#CFG_FILES[@]} -eq 0 ]` check (line 35), insert:

```bash

# Optional substring filter on config names (set via CFG_FILTER by ci.sh).
if [ -n "$CFG_FILTER" ] && [ ${#CFG_FILES[@]} -gt 0 ]; then
  FILTERED=()
  for f in "${CFG_FILES[@]}"; do
    base=$(basename "$f" .cfg)
    if [[ "$base" == *"$CFG_FILTER"* ]]; then FILTERED+=( "$f" ); fi
  done
  CFG_FILES=( ${FILTERED[@]+"${FILTERED[@]}"} )   # safe under set -u when empty
fi
```

- [ ] **Step 3: Mirror both edits in `run-spec2006.sh`**

In `scripts/run-spec2006.sh`, immediately after the line `CFG_DIR="$PROJECT_DIR/cfg"` (line 11), add:

```bash
CFG_FILTER="${CFG_FILTER:-}"
```

Then, after the line `shopt -u nullglob` (line 33) and before the `if [ ${#CFG_FILES[@]} -eq 0 ]` check (line 35), insert this identical filter block:

```bash

# Optional substring filter on config names (set via CFG_FILTER by ci.sh).
if [ -n "$CFG_FILTER" ] && [ ${#CFG_FILES[@]} -gt 0 ]; then
  FILTERED=()
  for f in "${CFG_FILES[@]}"; do
    base=$(basename "$f" .cfg)
    if [[ "$base" == *"$CFG_FILTER"* ]]; then FILTERED+=( "$f" ); fi
  done
  CFG_FILES=( ${FILTERED[@]+"${FILTERED[@]}"} )   # safe under set -u when empty
fi
```

(The glob in this file is `*2006*.cfg`; the filter block is the same as Step 2.)

- [ ] **Step 4: Syntax-check both scripts**

Run: `bash -n scripts/run-spec2017.sh && bash -n scripts/run-spec2006.sh && echo OK`
Expected: `OK` (no syntax errors).

- [ ] **Step 5: Verify the no-match path errors (real script, no SPEC run)**

Run:
```bash
CFG_FILTER="__nomatch__" bash scripts/run-spec2017.sh; echo "exit=$?"
```
Expected: prints `[ERROR] No config files matching .../cfg/*2017*.cfg found` and `exit=1`.
(The script fails at the empty-array check **before** `cd`/`source shrc`/`runcpu`, so nothing expensive runs. Run the same for `run-spec2006.sh` and expect the `*2006*.cfg` variant.)

- [ ] **Step 6: Verify the match path selects the right config (logic test)**

The match path proceeds to run SPEC after selection (not runnable here), so verify the identical filter logic in isolation:
```bash
bash -c '
set -euo pipefail
CFG_DIR="/home/user/code/llvm-spec-ci/cfg"
CFG_FILTER="clang"
shopt -s nullglob
CFG_FILES=( "$CFG_DIR"/*2017*.cfg )
shopt -u nullglob
if [ -n "$CFG_FILTER" ] && [ ${#CFG_FILES[@]} -gt 0 ]; then
  FILTERED=()
  for f in "${CFG_FILES[@]}"; do
    base=$(basename "$f" .cfg)
    if [[ "$base" == *"$CFG_FILTER"* ]]; then FILTERED+=( "$f" ); fi
  done
  CFG_FILES=( ${FILTERED[@]+"${FILTERED[@]}"} )
fi
echo "Selected ${#CFG_FILES[@]}: $(IFS=', '; echo "${CFG_FILES[*]}")"
'
```
Expected: `Selected 1: .../cfg/clang-2017.cfg`. Also confirm the unfiltered default still sees the config by running the same with `CFG_FILTER=""` (expect the same single config, proving backward compatibility).

- [ ] **Step 7: Commit**

```bash
git add scripts/run-spec2017.sh scripts/run-spec2006.sh
git commit -m "Add optional CFG_FILTER to SPEC 2017/2006 run scripts"
```

---

### Task 2: Copy `compare.html` into `results/latest/` during report generation

**Files:**
- Modify: `scripts/generate-report.sh` (insert between the 2006 detail-copy block and the history section)

**Interfaces:**
- Consumes: tracked `results/compare.html`; the existing report output dir `$OUTPUT_DIR` (`results/latest`).
- Produces: after `generate-report.sh` runs, `results/latest/compare.html` exists alongside `index.html` and `history.json`, so the page's relative `fetch('history.json')` resolves.

- [ ] **Step 1: Insert the compare.html copy**

In `scripts/generate-report.sh`, locate the end of the SPEC 2006 detail-copy block:

```bash
if [ -n "$SPEC2006_DIR" ] && [ -d "$SPEC2006_DIR" ]; then
  CFG_NAME=$(basename "$(dirname "$SPEC2006_DIR")")
  mkdir -p "$OUTPUT_DIR/spec2006-detail/$CFG_NAME"
  cp -r "$SPEC2006_DIR" "$OUTPUT_DIR/spec2006-detail/$CFG_NAME/" 2>/dev/null || true
fi
```

Immediately after that closing `fi` (and before the `# Append scores to history.json for online comparison` comment), insert:

```bash

# Copy the static comparison page into the publish dir so it sits next to
# history.json (fixes the relative fetch('history.json') path mismatch).
COMPARE_SRC="$PROJECT_DIR/results/compare.html"
if [ -f "$COMPARE_SRC" ]; then
  cp "$COMPARE_SRC" "$OUTPUT_DIR/compare.html"
fi
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n scripts/generate-report.sh && echo OK`
Expected: `OK`.

- [ ] **Step 3: Run report generation and confirm compare.html is copied**

Run: `bash scripts/generate-report.sh`
(Note: with no SPEC results present this still succeeds, emitting N/A scores and appending one entry to `results/latest/history.json` — expected on this dev machine.)
Then verify: `ls -l results/latest/compare.html`
Expected: the file exists (a copy of `results/compare.html`). Also confirm `results/latest/index.html` and `results/latest/history.json` exist.

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-report.sh
git commit -m "Copy compare.html into results/latest in report generation"
```

---

### Task 3: Add the `ci.sh` local orchestrator (+ `.gitignore`)

**Files:**
- Create: `scripts/ci.sh`
- Modify: `.gitignore` (append)

**Interfaces:**
- Consumes: `scripts/setup-env.sh`, `scripts/build-llvm.sh`, `scripts/run-spec2017.sh`, `scripts/run-spec2006.sh` (all honor `CFG_FILTER` from Task 1), `scripts/generate-report.sh` (copies compare.html from Task 2).
- Produces: `ci.sh <command> [--config NAME]` with commands `full|build|spec2017|spec2006|report|status|list-configs|help`; exit 0 on success, exit 1 on step failure / no matching config / usage error / lock busy. Creates `.ci.lock`, `.ci.lock.info` (while running), and `logs/<timestamp>-<command>/run.log`.

- [ ] **Step 1: Create `scripts/ci.sh`**

Write the full file:

```bash
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
```

- [ ] **Step 2: Make it executable and syntax-check**

Run: `chmod +x scripts/ci.sh && bash -n scripts/ci.sh && echo OK`
Expected: `OK`.

- [ ] **Step 3: Append `.gitignore` entries**

Append to `.gitignore`:

```
# Local CI
logs/
.ci.lock
.ci.lock.info
```

- [ ] **Step 4: Verify read-only commands and arg parsing**

Run each and check output:
```bash
./scripts/ci.sh list-configs            # expect: lists clang-2017.cfg, clang-2006.cfg
./scripts/ci.sh status                   # expect: "Idle (no run in progress)."
./scripts/ci.sh help >/dev/null; echo "help exit=$?"          # expect: exit=0
./scripts/ci.sh 2>/dev/null; echo "noarg exit=$?"             # expect: exit=1
./scripts/ci.sh bogus 2>/dev/null; echo "bogus exit=$?"       # expect: exit=1
./scripts/ci.sh --config x full 2>/dev/null; echo "optfirst exit=$?"  # expect: exit=1 (option before command rejected)
./scripts/ci.sh full --config 2>/dev/null; echo "noval exit=$?"       # expect: exit=1 (--config missing value)
```

- [ ] **Step 5: Verify the lock refuses a concurrent run**

Hold the lock in the background, then attempt a run command:
```bash
# Hold the lock for 5s in the background.
( exec 200>/home/user/code/llvm-spec-ci/.ci.lock; flock -x 200; sleep 5 ) &
HOLDER=$!
sleep 0.5
./scripts/ci.sh report 2>&1 | head -3; echo "locked exit=${PIPESTATUS[0]}"
wait "$HOLDER"
# After release, a run command should be allowed to proceed (report is cheap).
./scripts/ci.sh report >/dev/null 2>&1; echo "after-release exit=$?"
```
Expected: during the hold, `locked exit=1` and the output includes `Another run is already in progress`. After release, `after-release exit=0`.
(Also confirm the lock info is cleaned up: `ls .ci.lock.info 2>/dev/null || echo "cleaned"` → expect `cleaned`.)

- [ ] **Step 6: Verify the PATH fix works under a cron-like minimal environment**

Run:
```bash
env -i PATH=/usr/bin:/bin bash -c '
  case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH";; esac
  for t in cmake ninja clang clang++; do command -v "$t" >/dev/null || echo "MISSING $t"; done
  echo OK
'
```
Expected: `OK` with **no** `MISSING` lines.

- [ ] **Step 7: Verify `ci.sh report` runs and tees a log**

Run: `./scripts/ci.sh report`
Expected: exit 0; a new `logs/<timestamp>-report/run.log` is created and non-empty; `results/latest/compare.html` is (re)present (Task 2).
(Confirm: `ls -dt logs/*-report | head -1` shows the newest report log dir.)

- [ ] **Step 8: Verify `--config` no-match propagates through `ci.sh`**

Run: `./scripts/ci.sh spec2017 --config __nomatch__; echo "exit=$?"`
Expected: `exit=1` and the run log / output includes `No config files matching`.

- [ ] **Step 9: Commit**

```bash
git add scripts/ci.sh .gitignore
git commit -m "Add ci.sh local orchestrator with lock, logging, and config filter"
```

---

### Task 4: Add the systemd unit serving the report over HTTP

**Files:**
- Create: `systemd/spec-report-web.service`

**Interfaces:**
- Consumes: `results/latest/` (populated by Tasks 2/3: `index.html`, `compare.html`, `history.json`, detail dirs).
- Produces: a systemd unit that serves `results/latest/` at `http://<host>:8080/` using `/usr/local/bin/python3 -m http.server`.

- [ ] **Step 1: Create the unit file**

Write `systemd/spec-report-web.service`:

```ini
[Unit]
Description=SPEC CPU benchmark report web server
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/user/code/llvm-spec-ci
ExecStartPre=/usr/bin/mkdir -p results/latest
ExecStart=/usr/local/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory results/latest
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Validate the serving command (no root needed)**

Exercise the exact serving mechanism on a test port against a temp dir (avoids clashing with a live :8080):
```bash
cd /home/user/code/llvm-spec-ci
TESTDIR=$(mktemp -d)
echo "<html>idx</html>"  > "$TESTDIR/index.html"
echo "<html>cmp</html>"  > "$TESTDIR/compare.html"
echo "[]"                > "$TESTDIR/history.json"
( /usr/local/bin/python3 -m http.server 8099 --bind 127.0.0.1 --directory "$TESTDIR" >/dev/null 2>&1 & echo $! > /tmp/spec-web-test.pid )
sleep 1
for f in index.html compare.html history.json; do
  printf '%s -> ' "$f"; curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:8099/$f"
done
kill "$(cat /tmp/spec-web-test.pid)" 2>/dev/null || true
rm -rf "$TESTDIR" /tmp/spec-web-test.pid
```
Expected: three lines each ending in `200`.

- [ ] **Step 3: Best-effort unit syntax check**

Run: `systemd-analyze verify systemd/spec-report-web.service 2>&1 || echo "(systemd-analyze unavailable or flagged — review manually)"`
Expected: no errors if systemd is present; otherwise the fallback message (the unit is simple and reviewed by eye).

- [ ] **Step 4: Commit**

```bash
git add systemd/spec-report-web.service
git commit -m "Add systemd unit serving SPEC report over HTTP"
```

Note: installing/starting the unit requires root and is a deployment step (not done in this plan):
```
sudo cp systemd/spec-report-web.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now spec-report-web
```

---

### Task 5: Retire the GitHub Actions workflow and document the local CI

**Files:**
- Delete: `.github/workflows/spec-benchmark.yml`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the finished `ci.sh` (Task 3), systemd unit (Task 4), and all step scripts.
- Produces: no GitHub workflow; `CLAUDE.md` documents the local CI (commands, lock, cron, web server, logging).

- [ ] **Step 1: Delete the GitHub workflow**

Run: `git rm .github/workflows/spec-benchmark.yml`
(If `git rm` complains the file is missing, confirm with `ls .github/workflows/` and remove the directory if now empty: `rmdir .github/workflows 2>/dev/null || true`.)

- [ ] **Step 2: Replace the Workflow section in `CLAUDE.md`**

In `CLAUDE.md`, replace the entire `## Workflow (`.github/workflows/spec-benchmark.yml`)` section (from that heading through its last bullet, ending at the `- Trigger: cron ...` line) with:

```markdown
## Local CI (`scripts/ci.sh`)

Orchestration runs on the runner itself (no GitHub Actions). `scripts/ci.sh` is the
single entry point; it runs the existing step scripts under a global `flock` so two
runs (each using all cores) never overlap.

```bash
./scripts/ci.sh <command> [--config NAME]
```

Commands:
- `full` — setup-env → build → spec2017 → spec2006 → report
- `build` / `spec2017` / `spec2006` / `report` — run a single step
- `status` — show whether a run is in progress (read-only)
- `list-configs` — list available `cfg/*.cfg` (read-only)
- `help`

`--config NAME` runs only configs whose name contains NAME (substring match).

Behavior:
- A global lock (`.ci.lock`) is held for the duration of any run command; a second
  concurrent invocation is refused (exit 1), not queued or cancelled.
- `full` aborts if `setup-env` or `build` fails; a `spec2017`/`spec2006` failure is
  recorded but the remaining steps and `report` still run (partial results); the exit
  code reflects any step failure.
- Each run tees its output to `logs/<timestamp>-<command>/run.log`.
- `ci.sh` prepends `/usr/local/bin` to PATH (cron's default PATH lacks the build tools).

Scheduling (cron, replaces the old GitHub cron; edit the schedule as needed):
```
0 0 1,16 * * cd /home/user/code/llvm-spec-ci && mkdir -p logs && ./scripts/ci.sh full >> logs/cron.log 2>&1
```
Install via `crontab -e`. If a manual run is in progress when cron fires, the lock
makes cron skip safely.

Report web server (systemd; change the port in the unit if needed):
```
sudo cp systemd/spec-report-web.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now spec-report-web
```
Serves `results/latest/` at `http://<host>:8080/` (`index.html`, `compare.html`,
`history.json`, detail reports).
```

- [ ] **Step 3: Update the "Common Commands" section in `CLAUDE.md`**

Replace the `## Common Commands` code block with:

````markdown
```bash
# Check runner environment
./scripts/setup-env.sh

# Full local CI run (build + both SPEC suites + report)
./scripts/ci.sh full

# Single steps
./scripts/ci.sh build
./scripts/ci.sh spec2017 --config clang
./scripts/ci.sh report

# Inspect state / available configs
./scripts/ci.sh status
./scripts/ci.sh list-configs
```
````

- [ ] **Step 4: Remove GitHub-Actions-specific references elsewhere in `CLAUDE.md`**

In `CLAUDE.md`, remove or adjust bullets that only make sense with GitHub Actions:
- In `### Report Script` / `### Online Comparison`: keep (still accurate — `compare.html` + `history.json`), but if any line says "hosted on GitHub Pages", reword to "served by the local web server (see Local CI)".
- In `## Constraints`: the bullet referencing the workflow timing/artifacts, if present, should reflect the local cron + `logs/` instead. (Leave the repos-safety, single-runner, build-size, and architecture bullets unchanged.)

- [ ] **Step 5: Verify the workflow is gone and docs are consistent**

Run:
```bash
test ! -f .github/workflows/spec-benchmark.yml && echo "workflow removed"
grep -n "spec-benchmark.yml" CLAUDE.md || echo "no stale workflow refs in CLAUDE.md"
grep -n "ci.sh" CLAUDE.md | head
```
Expected: `workflow removed`; no (or only intentional) stale `spec-benchmark.yml` references; `ci.sh` appears in the new sections.

- [ ] **Step 6: Commit**

```bash
git add -A CLAUDE.md .github
git commit -m "Retire GitHub Actions workflow and document local CI in CLAUDE.md"
```

---

## Post-implementation (manual, not part of the automated tasks)

- Install the cron line (Task 5 documents it) via `crontab -e`.
- Install/enable the web server unit (root), then open `http://<host>:8080/`.
- First real end-to-end validation: `./scripts/ci.sh full` (24h+; run when the machine is free). Confirm `status` shows the running holder during it, and that a second `ci.sh` invocation is refused.

## Self-Review Notes

- Spec coverage: Task 1 = spec 6.4 (CFG_FILTER); Task 2 = spec 6.5 (compare copy); Task 3 = spec 6.1/6.2/6.3/6.8 (ci.sh + lock + full semantics + .gitignore); Task 4 = spec 6.6 (web service); Task 5 = spec 6.9/6.10 (docs + workflow retirement). cron (spec 6.7) is documented in Task 5's CLAUDE.md content. All 8 spec file changes are covered.
- No placeholders: every step carries concrete commands/code.
- Type/name consistency: `CFG_FILTER` used identically in Tasks 1 and 3; `results/latest/`, `.ci.lock`, `.ci.lock.info`, `logs/` named consistently; `ci.sh` subcommand set consistent between Task 3 code and Task 5 docs.
