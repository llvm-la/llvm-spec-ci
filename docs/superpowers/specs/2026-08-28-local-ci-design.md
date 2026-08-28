# 本地 CI 编排设计（去 GitHub Actions 化）

- 日期：2026-08-28
- 状态：已评审通过（待实现）
- 范围：将 SPEC CPU 2017/2006 基准测试的 CI 从 GitHub Actions 编排迁移到本机（LoongArch 自托管 runner 所在机器）本地编排。

## 1. 背景与动机

当前 CI 由 GitHub Actions 编排：cron（`0 0 1,16 * *`，每 15 天）触发，串行执行
`setup-env → build-llvm → run-spec2017 → run-spec2006 → generate-report`，结果作为
artifacts 归档（90 天）并部署到 GitHub Pages。

**关键事实**：所有重活（LLVM 编译 ~8h、SPEC 2017/2006 各 ~24h）本来就在自托管 runner 上跑，
即本机。GitHub Actions 在此仅承担**编排 + 托管**层：定时触发、任务链编排、并发控制、产物归档、
Pages 部署、运行日志/UI。

**迁移动机（用户确认）**：更灵活地控制运行——
1. 手动按需全量跑；
2. 分步/部分运行（只 build / 只某套 SPEC / 只出报告）；
3. 选特定 config 跑；
4. 保留定时 + 可叠加手动。

**报告查看方式（用户确认）**：本地 Web 服务（局域网可访问）。

## 2. 目标 / 非目标

**目标**
- 新增本地编排入口 `scripts/ci.sh`，支持上述四种灵活控制。
- 并发锁，防止 24h+ 的 SPEC 叠跑互扰。
- 本地 Web 服务长期查看/对比报告。
- 复用现有 5 个脚本，改动最小。

**非目标**
- 不改变 SPEC 编译/运行本身的行为（cfg、优化选项、数据集大小等不动）。
- 不引入新的编排框架/语言（保持全 bash）。
- 不做多机分布式、不做 Web 管理界面（只读静态报告）。
- 不改变结果目录布局（仍为 `results/spec{2017,2006}/<cfg>/` 与 `results/latest/`）。

## 3. 现状与已核实事实

| 事实 | 结论 |
|---|---|
| 报告"发布目录" | `results/latest/`（含 `index.html`、`history.json`、`spec2017-detail/`、`spec2006-detail/`） |
| `compare.html` 位置 | `results/compare.html`，**git 已跟踪**（force-add 过，fresh checkout 必在），但**不在** `results/latest/` |
| `compare.html` 数据加载 | 相对路径 `fetch('history.json')` → 与 `results/latest/history.json` **不同目录**，现有 Pages 只部署 `results/latest/`，故 compare 页实际未上线（潜在 bug） |
| Web 服务可用性 | 本机**无** nginx/caddy；`python3` = 3.12.5，支持 `http.server --directory` |
| 锁原语 | `flock` 可用（`/usr/bin/flock`） |
| 构建工具路径 | `cmake`/`ninja`/`clang`/`clang++`/`python3` 在 `/usr/local/bin`；`git`/`jq`/`nproc` 在 `/usr/bin`。**cron 默认 PATH 仅 `/usr/bin:/bin`**，找不到前者 |
| 结果归档 | `results/` 被 gitignore，结果仅存于本地磁盘 + GitHub artifacts + Pages |

## 4. 方案选择

**采用方案 A**：单个 bash 编排器 `ci.sh` + `flock` 全局锁 + cron 定时 + systemd 网页服务。
（备选 B=全 systemd services、C=Python 编排器，均因过重/多此一举被否决。）

**GitHub workflow 处置（用户选定 A1）**：**删除** `.github/workflows/spec-benchmark.yml`，
本地 `ci.sh` 成为唯一触发源。理由：自托管 runner 在本机，保留 workflow cron 会与本地 cron
双触发且不走同一把锁，导致叠跑。

## 5. 总体架构

```
 触发源                      编排层                            执行层（现有脚本，基本不动）
 ┌────────────┐          ┌─────────────────────────┐       ┌──────────────────────────────┐
 │ cron 定时   │────────▶ │                         │──────▶│ setup-env.sh                 │
 │ 手动 ci.sh │────────▶ │   scripts/ci.sh         │       │ build-llvm.sh                │
 └────────────┘          │  子命令 + --config 过滤  │       │ run-spec2017.sh (CFG_FILTER) │
                         │  ┌───────────────────┐  │       │ run-spec2006.sh (CFG_FILTER) │
                         │  │ flock 全局锁(占用即拒)│ │       │ generate-report.sh           │
                         │  └───────────────────┘  │       └──────────────────────────────┘
                         └─────────────────────────┘
                                    │ 输出
                                    ▼
   results/spec{2017,2006}/<cfg>/    results/latest/{index,compare}.html + history.json + detail/
                                    │
                                    ▼
   systemd: spec-report-web  →  python3 -m http.server 8080 --directory results/latest
```

