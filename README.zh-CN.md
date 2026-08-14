# Switch

[English](README.md)

Switch 是一款使用键盘操作的 macOS 窗口切换器。本 fork 已加入简体中文界面，并保留英文作为默认开发语言。

项目主页：[switch-dev.sanyamgarg.com](https://switch-dev.sanyamgarg.com)

## 功能

- `⌘-Tab`：循环切换所有窗口
- `⌥-\``：循环切换当前应用的窗口
- 直接输入文字：筛选窗口
- 数字键 `1–9`：快速选择对应窗口
- `⌘W`：关闭窗口；`⌘Q`：退出应用；`⌘H`：隐藏应用
- 回车确认，Esc 取消
- 按最近使用顺序排列窗口，并在后台预热切换面板
- 支持跨桌面空间窗口、垂直列表、排除指定应用和保持面板打开模式

## 系统要求

- macOS 14 或更高版本
- 辅助功能权限
- 屏幕录制权限（仅在启用窗口缩略图时需要）

## 从源码构建

先安装 Xcode 和 XcodeGen：

```bash
brew install xcodegen
```

生成 Xcode 工程：

```bash
xcodegen generate
open Switch.xcodeproj
```

在 Xcode 中选择 `Switch` scheme 后运行。首次启动时，请按引导授予所需权限。

## 安装原版

原作者提供的 Homebrew 安装方式：

```bash
brew install --cask Sanyam-G/switch/switch
```

也可以前往[项目主页](https://switch-dev.sanyamgarg.com)下载最新 DMG。请注意，在本 fork 发布独立构建之前，上述渠道安装的是原作者版本。

## 更新

应用使用 Sparkle 提供内置更新检查。可在“设置 → 关于 → 检查更新”中手动检查，也可在设置中关闭后台自动检查。

## 许可证

项目采用 [FSL-1.1-MIT](LICENSE.md) 许可证。版权和原作者信息保持不变。

---

© 2026 Sanyam Garg
