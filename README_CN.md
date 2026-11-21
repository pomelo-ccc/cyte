# Cyte

[English](README.md) · [最新版本下载 (Releases)](https://github.com/pomelo-ccc/cyte/releases/latest)

**Cyte** 是面向 **腾讯 CodeBuddy (`codebuddy` / `cbc`)** 的原生桌面工作台与轻量 IDE，基于 Flutter 与 macOS / Windows / Linux 原生能力构建。

## 下载安装

直接前往 [GitHub Releases](https://github.com/pomelo-ccc/cyte/releases/latest) 或点击下方对应平台安装包下载（当前版本 `v2.0.2`）：

| 平台 | 架构 | 直接下载 |
| --- | --- | --- |
| **macOS** | Apple Silicon (M1 / M2 / M3 / M4) | [Cyte-2.0.7-arm64.dmg](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-arm64.dmg) |
| **macOS** | Intel (x86_64) | [Cyte-2.0.7-x64.dmg](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-x64.dmg) |
| **Windows** | x64 (Windows 10 / 11) | [Cyte-2.0.7-setup.exe](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-setup.exe) |
| **Windows** | ARM64 | [Cyte-2.0.7-setup-arm64.exe](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-setup-arm64.exe) |
| **Linux** | x64 (Ubuntu / Debian `.deb`) | [Cyte-2.0.7-linux-amd64.deb](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-linux-amd64.deb) · [.tar.gz](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-linux-amd64.tar.gz) |
| **Linux** | ARM64 (Ubuntu / Debian `.deb`) | [Cyte-2.0.7-linux-arm64.deb](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-linux-arm64.deb) · [.tar.gz](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-linux-arm64.tar.gz) |

> **macOS 首次运行说明**：打开 `.dmg` 将 `Cyte` 拖入 `Applications` 后，若系统提示「已损坏 / 无法验证开发者」（未开启 Apple 公证签名），请在终端执行一次以下命令即可正常打开：
> ```bash
> xattr -cr /Applications/Cyte.app
> ```
> 同时请确保本机已安装 **CodeBuddy CLI (`codebuddy` / `cbc`)**（可执行 `npm install -g @tencent-ai/codebuddy-code`）。

## 核心特性

- **原生对接腾讯 CodeBuddy CLI (`codebuddy` / `cbc`)**：常驻多轮 `stream-json` 进程直连，完整支持中国版 CN（`copilot.tencent.com`：Hunyuan 2.0、GLM-5.1、DeepSeek V3.2、Kimi K2.5、MiniMax M2.5）、国际版 AI（`www.codebuddy.ai`：Claude 4.6、GPT-5.4、Gemini 3.1）、iOA、企业专享版及 `~/.codebuddy/models.json` 自定义模型。
- **多账号 OAuth 登录与积分监控**：内置「设置 → CodeBuddy 账号」与输入框快捷切号面板，支持中国版 / 国际版官方 OAuth 浏览器授权、API Key 账号（`CODEBUDDY_API_KEY`）、Token/JSON 批量导入导出、套餐状态查询、每轮 Credits 消耗统计及配额耗尽自动切号。
- **保留自定义 API 供应商（内置内核）**：除 CodeBuddy CLI 外，支持在「设置 → 模型」中配置自定义 Anthropic / OpenAI 协议供应商并通过内置内核运行。
- **完全独立的应用身份与数据隔离**：独立 Bundle ID（`dev.cyte.desktop`）、独立应用配置目录（`~/Library/Application Support/cyte`）并原生读写 `~/.codebuddy/projects/` 会话记录，与 `Byte`、`Ayte` 互不干扰共存运行。
- **原生对接 `.codebuddy` 扩展体系**：在「设置 → 自定义」与会话记忆胶囊中直接管理 CodeBuddy 的全局（`~/.codebuddy/`）与项目级（`.codebuddy/`、`CODEBUDDY.md`、`.mcp.json`）Skills、Subagents、Commands、Rules、MCP Servers、Hooks 与 Plugins。
- **高密度桌面工作台体验**：内置代码编辑器与 Diff 审阅、多标签终端、会话时间轴回放（Session Replay）、实时耗时秒表、Stash 灵感暂存、macOS 顶部灵动岛拖拽投喂与盯盘小窗、以及端到端加密手机互联。

## 本地运行与构建

1. 安装 **CodeBuddy CLI**：
   ```bash
   npm install -g @tencent-ai/codebuddy-code
   ```
2. 开发运行：
   ```bash
   flutter pub get
   flutter run -d macos
   ```
3. 打包 Release 应用：
   ```bash
   dart run tool/build_macos.dart    # macOS (.dmg / .zip)
   dart run tool/build_windows.dart  # Windows (-setup.exe)
   sh tool/package_linux_deb.sh      # Linux (.deb / .tar.gz)
   ```

## 致谢与开源协议

本项目基于开源软件 [BaoCode](https://github.com/baocode-dev/baocode) 衍生改造，遵循相同的开源许可证发布，详见 [LICENSE](LICENSE)。
