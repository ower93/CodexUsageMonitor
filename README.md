<p align="center">
  <img src="Assets/AppIcon.png" width="168" alt="Codex Usage Monitor 图标">
</p>

# Codex Usage Monitor

一个原生 macOS 菜单栏 Codex 用量监控工具。点击菜单栏里的仪表图标和百分比，即可展开毛玻璃质感的额度、token 统计与最近任务面板。

<p align="center">
  <img src="outputs/CodexUsageMonitor-preview.png" width="370" alt="Codex Usage Monitor 界面预览">
</p>

菜单栏入口使用原生 `NSStatusItem`，弹层使用透明、无边框的自定义 `NSPanel`；窗口本身没有系统弹层底色，仅保留低强度的可控玻璃材质。

## 功能

- 实时显示 5 小时与每周 Codex 剩余额度和重置时间。
- 显示最近线程、当前线程、近 7 天及累计 token。
- 按模型的公开 API 标准价估算近 7 天与本机可见生涯 token 价值，普通输入、缓存输入和输出分别计价。
- 通过右上角设置按钮选择显示的卡片，并可启用登录时自动启动。
- 复用 Codex Desktop 登录状态，无需额外填写 API Key。
- 原生 AppKit + SwiftUI 菜单栏体验，支持自动与手动刷新。
- 固定优化后的 `NSVisualEffectView` 与 `ultraThinMaterial` 毛玻璃参数。

## 下载

从 [Releases](https://github.com/ower93/CodexUsageMonitor/releases/latest) 下载 `CodexUsageMonitor.app.zip`，解压后打开应用。

运行要求：macOS 14 或更高版本，并已安装且登录 `/Applications/Codex.app`。

## 运行

```bash
./script/build_and_run.sh
```

脚本会使用当前 Xcode Command Line Tools 选中的 macOS SDK 构建 SwiftPM 工程，生成带应用图标的 `dist/CodexUsageMonitor.app`，然后启动应用。应用是菜单栏专用工具，不显示 Dock 图标。

## 真实数据来源

应用调用已安装 Codex 自带的本地 `app-server`，复用当前 Codex 登录状态，不保存或读取明文账号令牌：

- `account/rateLimits/read`：5 小时/7 天额度、重置时间、计划类型和可用重置次数。
- `account/usage/read`：近 7 天和账户累计 token。
- `thread/list`：最近更新的真实线程；每个线程的累计 token 从对应会话的最新 `token_count` 事件读取。

API 等值费用会扫描本机 `~/.codex/sessions` 与 `~/.codex/archived_sessions` 中可见的会话日志，根据每个会话的模型，将普通输入、缓存输入和输出 token 按不同价格估算。该金额不是实际账单，且不包含税费与长上下文加价。

应用启动时自动刷新，面板打开期间每 60 秒刷新一次，也可以点击右上角按钮手动刷新。运行条件是 `/Applications/Codex.app` 已安装且已经登录。

## 开发预览

```bash
/Library/Developer/CommandLineTools/usr/bin/swift build \
  --disable-sandbox \
  --product PreviewRendererTool
```

中文界面使用 STHeitiSC-Light / STHeitiSC-Medium。
