# Security Policy & Threat Model

## Supported Versions

| Version | Codename | Supported |
| :--- | :--- | :--- |
| `1.0.x` | `Heart-Under-Blade (刃下心)` | ✅ Active |

---

## Threat Model & Guarantee Scope

**`agent-blindfold`** is a deterministic, host-side `PreToolUse` physical firewall designed to protect developers using local multimodal AI Coding Agents (**Google Antigravity** and **Claude Code**) against **accidental or autonomous local media upload**.

### What `agent-blindfold` Protects Against
1. **Direct Multimodal File Reads**: Intercepts `read_file`, `view_file`, `read_resource`, `Read`, `View`, `NotebookRead`, and nested MCP calls (`call_mcp_tool`, `markitdown`, `filesystem`, `playwright` / `chrome-devtools` `file://` navigation) before file bytes leave your disk.
2. **Path Obfuscation & Symlink Escapes**: Normalizes `..` relative traversals, expands `~` / `$HOME` / `%USERPROFILE%`, decodes percent-encoded `file://` URIs (`%20`), and resolves filesystem symlinks to their real target paths before evaluation.
3. **Common Terminal / Shell Bypasses**: Inspects `run_command` and `Bash` invocations to block directory scans on personal media vaults (`Pictures`, `Videos`, `Music`), shell operations touching external/personal media files, and byte-dumping / imaging scripts (`base64`, `certutil`, `xxd`, `PIL`, `cv2`, `ffmpeg`, `magick`, `tesseract`) against locked workspace assets.
4. **Permission Hijacking Prevention**: On Claude Code, `agent-blindfold` exits with `0` and **empty `stdout`** whenever a tool call is permitted, preserving Claude Code's native user permission prompts instead of force-approving unrelated commands.

### Out of Scope (Defense-in-Depth Notes)
Static command-string inspection on arbitrary Turing-complete shell execution (`Bash` / `run_command`) cannot mathematically prove what dynamically generated code inside an external script file will read if an adversary intentionally obfuscates filenames without extensions. For adversarial or untrusted repositories, combine `agent-blindfold` with OS-level sandboxing.

---

## Reporting a Vulnerability / Bypass

If you discover a false-negative bypass (e.g., an unhandled tool parameter key, URI encoding trick, or shell one-liner that leaks media bytes in normal agent workflows), please open a GitHub Security Advisory or Issue on [github.com/zanex-dev/agent-blindfold](https://github.com/zanex-dev/agent-blindfold) with a minimal reproduction payload (without including private media).
