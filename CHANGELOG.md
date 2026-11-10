# Changelog

All notable changes to **`agent-blindfold`** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-10 — Codename: `Heart-Under-Blade (刃下心)`

### Added
- **Dual-Agent Protocol Engine (`scripts/guard.ps1` & `scripts/guard.sh`)**:
  - Native support for **Google Antigravity** (`toolCall` / `workspacePaths`) and **Claude Code** (`tool_name` / `tool_input` / `cwd` with neutral empty-stdout pass-through).
  - Clean UTF-8 (no BOM) output stream on Windows PowerShell 5.1+ without `cmd /c` backslash-quote corruption.
- **Smart 3-Tier Directory Isolation**:
  - **Tier 1 (Hard Vaults)**: `Pictures`, `Videos`, `Music`, and `AppData` are permanently locked, as are `Desktop`, `Downloads`, and `Documents` when accessed directly or opened as a root workspace.
  - **Tier 2 (External Isolation)**: Blocks media files outside active dedicated project workspaces.
  - **Tier 3 (Workspace Isolation & Subproject Support)**: Isolates binary media inside active project workspaces (including subprojects cloned under `~/Downloads/<repo>` or `~/Desktop/<repo>`) by default; unlocks via `<workspace>/.allow_media` while exempting workspace `.svg` vector icons.
- **Shell & MCP Bypass Protection**:
  - Guards `run_command` / `Bash` against `Pictures`/`Videos` directory scans, external media access, and byte-encoding/vision utilities (`base64`, `certutil`, `PIL`, `cv2`, `ffmpeg`, `magick`) while keeping `git add`/`git commit` friction-free.
  - Inspects nested MCP arguments (`call_mcp_tool`), decodes `file://` URIs, blocks `../` path traversals, and resolves symlinks.
- **Dual-Layer Antigravity Plugin (`plugin.json`, `hooks.json`, `rules/AGENTS.md`)**:
  - Combines prompt-level media skipping rules with deterministic `PreToolUse` enforcement.
- **Idempotent Installer & Uninstaller (`install.ps1` & `install.sh`)**:
  - Lossless JSON merge into `~/.claude/settings.json` with automatic `.bak` backup and one-command `-Uninstall` / `--uninstall`.
- **Cross-Platform E2E Test Suite & GitHub Actions CI**:
  - 18 automated test scenarios in `tests/run_tests.py` verified across Windows, Linux, and macOS.
