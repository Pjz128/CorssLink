# CrossLink Project Context (AI Reading Guide)

> 目标：让新的 AI 会话在 30 秒内理解项目全貌。阅读顺序：架构 → 关键文件 → 当前状态 → 工作流。

## 架构概览

```
手机 (Flutter) ──HTTP/SSE──► 云中继 crosslink.cyou:18080 ──WebSocket──► PC Agent (Go)
                                 (poc/relay/)                         (poc/ollama-agent/)
                                                                           │
                                                                  AgentRegistry (poc/plugin/)
                                                               ┌───────┬──────────┬──────────┐
                                                               │       │          │          │
                                                           Claude   DeepSeek   Ollama    (可扩展)
                                                          (CLI子进程) (云端API) (本地HTTP)

Dashboard (Web): http://crosslink.cyou:18080/dashboard
  ├─ 用户登录/鉴权 (admin + 多用户)
  ├─ 设备管理 (Agent 认领/归属隔离)
  ├─ 一键部署 (个性化 Agent zip + 自动归属令牌)
  └─ 下载分发 (Windows Agent + Android APK + QR 扫码)

App 交互流程:
  Home → 扫码配对 → AgentSelectScreen → ChatScreen (按 Agent 类型路由)
```

**双模式**：RELAY_ADDR 不为空 → 中继模式（手机通过云访问 Agent）；为空 → LAN 模式（手机直连 Agent HTTP）。

**Agent Plugin 架构**：每种 AI 后端作为独立 Plugin（`poc/plugin/`），统一 `AgentPlugin` 接口。新增后端只需实现接口 + 一行注册。

**协议层次**：
- 手机 ↔ 中继：HTTP POST（请求）+ SSE（流式响应）
- 中继 ↔ Agent：WebSocket 双向通道
- Agent ↔ Claude CLI：stdin/stdout `stream-json` 协议

## 关键文件地图

### Go 后端 (poc/)

| 文件 | 作用 | 关键点 |
|------|------|--------|
| `ollama-agent/main.go` | Agent 入口 | Plugin Registry → pairToken 持久化(`agent_pair_token`) → relay/LAN |
| `plugin/plugin.go` | Plugin 接口 | `AgentPlugin`(嵌入Backend) + `EventPlugin` + `UsagePlugin` |
| `plugin/registry.go` | Plugin 注册中心 | `Register→Init`, `Get`, `List`, `CloseAll` |
| `plugin/claude/claude.go` | Claude Plugin | 多会话管理(创建/切换/删除)，子进程生命周期 |
| `plugin/deepseek/deepseek.go` | DeepSeek Plugin | 无状态云端 API |
| `plugin/ollama/ollama.go` | Ollama Plugin | 本地 HTTP 代理，Init 自动检测 |
| `agent/server.go` | HTTP+SSE 服务器 | `/api/pair` `/api/chat` `/api/claude/sessions`，session-agent 绑定 |
| `agent/relay_bridge.go` | 中继桥接 | WebSocket→HTTP + DeployToken 自动认领 |
| `agent/claude/session.go` | Claude CLI 集成 | 子进程、事件循环、工具执行、权限(allow/deny/abort 三态) |
| `relay/main.go` | 云中继 | Hub + Dashboard + Auth + Download + Deploy + WS 稳定性修复 |
| `relay/auth.go` | 用户认证 | UserStore(bcrypt) + SessionManager + OwnershipManager + DeployTokens |
| `relay/dashboard.html` | Web 管理面板 | 内嵌 SPA：登录、设备、部署、下载分发 |

### Flutter 前端 (app/lib/)

| 文件 | 作用 |
|------|------|
| `screens/chat_screen.dart` | **Claude 专版**聊天 UI：SSE 流、Dialog 权限弹窗、模型 ChoiceChip、`/` 命令反馈 |
| `screens/agent_select_screen.dart` | Agent 选择页：配对后先选 Agent，按类型路由到对应 ChatScreen |
| `screens/home_screen.dart` | 设备列表 → AgentSelectScreen |
| `screens/scan_screen.dart` | QR 扫码配对 |
| `services/http_service.dart` | HTTP 客户端：chat SSE、sendChoice(trustSession)、Claude 会话 CRUD |
| `widgets/permission_panel.dart` | 权限侧边栏（旧版，已被 Dialog 取代） |

## 数据流

### 配对（修复后）
```
Agent 启动 → 加载 agent_pair_token（持久化，跨重启不变）
  → Relay 注册（token 稳定）
  → Dashboard QR 永久有效
  → 手机扫码 → POST /api/pair → 成功
```

### 权限交互（三态 Dialog）
```
Claude tool_use → choice-req → App showDialog
  → 允许(allow): 执行 → tool_result → Claude 继续
  → 暂停(deny):  关闭弹窗 → Claude 等待 → 用户稍后允许
  → 拒绝(abort): 发送 error → Claude 继续（带错误）
  无超时，永久等待
```

## 当前状态

- **版本**: 1.3.0 | **域名**: crosslink.cyou:18080
- **Agent**: pairToken 持久化，稳定连接
- **App**: Agent 选择前置 + Claude 专版会话 + Dialog 权限弹窗
- **Relay**: WebSocket 稳定性修复(`unregisterAgent` conn 指针精确删除)
- **调试**: `flutter build apk --debug && adb install`

## 关键约定
- 用户中文交互，代码注释中文
- 新增 Agent: 实现 `plugin.AgentPlugin` + 一行 `registry.Register()`
- ChatScreen = Claude 专版，未来 Agent (Codex) 可自建 ChatScreen
- Agent 选择在 `_routeFor()` 中路由分发
- pairToken 持久化到 `agent_pair_token`，重启不变
- APK 本地 `adb install`，不上传服务器
