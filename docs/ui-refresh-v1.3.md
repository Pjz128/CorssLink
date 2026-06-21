# CrossLink UI Refresh v1.3

> 品牌方向：**深空链路（Deep Space Link）**
> 图标形态：**终端窗口 + 连接符号**

## 设计目标

以资深产品交互专家的视角，统一移动端视觉语言、提升信息层级、强化品牌识别，让「跨端 AI 互联」的调性在每一步交互中都能被感知。

## 已完成改动

### 1. 品牌设计 Token

新增 `app/lib/theme/crosslink_theme.dart`：

- 深空黑/面板色/链路青蓝紫强调色
- 工具语义色（Bash、Read、Write、Grep、Glob、WebSearch…）
- 统一圆角、间距、动画时长、阴影
- `ToolColor` / `ToolIcon` 扩展，统一工具配色与图标

### 2. 品牌 SVG 资产

新增 `app/assets/brand/`：

| 文件 | 用途 |
|------|------|
| `crosslink_logo.svg` | 启动图标、About 页、品牌展示 |
| `empty_state_no_device.svg` | 首页无设备空状态 |
| `empty_state_no_session.svg` | 聊天页空状态 |
| `scan_frame.svg` | 扫码页瞄准框 |

已在 `pubspec.yaml` 注册 `assets`。

### 3. 聊天页重构（`chat_screen.dart`）

- 悬浮式渐变边框 Composer，发送按钮改为圆形渐变箭头
- 快捷操作从顶部 icon 行改为输入框上方 Chip 列表（清除 / 压缩 / 模型 / 停止）
- 新增 `TypingIndicator` 粒子动画，流式响应中显示「Agent 思考中…」
- 消息气泡统一深色/主色风格，用户消息带发光阴影
- 长按消息弹出操作菜单：复制 / 重试（错误消息） / 删除
- Markdown 代码块使用终端绿 + 深色背景
- 会话抽屉使用品牌面板色与选中高亮

### 4. 卡片组件统一

- `PermissionCard`：左侧强调条 + 折叠输入详情 + 双色操作按钮
- `ToolCallCard`：左侧强调条 + 工具图标 + 脉冲/完成/失败状态点
- `ToolResultCard`：左侧强调条 + 复制支持 + 等宽字体
- `ThinkingBlock`：面板折叠卡片

### 5. 首页 / 导航 / 设置 / 扫码

- `MainShell`：底部导航改为「设备 / 会话 / 能力 / 设置」，页面切换带淡入缩放
- `HomeScreen`：设备卡片增加在线呼吸灯、渐变头像、品牌空状态插画
- `SettingsScreen`：主题色改为圆角胶囊 + 发光选中效果，About 卡片使用新 Logo
- `ScanScreen`：扫描框改为四角瞄准 + 扫描线 SVG，配对进度改为底部 Sheet

### 6. 应用图标

- 新增 Android Adaptive Icon：
  - `mipmap-anydpi-v26/ic_launcher.xml`
  - `drawable/ic_launcher_background.xml`
  - `drawable/ic_launcher_foreground.xml`（矢量终端窗口 + 链路节点）
- 新增图标生成脚本：`scripts/generate_app_icons.py`
  - 基于 PIL 绘制品牌图标
  - 输出 Android 各密度 PNG 与 iOS 全尺寸 PNG
  - 自动更新 iOS `Contents.json`

## 待执行命令

图标 PNG 需要本地生成（当前环境无法直接执行绘图脚本）：

```bash
cd C:/mySpace/CorssLink
python -m pip install Pillow
python scripts/generate_app_icons.py
```

Flutter 依赖更新：

```bash
cd app
flutter pub get
flutter analyze
```

## 验证清单

- [ ] `flutter analyze` 无 error
- [ ] 聊天页空状态显示 SVG 插画
- [ ] 输入框显示渐变边框 Composer
- [ ] 流式响应显示 TypingIndicator
- [ ] 工具/权限卡片风格统一、可折叠
- [ ] 设备卡片显示在线绿点
- [ ] 设置页主题色胶囊有发光选中效果
- [ ] Android 启动图标显示终端窗口 + 连接符号
- [ ] iOS 启动图标 PNG 已替换

## 后续可继续优化

1. 扫码页暗角遮罩可升级为真正的「中心透明挖孔」效果。
2. 能力页（`abilities_screen.dart`）和会话页（`sessions_screen.dart`）可进一步按新设计系统美化。
3. 可增加 Hero 动画：首页设备卡片 → 聊天页标题。
4. 可增加震动反馈强度配置。