数据流：
- `build` → `build-info/info.json` + `build-llvm/bin/`
- `spec2017/2006` → `results/spec{2017,2006}/<cfg>/`（SPEC 原始 HTML 报告）
- `report` → `results/latest/`：`index.html`（汇总）+ `history.json`（追加一条）+
  `compare.html`（**新增**拷贝）+ `spec2017-detail/`、`spec2006-detail/`
- 浏览器：`http://<机器IP>:8080/` 看汇总，`/compare.html` 对比（fetch 同目录 `history.json`）

## 6. 组件与文件清单

### 6.1 新增 `scripts/ci.sh`（唯一新增编排逻辑）

接口：
```
Usage: ci.sh <command> [options]

Commands:
  full           完整链: setup-env -> build -> spec2017 -> spec2006 -> report
  build          仅编译 LLVM
  spec2017       仅跑 SPEC CPU 2017
  spec2006       仅跑 SPEC CPU 2006
  report         仅生成报告
  status         显示当前 run 状态（锁/PID/命令/开始时间）——只读，不取锁
  list-configs   列出 cfg/ 下可用配置——只读，不取锁

Options:
  --config NAME  仅运行名字包含 NAME 的 cfg（作用于 spec2017/spec2006/full）
  -h, --help     显示帮助

Exit codes:
  0  成功
  1  步骤失败 / 无匹配 config / 用法错误 / 锁被占用
```

实现要点：
- **PATH 修正**（置于脚本顶部，幂等）：cron 的 PATH 缺 `/usr/local/bin`，需保证构建工具可达：
  ```bash
  case ":$PATH:" in
    *:/usr/local/bin:*) ;;
    *) export PATH="/usr/local/bin:$PATH" ;;
  esac
  ```
- **变量**：`SCRIPT_DIR`/`PROJECT_DIR` 解析方式与现有脚本一致；`LOCK_FILE="$PROJECT_DIR/.ci.lock"`、
  `LOCK_INFO="$PROJECT_DIR/.ci.lock.info"`、`LOG_DIR="$PROJECT_DIR/logs"`。
- **参数解析**：`argv[1]` 必须是子命令（选项不得置于子命令之前）；其余参数中解析 `--config NAME`
  （`--config` 后紧跟的一个词为 NAME）。未知子命令/缺子命令/`--config` 缺值 → 打印用法，退出 1。
- **只读命令**（`status`、`list-configs`、`help`）不取锁、不建日志目录，直接执行后退出。
- **run 类命令**（`full`/`build`/`spec2017`/`spec2006`/`report`）流程：
  1. 取锁：`exec 200>"$LOCK_FILE"`；`flock -n 200` 失败 → 读取 `LOCK_INFO`（若有）打印
     "已有 run 在跑 (PID …, 命令 …)，拒绝启动"，退出 1。
  2. 取锁成功 → 写 `LOCK_INFO`（格式见 6.2），`trap` 在退出时删除 `LOCK_INFO`。
  3. 建日志目录 `LOG_DIR/<时间戳>-<命令>/`，把后续输出 `tee` 到其中的 `run.log`。
  4. 按 6.3 执行步骤链。
  5. 退出码 = 步骤链结果（见 6.3）。

### 6.2 锁机制

- 锁文件：`$PROJECT_DIR/.ci.lock`（空文件，仅作为 flock 的目标）。
- 信息文件：`$PROJECT_DIR/.ci.lock.info`，取锁后写入，多行 `key=value`：
  ```
  pid=<ci.sh 的 PID>
  command=<full|build|spec2017|spec2006|report>
  config=<--config 的值或 none>
  started=<ISO8601 本地时间>
  ```
- 机制：`exec 200>"$LOCK_FILE"; flock -n 200 || { …拒绝…; exit 1; }`。锁随进程退出自动释放；
  `trap 'rm -f "$LOCK_INFO"' EXIT` 清理信息文件。
- **全局单锁**：所有 run 类子命令取同一把锁。理由：build 与 SPEC 都占满所有核，任意两个
  run 都不能并发（即便 `spec2017` 与 `spec2006` 也不行）。
