# CrossLink Project Context (AI Reading Guide)

> 目标：让新的 AI 会话在 30 秒内理解项目全貌。阅读顺序：架构 → 关键文件 → 当前状态 → 工作流。

## 架构概览

```
手机 (Flutter) ──HTTP/SSE──► 云中继 45.197.144.16:18080 ──WebSocket──► PC Agent (Go)
                                 (poc/relay/)                         (poc/ollama-agent/)
                                                                           │
                                                                    BackendPool (poc/agent/pool/)
                                                                   ┌───┬───────┬──────────┐
                                                                   │   │       │          │
                                                               Ollama  Claude  DeepSeek   (未来)
                                                              (本地)  (CLI子进程) (云端API)
```

**双模式**：RELAY_ADDR 不为空 → 中继模式（手机通过云访问 Agent）；为空 → LAN 模式（手机直连 Agent HTTP）。

**协议层次**：
- 手机 ↔ 中继：HTTP POST（请求）+ SSE（流式响应）
- 中继 ↔ Agent：WebSocket 双向通道，消息类型：`req`/`res`/`res-start`/`res-chunk`/`res-end`/`err`/`cancel`
- Agent ↔ Claude CLI：stdin/stdout `stream-json` 协议

## 关键文件地图

### Go 后端 (poc/)

| 文件 | 作用 | 关键点 |
|------|------|--------|
| `ollama-agent/main.go` | Agent 入口 | 初始化 BackendPool → 选择 relay/LAN 模式 → 显示 QR |
| `agent/server.go` | HTTP+SSE 服务器 | `/health` `/api/pair` `/api/chat`(SSE) `/api/choice` `/api/agents` `/api/sessions` |
| `agent/relay_bridge.go` | 中继桥接 | WebSocket→HTTP 转换，`relayResponseWriter` 实现双模式(流/非流)响应 |
| `agent/claude/session.go` | Claude CLI 集成 | 子进程管理、事件循环、工具执行(Bash/Read/Write/Grep/Glob)、权限系统 |
| `agent/claude/parser.go` | stream-json 解析 | 解析 Claude stdout → ParseEvent(init/thinking/text/tool_use/tool_input/tool_stop/done/result) |
| `agent/claude/types.go` | Claude 线格式 | `claudeMsg`, `streamEvent`, `userMsg`, `toolResultBlock` |
| `agent/pool/pool.go` | 后端多路复用 | `Register/Get/Default/ListAgents` |
| `ollama/protocol.go` | 跨端消息协议 | `WireMessage`, MsgType 常量(chat-req/tok/done, thinking, tool-*, choice-req) |
| `ollama/handler.go` | 消息路由器 | 分派 chat/list/status/ping，转发 BackendEvent |
| `ollama/extended.go` | ExtendedBackend 接口 | `SetEventCallback`, `LastUsage()` |
| `ollama/proxy.go` | Ollama REST 客户端 | 本地 Ollama 的 HTTP 代理 |
| `relay/main.go` | 云中继 | Hub(agent/session/pending 映射), HTTP→WS 转发, SSE 中继, `/api/choice` |
| `cloud/deepseek.go` | DeepSeek 云端后端 | OpenAI 兼容 API 封装 |
| `pairing/` | NaCl 加密配对 | Curve25519+XSalsa20+Poly1305，密钥文件和设备存储 |
| `peer/peer.go` | WebRTC Peer | **v1 旧版**，pion/webrtc 封装，基本不再使用 |
| `signal/main.go` | WebSocket 信令 | **v1 旧版**，已被 relay 取代 |

### Flutter 前端 (app/lib/)

| 文件 | 作用 |
|------|------|
| `screens/chat_screen.dart` | 核心聊天 UI (1200 行)：SSE 流渲染、bubble 系统、权限卡片、快捷栏、模型切换 |
| `screens/home_screen.dart` | 设备列表、配对入口 |
| `screens/scan_screen.dart` | QR 扫码配对 |
| `screens/settings_screen.dart` | 中继地址、模型、主题色 |
| `services/http_service.dart` | HTTP v2 客户端：`chatStream()`(SSE)、`sendChoice()`、`fetchAgents()` |
| `services/webrtc_service.dart` | WebRTC v1 旧版客户端 |
| `models/protocol.dart` | 消息类型常量、WireMessage、ToolCallEvent、ChoiceRequestEvent |
| `widgets/permission_card.dart` | 权限卡片：Allow/Deny 按钮，工具彩色边框 |
| `widgets/tool_call_card.dart` | 工具调用卡片：展开 JSON、按工具名着色 |
| `widgets/tool_result_card.dart` | 工具结果卡片：可展开，复制按钮 |
| `widgets/thinking_block.dart` | 思考块：可折叠，流式自动展开 |
| `widgets/agent_picker.dart` | 两级选择器：Agent 类型 + Model |

### 部署配置

| 文件 | 作用 |
|------|------|
| `start.bat` | Windows 一键启动：构建→健康检查→启动 Agent |
| `.env` | `DEEPSEEK_API_KEY=sk-...` (gitignored) |
| `Makefile` | 构建目标：relay/signal/agent/app，单元测试 |
| `scripts/deploy-cloud.sh` | 云端部署：交叉编译→scp→systemd |
| `relay/Dockerfile` | Relay Docker 镜像 |

## 数据流详解

