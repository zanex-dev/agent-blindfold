# 更新日志 (Changelog)

[English](./CHANGELOG.md) | **简体中文**

**`agent-blindfold`（代号：`Heart-Under-Blade / 刃下心`）** 的所有重要版本演进均记录于此。

本日志格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/)。

---

## [1.1.0] - 2026-11-11 — 智能工程沙盒自动豁免与限时/永久通行证

> 本次更新源自真实前端/SVG 与 Playwright 视觉调试中的实战“捉虫”（Dogfooding）：在彻底消除前端工程误拦截的同时，封堵了 AI 智能体“自签发通行证”的提权绕过路径。

### ✨ 新增与升级
- **第零级（Tier 0）前端与工程沙盒原生自动豁免（`scripts/guard.ps1` & `scripts/guard.sh`）**：
  - 原生自动放行 Antigravity 官方项目沙盒（`~/.gemini/antigravity/scratch/<子项目>/...`）、当前活跃会话专属产物目录（`brain/<当前会话ID>/...`，同时严密物理阻断跨窗口读取其他会话 `brain/<其他ID>/` 的媒体与附件）、工程工作区内的 Playwright 前端视觉自检截图目录（`<workspace>/.playwright-mcp/`）以及非私人禁区内的 `.svg` 纯文本矢量代码——即使未挂载 Active Workspace，新建前端或 SVG 项目也畅通无阻。
- **`SessionStart` 会话开局自动下发豁免机制（`scripts/session_start.ps1` & `scripts/session_start.sh`）**：
  - 工作开始时自动读取全局策略 `~/.gemini/config/agent-blindfold.json`，支持为独立工程工作区自动签发**限时（`timed`，默认 `2h` TTL）**或**永久（`permanent`）**的 `.allow_media` v2 通行证（也可设为 `off` 纯手动授权）。
  - 智能识别并跳过私人禁区（`Pictures`、`Downloads` 根目录、`$HOME` 祖先目录等）以及纯日常闲聊/只读工作区（如 `chat` 目录或 `AGENTS.md` 声明为只读模式的目录），绝不污染只读目录。
  - 自动将 `.allow_media` 追加至 `<workspace>/.git/info/exclude`，无需改动仓库 `.gitignore` 即可保持 `git status` 干净。
- **`.allow_media` v2 结构化通行证与到期自动销毁**：
  - 支持结构化 JSON 通行证（`{"mode": "timed", "expires_at": ...}` 与 `{"mode": "permanent"}`）、纯文本简写（`permanent`、`30m`、`2h`、`1d`），并向后兼容旧版空文件（默认赋予 `2h` 安全限时 TTL），限时到期后拦截时自动清理失效文件。
- **跨平台通行证控制器与 Windows 一键面板（`scripts/unlock.ps1`、`scripts/unlock.sh`、`blindfold-control.cmd`）**：
  - 提供命令行工具与交互式控制台菜单，支持一键签发限时/永久通行证、立即上锁收回（`-Lock` / `--lock`）、查看剩余时间状态（`-Status` / `--status`）以及切换全局开局默认策略（`-GlobalAutoGrant` / `--global-auto-grant`）。
- **防自解锁护盾（Anti-Tamper Guard）与多跳软链加固**：
  - 全面拦截 AI 智能体通过 `write_file` / `edit_file` / `Write` / `Edit` / `MultiEdit` / `NotebookEdit`、MCP 工具或终端命令（含 `git log > .allow_media` 重定向与无后缀脚本调用）自行创建、修改、伪造 `.allow_media`、`agent-blindfold.json` 或篡改已安装的插件钩子，严禁 Agent 私自调用 `unlock` 解锁脚本。
  - 新增最多 16 跳 Windows 目录联接（`ReparsePoint` / Junction）真实路径追踪，封堵 `generate_image` `ImagePaths` 数组泄露及 `cp`/`mv` 跨层复制到沙盒的跳板绕过。
- **全量跨平台自动化回归测试套件扩展（`tests/run_tests.py`）**：
  - 扩展至 25 组多场景端到端测试，全面覆盖 Windows PowerShell 与 Bash + Python 3 双引擎及 `install.ps1` / `install.sh` 隔离沙盒安装与卸载。

---

## [1.0.0] - 2026-11-10 — 项目代号：`Heart-Under-Blade (刃下心)`

### ✨ 初始发布特性
- **双宿主协议物理防火墙引擎（`scripts/guard.ps1` & `scripts/guard.sh`）**：
  - 原生支持 **Google Antigravity**（`toolCall` / `workspacePaths`）与 **Claude Code**（`tool_name` / `tool_input` / `cwd` 空 `stdout` 零权限劫持中立透传）。
  - Windows PowerShell 5.1+ 底层直写无 BOM UTF-8 字节流，彻底消除 `cmd /c` 额外反斜杠转义问题。
- **智能三级目录物理隔离**：
  - **第一级（核心私人禁区）**：`Pictures`、`Videos`、`Music`、`AppData` 永久物理焊死；直接访问或直接作为根目录打开的 `Desktop`、`Downloads`、`Documents` 同样严格锁死。
  - **第二级（外部目录隔离）**：拦截当前独立项目工作区以外的一切本地媒体读取。
  - **第三级（独立工作区默认隔离与子项目兼容）**：智能兼容克隆在 `~/Downloads/<repo>` 下的子工程，默认隔离二进制媒体并放行工作区内 `.svg` 矢量图标。
- **终端与 MCP 穿透防绕过**：
  - 拦截针对私人目录的终端枚举及未授权时的 `base64`、`certutil`、`PIL`、`cv2`、`ffmpeg`、`magick` 转码偷看行为，无感放行安全 `git` 操作。
  - 穿透解析 `call_mcp_tool` 嵌套参数、解码 `file://` URI、拦截 `../` 路径穿越并解析符号链接。
- **软硬双层原生插件与无损幂等安装器（`install.ps1` & `install.sh`）**：
  - 结合 `rules/AGENTS.md` 提示词软纪律与 `PreToolUse` 物理拦截，提供自动备份的无损安装与一键干净卸载，内置跨平台 CI 矩阵测试。
