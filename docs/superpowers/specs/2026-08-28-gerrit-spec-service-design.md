# Gerrit SPEC 测试服务设计

- 日期：2026-08-28
- 状态：已评审通过（待实现）
- 前置：本地 CI 编排（见 `2026-08-28-local-ci-design.md`，已实现）

## 1. 背景与动机

现有本地 CI 是"定期全量跑"：每 15 天从上游拉 llvm-project、构建 clang/flang、跑全量
SPEC 2017/2006。团队的实际开发流程基于内部 Gerrit：llvm-project 的内部分支托管在 Gerrit，
开发者提交 patch（change）。需要一台共享 SPEC 测试服务：

1. 定期全量跑的代码来源从上游切换到**内部 Gerrit 分支**；
2. 任何人都能**手动选择性触发**对某个 change 的 SPEC 验证（不做每 patch 自动触发），
   并可**自定义测试子项（任意 benchmark 子集）与 benchmark 编译参数**；
3. 结果在局域网 Web 上公示，供 patch 作者评估性能变化。

**环境约束（已确认）**：
- 本机（loongarch64）**只开发 CI 脚本，不实际运行 CI**；真实 runner 是另一台机器。
- runner **没有互联网**，只有内网（可直达内部 Gerrit）→ runner 侧**零新增外部依赖**
  （只用 bash/git/flock/jq/python3 标准库，无 pip 包）。
- 所有 Gerrit 信息（URL、项目、分支、认证）一律走**配置文件/环境变量**，不硬编码。
- 需要真实环境验证的测试，输出清单交用户在 runner 上执行。

## 2. 目标 / 非目标

**目标**
- `build-llvm.sh` 支持从内部 Gerrit 分支拉主线代码（可配置，未配置时保留 GitHub 回退）。
- 新增 `ci.sh gerrit-pop` 子命令 + cron 周期触发：消费请求队列，跑
  "取 change → 构建 → 跑指定 benchmark 子集（自定义编译参数）→ 汇总结果" 流水线。
- 新增 Web 表单（复用 8080 报告服务）：提交请求、查看队列状态、查看历史 gerrit 结果
  与基线对比。
- 请求队列（FIFO、上限、失败标记、中断恢复），与主线 full 共享全局锁互斥。

**非目标（首期）**
- Gerrit 回帖（REST 发评论）与 Gerrit 评论触发（`/test` 之类）——`summary.json`
  结构预留兼容，后续扩展。
- 多机调度、Web 管理界面（删除/取消请求等写操作）、账号/认证体系。
- 主线 history.json 增加逐基准分数（用户明确不要；对比基线改用历史 gerrit run）。
- 修改 `cfg/` 下任何 cfg 文件（参数覆盖通过临时 cfg 追加实现）。

## 3. 已确认的决策记录

| 决策点 | 结论 |
|---|---|
| 适配目标 | 切换代码来源 + per-change 验证（手动选择性触发，非自动） |
| 提交入口 | 仅 Web 表单（SSH CLI / Gerrit 评论触发不进首期） |
| 结果去向 | 首期仅本地（Web 公示）；回帖后续加 |
| 自定义范围 | 自由选择每个 benchmark 子项 + benchmark 编译参数（cfg 层，不动编译器 CMake 参数） |
| 队列消费 | cron 周期 pop（每 5 分钟 `ci.sh gerrit-pop`），无常驻守护进程 |
| Web 认证 | 无（局域网信任，表单选填提交人） |
| 默认数据集 | `--size=ref`（trivial 可选） |
| 对比基线 | 任选一个历史 gerrit run 做逐基准对比；主线总分仅作参考展示 |
| Gerrit 信息 | 全部进 `config/ci.conf`（KEY=VALUE），环境变量可覆盖 |
| 源/构建布局 | 一个 clone（repos/llvm-project）+ 一个 worktree + 一个共享构建目录（build-llvm） |

## 4. 总体架构

