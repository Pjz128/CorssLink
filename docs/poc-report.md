# CrossLink POC 验证报告

> 日期：2026-06-14
> 目标：验证 WebRTC + 信令服务器 端到端连通性

---

## 测试结果：✅ 通过

### 测试环境

| 项目 | 值 |
|------|-----|
| OS | Windows 11 Home |
| Go | 1.24.5 |
| WebRTC 库 | pion/webrtc v4.1.3 |
| STUN | stun.l.google.com:19302 |
| 信令 | 自建 WebSocket 服务器 (localhost:18080) |

### 直连测试（进程内 WebRTC，无信令）

```
ICE candidates: host 192.168.1.116, host 172.19.144.1, srflx 120.244.61.149
ICE state: connected ✅
DataChannel: opened ✅
Ping-pong: 4/5 successful (第 1 个因时序丢失)
RTT: ~0ms（同机）
```

### 信令测试（WebSocket 信令 + WebRTC）

```
Signal server: offer/answer/candidate 全量路由 ✅
ICE state: checking → connected ✅
DataChannel: opened ✅
Ping-pong: 10/10 successful ✅
RTT: ~0ms（同机）
```

### 修复的关键问题

| 问题 | 原因 | 修复 |
|------|------|------|
| ICE candidate 未路由 | 信令服务器 `ICECandidate` 字段类型错误（string vs object） | 改为 `json.RawMessage` |
| WebSocket 并发写崩溃 | gorilla/websocket 不支持并发写 | 加 `signalWriteMu` 写锁 |
| connected channel 重复关闭 | ICE 和 DataChannel 回调都触发 onConnect | 用 `sync.Once` 防重入 |

### 发现的公网 IP（通过 STUN）

```
120.244.61.149 (srflx candidate)
```

证明 STUN 工作正常，NAT 后设备可以获取公网映射地址。

---

## 配对测试（QR Code + NaCl Box）

```
日期: 2026-06-14
目标: 验证 QR 码配对协议端到端流程
```

### 协议流程

```
Agent (桌面端)              Signal Server            Client (手机模拟)
   │                            │                         │
   │ ① 生成 NaCl 密钥对         │                         │
   │ ② 显示 QR(pk + signal)     │                         │
   │                            │           ③ 扫码 ──────→│
   │                            │           ④ 生成密钥对 ──→│
   │                            │ ← ⑤ pairing-request ───│
   │ ← ⑥ 转发 pairing-request ─│                         │
   │ ⑦ 加密 long-term token ──→│── ⑧ 转发 ──────────────→│
   │                            │           ⑨ NaCl box 解密→│
   │                            │                         │ ✅
```

### 测试结果：✅ 通过

```
Agent: pairing request received from mobile-001 (iPhone 15 Pro)
Agent: pairing accepted, encrypted token sent
Client: token decrypted successfully
Token:  UzRAPsWUL5nhc7JoS5ZY...
```

### 新增模块

| 模块 | 文件 | 说明 |
|------|------|------|
| `pairing/` | `pairing.go` | NaCl box 加解密、QR 编解码、长期令牌生成 |
| `pairing/` | `store.go` | 加密持久化设备存储 (secretbox + PBKDF2) |
| `pairing/` | `pairing_test.go` | 8 个测试全部通过 |
| `pairing-agent/` | `main.go` | 配对 Agent 端 POC |
| `pairing-client/` | `main.go` | 配对客户端(手机模拟) POC |
| `peer/` | `peer.go` | 新增 `SendSignal()` 和 `OnSignalMessage` |

## Ollama 代理测试

```
日期: 2026-06-14
目标: 验证 Agent 通过 DataChannel 代理 Ollama API
```

### 新增模块

| 模块 | 文件 | 说明 |
|------|------|------|
| `ollama/` | `proxy.go` | Ollama REST API 客户端 (Ping/List/Chat/ChatStream) |
| `ollama/` | `types.go` | 数据类型 (ModelInfo, Message, ChatRequest/Response) |
| `ollama/` | `protocol.go` | CrossLink DataChannel 消息协议 (8 种消息类型) |
| `ollama/` | `handler.go` | 消息处理器 (DataChannel ↔ Ollama API) |
| `ollama/` | `proxy_test.go` | 12 个测试全部通过 |
| `ollama-agent/` | `main.go` | 集成 Agent (配对 + Ollama 代理) |

### 消息协议

```
Client → Agent:  chat-req   { model, messages[], options }
        list-req   {}
        status-req {}

Agent → Client:  chat-tok   { token, index }  (流式)
        chat-done  { totalTokens, duration }
        chat-err   { code, message }
        list-res   { models[] }
        status-res { ollamaAlive, version }
        ping/pong
```

### 关键设计

- DataChannel 上的消息全部 JSON，带 id+time 信封
- 流式响应：Ollama SSE → 逐 token 发 DataChannel → App 实时渲染
- Agent 启动时自动检测本地 Ollama 是否可用
- 无 Ollama 时优雅降级（发送错误消息给客户端）

## 下一步

- [x] QR 码配对协议实现 & 测试
- [ ] 跨 NAT 测试（Agent 在家，Client 用 4G 热点）
- [ ] TURN 中继测试（打洞失败回退）
- [ ] 集成 Ollama 代理
- [ ] Flutter App 扫码配对原型
