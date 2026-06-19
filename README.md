# CrossLink

> 跨端 AI 互联 — 手机远程调用家中电脑的 AI 模型，扫码即用，零配置。

[![Flutter](https://img.shields.io/badge/Flutter-3.12+-02569B)](https://flutter.dev)
[![Go](https://img.shields.io/badge/Go-1.24+-00ADD8)](https://go.dev)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

---

## 是什么

在家里的电脑上装一个 Agent，手机扫码配对后，就能远程调用电脑上的 AI 能力。支持三种 AI 后端自由切换：

| 后端 | 类型 | 说明 |
|------|------|------|
| **Claude Code** 🤖 | 本地 Agentic | 电脑上的 Claude CLI，可以用工具、读文件、编辑代码 |
| **Ollama** 🦙 | 本地模型 | 自己跑的 llama/qwen 等开源模型 |
| **DeepSeek** ☁️ | 云端 API | DeepSeek 云服务（兼容 OpenAI 协议） |

手机端实时看到 Claude 的思考过程、工具调用、结果输出。连接采用 WebRTC P2P 直连，数据不经过第三方。

---

## 快速开始

### 1. 电脑端：一键启动

```batch
start.bat
```

脚本自动完成：检测 Go 环境 → 编译 Agent → 检查服务器连通性 → 启动。

启动后终端显示配对二维码 URI（`crosslink://pair?...`），手机 App 扫码即可配对。

### 2. 电脑端：安装为 Windows 服务（开机自启）

```batch
# 右键 → 以管理员身份运行
install.bat
```

服务特性：
- **开机自启**，无需登录
- **崩溃自动重启**：5s → 10s → 30s 渐进重试
- **日志文件**：`C:\ProgramData\CrossLink\agent.log`

管理命令：

```batch
sc query CrossLinkAgent          # 查看状态
sc stop  CrossLinkAgent          # 停止
sc start CrossLinkAgent          # 启动
bin\crosslink-agent.exe uninstall # 卸载
```

### 3. 手机端：编译安装

```bash
cd app
flutter pub get
flutter build apk --debug
```

安装 APK → 打开 App → 扫码配对 → 开始对话。

---

## 架构

```
┌─────────────────┐     WebRTC P2P      ┌─────────────────────────────┐
│   手机 App       │◄══════════════════►│        PC Agent              │
│   (Flutter)      │    DataChannel      │       (Go, 常驻进程)         │
│                  │                     │                             │
│  • 扫码配对       │                     │  BackendPool:               │
│  • Agent 切换     │                     │  ├─ ollama  → Ollama HTTP   │
│  • 模型选择       │                     │  ├─ claude  → Claude CLI    │
│  • 流式聊天       │   信令/中继           │  ├─ deepseek→ DeepSeek API │
│  • Thinking 块   │◄══════════════════►│  └─ (future)               │
│  • 工具调用卡片   │   WebSocket/TURN     │                             │
└─────────────────┘                     └─────────────────────────────┘
```

**传输层**：WebRTC DataChannel 优先 P2P 直连（DTLS/SRTP 加密），打洞失败时自动切 TURN/TCP 中继。

**协议**：JSON WireMessage（`id + time + type + body`），10+ 种消息类型覆盖文本、思考、工具调用、模型切换。

---

## 开发

### 前置条件

- Go 1.24+
- Flutter 3.12+ / Android SDK
- Claude Code CLI（可选：`npm i -g @anthropic-ai/claude-code`）

### 启动开发环境

```bash
# 1. 信号服务器（如果远端没有运行）
cd poc && go run ./signal/

# 2. Agent（交互模式，控制台日志）
cd poc && go run ./ollama-agent/

# 3. 手机 App
cd app && flutter run
```

### 编译

```bash
# Go — agent
cd poc && go build -o ../bin/crosslink-agent.exe ./ollama-agent/

# Flutter — APK
cd app && flutter build apk --debug
```

### 测试

```bash
cd poc
go test ./...    # ollama + pairing 包测试
go vet ./...     # 代码检查
```

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SIGNAL_ADDR` | `ws://45.197.144.16:18080` | 信令服务器地址 |
| `TURN_SERVER` | `turn:45.197.144.16:3478?transport=tcp` | TURN 中继 |
| `CLAUDE_PATH` | `%APPDATA%\npm\...\claude.exe` | Claude CLI 路径 |
| `CLAUDE_MODEL` | `sonnet` | Claude 模型：sonnet / opus / haiku |
| `DEEPSEEK_API_KEY` | — | DeepSeek API 密钥 |

---

## 项目结构

```
CorssLink/
├── start.bat              # 一键启动（交互模式）
├── install.bat            # 安装 Windows 服务
├── README.md
├── Makefile               # 构建/测试/部署
│
├── app/                   # Flutter 移动端
│   └── lib/
│       ├── models/        # 数据模型 (Protocol, Pairing)
│       ├── services/      # 核心服务 (WebRTC, Crypto, History)
│       ├── screens/       # 页面 (Home, Chat, Sessions, Abilities, Settings)
│       └── widgets/       # UI 组件 (Thinking, ToolCard, AgentPicker)
│
├── poc/                   # Go 后端
│   ├── ollama-agent/      # 主 Agent 入口 + Windows 服务
│   ├── agent/
│   │   ├── claude/        # Claude CLI 后端 (子进程管理 + stream-json 解析)
│   │   └── pool/          # BackendPool (多后端路由)
│   ├── ollama/            # 协议定义 + Handler + ExtendedBackend 接口
│   ├── peer/              # WebRTC Peer 封装 (pion/webrtc)
│   ├── signal/            # 信令服务器 (WebSocket Hub)
│   ├── pairing/           # NaCl Box 配对加密
│   └── cloud/             # DeepSeek 云后端
│
├── scripts/               # 部署/运维脚本
│   ├── start-agent.sh     # Agent 启动 + QR 生成
│   ├── deploy-cloud.sh    # 云端部署
│   └── watchdog.sh        # 进程守护
│
├── docs/                  # 产品文档
│   ├── prd.md             # 产品需求文档
│   └── poc-report.md      # POC 验证报告
│
└── signal/                # 信令 Docker 配置
```

---

## 协议

手机与 Agent 之间通过 WebRTC DataChannel 传输 JSON 消息。

### 消息类型

| 类型 | 方向 | 说明 |
|------|------|------|
| `chat-req` | App → Agent | 发送聊天消息 |
| `chat-tok` | Agent → App | 流式文本 token |
| `chat-done` | Agent → App | 回答结束 |
| `chat-err` | Agent → App | 错误 |
| `thinking` | Agent → App | Claude 思考 token |
| `tool-use` | Agent → App | 工具调用开始 |
| `tool-input` | Agent → App | 工具参数流 |
| `tool-result` | Agent → App | 工具执行结果 |
| `list-req` | App → Agent | 请求模型列表 |
| `list-res` | Agent → App | 模型列表（含 agents 分组） |
| `list-agents` | App → Agent | 请求 Agent 类型列表 |
| `set-model` | App → Agent | 切换模型 |
| `status-req` | App → Agent | 状态查询 |
| `status-res` | Agent → App | 状态回复 |
| `ping` / `pong` | ↔ | 心跳 |

### 扩展后端

新增 AI 后端只需实现 `Backend` 接口（3 个方法），Agentic 后端额外实现 `ExtendedBackend`：

```go
type Backend interface {
    ChatStream(req ChatRequest) (<-chan string, <-chan error)
    ListModels() ([]ModelInfo, error)
    Ping() (string, error)
}

type ExtendedBackend interface {
    Backend
    SetEventCallback(fn func(BackendEvent))
    Models() []ModelInfo
    Close() error
}
```

然后在 `ollama-agent/main.go` 中 `pool.Register("name", backend, info)` 即可。

---

## 技术栈

| 层 | 技术 |
|----|------|
| 移动端 | Flutter 3.12, flutter_webrtc, flutter_markdown |
| Agent 核心 | Go 1.24, pion/webrtc v4, gorilla/websocket |
| Claude 集成 | Claude CLI — stream-json 长连接模式 |
| 信令 | Go + gorilla/websocket, TCP Keepalive |
| 加密 | NaCl Box (Curve25519 + XSalsa20-Poly1305) |
| P2P | WebRTC DataChannel, TURN/TCP 中继 |
| 服务化 | Windows SCM (golang.org/x/sys/windows/svc) |

---

## 版本

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0.0 | 2026-06-17 | 首个可用版本：扫码配对、多会话聊天、Markdown、模型管理、断线重连 |
| v1.1.0 | 2026-06-18 | Claude Code 集成：BackendPool 多后端、thinking/工具调用渲染、Agent/模型选择器、Windows 服务化 |

---

## License

MIT
