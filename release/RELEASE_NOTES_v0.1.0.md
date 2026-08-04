# TriCap v0.1.0 Release Notes / 发布说明

> **Status / 状态：Source preview / 源码预览**
>
> This note documents commit `4c46217`. No signed and notarized binary is published yet.
>
> 本说明对应提交 `4c46217`。目前尚未发布经过 Developer ID 签名与 Apple 公证的安装包。

---

## 中文

### TriCap 是什么

TriCap 是一款完全在本机运行的原生 macOS 菜单栏截图与短动图工具。它不上传内容、
不包含遥测，也不需要账号。核心工作流是：快速框选或识别窗口、截图直接进入剪贴板、
短录制导出 Animated WebP，并按需标注、保存或生成 Markdown/Obsidian 引用。

### v0.1.0 主要功能

- 默认按 `⌥⇧5` 进入跨显示器区域选择；鼠标悬停可自动识别窗口，拖动时吸附窗口与屏幕边界。
- 截图默认直接复制到剪贴板，不弹出编辑窗口；菜单中仍保留“截图并编辑”。
- 默认按 `F3` 将剪贴板中的图片置顶展示。贴图不抢键盘焦点，可移动、缩放、调透明度和关闭。
- 支持短录制、倒计时、全局 `Esc` 取消、可点击的 Stop HUD、首尾裁剪与 Animated WebP 导出。
- 录制期间增量预编码 Animated WebP；在合成高动态素材基准中，典型导出尾延迟由 177.0 秒降至 0.85 秒。
- 支持箭头、矩形、文本、画笔和 Core Image `CIPixellate` 马赛克，支持撤销与重做。
- 支持 PNG、JPEG、静态 WebP 和 Animated WebP；提供四档画质预设与高级编码参数。
- 保存后可复制 Markdown 或 Obsidian 图片引用；路径位于配置的 Vault 内时使用相对路径。
- 可选“登录时启动”，使用 macOS 公开 API `SMAppService.mainApp`，默认关闭。
- 原创 App 图标；截图模式标签始终位于选区和窗口高亮之上，且不会进入最终截图。

### 系统要求

- 配置的最低版本：macOS 14.0。
- 当前构建架构：Apple Silicon `arm64`。
- Intel Mac 和 Universal 2 尚无可用构建。

最低版本是构建配置，不代表所有 macOS 14/15 版本均已实机验证。

### 当前开发验证环境

| macOS | 架构 | 显示器 | 验证内容 |
|---|---|---|---|
| 26.5.2（25F84） | Apple Silicon arm64 | 1470×956 @2x + 1280×800 @2x | 449 项测试、Debug/Release 构建、UI 快照、自检、local-test DMG、发布失败门探针 |

发布门探针覆盖 10 个场景，连续 5 轮共 365/365 项断言通过，包括公证拒绝、命令失败、
不可解析结果、staple 失败、Gatekeeper 拒绝、中断清理、并发产物认领与测试模式隔离。
这些是开发与失败路径验证，不等于真实 Developer ID 公证快乐路径已经完成。

### 从源码构建

```bash
./scripts/test.sh
./scripts/build-app.sh release
open build/release/TriCap.app
```

TriCap 需要“屏幕与系统音频录制”权限，但不会录制音频。首次截取时 macOS 会请求授权。
当前本机构建使用 ad-hoc 签名，适合开发测试；请勿将 `LOCAL-TEST-adhoc.dmg` 分发给其他用户。

### 已知限制与发布状态

- **公开二进制 Release 仍为 `BLOCKED`**：尚无 Developer ID Application identity，真实
  `Accepted → staple → spctl` 链路尚未运行，因此没有可安全分发的 DMG。
- macOS 14.x、15.x、Intel Mac、Universal 2 和其他机器的首次安装流程尚未验证。
- “登录时启动”尚未通过真实注销/登录验证；正式安装后应将 App 放入 `/Applications`。
- 马赛克属于视觉遮挡，并非不可逆脱敏。处理密钥、身份信息等敏感内容时请使用实色覆盖。

---

## English

### What is TriCap?

TriCap is a native macOS menu-bar utility for screenshots and short animated captures. Everything
stays on the Mac: there is no upload, telemetry, cloud sync, or account. Its core workflow combines
window-aware region selection, clipboard-first screenshots, short Animated WebP recordings,
lightweight annotation, and Markdown/Obsidian-friendly references.

### Highlights in v0.1.0

- Press `⌥⇧5` by default to select across displays. Hover to detect a window, or drag with snapping
  to nearby window and display edges.
- Screenshots go straight to the clipboard by default without opening the editor. A separate
  “Screenshot and Edit” menu item remains available.
- Press `F3` by default to pin the clipboard image above ordinary windows. Pins do not steal
  keyboard focus and support moving, zooming, opacity controls, and dismissal.
- Record short regions with an optional countdown, global `Esc` cancellation, a clickable Stop
  HUD, head/tail trimming, and Animated WebP export.
- Incremental Animated WebP pre-encoding runs during capture. On the synthetic high-motion
  benchmark, typical post-recording export latency fell from 177.0 seconds to 0.85 seconds.
- Annotate with arrows, rectangles, text, pen, and Core Image `CIPixellate`, with undo and redo.
- Export PNG, JPEG, static WebP, and Animated WebP with four quality presets and advanced controls.
- Copy Markdown or Obsidian image references after saving, using relative paths inside a configured
  vault root.
- Optional launch at login via the public macOS API `SMAppService.mainApp`; disabled by default.
- Includes an original app icon. The capture-mode banner stays above selection and window
  highlights while remaining excluded from the final capture.

### Requirements

- Configured minimum: macOS 14.0.
- Current build architecture: Apple Silicon `arm64`.
- No Intel or Universal 2 build is available yet.

The configured minimum is not a claim that every macOS 14 or 15 release has been exercised.

### Current development verification environment

| macOS | Architecture | Displays | Coverage |
|---|---|---|---|
| 26.5.2 (25F84) | Apple Silicon arm64 | 1470×956 @2x + 1280×800 @2x | 449 tests, Debug/Release builds, UI snapshots, self-test, local-test DMG, and release failure-gate probe |

The release-gate probe covers 10 scenarios and passed 365/365 assertions across five consecutive
runs, including notarization rejection, command failure, malformed output, staple failure,
Gatekeeper rejection, interruption cleanup, concurrent product claims, and test-mode isolation.
This is development and failure-path evidence; it does not verify the real Developer ID happy path.

### Build from source

```bash
./scripts/test.sh
./scripts/build-app.sh release
open build/release/TriCap.app
```

TriCap requires Screen & System Audio Recording permission, although it does not record audio.
macOS asks for access on the first capture. Current local builds are ad-hoc signed and intended for
development only; do not redistribute a `LOCAL-TEST-adhoc.dmg`.

### Known limitations and release status

- **The public binary release remains `BLOCKED`**: there is no Developer ID Application identity,
  and the real `Accepted → staple → spctl` path has not run. No distributable DMG is available.
- macOS 14.x, macOS 15.x, Intel Macs, Universal 2, and first install on another machine are untested.
- Launch at login has not been verified across a real logout/login. Install the final app in
  `/Applications` before enabling it.
- Pixelation is visual obscuration, not irreversible redaction. Use an opaque filled cover for
  secrets, credentials, or identity data.
