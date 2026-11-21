# Changelog

**English** | [简体中文](./CHANGELOG_zh.md)

All notable changes to **`agent-blindfold`** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-11-21 — User-Scoped Private Grant Store, Fail-Closed Hardening & Modular Python Runtime

### Added & Changed
- **User-Scoped Private Grant Store (`scripts/grant_store.ps1` & `scripts/grant_store.py`)**:
  - Moved workspace pass storage out of project repositories into the current user's private directory (`~/.gemini/config/agent-blindfold-grants/`), keyed by canonical resolved workspace path with symlink/reparse verification, file locking, and atomic writes.
  - Issuing, renewing, or revoking a grant never touches project files or `.git/info/exclude`—keeping Git working trees clean across regular repositories, linked Git worktrees, and submodules (gitfile layouts).
  - Windows PowerShell and Python engines share identical canonical workspace identity (including Chinese characters and spaces in paths), and root or empty paths are strictly rejected as workspace targets.
- **Modular Python 3.9+ Unix Engine & Verified Runtime Discovery (`scripts/guard.py`, `scripts/session_start.py`, `scripts/unlock.py`, `scripts/python_runtime.sh`)**:
  - Refactored Unix hooks into modular Python 3.9+ scripts wrapped by lightweight Bash entrypoints (`guard.sh`, `session_start.sh`, `unlock.sh`).
  - Probes active virtual environments, verified `PATH` executables (skipping empty `WindowsApps` stub aliases under Git Bash), and the Windows `py -3` launcher while ensuring hook bodies execute only once.
- **Expanded Local Grant & Host Integration Test Suite (`tests/test_local_grants.py`)**:
  - Added 28 integration and regression tests covering user-scoped grant storage, ignored legacy `.allow_media` files, gitfile worktrees, corrupted policies, host-specific fail-closed responses, surgical installer/uninstaller hook merging, and cross-engine interoperability.

### Fixed & Hardened
- **Legacy Repo-Bundled `.allow_media` Ignored & Fail-Closed Policy Handling (Migration Note)**:
  - In-project `.allow_media` files are now ignored and left untouched so cloned third-party repositories can never ship pre-unlocked passes. Existing manual grants must be reissued via the local controller (`unlock.ps1` / `unlock.sh` / `blindfold-control.cmd`).
  - Corrupt or invalid top-level JSON in `~/.gemini/config/agent-blindfold.json` pauses new automatic grant issuance with diagnostics instead of falling back to auto-grant.
- **Explicit Host Protocol Binding & Fail-Closed Guard Responses (`hooks.json`, `scripts/guard.ps1`, `scripts/guard.sh`, `scripts/guard.py`)**:
  - Installed entrypoints explicitly bind the target host (`-HookHost antigravity|claude` or `antigravity|claude`). Malformed/empty hook payloads or a missing Python 3.9+ interpreter now return a host-compatible `deny` decision and diagnostic message instead of silently passing through.
- **Surgical Non-Destructive Claude Code Hook Merging (`scripts/claude_settings.py`, `install.ps1`, `install.sh`)**:
  - Install, upgrade, and uninstall match only `agent-blindfold`-owned hook commands—preserving co-located third-party hooks, matchers, and ordering. Uninstall cleans host settings before removing scripts and only deletes local grants/policy after the final host target is removed.
- **Unified Policy & Status Diagnostics (`scripts/unlock.ps1`, `scripts/unlock.py`)**:
  - `-Status` / `--status` shares policy resolution with `SessionStart`, displaying effective values, TTL, environment override sources, and explicitly noting ignored legacy `.allow_media` files.
- **Windows Batch-Read Performance Optimization (`scripts/guard.ps1`)**:
  - Reuses canonical path resolution and fixed control directories within a single guard invocation (never persisted across calls), reducing median 100-file Markdown batch-read guard time on Windows from ~4.72s to ~1.10s.

## [1.1.2] - 2026-11-11 — Windows CLI Crash Fixes & Shell Option/Subcommand Hardening

### Fixed & Hardened
- **Crash Fixes on Windows PowerShell 5.1 / .NET 4.8 (`scripts/guard.ps1`)**:
  - Fixed a `Join-Path` `DriveNotFoundException` (`Cannot find drive. A drive with the name '/out' does not exist`) when commands pass MSVC/.NET/MSBuild slash switches containing colons (`csc "/out:C:\..."`, `/target:winexe`, `/win32icon:...`, `msbuild "/p:OutDir=C:\..."`).
  - Fixed `.NET Framework 4.8` `ArgumentException` (`Illegal characters in path`) in `GetExtension` / `GetFileName` when shell regexes or pipelines contain `|`, `<`, `>`, or nested quotes (e.g. `rg "hero.jpg|banner.png"`).
- **Eliminated False-Positive Blocks on Quoted Flags & Compound Subshells in Tier 0 Sandboxes (`scripts/guard.ps1` & `scripts/guard.sh`)**:
  - Unwraps quoted CLI option prefixes (`"--output=<path>"`, `"/win32icon:<path>"`) and distinguishes multi-argument subshell commands (`powershell -Command "Copy-Item <scratch>\a.png <scratch>\b.png"`) from single literal filenames so Tier 0 sandbox operations are never misclassified when a locked workspace is mounted.
