# SPEC CI Result Compare

轻量级 Python Web 对比工具。

## 使用

1. 将 SPEC CI 生成的 JSON 放入 `results/`（或 `$SPEC_RESULT_DIR` 指向的目录）。
2. 安装依赖：

```bash
pip install -r requirements.txt
```

3. 启动：

```bash
python app.py
```

4. 浏览器访问：

```text
http://127.0.0.1:5000
```

## 配置

编辑 `config.json` 设置链接前缀，Change 和 Build 字段会渲染为可点击链接：

```json
{
    "gerrit_change_url": "https://gerrit.example.com/c/{change}",
    "jenkins_build_url": "https://jenkins.example.com/job/spec-ci/{build_number}"
}
```

`{change}` 和 `{build_number}` 为占位符，会被实际值替换。留空或删除字段则显示纯文本。

- 自动扫描 `results/*.json`，不需要上传文件。
- 共同运行的子项进行精细化对比。
- 单方运行的子项仍保留在对应 Suite 下。
- 每个 Suite 计算 Score Geomean。
- Geomean 只使用双方共同运行且双方 Score 均有效的子项。
- 任意负数 Score 视为 ERROR，不参与 Score 对比和 Geomean。
- `iterations` 表示每个测试运行次数，详情页保留每次运行结果。
- 点击 Benchmark 行展开运行时间、Score、编译参数和运行参数。
