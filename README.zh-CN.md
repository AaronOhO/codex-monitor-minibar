# CodexMonitorMinibar

[English README](README.md)

CodexMonitorMinibar 是一个原生 macOS 菜单栏应用，用来展示本机 Codex 的额度状态和会话运行状态。

它会在顶部栏里展示今日本机 token 使用量、5 小时额度、周额度、5 小时消耗进度边框，以及一个由 Codex hooks 驱动的状态灯。

## 背景

这个小程序的目标是尽可能把 20x Pro 的 Codex 额度用满。额度和会话状态需要在工作时随时可见，所以把它做成了 macOS 状态栏里的 monitor，而不是一个需要单独切换的窗口。

## 预览

<img src="Assets/codex-monitor-icon.png" alt="CodexMonitorMinibar app icon" width="128">

![CodexMonitorMinibar 菜单栏截图](Assets/minibar-screenshot.png)

## 功能

- 原生 AppKit 菜单栏应用，使用 `LSUIElement`
- 从本机 Codex app-server 读取额度
- 顶部栏展示：
  - 今日本机 token 使用量
  - 5 小时剩余额度和重置倒计时
  - 周剩余额度和重置倒计时
  - 用胶囊形 border 展示 5 小时已消耗进度
- 展开菜单里展示更详细的额度进度条
- 展开菜单里展示今天的 input/cache/output/reasoning token 拆分
- 通过 Codex hooks 追踪会话状态
- 支持多个 Codex 会话并行
- App 启动时自动安装所需 Codex hooks
- 保留已有 hooks，并避免重复插入同一个 hook

## 状态颜色

| 状态 | 含义 |
| --- | --- |
| 🟢 绿色 | Codex 正在干活，例如有会话正在运行或正在调用工具 |
| 🔴 红色 | Codex 遇到了阻塞，需要人工介入，例如需要授权或工具调用失败 |
| 🟡 黄色 | Codex 正在空闲，应该给 Codex 安排一些任务 |
| ⚪️ 白色 | 未知状态 / 当前没有可用 hook 数据 |

白色不是“空闲”。白色表示 app 暂时没有可靠的会话活动信号，常见于刚启动、还没收到下一次 Codex hook 事件，或者所有会话状态已经过期。

## 指标说明

状态栏文案刻意保持紧凑：

```text
TK | 5H | WK
```

- `TK` 表示今天这台 Mac 上新增使用了多少 token。
- `5H` 表示 5 小时滚动窗口的剩余额度百分比，以及距离这个窗口重置还剩多久。
- `WK` 表示周窗口的剩余额度百分比，以及距离周窗口重置还剩多久。
- 胶囊形 border 展示 5 小时额度的已消耗进度，因为在持续工作时，5 小时窗口通常是最需要及时关注的限制。
- `This Mac Tokens` 是本机可观测 token 用量，来自这台 Mac 上 Codex session JSONL 的 `token_count` 事件。如果同一个账号还在其他设备上使用 Codex，它会和 Codex 个人详情页的账号级统计不同。展开菜单只展示今天的 input/cache/output/reasoning 拆分。

## 工作原理

额度数据来自本机 Codex app-server：

```text
/Applications/Codex.app/Contents/Resources/codex app-server proxy --sock ~/.codex/app-server-control/app-server-control.sock
```

如果 control socket 不存在或失效，会自动回退到：

```text
/Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://
```

应用通过 JSON-RPC 调用：

```text
account/rateLimits/read
```

重点读取字段：

```text
usedPercent
windowDurationMins
resetsAt
```

会话活动数据来自 Codex hooks：

```text
Codex hook event
  -> CodexMonitorHookBridge
    -> /tmp/codex-monitor-<uid>.sock
      -> CodexMonitorMinibar
```

`CodexMonitorHookBridge` 会从 stdin 读取一条 hook JSON，把它发到本机 Unix socket。菜单栏 app 按 `session_id` 维护内存里的会话状态表。

本机 token 用量来自：

```text
~/.codex/sessions/**/*.jsonl
~/.codex/archived_sessions/**/*.jsonl
```

应用只索引今天修改过的 JSONL 文件里的 `token_count` 事件。有 `total_token_usage` 时优先用累计值做差分纠偏，否则回退到 `last_token_usage`；如果 fork 子会话能找到 parent session，也会扣掉继承的 parent totals。第一次扫描会建立索引：

```text
~/.codex-monitor-minibar/token-usage-index.json
```

后续刷新只枚举文件元信息，并从上次处理到的 offset 继续读取变更文件尾部；没有变化的 JSONL 不会被重复读取，历史文件会直接跳过。

## 自动安装 Hooks

App 启动时会自动把 bridge hook 合并写入：

```text
~/.codex/hooks.json
```

同时确保这里启用了 hooks：

```text
~/.codex/config.toml
```

写入的命令指向 app bundle 内部的 bridge：

```text
CodexMonitorMinibar.app/Contents/MacOS/CodexMonitorHookBridge
```

会自动接入这些事件：

```text
SessionStart
UserPromptSubmit
PreToolUse
PermissionRequest
PostToolUse
SubagentStart
SubagentStop
Stop
```

安装逻辑是幂等的。同一个 app 路径重复启动不会重复插入 hook；已有的其他 hook 会被保留。

## 构建

要求：

- macOS 13+
- Swift 6 toolchain
- Codex 安装在 `/Applications/Codex.app`

构建并打包：

```sh
Scripts/package_app.sh
```

打包产物：

```text
CodexMonitorMinibar.app
```

启动：

```sh
open CodexMonitorMinibar.app
```

## 验证

运行自定义测试：

```sh
swift run --disable-sandbox CodexMonitorCoreTestRunner
```

构建两个可执行产物：

```sh
swift build --disable-sandbox --product CodexMonitorMinibar
swift build --disable-sandbox --product CodexMonitorHookBridge
```

验证 app 包：

```sh
Scripts/package_app.sh
plutil -lint CodexMonitorMinibar.app/Contents/Info.plist
codesign --verify --deep --strict CodexMonitorMinibar.app
```

## 注意事项

- Codex app-server 和 hook payload 都属于本机 Codex 的实现细节，后续 Codex 版本可能变化。
- 会话状态只保存在内存里，默认 30 分钟后过期。
- app 不上传额度数据或 hook 数据。
- 点击 `Open Codex` 时，macOS 可能会弹出隐私与安全提示，说 CodexMonitorMinibar 被阻止“修改 App”。这个菜单项只是通过 Launch Services 打开或切到 `/Applications/Codex.app`，CodexMonitorMinibar 不会修改、替换或更新 Codex.app。允许这个权限只用于这个快捷入口启动/切换到 Codex；如果拒绝，额度和 hook 监控仍然可以工作，但 `Open Codex` 快捷入口可能不可用。
- 如果把 app 移动到新路径，bridge 命令路径会变化，安装器会为新路径追加一条新的 bridge hook。