- `status` 读取 `LOCK_INFO` 展示当前占用；文件不存在则显示"空闲"。

### 6.3 `full` 步骤链与错误处理

对齐现有 CI 的容错语义（`generate-report` 带 `if: always()`，出部分结果报告）：

| 步骤 | 失败行为 |
|---|---|
| `setup-env` | **中止**（无环境无法继续），退出 1 |
| `build` | **中止**（无编译器无法跑 SPEC），退出 1 |
| `spec2017` | 记录失败，**继续**跑 `spec2006` 与 `report`（尽量出另一套 + 部分结果） |
| `spec2006` | 记录失败，**继续**跑 `report` |
| `report` | **总是执行** |

最终退出码：全部成功=0；任一**被执行的**步骤（spec 或 report）失败=1（report 仍尽量生成）。
实现上用变量累计：`OVERALL=0`；`run spec2017 || OVERALL=1`；`run spec2006 || OVERALL=1`；
`run report || OVERALL=1`；最后 `exit $OVERALL`。`setup-env`/`build` 失败直接 `exit 1`（不再继续）。

单步子命令（如 `ci.sh spec2017`）失败即非零退出（各脚本已有 `set -euo pipefail`）。

### 6.4 `run-spec2017.sh` / `run-spec2006.sh` 增加 `CFG_FILTER`

- 在 `CFG_DIR` 定义后读取：`CFG_FILTER="${CFG_FILTER:-}"`。
- 在现有 `CFG_FILES=( "$CFG_DIR"/*2017*.cfg )`（2006 同理）之后、空数组检查之前，插入过滤：
  ```bash
  if [ -n "$CFG_FILTER" ] && [ ${#CFG_FILES[@]} -gt 0 ]; then
    FILTERED=()
    for f in "${CFG_FILES[@]}"; do
      base=$(basename "$f" .cfg)
      if [[ "$base" == *"$CFG_FILTER"* ]]; then FILTERED+=( "$f" ); fi
    done
    CFG_FILES=( ${FILTERED[@]+"${FILTERED[@]}"} )   # 兼容 set -u 下的空数组
  fi
  ```
  注：`[ ${#CFG_FILES[@]} -gt 0 ]` 守卫避免在 nullglob 产生空数组时对空数组做
  `"${CFG_FILES[@]}"` 展开（旧 bash 下 `set -u` 会报 unbound）。
- 子串匹配（`*"$CFG_FILTER"*`）。无匹配时 `CFG_FILES` 为空，现有
  `if [ ${#CFG_FILES[@]} -eq 0 ]` 分支报错退出（"No config files matching …"），语义自然。
- 向后兼容：`CFG_FILTER` 未设置时行为与现在完全一致（跑全部匹配 cfg）。
- `ci.sh` 通过 `CFG_FILTER=<name> ./scripts/run-spec20XX.sh` 传入（环境变量，不改脚本调用签名）。

### 6.5 `generate-report.sh` 拷贝 compare.html

- 在"拷贝 SPEC 明细报告"代码块之后、history 追加之前，新增：
  ```bash
  # 把静态对比页拷进发布目录，使其与 history.json 同目录（修掉相对 fetch 错位）
  COMPARE_SRC="$PROJECT_DIR/results/compare.html"
  if [ -f "$COMPARE_SRC" ]; then
    cp "$COMPARE_SRC" "$OUTPUT_DIR/compare.html"
  fi
  ```
- `$COMPARE_SRC` 是 git 跟踪文件，fresh checkout 必在，拷贝可靠。
- 效果：`results/latest/` 同时含 `index.html`、`compare.html`、`history.json`、detail 目录，
  Web 根目录内相对 `fetch('history.json')` 成立。

### 6.6 Web 服务（systemd）

新增 `systemd/spec-report-web.service`：
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
- 端口 8080（文档注明可改）；`--bind 0.0.0.0` 供局域网访问。
- `ExecStartPre` 确保 `results/latest/` 存在，首跑 report 前服务也能起（显示空目录列表）。
- `WorkingDirectory` 硬编码为本机项目路径（单机专用，可接受，文档注明）。
- `python3` 用绝对路径 `/usr/local/bin/python3`（已核实）。
- 安装（需 root，文档给出命令）：
  ```
  sudo cp systemd/spec-report-web.service /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now spec-report-web
  ```

### 6.7 定时（cron）

