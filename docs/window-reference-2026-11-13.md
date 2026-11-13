# Claude 窗口定位引用（⌘⌘）

## 目标与使用

参照 Codex Appshots 的 Command-Command：在目标窗口里连按两下 `⌘`（或同时按住左右两个 `⌘`），
TriCap 直接把**最前窗口**的身份复制为一行 JSON，前后不加任何说明文字。
粘贴到 Claude，在前面或后面写上请求即可。不弹选择层，不需要点选，不保存截图。

菜单 **Copy Front Window for Claude** 做同样的事，不需要额外权限。

复制内容示例：

```json
{"app":"微信","bundleId":"com.tencent.xinWeChat","pid":20240,"title":"微信","windowId":119145}
```

## 2026-11-13 简化说明

第一版（`df1a78b`）用 `⌥⇧6` 打开专用选择层点选窗口，提示词含坐标、时间戳、schema 版本和多条注意事项，
剪贴板另带自定义 JSON 类型。本次简化为：

- 触发：`⌥⇧6` + 点选 → 双击 `⌘`，抓最前窗口；删除专用选择层、`⌥⇧6` 快捷键设置及 Escape 优先级。
- 复制内容：只保留应用名、Bundle ID、PID、窗口 ID、标题，一行 JSON；删掉坐标、`capturedAt`、`schemaVersion`。
  后续按用户要求再去掉 JSON 前后的提示词、代码围栏和「我的要求：」，剪贴板只剩这一行 JSON。
  字段名本身足以让 Claude 识别出这是窗口定位；要做什么由用户在粘贴时自己写。
- 删除「CGWindowID 不能当作其他工具窗口编号」的提醒。依据：同日在 Claude 桌面版实测，
  电脑使用工具 `app_list_windows` 返回的 `window_id` 就是 CGWindowID（120864），且与点选时的 PID、标题、
  位置完全一致，可直接核对。
- 删除没有任何程序读取的 `app.tricap.window-reference` 剪贴板类型，剪贴板只放纯文本。
- 删除选中后的二次复核：按键当下立即读取窗口列表，不存在选择期间窗口关闭的时间差。

旧版本保存的 `windowReferenceHotKey` 设置会被忽略，不影响其他设置读取。

## 行为与边界

- 只粘贴 JSON、不写要求时，Claude 需要自己判断该做什么。实测中曾出现 Claude 猜成「读取内容」的情况，
  所以粘贴时最好带上一句要求。
- 窗口标题和应用名会去掉不可见的格式字符（Unicode Cf：零宽空格／连接符、BOM、双向控制符）。
  实测 Chrome 里的飞书云文档标题前带有几十个零宽字符（疑似水印），Claude 的工具因此不显示该标题，
  这些字符也会原样进入聊天记录。带变体选择符的 emoji 不受影响；ZWJ 组合 emoji 会拆成单个 emoji。
- 最前窗口 = 当前最前应用的最上层普通窗口（layer 0、在屏）。宽 < 200 pt 或高 < 100 pt 的小窗
  （浮标、提示条、工具条）会被跳过；该应用只有小窗时仍选它。
  最前应用没有普通窗口时提示「No window in front」，不会改抓其他应用的窗口。
  TriCap 自己在最前（设置窗口）时，取其他应用的最上层窗口。
- 小窗规则来自实测：飞书文档预览时，⌘⌘ 抓到的是叠在预览窗口左上角的「窗口共享」按钮
  （`WindowSharingSessionButton`，66×20 pt，windowId 125318），而不是下面的预览窗口（1182×925）。
- 多个窗口：一分钟内连续 ⌘⌘、且期间剪贴板没被其他内容替换时，新窗口追加为下一行 JSON
  （每行一个窗口，按引用顺序）；同一窗口再按只刷新该行，不重复添加。超过一分钟或中间复制过别的内容，
  则重新开始。提示显示刚加入的窗口和当前总数。macOS 无法得知是否已粘贴，所以粘贴后一分钟内再引用新窗口
  会接在上一批后面，需看提示里的数量；想重新开始，复制任意其他内容即可。参照 Codex Appshots
  「60 秒内连续截图进入同一对话」的做法。
- 判定：两次 `⌘` 单击，每次按住 ≤ 0.35 s，间隔 ≤ 0.4 s；期间按了任何普通键（如 `⌘C`、`⌘V`）
  或 `⇧⌥⌃fn`，都会重新计数。Caps Lock 不影响。
- 窗口标题是不可信数据：放在 JSON 字符串里，换行和引号由 JSON 转义，反引号转为 `\u0060`，标题无法形成 Markdown 代码块。
- 窗口标题来自 ScreenCaptureKit，仍需「屏幕录制」权限（TriCap 原本就要）。

## 权限

Carbon 热键无法绑定单独的修饰键，所以 ⌘⌘ 用只监听（listen-only）的事件监听，需要 macOS「输入监控」：

- 只在用户点 **Turn On ⌘⌘ Shortcut…**（菜单）或 Settings 里的 **Turn On…** 时请求，启动时不弹窗。
- 监听只读取「有普通键按下」这一事实和修饰键状态，不读取键码或文字，也不拦截、修改任何事件。
- 授权后 TriCap 再次激活时会自动开始监听；若仍无效，退出并重新打开 TriCap。
- ad-hoc 签名每次重建都会改变 TCC 身份，可能需要重新授权（同屏幕录制）。

## 实现位置

- `Sources/TriCapKit/DoubleCommandTap.swift`：⌘⌘ 判定状态机（纯逻辑，可测试）。
- `Sources/TriCapApp/DoubleCommandMonitor.swift`：输入监控权限、listen-only event tap。
- `Sources/TriCapKit/WindowReference.swift`：最前窗口选择、标题清理与 JSON。
- `Sources/TriCapKit/WindowReferenceBatch.swift`：多窗口追加规则（一分钟、剪贴板未变、去重）。
- `Sources/TriCapApp/AppDelegate.swift`：启动监听、菜单入口、复制与提示。
- `Sources/TriCapApp/SettingsView.swift`：General → Window reference for Claude 状态与开启按钮。
- `Sources/CaptureCore/WindowSurvey.swift`、`Sources/TriCapKit/WindowPicker.swift`：窗口的应用名和 PID。
- `Tests/TriCapTests/WindowReferenceTests.swift`：⌘⌘ 判定、最前窗口选择、标题清理与 JSON 转义、多窗口追加、旧设置兼容。

## 验证

- `./scripts/test.sh`：585 项测试、81 个测试集全部通过（删除旧版 11 项，新增 17 项，含飞书浮标、隐形水印与多窗口追加用例）。
- `./scripts/build-app.sh debug`：打包与签名通过。
- `--render-ui-snapshots`：设置页 General 新分区已渲染查看，无裁切。
- **尚未验证**：真实双击 `⌘` 触发（自动化工具无法产生系统级按键），以及授权「输入监控」后是否需要重启 TriCap。
  下一步：启动新构建，点 **Turn On ⌘⌘ Shortcut…** 授权，在任一窗口连按两下 `⌘`，粘贴到 Claude 确认。