```
局域网用户 ──▶ Web 表单 POST /submit（change/ps/benchmarks/参数/size）
                    │ 校验后写 JSON 请求文件（原子）
                    ▼
          queue/pending/*.json（FIFO，上限 QUEUE_MAX_PENDING）
                    │  */5 cron: ci.sh gerrit-pop
                    │  （取全局 flock；忙/空 → 静默 exit 0）
                    ▼
  ┌── gerrit 流水线（全程持锁，与主线 full 互斥）──────────────────────────┐
  │ 1. 磁盘水位检查：可用 < DISK_MIN_FREE_GB → 直接判 failed             │
  │ 2. scripts/gerrit-fetch.sh <change> [ps]                             │
  │      ls-remote refs/changes/XX/NNNN/* → 选 ps（默认最新）             │
  │      → fetch → git worktree add --detach repos/llvm-gerrit-wt        │
  │      → 写 build-info-gerrit/{commit.txt,info.json}                   │
  │ 3. build-llvm.sh（LLVM_SRC_DIR=worktree, LLVM_SKIP_UPDATE=1,         │
  │      BUILD_INFO_DIR=build-info-gerrit；共享 build-llvm 目录，        │
  │      change 间 ninja 增量编译）                                       │
  │ 4. run-spec2017.sh / run-spec2006.sh（有对应基准才调）：              │
  │      BENCHMARK_LIST / CFG_OVERRIDES_FILE / RESULT_BASE_DIR /         │
  │      SPEC_RUNGUID 全环境变量注入，脚本不改调用签名                    │
  │ 5. scripts/gerrit-summarize.sh <run-id-dir> → summary.json           │
  │      （逐基准分数 + 总分；失败 run 也写，status=failed）              │
  │ 6. 请求文件 → done/ 或 failed/（补 finished_at/run_id/result_dir/    │
  │      error），清理超过 QUEUE_KEEP_DAYS 的旧文件                      │
  └──────────────────────────────────────────────────────────────────────┘
                    │
  results/gerrit/<run-id>/{summary.json, 2017/<cfg>/, 2006/<cfg>/}
                    ▼
  Web：/queue（当前在跑 + 等待 + 最近完成）、/gerrit/（历史列表）、
       /gerrit/<run-id>/（结果页 + 基线对比 + 详细报告链接）
  results/latest/（主线报告，完全不变）
```

数据流要点：
- gerrit lane 与主线 lane 共用 `repos/llvm-project` clone 与 `build-llvm/` 构建目录
  （全局锁保证串行，互不干扰）；worktree 共享 clone 对象库，省磁盘。
- 两条 lane 的构建 info 分开：主线 `build-info/`（`generate-report.sh` 的输入，不变），
  gerrit lane `build-info-gerrit/`。
- 请求文件是唯一队列介质；Web 表单只写 `queue/pending/`，popper 只动 `queue/`，
  两者无直接耦合。

## 5. 请求队列设计

### 5.1 目录与文件

- `queue/{pending,running,done,failed}/`（整体 gitignore）
- 请求文件名：`<epoch 毫秒>-gerrit-<change>-<4 位随机十六进制>.json`（毫秒 + 随机尾
  防同秒同 change 撞名；FIFO 按名排序）
- 请求 JSON（表单提交时的字段）：

```json
{
  "id": "1756345678901-gerrit-1234-a1b2",
  "change": "1234",
  "patchset": 0,
  "requester": "zhangsan",
  "size": "ref",
  "bench2017": ["500.perlbench_r", "502.gcc_r"],
  "bench2006": [],
  "opt2017": {
    "OPTIMIZE": "",
    "EXTRA_COPTIMIZE": "",
    "EXTRA_CXXOPTIMIZE": "",
    "EXTRA_FOPTIMIZE": ""
  },
  "opt2006": {
    "COPTIMIZE": "",
    "CXXOPTIMIZE": "",
    "FOPTIMIZE": ""
  },
  "extra_cfg_2017": "",
  "extra_cfg_2006": "",
  "created_at": "2026-08-28T12:00:00+0800"
}
```

