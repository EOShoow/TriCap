# 动图剪贴板交付（2026-10-14）

目标：录制完成自动把完整动图放进剪贴板；默认 Copy，只有用户选择 Save 才写入配置的保存目录。

已完成：

- 生产录制请求一次自动复制，支持实时预编码和后台补编码两条路径；修改后需要显式 Copy。
- 剪贴板同一项携带 WebP、GIF 和临时 GIF 文件 URL，接收应用可按自己的能力读取。
- 裁剪、截短、标注在两个格式中一致；GIF 保留时长与循环语义，WebP 保存沿用原有设置。
- Return 默认 Copy，`⌘S` / Save 手动保存；关闭窗口取消待处理任务，较新的剪贴板内容受保护。
- 临时 GIF 位于系统临时目录；剪贴板被替换后保留 5 分钟再清理，活跃文件在应用退出后仍可粘贴。

主要文件：

- `Sources/ExportCore/PasteboardAnimation.swift`、`AnimationClipboardFileStore.swift`、`ExportService.swift`：完整动图表示、缓存及共享验证。
- `Sources/TriCapApp/EditorModel.swift`、`EditorPresenter.swift`、`EditorView.swift`、`AppDelegate.swift`：自动复制、窗口生命周期与 Copy / Save 操作。
- `Tests/TriCapTests/AnimationClipboardTests.swift`、`Sources/TriCapApp/AnimationClipboardSelfTest.swift`：格式和编辑器流程验收。
- `SettingsView.swift` 与 `scripts/test.sh` 另修复本机新版 CLT 缺失宏插件导致的编译问题。

验证：

- `./scripts/test.sh`：568 项测试、78 个 suite 全部通过。
- `./scripts/build-app.sh debug`：构建成功，签名验证通过；应用位于 `build/debug/TriCap.app`。
- `--selftest-animation-clipboard build/clipboard-verification`：20 项检查通过，使用合成录制输入和独立剪贴板，包含实时编码复用、只手动 Save 才生成保存文件、标题栏关闭取消及新剪贴板保护。
- `--render-ui-snapshots build/clipboard-verification/ui`：实际渲染并查看 `22-editor-clip-copy.png` 和裁剪界面，Copy / Save 布局正常。
- `git diff --check` 通过。

下一步：退出重开 TriCap，再在常用接收应用粘贴验证播放。界面控制连接超时，微信、Obsidian 等应用的实际粘贴未验收；帧数回读通过不代表每个接收应用都保留动画。

不要误碰：已有截图快捷流程、录制帧率与质量设置、用户旧截图/录制文件。`build/` 的测试导出和渲染图片保持 gitignore，不作为正式用户保存结果。
