# Cyte

[中文说明](README_CN.md) · [Latest Release](https://github.com/pomelo-ccc/cyte/releases/latest)

**Cyte** is a native desktop workbench and IDE for **Tencent CodeBuddy (`codebuddy` / `cbc`)**, built with Flutter and native macOS/Windows/Linux integrations.

## Download & Install

Grab the prebuilt installer for your platform from [GitHub Releases](https://github.com/pomelo-ccc/cyte/releases/latest) (current version `v2.0.2`):

| Platform | Architecture | Direct Download |
| --- | --- | --- |
| **macOS** | Apple Silicon (M1 / M2 / M3 / M4) | [Cyte-2.0.7-arm64.dmg](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-arm64.dmg) |
| **macOS** | Intel (x86_64) | [Cyte-2.0.7-x64.dmg](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-x64.dmg) |
| **Windows** | x64 (Windows 10 / 11) | [Cyte-2.0.7-setup.exe](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-setup.exe) |
| **Windows** | ARM64 | [Cyte-2.0.7-setup-arm64.exe](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-setup-arm64.exe) |
| **Linux** | x64 (Ubuntu / Debian `.deb`) | [Cyte-2.0.7-linux-amd64.deb](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-linux-amd64.deb) · [.tar.gz](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-linux-amd64.tar.gz) |
| **Linux** | ARM64 (Ubuntu / Debian `.deb`) | [Cyte-2.0.7-linux-arm64.deb](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-linux-arm64.deb) · [.tar.gz](https://github.com/pomelo-ccc/cyte/releases/download/v2.0.7/Cyte-2.0.7-linux-arm64.tar.gz) |

> **macOS First Launch Note**: After dragging `Cyte` into `Applications`, if Gatekeeper blocks opening an ad-hoc signed build, run this once in Terminal:
> ```bash
> xattr -cr /Applications/Cyte.app
> ```
> Make sure **CodeBuddy CLI (`codebuddy` / `cbc`)** is installed (`npm install -g @tencent-ai/codebuddy-code`).

## Highlights

- **First-Class CodeBuddy CLI (`codebuddy` / `cbc`) Engine**: Persistent multi-turn `stream-json` sessions supporting CN (`copilot.tencent.com`), Global (`www.codebuddy.ai`), iOA, Enterprise, and custom `~/.codebuddy/models.json` models with `--effort` and `--autocompact`.
- **Multi-Account OAuth & Credit Center**: Browser OAuth login for both CN & Global regions, API Key accounts (`CODEBUDDY_API_KEY`), Token/JSON import & export, live edition/billing checks, per-turn credit tracking, and automatic failover when credits run out.
- **Custom API Upstreams (Built-in Core)**: Optional built-in agent core supporting custom Anthropic / OpenAI-compatible API providers alongside CodeBuddy CLI.
- **Isolated Storage (`~/.cyte` & `~/.codebuddy`)**: Completely independent bundle ID (`dev.cyte.desktop`), settings (`~/Library/Application Support/cyte`), and native CodeBuddy session transcripts (`~/.codebuddy/projects/`), coexisting cleanly alongside `Byte` and `Ayte`.
- **Native `.codebuddy` Customizations**: Inspect and edit global (`~/.codebuddy/`) and workspace (`.codebuddy/`, `CODEBUDDY.md`, `.mcp.json`) Skills, Subagents, Commands, Rules, MCP Servers, Hooks, and Plugins directly inside Settings → Customize.
- **Rich Workbench UX**: Built-in code editor & diff viewer, terminal deck, Session Replay waterfall timeline, live turn chronograph, Stash, Notch Dynamic Island & PiP watcher on macOS, and end-to-end encrypted mobile pairing.

## Building from Source

1. Install **CodeBuddy CLI**:
   ```bash
   npm install -g @tencent-ai/codebuddy-code
   ```
2. Run locally with Flutter:
   ```bash
   flutter pub get
   flutter run -d macos
   ```
3. Build release installers:
   ```bash
   dart run tool/build_macos.dart    # macOS (.dmg / .zip)
   dart run tool/build_windows.dart  # Windows (-setup.exe)
   sh tool/package_linux_deb.sh      # Linux (.deb / .tar.gz)
   ```

## Credits & License

Cyte is derived from the open-source [BaoCode](https://github.com/baocode-dev/baocode) project and distributed under the same open-source license — see [LICENSE](LICENSE) for full terms.