- 语义：`patchset: 0` = 最新 patchset；`opt*`/`extra_cfg_*` 空串 = 用 cfg 默认。
- 生命周期中追加的字段：`status`（pending/running/done/failed）、`started_at`、
  `finished_at`、`run_id`、`result_dir`、`error`（failed 时）。
- run-id：`<YYYYmmdd-HHMMSS>-gerrit-<change>-ps<实际ps>`（ps 在 fetch 时解析；
  patchset=0 时取实际最新 ps）。结果目录 `results/gerrit/<run-id>/`。

### 5.2 规则

- **FIFO**：按文件名取第一个 pending。
- **上限**：`QUEUE_MAX_PENDING`（默认 10）。pending 数达到上限时 Web 表单返回 503
  "队列已满"。popper 每次 cron tick 最多消费 1 个（流水线长达数小时，天然节流）。
- **并发**：`gerrit-pop` 先取全局 flock（与主线 full 同一把锁 `.ci.lock`）：
  - 锁被占 → **静默 exit 0**（cron tick 的正常情况，不写错误日志、不建日志目录）；
  - 取到锁且无 pending → 静默 exit 0；
  - 取到锁且有 pending → 建日志目录 `logs/<时间戳>-gerrit-pop/`（tee 到 run.log），
    原子 `mv` pending→running 后执行流水线。
- **中断恢复**：popper 取到锁后发现 `running/` 有文件 = 上一次运行已中断
  （持锁进程已死，锁已释放）→ 将该文件标记 failed（`error=interrupted`）移入
  `failed/`，然后继续处理 pending。
- **保留期**：每次 pop 时删除 `done/`、`failed/` 中文件名 epoch 超过
  `QUEUE_KEEP_DAYS`（默认 30 天）的文件（结果目录 `results/gerrit/<run-id>/` 保留，
  由用户自行清理）。

## 6. Gerrit 取码与构建

### 6.1 配置（config/ci.conf）

`config/ci.conf`（KEY=VALUE，`#` 注释；bash `source` 可用、python 逐行解析；
真实文件 gitignore，仓库提交模板 `config/ci.conf.example`）。环境变量覆盖同名配置。

```
# Gerrit（空 = 回退 GitHub 上游，保留开发机行为）
GERRIT_CLONE_URL=            # 完整 clone URL，如 ssh://user@gerrit.example.com:29418/llvm-project
                             #   或 http://gerrit.example.com:8080/a/llvm-project
GERRIT_BRANCH=main           # 主线跟踪分支

# gerrit 验证 lane
LLVM_GERRIT_WT=repos/llvm-gerrit-wt
DISK_MIN_FREE_GB=40          # 首跑实测构建体积后校准（见 §14 风险）

# 队列
QUEUE_MAX_PENDING=10
QUEUE_KEEP_DAYS=30

# Web
WEB_PORT=8080
```

### 6.2 主线取码切换（build-llvm.sh 修改）

- `LLVM_BRANCH="${LLVM_BRANCH:-main}"`；`GERRIT_CLONE_URL` 非空时 clone/pull 源
  用它、分支用 `GERRIT_BRANCH`（`LLVM_BRANCH` 环境变量可再覆盖）；为空时保留现有
  GitHub `main` 行为（开发机回退）。
- 新增 `LLVM_SKIP_UPDATE=1`：跳过整个 clone/pull 步骤（仅校验 `$SRC_DIR` 是
  git 仓库），供 gerrit lane 使用（worktree 已就位）。
- 新增 `BUILD_INFO_DIR`（默认 `$PROJECT_DIR/build-info`）：info.json/commit.txt
  写入目录。gerrit lane 传 `build-info-gerrit/`，不污染主线报告输入。
- 其余（cmake 参数、ninja clang flang、校验）不变。

### 6.3 gerrit-fetch.sh（新增）

