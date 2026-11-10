# Security Policy & Threat Model

## Supported Versions

| Version | Codename | Supported |
| :--- | :--- | :--- |
| `1.1.x` | `Heart-Under-Blade (刃下心)` | ✅ Active |
| `1.0.x` | `Heart-Under-Blade (刃下心)` | ⚠️ Security fixes only |

---

## Threat Model & Guarantee Scope

**`agent-blindfold`** is a deterministic, host-side `SessionStart` + `PreToolUse` physical firewall designed to protect developers using local multimodal AI Coding Agents (**Google Antigravity** and **Claude Code**) against **accidental or autonomous local media upload** while keeping frontend and UI engineering friction-free.

### What `agent-blindfold` Protects Against
1. **Direct Multimodal File Reads**: Intercepts `read_file`, `view_file`, `read_resource`, `Read`, `View`, `NotebookRead`, and nested MCP calls (`call_mcp_tool`, `markitdown`, `filesystem`, `playwright` / `chrome-devtools` `file://` navigation) before file bytes leave your disk.
2. **Path Obfuscation & Symlink Escapes**: Normalizes `..` relative traversals, expands `~` / `$HOME` / `%USERPROFILE%`, strips NTFS Alternate Data Streams (`::$DATA`), decodes percent-encoded `file://` URIs (`%20`), and resolves filesystem symlinks/junctions to their real target paths **before** evaluating Tier 0 sandbox or Tier 3 workspace exemptions—ensuring a symlink inside `scratch/` or a project workspace pointing to `Pictures/` is still unconditionally denied.
3. **Cross-Session Upload Leakage**: While exempting the active conversation's `artifactDirectoryPath` (`brain/<current-conversation-id>`), `agent-blindfold` explicitly blocks reading `.user_uploaded/` attachments belonging to **other** conversation IDs unless explicitly pointed to by `artifactDirectoryPath`.
4. **Agent Self-Unlock / Privilege Escalation (Anti-Tamper Guard)**: Intercepts file-mutation tools (`write_file`, `edit_file`, `Write`, `Edit`, `MultiEdit`, MCP write tools) and shell commands (`run_command`, `Bash`) to strictly forbid AI Agents from creating, modifying, forging, or deleting `.allow_media`, `~/.gemini/config/agent-blindfold.json`, or invoking `unlock.ps1` / `unlock.sh` / `blindfold-control.cmd`.
5. **Common Terminal / Shell Bypasses**: Inspects `run_command` and `Bash` invocations to block directory scans on personal media vaults (`Pictures`, `Videos`, `Music`), shell operations touching external/personal media files, command-chained `git` spoofing (`git status && base64 a.png`), and byte-dumping / imaging scripts (`base64`, `certutil`, `xxd`, `PIL`, `cv2`, `ffmpeg`, `magick`, `tesseract`) against locked workspace assets.
6. **Permission Hijacking Prevention**: On Claude Code, `agent-blindfold` exits with `0` and **empty `stdout`** whenever a tool call or `SessionStart` event is permitted, preserving Claude Code's native user permission prompts instead of force-approving unrelated commands.

### Out of Scope (Defense-in-Depth Notes)
Static command-string inspection on arbitrary Turing-complete shell execution (`Bash` / `run_command`) cannot mathematically prove what dynamically generated code inside an external script file will read if an adversary intentionally obfuscates filenames without extensions. For adversarial or untrusted repositories, combine `agent-blindfold` with OS-level sandboxing.

---

## Reporting a Vulnerability / Bypass

If you discover a false-negative bypass (e.g., an unhandled tool parameter key, URI encoding trick, or shell one-liner that leaks media bytes in normal agent workflows), please open a GitHub Security Advisory or Issue on [github.com/zanex-dev/agent-blindfold](https://github.com/zanex-dev/agent-blindfold) with a minimal reproduction payload (without including private media).
