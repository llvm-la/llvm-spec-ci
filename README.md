# llvm-performance-ci

LLVM + Gerrit + Jenkins + SPEC CPU2006/CPU2017 performance CI.

## 用途

本项目用于在 Gerrit 提交 LLVM patch 时，自动构建 LLVM 并运行 SPEC CPU2006/CPU2017 性能测试，量化 patch 对编译性能的影响。每次构建的结果以 JSON 格式保存，可通过 `spec-compare` 网页工具对任意两次构建进行精细化对比，快速定位 patch 带来的性能回归或提升。

### 核心能力

- **自动化性能测试**：Jenkins 监听 Gerrit patch，自动 checkout、构建 LLVM、运行 SPEC 测试并收集结果
- **灵活的测试配置**：通过 `spec-ci.yaml` 控制优化参数、启用的 benchmark、运行规模（test/train/ref）和迭代次数
- **精细化结果对比**：`spec-compare` 网页工具支持任意两次构建的逐项对比，按 SPEC CPU2006 / CPU2017 分组展示
- **可视化分析**：展示每次运行时间、Score、编译参数，计算 Geomean，支持展开查看单次运行详情
- **可追溯性**：结果关联 Gerrit Change 和 Jenkins Build，方便回溯

## 工作流程

```
Gerrit Patch
 -> Save spec-ci.yaml
 -> Validate spec-ci.yaml (spec-ci.py validate)
 -> Validate Parameters (GERRIT_CHANGE, GERRIT_PATCHSET)
 -> Cleanup (rm $SPEC_BUILD_DIR; keep $LLVM_BUILD_DIR, $SPEC_RESULT_DIR, workspace)
 -> Verify Upload (spec-ci.yaml exists)
 -> Checkout Gerrit patch
 -> Build LLVM (exports LLVM_DIR)
 -> Generate SPEC cfg + run scripts (tools/generate.py, per suite present in YAML)
 -> Run SPEC (generated run-cpu2006.sh / run-cpu2017.sh: source shrc, ulimit, runspec/runcpu)
 -> Collect result (tools/collect-result.py) -> $SPEC_RESULT_DIR/result-{name}-{author}-{change}-{patchset}-{build}.json
 -> Package results (scripts/package-build.sh + archiveArtifacts) -> spec-build-<timestamp>.tar.gz (Jenkins artifact)
 -> Cleanup Workspace (rm spec-ci.yaml, tarball; keep $SPEC_RESULT_DIR for comparison)
```

`SPEC_RESULT_DIR` defaults to `$SPEC_RESULT_DIR` from `.env` (local dev) or `$WORKSPACE/spec-result` (Jenkins).
The `spec-compare` web app reads the same directory via `$SPEC_RESULT_DIR`, so CI results are immediately available for comparison.

## spec-compare 对比工具

`spec-compare/` 是一个轻量级 Flask 网页应用，用于对比两次 SPEC CI 运行的结果。

### 功能特性

- 自动扫描结果目录中的 JSON 文件，无需手动上传
- 按 SPEC CPU2006 / CPU2017 分组展示，每组显示默认编译参数对比
- 逐 benchmark 对比运行时间和 Score，支持展开查看每次运行详情
- 单方运行的 benchmark 仍保留在表格中，可展开查看编译参数
- 每个 Suite 计算 Geomean（仅当所有子项均成功运行时）
- 负数 Score 视为 ERROR，不参与对比和 Geomean 计算
- 支持 Gerrit Change / Jenkins Build 可点击链接（通过 `config.json` 配置）

### 启动方式

```bash
cd spec-compare
pip install -r requirements.txt
python app.py
```

浏览器访问 `http://127.0.0.1:5005`。

### 配置

编辑 `spec-compare/config.json` 设置链接前缀：

```json
{
    "gerrit_change_url": "https://gerrit.example.com/c/{change}",
    "jenkins_build_url": "https://jenkins.example.com/job/spec-ci/{build_number}"
}
```

`{change}` 和 `{build_number}` 为占位符，会被实际值替换。留空或删除字段则显示纯文本。

结果目录通过环境变量 `$SPEC_RESULT_DIR` 指定，默认为仓库根目录下的 `spec-result/`。

## SPEC 配置说明

The SPEC configuration is generated from a single human-readable YAML file
(`spec-ci.yaml`) plus the LLVM build directory. The YAML only holds what
changes per run: optimization flags (`COPTIMIZE`/`CXXOPTIMIZE`/`FOPTIMIZE`),
which benchmarks are enabled, and run parameters (`size`, `iterations`).
Compiler paths, hardware descriptions, and per-benchmark portability rules
live in the templates (`templates/cfg/cpu2006.cfg`, `templates/cfg/cpu2017.cfg`) and are
filled in by `tools/generate.py`, which also emits `run-cpu2006.sh` /
`run-cpu2017.sh` to invoke runspec/runcpu with the generated cfg.

## spec-ci.yaml layout

```yaml
version: 1
name: example
cpu2006:            # present => cpu2006.cfg generated
  compiler:
    default:
      COPTIMIZE: -O3
      CXXOPTIMIZE: -O3
      FOPTIMIZE: -O3
  benchmarks:
    400.perlbench: { enabled: true }
  run:
    size: ref        # test/train/ref, passed to runspec
    iterations: 3    # passed to runspec
cpu2017:            # present => cpu2017.cfg generated
  ...
```

## CLI

```sh
python3 spec-ci.py init --specs cpu2006 cpu2017   # scaffold a YAML
python3 spec-ci.py validate spec-ci.yaml          # validate
```

Path configuration (`LLVM_BUILD_DIR`, `SPEC_CI_FILE`, ...) is read from the
repo-root `.env` by the Python scripts via `python-dotenv`. Copy
`.env.example` to `.env` and adjust for the machine.