```
用法: gerrit-fetch.sh <change> [patchset]     # patchset 缺省/0 = 最新
```

1. clone 目录 = `$PROJECT_DIR/repos/llvm-project`（与主线共享）。不存在则 clone
   （源：`GERRIT_CLONE_URL` 或 GitHub 回退，检出 `GERRIT_BRANCH`，使后续主线
   lane 的 `git pull` 直接可用）。
2. `git ls-remote origin 'refs/changes/XX/NNNN/*'`（XX = change 号末两位）。
   无匹配 → exit 1（"change 不存在或无权限"）。
3. 选定 patchset：参数为 0/缺省 → 取最大 ps；否则取参数 ps（不存在 → exit 1）。
4. `git fetch origin refs/changes/XX/NNNN/PS`。
5. worktree：`$LLVM_GERRIT_WT` 已存在 → `git worktree remove --force`；
   `git worktree add --detach "$LLVM_GERRIT_WT" FETCH_HEAD`。
   （detached，不影响主线分支 checkout。）
6. 写 `build-info-gerrit/commit.txt` 与 `info.json`
   （change、patchset、commit、short、date、fetched_at）。
7. stdout 输出解析结果（change、ps、sha），供流水线日志。

### 6.4 构建与磁盘

- 共享 `build-llvm/` 目录：change 之间源码差异小 → ninja 增量编译（通常远短于
  全新 8h 构建）；同一 change 重复验证 = 接近全增量。
- 磁盘水位：流水线第 1 步对 `$PROJECT_DIR` 所在文件系统 `df`，可用空间
  < `DISK_MIN_FREE_GB` → 请求直接 failed（`error=disk full: ...`），不启动构建。
- 首跑实测构建体积后校准阈值（runner 清单第 3 项）。

## 7. SPEC 运行层定制（复用现有 run 脚本）

`run-spec2017.sh` / `run-spec2006.sh` 各增加 3 个环境变量（默认值 = 现有行为，
完全向后兼容；调用签名不变）：

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `BENCHMARK_LIST` | `intrate fprate`（2017）/ `specint specfp`（2006） | 替换 runcpu/runspec 的基准集合参数（可传单个基准名，空格分隔） |
| `CFG_OVERRIDES_FILE` | 空 | 非空且存在时，把该文件内容**追加**到 `@@BUILD_DIR@@` 替换后的临时 cfg 末尾 |
| `RESULT_BASE_DIR` | `results/spec2017` / `results/spec2006`（相对项目根） | 结果拷贝基础目录；脚本在其下按 `<cfg>` 建子目录（现有行为 = 默认值） |

- `SPEC_RUNGUID`（已有）：gerrit lane 设 `<ts>-clang-loongarch-gerrit-<change>-ps<ps>`
  （兼容现有 `result/*clang-loongarch*` 收集 glob）。
- `ulimit -s/-c unlimited`：两个 run 脚本顶部已有，gerrit lane 复用同一脚本自动覆盖。
- 每个 cfg 循环内的行为不变（逐个 cfg 跑、收集结果），仅上述三处参数化。

### 7.1 cfg 参数覆盖（不改 cfg/ 文件）

覆盖内容 = "后定义覆盖先定义"的 cfg 段，由 `ci.sh` 的 gerrit-pop 流水线从请求 JSON
生成临时覆盖文件（仅含非空字段）：

- 2017（对应 `clang-2017.cfg` 的现有段名）：
  ```
  default=base:
     OPTIMIZE = <值>
  intrate,intspeed=base:
     EXTRA_COPTIMIZE = <值>
     EXTRA_CXXOPTIMIZE = <值>
     EXTRA_FOPTIMIZE = <值>
  ```
- 2006（对应 `clang-2006.cfg`）：
  ```
  default=base=default=default:
     COPTIMIZE = <值>
     CXXOPTIMIZE = <值>
     FOPTIMIZE = <值>
  ```
