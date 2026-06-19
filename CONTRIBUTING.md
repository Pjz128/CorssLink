# 贡献指南

欢迎为 CrossLink 做贡献！在开始之前，请花 5 分钟阅读本文档。

## 项目结构

```
CorssLink/
├── poc/          # Go 后端（Agent + 信令 + 协议）
├── app/          # Flutter 手机端
├── docs/         # 产品/技术文档
├── scripts/      # 部署运维脚本
└── .github/      # CI/CD
```

## 开发环境

### 必需
- Go 1.24+ ([下载](https://go.dev/dl/))
- Flutter 3.12+ ([安装](https://docs.flutter.dev/get-started/install))
- Git

### 可选
- Claude Code CLI（`npm i -g @anthropic-ai/claude-code`）
- Ollama（本地模型运行时）
- DeepSeek API Key

## 开局三步

```bash
# 1. Clone
git clone <repo-url> && cd CorssLink

# 2. 验证 Go
cd poc && go build ./... && go test ./... && cd ..

# 3. 验证 Flutter
cd app && flutter pub get && flutter analyze && cd ..
```

## 开发流程

详细规范见 [.claude/skills/workflow/](.claude/skills/workflow/)，核心流程：

```
1. 从 main 拉 feature 分支
2. 写代码 + 测试
3. go test ./... && flutter analyze
4. 提交 PR（附 P 描述 + 关联 Issue）
5. Code Review → Approve → Squash Merge
```

### 分支命名

```
feature/<模块>-<简短描述>
fix/<模块>-<简短描述>
```

### Commit 格式

```
<type>(<scope>): <描述>

feat(claude): 添加 Claude 长连接 session 管理
fix(app): 修复 thinking 块切换状态残留
```

## 测试要求

- **Go**：新增逻辑必须有测试覆盖。`go test -race ./...` 必须通过。
- **Flutter**：`flutter analyze` 必须零 warning。

## 协议变更

如果修改了 `poc/ollama/protocol.go`，**必须同步**修改 `app/lib/models/protocol.dart`，在同一个 PR 中提交。协议变更必须向后兼容（新字段用 `omitempty` / `?`）。

## 需要帮助？

- 查看 [docs/](docs/) 产品文档
- 查看 [.claude/skills/workflow/](.claude/skills/workflow/) 开发规范
- 在 Issue 中提问

## License

MIT — 贡献即表示同意代码以 MIT 协议发布。