- **Closed Shell Option-Prefix, `file:` URI, Space-in-Path & Dynamic `cd` Bypasses (`scripts/guard.ps1` & `scripts/guard.sh`)**:
  - Prevents `Normalize-LocalPath` fallback from prepending an unlocked workspace `BaseDir` onto malformed/embedded-drive tokens, and unwraps `curl` `@`/`key=@` upload tokens, `dd` `if=`, and RFC 8089 `file:<path>` URIs (without `//`) so external/personal media cannot masquerade as relative workspace files.
  - Extracts space-containing rooted media paths inside quoted subcommands (e.g. `cmd /c "certutil -encode C:\Users\...\Downloads\my secret.png out.txt"`).
  - Treats `cd` into unexpanded dynamic shell variables (`cd "$d"`) as untrusted when evaluating relative media operations, blocking `d=~/Downloads; cd "$d" && base64 secret.jpg` escapes without affecting non-media loops.

## [1.1.1] - 2026-11-11 — Tier 0 & Workspace Media Editing Fix

### Fixed & Hardened
- **Shell Media Editing & Slicing inside Tier 0 Sandboxes (`scripts/guard.ps1` & `scripts/guard.sh`)**:
  - Fixed false-positive blocks when inline scripts (`PIL`/`Pillow`, `cv2`, `ffmpeg`, `magick`) operate on Tier 0 sandboxes (`brain/<conversationId>` including current-session `.user_uploaded/` & `scratch/`, or `scratch/<subproject>`) using relative/template output filenames (e.g. `slice_{idx}.png`) without an active workspace (`workspacePaths = []`) or inside read-only chat workspaces.
  - Added shell directory-change tracking (`cd`, `chdir`, `pushd`, `Set-Location`, `Push-Location`, `sl`): permits relative media operations after changing into Tier 0 sandboxes or unlocked workspaces while blocking rogue `cd ~/Downloads && base64 ...` escapes from unlocked workspaces.
  - Excluded `=` and `,` from unquoted shell path token extraction so CLI flag syntax (`--output=<path>`, `file=<path>`) resolves cleanly.
- **Explicit Media Editing Guidance (`rules/AGENTS.md`, `session_start.ps1`, `session_start.sh`)**:
  - Clarified that Tier 0 sandboxes and `.allow_media`-unlocked workspaces permit full media creation, cropping, slicing, and script-based editing—reserving bypass prohibitions strictly for blocked private, external, or cross-session paths.

## [1.1.0] - 2026-11-11 — Smart Engineering Auto-Exemption & Timed/Permanent Passes

### Added
- **Tier 0 Engineering Sandbox Auto-Exemption (`scripts/guard.ps1` & `scripts/guard.sh`)**:
  - Automatically exempts Antigravity project sandboxes (`~/.gemini/antigravity/scratch/<subproject>/...`), the active conversation's `artifactDirectoryPath` (`brain/<conversationId>/...` while blocking cross-session `.user_uploaded/` leaks), Playwright frontend verification screenshots (`<workspace>/.playwright-mcp/`), and non-vault `.svg` vector files—eliminating false-positive blocks during UI/frontend engineering even when no Active Workspace is mounted.
- **`SessionStart` Automatic Pass Issuance (`scripts/session_start.ps1` & `scripts/session_start.sh`)**:
  - Automatically issues a **Timed (`timed`, default TTL `2h`)** or **Permanent (`permanent`)** `.allow_media` v2 pass at the start of an engineering session based on `~/.gemini/config/agent-blindfold.json` (configurable via installer flags `-AutoGrant` / `--auto-grant` or `unlock` CLI).
  - Automatically skips personal vaults (`Pictures`, `Downloads` root, etc.) and read-only chat workspaces (`chat` folder or `AGENTS.md` declaring read-only/chat mode).
  - Automatically appends `.allow_media` to `<workspace>/.git/info/exclude` so Git repositories remain clean without modifying tracked `.gitignore` files.
- **`.allow_media` v2 Structured Pass & Auto-Expiration**:
  - Supports structured JSON passes (`{"mode": "timed", "expires_at": ...}` and `{"mode": "permanent"}`), shorthand plain-text (`permanent`, `30m`, `2h`, `1d`), and legacy empty `.allow_media` files (defaulting to `2h` TTL via `file mtime + AGENT_BLINDFOLD_EMPTY_TTL`) with automatic cleanup of expired passes.
- **User Pass Controller CLI & Click-Through Launcher (`scripts/unlock.ps1`, `scripts/unlock.sh`, `blindfold-control.cmd`)**:
  - One-command CLI and interactive console menu on Windows/macOS/Linux to grant timed or permanent workspace passes, revoke passes (`-Lock` / `--lock`), inspect remaining TTL (`-Status` / `--status`), or switch global `SessionStart` policy.
- **Anti-Tamper Guard (Self-Unlock Prevention)**:
  - Blocks AI Agents from creating, editing, forging, or deleting `.allow_media` or `agent-blindfold.json` via `write_file`/`edit_file`/`Write`/`Edit`/`MultiEdit`, MCP tools, or shell commands (`run_command`/`Bash`), and blocks Agents from invoking `unlock.ps1`/`unlock.sh`/`blindfold-control.cmd`.
  - Hardens shell `git` exemptions against command chaining (`&&`, `;`, `|`, `` ` ``, `$()`).
- **Expanded Cross-Platform E2E Security Suite (`tests/run_tests.py`)**:
  - Expanded test coverage across PowerShell and Bash engines for Tier 0 sandboxes, cross-session `.user_uploaded` isolation, timed pass expiration & auto-deletion, permanent passes, Anti-Tamper Guard, `SessionStart` auto-grant, and `unlock` CLI controllers.

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