- 之后原样追加 `extra_cfg_*` 自由文本（高级用户覆盖 PORTABILITY/makeflags/
  单基准段等）。段头只在该段下有非空字段时输出。
- 覆盖是否真实生效（SPEC cfg 追加段语义）列入 runner 验证清单第 4 项
  （查看详细报告中 benchmark 的实际编译行）。

## 8. 汇总（gerrit-summarize.sh，新增）

```
用法: gerrit-summarize.sh <results/gerrit/<run-id> 目录>
```

- 读取该目录下的 `2017/<cfg>/`、`2006/<cfg>/`（run 脚本拷入的 SPEC 结果）与
  `build-info-gerrit/info.json`。
- 从 SPEC 汇总 `index.html` 解析**逐基准分数**（基准名 + 分数列）与总分
  （2017: `SPECrate2017_int`/`SPECrate2017_fp`；2006: `SPECint_rate2006`/
  `SPECfp_rate2006`；子集运行时为子集总分）。解析方式沿用现有 `grep -oP`
  风格；**某基准解析失败 = 该基准 null，不中断**。
- 写 `<run-id>/summary.json`（done 与 failed run 都写，failed 时分数为 null）：

```json
{
  "run_id": "20260828-120000-gerrit-1234-ps2",
  "change": "1234",
  "patchset": 2,
  "requester": "zhangsan",
  "size": "ref",
  "status": "done",
  "llvm_commit": "<sha>",
  "llvm_short": "<short>",
  "created_at": "2026-08-28T12:00:00+0800",
  "finished_at": "2026-08-28T15:30:00+0800",
  "error": null,
  "opts": { "2017": { "OPTIMIZE": "-O2", "EXTRA_COPTIMIZE": "" }, "2006": {} },
  "suites": {
    "2017": {
      "config": "clang-2017",
      "aggregate_int": "123.4",
      "aggregate_fp": "56.7",
      "benchmarks": { "500.perlbench_r": "12.3", "502.gcc_r": null },
      "detail_dir": "2017/clang-2017"
    },
    "2006": { }
  }
}
```

- 某 suite 失败时（§10 语义）：总体 `status` 为 `failed`，失败 suite 的
  字段为 null / 空对象，成功 suite 的分数照常保留。

该结构同时是未来"回帖 Gerrit"的数据源（非目标，预留兼容）。

## 9. Web 服务（web/server.py，新增，单文件纯标准库）

替换现 `python3 -m http.server` 方案，systemd unit 的 ExecStart 指向它；
仍绑定 0.0.0.0:8080（`WEB_PORT` 可配）。Python ≥ 3.7 标准库
（`http.server.ThreadingHTTPServer`、`urllib.parse`、`json`、`html`）。
启动时读 `config/ci.conf`（若存在），环境变量优先。**无认证**（局域网信任，
文档注明）。

### 9.1 路由

| 路由 | 行为 |
|---|---|
| `GET /` | 主线 `results/latest/index.html`（不存在时显示"暂无报告"页） |
| `GET /<静态>` | `results/latest/` 下现有文件：`compare.html`、`history.json`、`spec2017-detail/…`、`spec2006-detail/…` |
| `GET /submit` | 提交表单（字段见 9.2） |
| `POST /submit` | 校验 → 原子写 `queue/pending/<epoch 毫秒>-gerrit-<change>-<4 位随机十六进制>.json`（同目录临时文件 + rename，命名见 §5.1）→ 302 到 `/queue`；校验失败 400（附原因）；队列满 503 |
| `GET /queue` | 当前在跑（读 `.ci.lock.info`：主线 full 还是 gerrit change、pid、开始时间）+ pending 列表（FIFO 序）+ 最近 20 条 done/failed（带结果链接） |
| `GET /gerrit/` | 历史 run 列表：遍历 `results/gerrit/*/summary.json`，表格 run_id/change/ps/提交人/size/状态/完成时间/链接 |
| `GET /gerrit/<run-id>/` | 结果页：meta（change、ps、commit、提交人、size、所用参数）+ 逐基准分数表 + **基线下拉框**（选另一个历史 gerrit run，客户端 JS 拉两个 summary.json 做逐基准 diff，涨跌着色，null 安全）+ 主线最近总分（取 `history.json` 最新条目的 SPECrate 总分字段，标注"全量总分，选子集时不直接可比"）+ 详细 SPEC HTML 链接 |
| `GET /gerrit/<run-id>/<path>` | 该 run 的 SPEC 详细报告静态文件 |

