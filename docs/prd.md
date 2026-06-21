# CrossLink PRD — 产品需求文档

> 版本: 1.4.0 | 更新: 2026-06-21
> 跨端互联工具：手机远程操控 PC 端 AI Agent，扫码即用，数据自主可控。

## 产品概述

CrossLink 是一个跨端 AI 互联工具。手机通过云端中继远程操控 PC 端的 AI Agent（Claude Code / DeepSeek / Ollama），实现移动端 AI 编程与工具执行。

## 功能架构

### 1. 多 Agent 架构 (Plugin 模式)

| Agent | 类型 | 能力 | 会话特点 |
|-------|------|------|---------|
| Claude Code | CLI 子进程（有状态） | chat + thinking + tools | 多会话管理，每会话独立子进程 |
| DeepSeek | 云端 API（无状态） | chat | 无状态 HTTP |
| Ollama | 本地 HTTP（无状态） | chat + vision | 自动检测可用性 |

**扩展性**: 新增 Agent 只需 `plugin.AgentPlugin` + 一行 `registry.Register()`。

### 2. App 交互架构

```
Home（设备列表）
  → 扫码配对（QR 永久有效，pairToken 持久化）
  → AgentSelectScreen（按类型显示卡片）
  → ChatScreen（Claude 专版 / 未来 Codex 等自建）
```

- **Agent 选择前置**：配对后先选 Agent，再进入对应会话
- **ChatScreen = Claude 专版**：完整 tool/thinking/permission 支持
- **权限弹窗**：阻断式 Dialog，三按钮（允许/暂停/拒绝），暂停时不发 tool_result

### 3. 用户系统

- Dashboard 登录 + session cookie (24h)
- 用户归属隔离：只看自己的 Agent
- 部署令牌：一键下载个性化 zip，Agent 启动自动认领
- pairToken 持久化：QR 码永久有效，重启不变

### 4. 权限系统

- 安全工具（自动）：Read, Grep, Glob
- 危险工具（审批）：Bash, Write, Edit
- Dialog 弹窗替代侧边栏，弹出时自然暂停会话
- 三项操作：**允许**(执行) / **暂停**(等待) / **拒绝**(错误)
- 无超时，永久等待用户决策

### 5. Web Dashboard

`http://crosslink.cyou:18080/dashboard`

- 我的设备 + 一键部署 + 下载分发 + 用户管理

## 关键修复记录

| 版本 | 修复 |
|------|------|
| v1.4.0 | pairToken 持久化→QR 永久有效；App Agent 选择前置+Dialog 权限 |
| v1.3.0 | Plugin 架构、用户系统、Dashboard、Claude 多会话 |
| v1.2.x | 权限重构、SSE 修复、云中继 |

## 技术栈

| 层 | 技术 | 
|----|------|
| 手机端 | Flutter 3.44 / Dart 3.12 |
| 云中继 | Go 1.24 / gorilla/websocket / bcrypt |
| PC Agent | Go 1.24 / Claude CLI subprocess |
| Dashboard | 内嵌 HTML+CSS+JS (Go embed) |
| 存储 | JSON 文件 + 持久化 pairToken |
