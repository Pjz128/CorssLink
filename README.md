# CrossLink

> 跨端 AI 互联工具 — 手机远程调用家中电脑的 AI 模型，扫码即用，零配置。

[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.12+-02569B)](https://flutter.dev)
[![Go](https://img.shields.io/badge/Go-1.24+-00ADD8)](https://go.dev)

---

## 核心价值

| 痛点 | CrossLink 方案 |
|------|---------------|
| 出门想用家中 AI 算力 | WebRTC P2P + TURN 中继，自动穿透 NAT |
| 配置 IP/端口/证书太麻烦 | 扫码配对，30 秒内建立连接 |
| 云 API 费用高、数据隐私担忧 | 数据直连家中电脑，不经过第三方 |

## 架构

```
┌──────────┐    WebRTC P2P     ┌──────────────┐
│  📱 App  │◄══════════════════►│  💻 Agent    │
│  Flutter │    DataChannel     │  Go (PC)     │
└────┬─────┘                    └──────┬───────┘
     │ 信令/中继                       │ DeepSeek API
     │                                 │ / Ollama
┌────▼──────────────────────────────────▼───────┐
│             ☁️  Cloud Services                 │
│  信令服务器 (WebSocket)  │  TURN 中继 (TCP)    │
│  Go + gorilla/websocket │  coturn              │
└───────────────────────────────────────────────┘
```

## 功能

- **扫码配对** — NaCl 加密握手，信号服务器无法解密
- **多会话聊天** — 创建/切换/删除对话，自动标题
- **Markdown 渲染** — 代码高亮、引用、列表
- **模型管理** — 浏览 Agent 模型列表，设置默认模型
- **Agent 管理** — 在线状态、重命名、连接测试
- **断线重连** — 指数退避自动重连
- **主题色** — 6 色可选，实时预览
- **连接可视化** — 12 步连接状态实时显示

## 快速开始

### 前置条件

- Go 1.24+ / Flutter 3.12+ / Android SDK
- DeepSeek API Key（或本地 Ollama）

### 1. 启动 Agent（家中 PC）

```bash
cd poc
export DEEPSEEK_API_KEY="sk-xxx"
go build -o ollama-agent/ollama-agent.exe ./ollama-agent/
./ollama-agent/ollama-agent.exe
```

Agent 启动后会在终端打印配对二维码 URI。

### 2. 构建 App（手机）

```bash
cd app
flutter pub get
flutter build apk --debug
```

安装 APK → 打开 App → 扫码 → 配对完成。

### 3. 云服务部署

```bash
# 信令服务器
cd poc/signal && go build -o signal-server . && ./signal-server

# TURN 服务器
# 使用 coturn，监听 TCP 3478（UDP 被云厂商封禁时用 TCP）
```

## 目录结构

```
CorssLink/
├── app/                  # Flutter 移动端
│   └── lib/
│       ├── models/       # 数据模型 (Pairing, Protocol)
│       ├── services/     # 核心服务 (WebRTC, Crypto, History)
│       ├── screens/      # 页面 (Home, Chat, Sessions, Abilities, Settings)
│       └── widgets/      # UI 组件 (AnimatedMessenger, StatusPulse...)
├── poc/                  # Go 后端（POC）
│   ├── ollama-agent/     # 主 Agent（DeepSeek 代理）
│   ├── peer/             # WebRTC Peer 库
│   ├── signal/           # 信令服务器
│   ├── ollama/           # 协议定义 + Ollama 客户端
│   ├── pairing/          # NaCl 配对加密
│   └── cloud/            # DeepSeek 云后端
├── docs/                 # 产品文档
├── scripts/              # 部署脚本
└── signal/               # 信令 Docker 配置
```

## 技术栈

| 层 | 技术 |
|----|------|
| 移动端 | Flutter 3.12, flutter_webrtc, flutter_markdown |
| Agent | Go 1.24, pion/webrtc v4, gorilla/websocket |
| 信令 | Go + gorilla/websocket, TCP Keepalive |
| 加密 | NaCl Box (Curve25519 + XSalsa20-Poly1305) |
| P2P | WebRTC DataChannel, TURN/TCP 中继 |

## 版本

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0.0 | 2026-06-17 | 首个可用版本：扫码配对、多会话聊天、Markdown、模型管理、断线重连、主题色 |

## License

MIT