### 一次聊天请求的完整路径
```
1. 手机 POST /api/chat {messages:[...]}  Authorization: Bearer <sessionToken>
2. Relay 根据 sessionToken 找到 agent WebSocket → 转发 req{rid, method, path, headers, body}
3. Agent relay_bridge 收到 req → 构建 http.Request → Server.Handler().ServeHTTP(w, req)
4. Server.handleChat → SSE 响应头 → backend.ChatStream() → tokenCh/errCh
5. Session.ChatStream → 写用户消息到 Claude stdin → 返回 tokenCh
6. eventLoop 读 Claude stdout → 解析 stream-json → tokenCh ← text/thinking 事件
7. Server 读 tokenCh → sseWriter.writeEvent("chat-tok", token) → relayResponseWriter.Write()
8. relayResponseWriter.Flush() → base64 → WS res-chunk → Relay → SSE 转写 → 手机
9. 手机 HttpService._parseSSE → utf8.decoder → LineSplitter → jsonDecode → WireMessage → UI
```

### 工具调用路径
```
Claude emits: content_block_start(tool_use) → input_json_delta(多次) → content_block_stop
    → message_delta(stop_reason="tool_use") → message_stop

eventLoop 处理:
  tool_use  → 存 toolName, emit tool-use 事件
  tool_input → 累积 partial_json
  tool_stop → go executeAndRespond(toolID, toolName, input)
       │
       ├─ needsPermission? → 是 → requestPermission() → emit choice-req → 等手机响应（60s超时）
       │                      ↓否
       └─ execTool() → sendToolResult(写 Claude stdin) → emit tool-result 事件
```

### 权限系统
- **安全工具**（直接执行）：Read, Grep, Glob
- **危险工具**（弹窗确认）：Bash, Write, Edit
- 权限请求：`executeAndRespond → requestPermission → emitEvent("choice_request") → 手机 PermissionCard → /api/choice → SubmitChoice → channel`
- 超时 60s，自动拒绝

## 当前状态

### 运行环境
- 云中继：45.197.144.16:18080（systemd: crosslink-relay）
- Agent：Windows PC，通过 RELAY_ADDR=ws://45.197.144.16:18080/agent 连接
- 手机：APK 已编译安装，扫码配对

### 已知问题
1. **execBash 在 Windows 上**：使用 `cmd /c`，但某些 bash 命令语法不兼容
2. **无 TLS**：所有 HTTP/WS 明文传输
3. **测试覆盖低**：仅 `pairing_test.go` 和 `proxy_test.go` 有测试
4. **Claude 模型显示异常**：session 启动时 model 显示为 `deepseek-v4-pro`（可能是 Claude CLI 默认值）
5. **v1 残留代码**：`peer/` `signal/` `pairing/` `webrtc_service.dart` 仍保留但基本不用

### 提交历史
```
26a4b04 v1.2.2: 权限系统重构 + SSE 编码修复 + 快捷栏紧凑化
c419707 v1.2.1: 权限交互支持 + 工具调用修复 + 快捷操作栏
ec6fd05 v1.2.0: 云中继 + 移动端 UI 优化 + 工具执行修复
24f4449 v1.0.0: CrossLink 跨端 AI 互联工具
```

## 开发工作流

### 日常迭代（改代码→测试）
```bash
# 1. 仅改了 Flutter → 直接构建 APK 安装
cd app && flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk

# 2. 改了 Go Agent 侧 → 重启 Agent
cd poc && taskkill /f /im ollama-agent.exe
source ../.env && export RELAY_ADDR=ws://45.197.144.16:18080/agent
go run ./ollama-agent/

# 3. 改了 Relay 侧 → 重新部署到云端
cd poc && GOPROXY=https://goproxy.cn,direct GOOS=linux GOARCH=amd64 go build -o ../bin/crosslink-relay ./relay/
ssh root@45.197.144.16 'systemctl stop crosslink-relay'
scp ../bin/crosslink-relay root@45.197.144.16:/root/crosslink/relay-server
ssh root@45.197.144.16 'chmod +x /root/crosslink/relay-server && systemctl start crosslink-relay'

# 4. 全流程（含 APK）
cd app && flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

### Go 构建注意事项
- 始终在 `poc/` 目录下运行 `go build`
- 使用 `GOPROXY=https://goproxy.cn,direct`（国内代理）
- Relay 交叉编译：`GOOS=linux GOARCH=amd64`
- Go module 名：`crosslink-poc`

### Flutter 构建注意事项
- 始终在 `app/` 目录下运行 `flutter` 命令
- 使用 `flutter build apk --debug`（debug 模式更快）
- `flutter analyze` 不应有新 error

## 消息类型速查

| Go 常量 | Flutter 常量 | 方向 | 含义 |
|---------|-------------|------|------|
| `chat-req` | `chatRequest` | → | 聊天请求 |
| `chat-tok` | `chatToken` | ← | 流式 token |
| `chat-done` | `chatDone` | ← | 流结束 |
| `chat-err` | `chatError` | ← | 错误 |
| `thinking` | `thinking` | ← | Claude 思考 token |
| `tool-use` | `toolUse` | ← | 工具调用开始 |
| `tool-input` | `toolInput` | ← | 工具输入 JSON |
| `tool-result` | `toolResult` | ← | 工具执行结果 |
| `choice-req` | `choiceRequest` | ← | 权限请求(手机→用户选择) |
| `list-req` | `listModels` | → | 请求模型列表 |
| `list-res` | `listResponse` | ← | 模型列表响应 |

## 关键约定
- 用户中文交互，代码注释中文
- 工具执行在 Agent PC 本地，Bash 走 `cmd /c`（Windows）
- 会话通过 `Authorization: Bearer <sessionToken>` 认证
- 配对 token 由 Agent 生成，通过 QR 码传递
- `.env` 在 .gitignore 中，`start.bat` 通过 source 加载