- run-id 与静态路径逐段做白名单字符校验（每段 `[A-Za-z0-9._-]`，段间以 `/` 分隔）
  + `realpath` 前缀检查，防路径穿越；表单字段渲染进 HTML 一律 `html.escape`（防 XSS）。
- 样式沿用现有报告的深色 monospace 风格（内联 CSS）。

### 9.2 表单字段

| 字段 | 类型 | 规则 |
|---|---|---|
| change | 文本（必填） | 正整数 |
| patchset | 文本（可选） | 空 = 最新；否则正整数 |
| 提交人 | 文本（可选，≤64 字符） | |
| 数据集 | 单选 | `ref`（默认）/ `trivial` |
| SPEC 2017 基准 | 复选框组 | 见 9.3 |
| SPEC 2006 基准 | 复选框组 | 见 9.3 |
| 2017 参数 | 4 个文本框 | `OPTIMIZE` / `EXTRA_COPTIMIZE` / `EXTRA_CXXOPTIMIZE` / `EXTRA_FOPTIMIZE`，空 = cfg 默认（placeholder 显示 cfg 现值） |
| 2006 参数 | 3 个文本框 | `COPTIMIZE` / `CXXOPTIMIZE` / `FOPTIMIZE`，同上 |
| 追加 cfg 片段（2017 / 2006） | 两个 textarea（可选） | 原样追加到临时 cfg，≤64KB |

校验（服务端）：change 正整数；至少勾选一个基准（2017 或 2006）；size ∈
{ref, trivial}；单个参数框 ≤1024 字符；片段 ≤64KB；pending 未超上限。

### 9.3 benchmark 清单来源

1. 优先动态：扫描 SPEC 安装目录（`repos/cpu2017/benchmarks/`、
   `repos/cpu2006/benchmarks/` 下的基准目录名）；
2. 兜底（开发机无 SPEC 安装）：内置清单。
   - 2017（rate 基准名，共 19 个，int/fp 共用名归并）：
     `500.perlbench_r 502.gcc_r 503.bwaves_r 505.mcf_r 507.cactuBSSN_r
     508.namd_r 510.parest_r 511.povray_r 519.lbm_r 521.wrf_r
     523.xalancbmk_r 526.blender_r 527.cam4_r 538.imagick_r
     544.nush_fd_r 548.exchange2_r 549.fotonik3d_r 554.h264ref_r 557.xz_r`
   - 2006：标准 SPEC CPU 2006 rate 基准名清单（int+fp 归并），实现时依据
     SPEC CPU 2006 文档整理，并在 runner 上与 `$SPEC/benchmarks/` 目录核对
     （runner 清单第 6 项）。
- 用户勾选后按名字前缀归类到 2017/2006 两个列表（`5xx`/`6xx` → 2017，
  `3xx`/`4xx` → 2006）；2017 列表内 int/fp 混选无需拆分，runcpu 自行归类。

## 10. ci.sh 修改（gerrit-pop 子命令）

- 子命令 `gerrit-pop`（run 类，取全局锁；usage/list 更新）。
- 与现有 run 命令的差异：**锁忙或队列空时静默 exit 0**（不打印错误、不建日志目录）；
  真正消费请求时才建 `logs/<时间戳>-gerrit-pop/` 并 tee。