- 替代 GitHub cron，crontab 一行（周期可随意改）：
  ```
  0 0 1,16 * * cd /home/user/code/llvm-spec-ci && mkdir -p logs && ./scripts/ci.sh full >> logs/cron.log 2>&1
  ```
  （`mkdir -p logs` 必须前置：cron 的 `>> logs/cron.log` 重定向发生在 `ci.sh` 启动之前，
  目录不存在会导致整行失败。）
- 安装：用户 `crontab -e`（或 `/etc/cron.d/`）。
- 因 `ci.sh` 顶部已修正 PATH，cron 的最小环境不影响构建工具发现。
- 锁保证：cron 触发时若有手动 run 在跑，安全跳过（退出 1，记入 `logs/cron.log`）。

### 6.8 `.gitignore` 追加

```
# Local CI
logs/
.ci.lock
.ci.lock.info
```

### 6.9 `CLAUDE.md` 更新

- 将 "Workflow (`.github/workflows/spec-benchmark.yml`)" 章节替换为本地流程说明：
  `ci.sh` 子命令与选项、`--config` 过滤、锁行为、cron 定时、Web 服务（端口/安装）、
  日志位置（`logs/`）、结果与报告布局不变。
- "Common Commands" 增加 `ci.sh` 用法示例。
- 删除/调整与 GitHub Actions 专属相关的描述（artifacts、Pages、workflow 触发）。

### 6.10 退役 GitHub workflow

- 删除 `.github/workflows/spec-benchmark.yml`。

## 7. 文件变更清单（汇总）

| 操作 | 文件 | 说明 |
|---|---|---|
| 新增 | `scripts/ci.sh` | 编排入口（子命令/过滤/锁/日志/PATH） |
| 新增 | `systemd/spec-report-web.service` | 报告 Web 服务 unit |
| 修改 | `scripts/run-spec2017.sh` | 增加 `CFG_FILTER` 过滤 |
| 修改 | `scripts/run-spec2006.sh` | 增加 `CFG_FILTER` 过滤 |
| 修改 | `scripts/generate-report.sh` | 拷贝 `compare.html` 到 `results/latest/` |
| 修改 | `.gitignore` | 追加 `logs/`、`.ci.lock`、`.ci.lock.info` |
| 修改 | `CLAUDE.md` | 文档改为本地流程 |
| 删除 | `.github/workflows/spec-benchmark.yml` | 退役 GitHub 编排（A1） |

## 8. 测试与验证（不真跑 24h SPEC）

1. `bash -n` 语法检查所有改动/新增脚本。
2. `ci.sh list-configs`、`ci.sh status`（只读，秒级）：验证输出正确、空闲时 status 显示"空闲"。
3. `ci.sh report`：验证 `results/latest/` 生成 `index.html`、追加 `history.json`、
   **拷贝 `compare.html`**；随后起 Web 服务 `curl` 验证 `index.html`/`compare.html`/`history.json` 均可访问。
4. 锁：后台起一个 `ci.sh build`（或一个持锁的 sleep 占位）的同时再触发 `ci.sh spec2017`，
   验证后者打印"已有 run 在跑"并退出 1；前结束后锁释放。
5. `--config` 过滤：用一个**不匹配任何 cfg** 的名字跑 `ci.sh spec2017 --config __nomatch__`，
   验证走"无匹配 config"报错路径；再用真实 cfg 名（如 `clang`）干跑验证只匹配目标
   （可用 `CFG_FILTER=clang bash -x` 观察，或临时脚本断言过滤后的列表）。
6. PATH：模拟 cron 的最小环境，验证 `ci.sh` 顶部的 PATH 修正片段使构建工具可达。
   抽出该片段单独测（不触发真实 build）：
   ```
   env -i PATH=/usr/bin:/bin bash -c '
     case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH";; esac
     for t in cmake ninja clang clang++; do command -v "$t" >/dev/null || echo "MISSING $t"; done
     echo OK
   '
   ```
   期望无 `MISSING` 行。说明：SPEC 步骤用 build 目录内**绝对路径**编译器 + `/usr/bin` 标准工具，
   不依赖 `/usr/local/bin`；真正需要 PATH 修正的是 `build`（cmake/ninja/clang），故以此验证。
7. 真实全量链 `ci.sh full` 留作首次人工验证（本设计不覆盖其 24h+ 运行）。

## 9. 范围外 / 后续（YAGNI）

- 不做 Web 管理界面、远程触发、多机调度。
- 不做 `--dry-run`、结果清理/归档轮转（如需后续再加）。
- 不改 SPEC cfg 内容与优化策略。
- 若未来需要更复杂编排，再考虑 systemd services 或 Python 编排器。
