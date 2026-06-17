# CrossLink vs Happy Coder — 竞品对比分析

> 日期：2026-06-14
> 分析对象：[slopus/happy](https://github.com/slopus/happy) (21.9k ⭐, MIT License)
> 目的：识别可借鉴的设计模式，明确差异化定位，为后期宣传储备素材

---

## 一、项目概况

| 维度 | **Happy Coder** | **CrossLink** |
|------|-----------------|---------------|
| 一句话定位 | 手机远程控制 Claude Code/Codex 编程会话 | 手机远程访问家里 PC 的 Ollama AI 模型 |
| 开源协议 | MIT | 专有（$59-99 买断） |
| GitHub Stars | 21,886 | — |
| 主要语言 | TypeScript (99%) | Go + Dart (Flutter) |
| 仓库规模 | 6 个包 (monorepo) | 4 个模块 (monorepo) |
| 活跃度 | 持续维护 (2026-06 仍活跃) | 开发中 |
| 官网 | happy.engineering | — |
| 已上架 | iOS App Store + Google Play | — |

---

## 二、架构对比

### 通信拓扑

```
Happy Coder — 中心服务器中转:
  CLI ──Socket.IO──→ Fastify Server ←──Socket.IO── Mobile App
                          │
                     Postgres + Redis

CrossLink — P2P 直连:
  Agent ──WebRTC DataChannel──→ Mobile App
    │            ↑                    │
    └─WS信令──→ Signal Server ←──WS信令─┘
```

| 特性 | Happy | CrossLink | 优势 |
|------|-------|-----------|------|
| 数据路径 | 服务器中转 | 点对点直连 | CrossLink 数据不过服务器 |
| 延迟 | 受服务器位置影响 | 取决于 NAT 后网络 | CrossLink 局域网可零延迟 |
| 隐私性 | 服务器存储加密数据 | 服务器仅做信令 | CrossLink 隐私更强 |
| 离线可用 | 依赖服务器在线 | 局域网可直连 | CrossLink 可完全离线 |
| 部署复杂度 | 需要 Postgres + Redis + Node.js | 仅需一个 Go 信令二进制 | CrossLink 运维更简单 |

### 整体架构

```
Happy Coder:
  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐
  │  happy-cli   │  │  happy-app   │  │  happy-server    │
  │  (npm 全局)  │  │  (Expo RN)   │  │  (Fastify+Prisma)│
  │              │  │              │  │                   │
  │  · CLI 入口  │  │  · 移动端    │  │  · REST API       │
  │  · daemon    │  │  · Web 端    │  │  · Socket.IO      │
  │  · 加密层    │  │  · 加密层    │  │  · 事件路由       │
  │  · Socket.IO │  │  · Socket.IO │  │  · 数据库         │
  └─────────────┘  └──────────────┘  └──────────────────┘
         │                │                    │
         └────────────────┼────────────────────┘
                          │
                    happy-wire (共享协议)

CrossLink:
  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐
  │   agent/     │  │    app/       │  │   signal/        │
  │  (Go+Wails)  │  │  (Flutter)    │  │  (Go+WebSocket)  │
  │              │  │              │  │                   │
  │  · 托盘应用  │  │  · 移动端    │  │  · 信令服务器     │
  │  · WebRTC    │  │  · WebRTC    │  │  · STUN/TURN     │
  │  · Ollama代理│  │  · 扫码配对  │  │  · 对等路由       │
  │  · License   │  │  · 聊天UI    │  │                   │
  └─────────────┘  └──────────────┘  └──────────────────┘
         │                │                    │
         └──WebRTC P2P────┘                    │
              (直连数据)                       │
         └──────────WS信令─────────────────────┘
```

---

## 三、设备配对流程对比

### Happy 的 QR 配对流程

```
桌面 CLI                    Happy Server                 手机 App
   │                            │                            │
   │ ① 生成临时 NaCl 密钥对      │                            │
   │ ② POST 公钥 ──────────────→│ (存 TerminalAuthRequest)    │
   │ ③ 显示 QR(公钥的 base64)    │                            │
   │                            │             ④ 扫码获取公钥 ─→│
   │                            │             ⑤ POST 自己的公钥─→│
   │                            │             ⑥ 轮询等待授权 ──→│
   │ ⑦ 轮询等待 ───────────────→│                            │
   │                            │        ⑧ 用户点击"批准" ───→│
   │                            │        ⑨ 加密长期凭证 ────→│
   │ ⑩ 收到加密凭证 ────────────→│                            │
   │ ⑪ NaCl box 解密得 token     │                            │
   └────────────────────────────┴────────────────────────────┘
```

**关键设计：**
- QR 码仅包含临时公钥（不直接放 token）
- 服务器仅做"会合点"——存储 `公钥 → 加密响应` 映射，**不解密任何内容**
- 双向轮询等待确认
- NaCl box 加密传递长期凭证，中间人即使截获也无法解密

### CrossLink 的配对方案（借鉴 + 简化）

```
Agent 桌面端               Signal Server               Mobile App
   │                            │                            │
   │ ① 生成临时 NaCl 密钥对      │                            │
   │ ② 显示 QR(公钥+信令地址)    │                            │
   │                            │             ③ 扫码 ────────→│
   │                            │             ④ 连接信令服务器─→│
   │                            │ ←────────── ⑤ 发送配对请求 ─│
   │ ←────── ⑥ 转发配对请求 ────│                            │
   │ ────── ⑦ 交换 SDP/ICE ───→│ ←────── ⑧ 交换 SDP/ICE ────│
   │                            │                            │
   │ ←══════════ ⑨ WebRTC DataChannel 直连 ═══════════════→│
   │                            │                            │
   │ ←════ ⑩ NaCl box 加密交付长期 token(通过 DataChannel) ═→│
   └────────────────────────────┴────────────────────────────┘
```

**CrossLink 优于 Happy 的改进：**
- 配对完成后数据不再经过服务器（Happy 一直是服务器中转）
- 局域网配对时可以完全不用服务器（mDNS 发现 + 直连交换 SDP）
- 第⑦⑧步的 SDP/ICE 交换利用了已有的 WebRTC 基础设施，不增加复杂度

---

## 四、加密方案对比

| 加密层 | Happy | CrossLink |
|--------|-------|-----------|
| **密钥交换** | NaCl box (Curve25519-XSalsa20-Poly1305) | WebRTC DTLS (传输层) + NaCl box (应用层) |
| **消息加密** | secretbox (XSalsa20-Poly1305) / AES-256-GCM | DTLS-SRTP (WebRTC 内置) |
| **密钥派生** | HMAC-SHA512 树 (类 BIP32) | PBKDF2 (license key) + 待实现 |
| **数字签名** | Ed25519 | Ed25519 (license 签名) |
| **哈希** | HMAC-SHA512 | SHA-256 |
| **库** | tweetnacl.js + libsodium (native) | `golang.org/x/crypto/nacl/box` + `crypto/ed25519` |
| **License 加密** | 无 (MIT 开源) | AES-256-GCM + 硬件指纹绑定 |
| **客户端加密** | 是 (消息体 E2E 加密) | 是 (WebRTC 固有 + 可选应用层) |
| **服务器可见性** | 零（服务器只存加密 blob） | 零（服务器只做信令，不存数据） |

**值得借鉴的 Happy 设计：**

1. **密钥派生树** (`deriveKey.ts`)：
   ```
   Root = HMAC-SHA512("usage" + " Master Seed", masterKey)
   Child[i] = HMAC-SHA512(Root.chainCode, 0x00 || i)
   ```
   可用于 CrossLink 的"一个 Agent → 多个 App 设备"场景，每个设备独立派生密钥路径。

2. **多算法演进路径**：Happy 同时支持 legacy (secretbox) 和 v2 (AES-GCM)，通过版本字节区分。CrossLink 应在协议里预留算法版本字段。

3. **二进制布局规范**：
   ```
   Happy blob: [ ephemeralPubKey(32) | nonce(24) | ciphertext ]
   ```
   显式、稳定的二进制布局利于跨版本互操作。

---

## 五、技术栈逐层对比

### 桌面端

| 维度 | Happy CLI | CrossLink Agent |
|------|-----------|-----------------|
| 语言 | TypeScript (Node.js) | Go |
| 分发方式 | `npm install -g happy` | MSI/DMG/AppImage 安装包 |
| GUI | 终端 + Web UI | Wails v3 原生窗口 + 系统托盘 |
| 后台运行 | daemon 子进程 + lock file | 托盘应用常驻 + 可选 Windows Service |
| 内存占用 | ~80-150 MB (Node.js) | ~20-40 MB (Go) |
| AI 集成 | SDK 直接调用 (Claude Agent SDK) | HTTP 代理 Ollama API |

**Happy CLI 的 daemon 模型值得借鉴：**
- lock file 防止多实例 (`~/.happy/daemon.lock`)
- 本地 HTTP 控制服务器用于进程间通信
- 心跳 + 自动重启 + 版本检测更新
- session 状态文件持久化，重启后可恢复

### 移动端

| 维度 | Happy App | CrossLink App |
|------|-----------|---------------|
| 框架 | Expo SDK 55 (React Native) | Flutter |
| 导航 | expo-router (文件路由) | go_router 或 auto_route |
| 状态管理 | zustand + MMKV | Riverpod 或 Bloc |
| UI 样式 | unistyles + nativewind | Material Design 3 |
| 加密库 | @more-tech/react-native-libsodium | pointycastle / cryptography_flutter |
| WebRTC | @livekit/react-native-webrtc (仅语音) | flutter_webrtc (核心功能) |
| 动画 | reanimated v4 + Lottie | Flutter 内置 + Lottie |
| iOS 上架 | ✅ | 🔜 TODO |
| Android 上架 | ✅ | 🔜 待开发 |
| Web 端 | ✅ react-native-web | ❌ (不在 MVP 范围) |

### 服务端

| 维度 | Happy Server | CrossLink Signal |
|------|-------------|------------------|
| 语言 | TypeScript (Node.js) | Go |
| 框架 | Fastify v5 | gorilla/websocket + net/http |
| 数据库 | Postgres + Redis | 无（无状态信令） |
| 自托管 | PGlite (嵌入式 PG via WASM) | 单二进制 |
| 存储 | MinIO (S3 兼容) | 不存储用户数据 |
| 验证 | Zod v4 | Go struct tags |
| 监控 | Prometheus | 待定 |
| 消息推送 | expo-server-sdk | 待定 |

**Happy Server 中值得借鉴的：**
- **PGlite**：嵌入式 PostgreSQL，可用于 CrossLink Agent 本地存储（备选 SQLite）
- **Zod 验证**：Go 端可用 `go-playground/validator` 达到类似效果
- **Prisma 迁移**：Go 端可用 `golang-migrate` 或 `atlas`

---

## 六、消息协议对比

### Happy 的 session 事件类型

```typescript
// Happy sessionProtocol.ts 定义的 9 种事件类型：
type SessionEvent =
  | { t: 'text', text: string }                    // 文本内容（支持 Markdown）
  | { t: 'service', service: string, ... }         // 服务消息
  | { t: 'tool-call-start', id, name, args }      // 工具调用开始
  | { t: 'tool-call-end', id, result }            // 工具调用结束
  | { t: 'file', name, ref, width?, height?, ... }// 文件/图片
  | { t: 'turn-start', id, ... }                  // 对话轮次开始
  | { t: 'start', ... }                           // Agent 启动
  | { t: 'turn-end' }                             // 轮次结束
  | { t: 'stop' }                                 // Agent 停止
```

### CrossLink 的 Ollama 代理协议 (设计参考)

```json
// CrossLink DataChannel 消息格式（建议）:
{
  "id": "<cuid2>",
  "time": 1700000000000,
  "type": "chat|stream|status|error",
  "payload": {
    // chat: { model, messages[], stream }
    // stream: { token, done }
    // status: { models[], gpu, memory }
    // error: { code, message }
  }
}
```

---

## 七、差异化定位

| 独特卖点 | Happy Coder | CrossLink |
|----------|-------------|-----------|
| **数据隐私** | 加密但经服务器 | 端到端 P2P，不经服务器 |
| **模型选择** | 依赖 Claude/Codex API | 用户自己的 Ollama 模型 |
| **运行成本** | 免费 + 语音付费 | 一次性 $59-99 买断 |
| **离线可用** | 不支持 | 局域网可离线直连 |
| **部署难度** | npm install 即可 | 安装包一键部署 |
| **自主权** | 依赖第三方 AI 服务 | 完全自托管 |
| **企业应用** | 不适合（数据经第三方） | 适合（私有化部署） |

---

## 八、宣传素材要点

### CrossLink 对比 Happy 的核心优势

1. **真正的隐私**："Happy 的代码经过服务器，CrossLink 的数据直接从你家电脑到你手机，不经过任何中间服务器"
2. **你自己的模型**："Happy 用的是 Claude/Codex 的云端模型，CrossLink 用的是你自己的 Ollama 模型——你完全掌控 AI"
3. **一次付费**："Happy 语音功能需要订阅，CrossLink 一次买断，永久使用"
4. **离线可用**："断网也能用——只要手机和电脑在同一 WiFi 下"
5. **企业就绪**："CrossLink 支持私有化部署，数据不出企业内网"

### Happy 做得更好、需要追赶的

1. **上架完成度**：Happy 已上架 App Store + Google Play，CrossLink 还未开始
2. **社区生态**：21.9k Stars, 1828 Forks，活跃的 Discord 社区
3. **多 AI 提供商**：支持 Claude Code / Codex / Gemini / OpenClaw
4. **功能丰富度**：语音交互、推送通知、会话历史、支付集成
5. **Web 端**：支持浏览器访问，降低使用门槛

---

## 九、行动计划

| 优先级 | 行动项 | 参考 Happy |
|--------|--------|-----------|
| **P0** | QR 码配对协议实现 | `authQRStart.ts` + `authQRWait.ts` + NaCl box 模式 |
| **P0** | Agent daemon 后台服务 | `daemon/run.ts` — lock file + HTTP 控制 + 心跳 |
| **P1** | DataChannel 消息协议 | `sessionProtocol.ts` 事件类型设计 |
| **P1** | 多设备密钥管理器 | `deriveKey.ts` 的密钥派生树 |
| **P2** | App ↔ Agent RPC 框架 | `RpcHandlerManager.ts` 注册/重连/调用模型 |
| **P2** | 本地存储方案 | PGlite 自托管 vs SQLite 选型 |
| **P3** | 语音交互 | ElevenLabs SDK vs WebRTC 原生音频 |
| **P3** | 消息推送 | expo-server-sdk vs FCM 直连 |
| **不采纳** | Socket.IO 中转架构 | 坚持 WebRTC P2P 核心差异点 |

---

## 十、参考资料

- Happy 主仓库: https://github.com/slopus/happy
- Happy 文档: https://happy.engineering/docs/
- Happy App (iOS): https://apps.apple.com/us/app/happy-claude-code-client/id6748571505
- Happy App (Android): https://play.google.com/store/apps/details?id=com.ex3ndr.happy
- Happy 加密设计: `packages/happy-wire/src/` + `docs/encryption.md`
- Happy 协议设计: `docs/protocol.md` + `docs/session-protocol.md`