- 流水线顺序与失败语义：
  1. stuck-running 恢复（§5.2）；
  2. 取第一个 pending → 原子 mv 到 `running/`（写 `status/started_at`）；
  3. 磁盘水位 → 4. gerrit-fetch.sh → 5. build-llvm.sh（env 注入 §6.2）
     → 6. run-spec2017.sh / run-spec2006.sh（仅基准列表非空的 suite；env 注入 §7）
     → 7. gerrit-summarize.sh → 8. 请求文件移 `done/`（或任一步失败移 `failed/`，
     写 `error`，已完成的步骤结果保留在磁盘）→ 9. 保留期清理。
  - 任一步失败：exit 1（记入 `logs/gerrit-pop.log`），请求标 failed，
    后续步骤不再执行（与主线 full 的"spec 失败继续出报告"不同：gerrit lane
    的构建失败没有可汇总的结果；SPEC 某 suite 失败时另一 suite 与 summarize
    仍执行，summary 中标记 failed suite）。
- 测试接缝：`CI_PIPELINE_STUB=1` 环境变量时，第 4-7 步替换为 stub
  （写假的 `build-info-gerrit/` 与最小 `summary.json`/结果目录，不执行真实
  fetch/构建/SPEC）；第 3 步磁盘水位检查保持真实（供测试 disk 错误路径）。
  仅供开发机离线测试队列状态机，runner 上不启用。

## 11. 部署配置

- **cron**（两条，`crontab -e` 安装；替代关系见 local-ci spec §6.7）：
  ```
  0 0 1,16 * * cd /home/user/code/llvm-spec-ci && mkdir -p logs && ./scripts/ci.sh full >> logs/cron.log 2>&1
  */5 * * * * cd /home/user/code/llvm-spec-ci && mkdir -p logs && ./scripts/ci.sh gerrit-pop >> logs/gerrit-pop.log 2>&1
  ```
- **systemd**：`systemd/spec-report-web.service` 的 ExecStart 改为
  `/usr/local/bin/python3 web/server.py`（其余不变；WorkingDirectory 仍为项目目录，
  server 自行读 `config/ci.conf`）。
- **runner 部署步骤**（文档给出，需用户执行）：部署代码 → 填 `config/ci.conf`
  → 装 cron → 装/更新 systemd unit。

## 12. 文件变更清单（汇总）

| 操作 | 文件 | 说明 |
|---|---|---|
| 新增 | `scripts/gerrit-fetch.sh` | ls-remote / fetch / worktree / build-info-gerrit |
| 新增 | `scripts/gerrit-summarize.sh` | 解析分数 → summary.json |
| 新增 | `web/server.py` | 单文件 Web 服务（表单/队列/结果页） |
| 新增 | `config/ci.conf.example` | 配置模板 |
| 修改 | `scripts/ci.sh` | +`gerrit-pop`（队列消费流水线 + stub 接缝） |
| 修改 | `scripts/build-llvm.sh` | 源切换 / `LLVM_SKIP_UPDATE` / `LLVM_BRANCH` / `BUILD_INFO_DIR` |
| 修改 | `scripts/run-spec2017.sh`、`scripts/run-spec2006.sh` | +`BENCHMARK_LIST` / `CFG_OVERRIDES_FILE` / `RESULT_BASE_DIR` |
| 修改 | `systemd/spec-report-web.service` | ExecStart → `web/server.py` |
| 修改 | `.gitignore` | +`queue/`、`config/ci.conf`、`build-info-gerrit/` |
| 修改 | `CLAUDE.md` | gerrit lane 文档、新环境变量、cron 行、Web 服务说明 |

不改动：`cfg/*`、`generate-report.sh`、`results/latest/` 布局、`compare.html`、
主线 full 的行为（仅取码源按配置切换）。

## 13. 测试与验证

### 13.1 开发机（离线，实现者执行）

1. `bash -n` 全部改动/新增脚本；`python3 -m py_compile web/server.py`。
2. **假 Gerrit**：本地 bare 仓库 + `git update-ref` 造
   `refs/changes/34/1234/{1,2}` → 以 `GERRIT_CLONE_URL=<本地路径>` 验证
   `gerrit-fetch.sh`：指定 ps 命中对应 commit、缺省取最新 ps、不存在的 change
   退出 1。
