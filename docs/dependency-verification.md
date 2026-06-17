# CrossLink — 关键依赖验证清单

> 目标：在正式开发前，逐项验证各组件的核心能力
> 每个验证项产出一个小 demo

---

## 1. Go + pion/webrtc ✅ 已验证

| 项目 | 状态 | 备注 |
|------|------|------|
| Go 安装 | ✅ | 1.24.5, Windows |
| pion/webrtc 可用 | ✅ | v4.1.3, POC 已跑通 |
| gorilla/websocket | ✅ | v1.5.3 |
| 跨进程 WebRTC | ✅ | signal + agent + client 全量通 |
| STUN 可达 | ✅ | 获取到公网 IP 120.244.61.149 |

---

## 2. Wails (Agent GUI) — ✅ 已验证

### 验证目标

- [x] Wails v3 CLI 安装 (v3.0.0-alpha.98)
- [x] 项目创建和编译 (Go + Vue + Vite)
- [x] Windows 系统托盘集成 (app.SystemTray)
- [x] 托盘右键菜单 (Open Dashboard / QR Code / Settings / Quit)
- [x] 关闭窗口隐藏到托盘 (RegisterHook + Cancel + Hide)
- [x] 二进制产出: `crosslink-agent.exe` (9.3 MB)
- [ ] 需要在桌面环境运行验证托盘图标实际显示

### 项目位置
`poc/crosslink-agent/`

### 架构要点
- `main.go`: 托盘应用入口，菜单构建，窗口生命周期
- `agentservice.go`: 后端服务绑定（Status / Greet）
- `frontend/`: Vue + Vite 前端
- `build/`: 平台构建配置 + 图标资源
- `bin/crosslink-agent.exe`: 编译产物

### 验证命令

```bash
cd poc/crosslink-agent
wails3 build          # 生产构建
wails3 dev            # 开发模式（热重载）
```

---

## 3. Flutter (Mobile App) — 待验证

### 验证目标

- [ ] Flutter 3.22+ 安装
- [ ] Android APK 可编译
- [ ] `flutter_webrtc` 插件可集成
- [ ] 真机扫码功能 (qr_code_scanner / mobile_scanner)
- [ ] WebSocket 连接可建立

### 验证命令

```bash
# 安装 Flutter
# Windows: https://docs.flutter.dev/get-started/install/windows
flutter doctor

# 创建测试项目
flutter create flutter_webrtc_test
cd flutter_webrtc_test

# 添加依赖
flutter pub add flutter_webrtc
flutter pub add web_socket_channel
flutter pub add mobile_scanner

# 编译 Android
flutter build apk --debug
```

### 预期产出
- 一个 Android APK，扫码后显示二维码内容

---

## 4. SQLite + Encryption (go-sqlcipher) — 待验证

### 验证目标

- [ ] 可创建加密 SQLite 数据库
- [ ] 可读写数据
- [ ] 用错误密码无法打开
- [ ] 跨平台编译（Windows/macOS/Linux）

### 验证代码（Go 脚本）

```go
package main

import (
    "database/sql"
    _ "github.com/mattn/go-sqlcipher"
)

func main() {
    // Create encrypted DB
    db, err := sql.Open("sqlite3", "test.db?_key=mysecret")
    // ...
}
```

### 预期产出
- 一个小脚本，演示加密数据库的创建/读写/验证

---

## 5. 自动更新方案 — 待选型

### 方案对比

| 方案 | Windows | macOS | Linux | 复杂度 |
|------|---------|-------|-------|--------|
| `go-selfupdate` | ✅ | ✅ | ✅ | 低 |
| Sparkle (macOS) | ❌ | ✅ | ❌ | 中 |
| Squirrel.Windows | ✅ | ❌ | ❌ | 中 |
| 自建（下载+替换） | ✅ | ✅ | ✅ | 中 |

### 建议
MVP 阶段用 `go-selfupdate`（基于 GitHub Releases），各平台统一方案。
后期 macOS 切 Sparkle 获得原生体验。

---

## 6. 待安装工具

| 工具 | 用途 | 优先级 |
|------|------|--------|
| Flutter SDK | App 开发 | P0 |
| Android Studio | Android 模拟器 | P0 |
| Wails CLI | Agent GUI | P1 |
| Docker Desktop | 信令服务器部署 | P1 |
| libsodium | go-sqlcipher 依赖 | P1 |
