# Claude / Cowork 窗口定位引用

## 目标与使用

用户在 TriCap 中按 `⌥⇧6`，点选窗口，将定位引用粘贴到 Claude 桌面版／Cowork，
让有电脑使用能力的 Claude 确认目标窗口后继续处理用户的请求。
也可从菜单 `Reference a Window…` 启动；快捷键位于 Settings → General。

复制内容包括应用名、Bundle ID、进程 PID、完整窗口标题、macOS CGWindowID、
窗口在 Quartz 全局 point 中的位置和 Unix 毫秒采样时间。
剪贴板同时保留可读提示词和 `app.tricap.window-reference` JSON。

## 行为与边界

- 专用选择入口只提供完整窗口；不进入截图编辑器或录制，不运行视觉内容区域检测。
- 选中后重新查询窗口列表，核对 Bundle ID、PID、CGWindowID；关闭、隐藏、重启或无法唯一匹配时要求重新选择。
- 普通截图快捷键的模式记忆保持独立；旧设置自动补入 `⌥⇧6`，原有快捷键保留。
- `Esc` 和右键取消；有贴图时，选择器优先取得 Escape，结束后交还贴图。
- 成功和取消都恢复原应用焦点。空白桌面点击继续等待，不生成无效引用。
- 窗口名只作为 JSON 数据，反引号转义，避免标题破坏提示词的代码围栏。
- 复核期间用户复制了新内容时，保留较新的剪贴板，不异步覆盖。
- 本地操作只复制窗口身份信息，不保存截图，不自动发送 Claude 消息，不消耗外部模型额度。

CGWindowID 属于 macOS 的编号空间，不等于任意电脑控制工具的内部窗口编号。
引用明确要求 Cowork 重新枚举、匹配应用和窗口，并读取当前状态，不能拿旧坐标直接点击。
窗口关闭或应用重启后，应重新点选。

Claude 端仍取决于电脑使用功能、套餐／版本以及当前会话的应用许可；
本功能不修改 Claude 配置或系统权限，不保证仅凭复制文本就取得窗口控制权。
参见 [Claude 官方电脑使用说明](https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork)。

## 实现位置

- `Sources/TriCapKit/WindowReference.swift`：引用结构、坐标、提示词和精确身份复核。
- `Sources/CaptureCore/WindowSurvey.swift`：补齐应用名和 PID。
- `Sources/SelectionUI/RegionSelector.swift`、`SelectionOverlayView.swift`：专用窗口选择行为和提示。
- `Sources/ExportCore/PasteboardWindowReference.swift`：文本和 JSON 剪贴板表示。
- `Sources/TriCapApp/AppDelegate.swift`、`GlobalHotKey.swift`、`SettingsView.swift`：入口、快捷键与串联。
- `Tests/TriCapTests/WindowReferenceTests.swift`：迁移、匹配、转义、坐标、剪贴板和取消键规则。

## 验证与收尾

- `./scripts/test.sh`：579 项测试、80 个测试集全部通过；本次新增 11 项。
- `./scripts/build-app.sh debug`：打包通过，代码签名验证通过；产物为 `build/debug/TriCap.app`。
- `--render-ui-snapshots build/window-reference-ui`：真实设置页和专用窗口选择覆盖层已渲染并人工查看，提示、快捷键和边框可见，无裁切。
- 启动后的本机统一日志确认 `⌥⇧6` 已注册在独立的 slot 4。
- 自动化 UI 工具无法绑定无普通窗口的菜单栏 App；发送到“文本编辑”的按键未触发系统全局热键，已撤销产生的测试字符。故真实鼠标点选到普通应用粘贴的链路尚未完成自动验收，不能将此尝试记为通过。
- Claude 实际接收并定位窗口属于外部模型调用，尚未授权消费额度，未发送任何测试请求。

下一步最有效的检查：在已启动的 TriCap 中实际按 `⌥⇧6`，点选一个测试窗口，
粘贴到 Cowork，确认应用与标题；如需让 Claude 实际定位，再经用户确认调用额度后发送一次仅定位的测试。

后续使用者无需更改截图／动图导出设置。不要将 CGWindowID 当作其他工具的窗口句柄，
也不要通过修改权限或自动发送消息来隐藏 Claude 端的接入条件。