3. **队列状态机**（`CI_PIPELINE_STUB=1`）：
   - 空队列 / 锁被占 → 静默 exit 0；
   - 单请求 → `done/`，`results/gerrit/<run-id>/summary.json` 生成；
   - 多请求 → FIFO 顺序；
   - 手工在 `running/` 放文件（模拟中断）→ 下次 pop 标 `failed: interrupted`
     并继续消费 pending；
   - `DISK_MIN_FREE_GB=99999` → 请求 failed（disk 错误）；
   - 保留期清理：造超期文件 → 被删除。
4. **Web**（`env -u LD_PRELOAD` 下启动，测试端口）：
   - `GET /submit` 200 且含复选框组；
   - `POST` 合法 → 302 + queue 文件内容正确；无基准 / change 非数字 → 400 且无文件；
   - 队列满（`QUEUE_MAX_PENDING=1` + 预置 1 个 pending）→ 503；
   - `GET /queue` 显示 pending 与当前在跑；`GET /gerrit/` 列出种子 done run；
     `GET /gerrit/<run-id>/` 渲染分数表与基线下拉框；
   - 路径穿越（`/gerrit/../queue/…` 等）→ 404；表单注入内容被转义。
5. 现有行为回归：`ci.sh list-configs/status/report` 正常；`run-spec2017.sh`
   不带新环境变量时行为不变（过滤/无匹配报错路径不变）。

### 13.2 runner 机器（用户执行，实现完成后提供清单）

1. 填 `config/ci.conf`（GERRIT_CLONE_URL / GERRIT_BRANCH）并部署代码；
2. `scripts/gerrit-fetch.sh <真实change>` 验证真实 Gerrit 取码（URL/认证）；
3. `ci.sh build` 主线构建一次 → 实测 `build-llvm/` 体积 → 校准
   `DISK_MIN_FREE_GB`；
4. Web 表单小真实 run：2017 + trivial + 2 个基准 + 修改一个 OPTIMIZE →
   跟踪 `/queue` → 完成后查结果页：**确认覆盖参数生效**（详细报告中 benchmark
   实际编译行）、分数解析正确；
5. 第二次 run（不同参数）→ 验证基线对比下拉框 diff 正确；
6. 核对表单 benchmark 清单与 `$SPEC/benchmarks/` 一致（含 2006 内置清单核对）；
7. 安装 cron 两行 + systemd unit（`systemctl enable --now spec-report-web`）；
8. 主线 `ci.sh full` 跑一次（验证从 Gerrit 分支拉码 + 全链路）。

## 14. 风险与对策

| 风险 | 对策 |
|---|---|
| 磁盘：/home 空闲 48G vs 记录构建 ~50G | 首跑实测 → 校准水位；不足时再议（减 runtimes / 清数据 / 加盘）；水位保护防构建中途写满 |
| 逐基准分数解析依赖 SPEC HTML 结构，开发机无样本 | 解析失败单基准落 null 不中断；列入 runner 清单第 4 项验证 |
| cfg 追加段"后定义覆盖先定义"语义未经真实 SPEC 验证 | 列入 runner 清单第 4 项（看实际编译行）；不成立则改为 `%define` 间接层方案 |
| runner 的 python3 版本未知 | 只用 3.7+ 标准库；部署时核对版本 |
| Gerrit HTTP 认证方式（`/a/` 路径 vs ssh key）未定 | 配置项留完整 URL，两种都支持；runner 清单第 2 项验证 |

## 15. 范围外 / 后续（YAGNI）

- Gerrit 回帖（summary.json 已预留数据源）与 Gerrit 评论触发。
- Web 写操作（取消/删除请求）、认证体系、多机调度。
- 结果目录轮转清理（仅队列文件按保留期清理）。
- 主线 history.json 逐基准分数（用户明确不加）。
