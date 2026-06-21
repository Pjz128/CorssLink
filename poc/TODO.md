# CrossLink TODO

> 最后更新：2026-06-21 | 状态：✅ 全部完成

---

## Bug 清单

### #1 `/` 命令无反馈
- 现象：用户输入 `/` 开头命令发送后无任何 UI 反馈
- 方案：消息处理层加前缀检测 + 本地 Toast
- 影响：中 | 状态：✅ 已修复

### #2 权限弹窗频繁 / Android 端不显示
- 现象：PermissionCard 弹出过于频繁；Android 端可能完全不显示权限请求
- 方案：独立权限面板 + 信任本次会话
- 影响：高 | 状态：✅ 已修复

### #3 Android 客户端发送空/null 消息
- 现象：Android 端正常输入，后端收到空内容（本会话 50+ 次）
- 疑似根因：TextField controller 状态丢失 / body 空字段 / 中继截断 / IME 交互 / PermissionCard 打断
- 排查：chat_screen.dart / http_service.dart / relay/main.go / Android logcat
- 影响：严重 | 状态：✅ 已修复

### #4 工具权限请求在 Android 端不显示
- 现象：choice-req 未在 Android 端展示 PermissionCard，60s 超时自动拒绝
- 数据流断点：SSE 解析 / PermissionCard 挂载 / 事件竞争
- 策略：P0 独立权限面板不再依赖消息列表渲染
- 影响：严重 | 状态：✅ 已修复

---

## 解决方案：独立权限侧边栏

架构：权限卡片从消息列表移除，改为右侧独立面板。不参与滚动，不干扰 TextField 状态。
会话信任：勾选后，同工具后续自动放行，不再弹窗。

### 文件改动清单

| 文件 | 操作 | 说明 |
|------|------|------|
| widgets/permission_panel.dart | 新建 | 侧边栏权限面板（200px，滑入动画，60s 倒计时，Trust 勾选） |
| screens/chat_screen.dart | 修改 | 移除消息列表中 PermissionCard；build 改为 Row 布局；新增 _trustedTools |
| widgets/permission_card.dart | 修改 | 新增「信任本次会话」勾选框 |
| services/http_service.dart | 修改 | sendChoice() 增加 trustSession 参数 |
| agent/claude/session.go | 修改 | Session 增加 trustedTools 白名单 |

### 实现优先级

| 优先级 | 内容 | 修复的 Bug |
|--------|------|-----------|
| P0 | 新建 PermissionPanel + chat_screen 集成 | #2 #4 #3 |
| P1 | 会话信任机制 + Go 侧配套 | #2 |
| P2 | 消息发送加非空校验 + 日志 | #3 |
| P3 | `/` 命令本地反馈提示 | #1 |

---

## 排查记录

2026-06-21 Android 端调试会话：
- 环境：Android → 云中继 (45.197.144.16:18080) → PC Agent (Windows)
- 空消息 50-60 条
- 所有 Write/Edit/Bash 权限请求均未在 Android 端显示
- 结论：#3 和 #4 高频复现，权限死锁导致无法通过 AI 直接修改文件
