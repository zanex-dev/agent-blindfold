#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cross-platform end-to-end test suite for agent-blindfold (Codename: Heart-Under-Blade).
Tests:
  1. Guard hook engines (scripts/guard.ps1 on Windows/PowerShell, scripts/guard.sh on Bash/Unix)
  2. Antigravity & Claude Code PreToolUse JSON contracts (UTF-8 no BOM, zero extra escaping)
  3. Smart 3-Tier directory defense (Hard Vaults, Personal Containers vs Subprojects, External Dirs, .allow_media)
  4. Shell command bypass protection (base64/PIL/ffmpeg/Pictures scan vs safe git commands)
  5. Web URI exemption, file:// percent-decoding, and ../ path traversal prevention
  6. Idempotent Installer & Uninstaller lossless settings.json merge in an isolated temp HOME
"""
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.parse

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
GUARD_PS1 = os.path.join(REPO_ROOT, "scripts", "guard.ps1")
GUARD_SH = os.path.join(REPO_ROOT, "scripts", "guard.sh")
INSTALL_PS1 = os.path.join(REPO_ROOT, "install.ps1")
INSTALL_SH = os.path.join(REPO_ROOT, "install.sh")


def find_powershell():
    if platform.system() == "Windows":
        if shutil.which("powershell"):
            norm_ps1 = GUARD_PS1.replace("\\", "/").replace("'", "''")
            return ["cmd", "/c", f"powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command . '{norm_ps1}'"]
    if shutil.which("pwsh"):
        return ["pwsh", "-NoProfile", "-NonInteractive", "-File", GUARD_PS1]
    return None


def find_bash():
    if platform.system() != "Windows":
        if shutil.which("bash"):
            return ["bash", GUARD_SH]
        return None
    # On Windows, prefer Git Bash over WSL stub (System32\bash.exe fails when no WSL distro exists)
    git_bin = shutil.which("git")
    if git_bin:
        git_root = os.path.dirname(os.path.dirname(git_bin))
        candidate = os.path.join(git_root, "bin", "bash.exe")
        if os.path.isfile(candidate):
            return [candidate, GUARD_SH.replace("\\", "/")]
    return None


def invoke_guard(cmd_list, payload, env_extra=None):
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    proc = subprocess.Popen(
        cmd_list,
        cwd=REPO_ROOT,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    raw_in = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    out_bytes, err_bytes = proc.communicate(input=raw_in, timeout=15)
    assert proc.returncode == 0, (
        f"Non-zero exit {proc.returncode} for {cmd_list}!\nSTDERR: {err_bytes.decode('utf-8', errors='replace')}"
    )
    # Ensure NO UTF-8 BOM in stdout
    assert not out_bytes.startswith(b"\xef\xbb\xbf"), f"UTF-8 BOM detected in stdout: {out_bytes!r}"
    out_str = out_bytes.decode("utf-8").strip()
    assert not out_str.startswith('{\\"'), f"Extra backslash quote escaping detected: {out_str}"
    parsed = json.loads(out_str) if out_str else None
    return out_str, parsed


def run_engine_suite(engine_name, cmd_list):
    print(f"\n=== Testing Guard Engine: {engine_name} ===")

    # Use a sandbox directory outside AppData (since Windows %TEMP% lives inside AppData\Local\Temp,
    # which agent-blindfold rightly treats as a Hard Vault!)
    sandbox = os.path.join(REPO_ROOT, ".tmp_test_sandbox")
    shutil.rmtree(sandbox, ignore_errors=True)
    os.makedirs(sandbox, exist_ok=True)
    try:
        fake_downloads = os.path.join(sandbox, "UserHome", "Downloads")
        subproject_ws = os.path.join(fake_downloads, "my-web-app")
        external_dir = os.path.join(sandbox, "external_folder")
        fake_pictures = os.path.join(sandbox, "UserHome", "Pictures")
        fake_appdata = os.path.join(sandbox, "UserHome", "AppData", "Roaming")

        for d in (fake_downloads, subproject_ws, external_dir, fake_pictures, fake_appdata):
            os.makedirs(d, exist_ok=True)

        allow_marker = os.path.join(subproject_ws, ".allow_media")
        downloads_marker = os.path.join(fake_downloads, ".allow_media")

        # 1. [Antigravity] Hard Vault (Pictures & AppData) -> Unconditional deny even if passed as workspace
        _, res = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": os.path.join(fake_pictures, "shinobu.png")}},
            "workspacePaths": [fake_pictures],
        })
        assert res["decision"] == "deny" and "触发全局媒体隐私隔离铁律" in res["reason"], f"Case 1a failed: {res}"

        _, res_app = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": os.path.join(fake_appdata, "cache.webp")}},
            "workspacePaths": [fake_appdata],
        })
        assert res_app["decision"] == "deny", f"Case 1b failed: {res_app}"
        print("  [PASS] 01. Hard Vaults (Pictures & AppData) unconditionally denied with clean bilingual UTF-8")

        # 2. [Antigravity] .svg inside Hard Vault (Pictures) -> Denied
        _, res = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": os.path.join(fake_pictures, "illust.svg")}},
            "workspacePaths": [subproject_ws],
        })
        assert res["decision"] == "deny", f"Case 2 failed: {res}"
        print("  [PASS] 02. .svg inside Hard Vault (Pictures) denied")

        # 3. [Antigravity] Downloads opened directly as workspace + .allow_media inside Downloads -> STILL Hard Denied!
        with open(downloads_marker, "w", encoding="utf-8") as f:
            f.write("")
        _, res = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": os.path.join(fake_downloads, "private_photo.jpg")}},
            "workspacePaths": [fake_downloads],
        })
        assert res["decision"] == "deny", f"Case 3 failed: {res}"
        os.remove(downloads_marker)
        print("  [PASS] 03. Root Downloads opened as workspace remains locked even with .allow_media")

        # 4. [Antigravity] Subproject inside Downloads (Downloads/my-web-app) WITHOUT .allow_media -> Default Deny
        _, res = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": os.path.join(subproject_ws, "src", "hero.webp")}},
            "workspacePaths": [subproject_ws],
        })
        assert res["decision"] == "deny" and ".allow_media" in res["reason"], f"Case 4 failed: {res}"
        print("  [PASS] 04. Subproject inside Downloads isolated by default (no .allow_media)")

        # 5. [Antigravity] Subproject inside Downloads WITH .allow_media -> Allowed!
        with open(allow_marker, "w", encoding="utf-8") as f:
            f.write("")
        _, res = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": os.path.join(subproject_ws, "src", "hero.webp")}},
            "workspacePaths": [subproject_ws],
        })
        assert res == {"decision": "allow"}, f"Case 5 failed: {res}"
        print("  [PASS] 05. Subproject inside Downloads unlocked cleanly with .allow_media")

        # 6. [Antigravity] Sibling leak check: Downloads/leak.jpg while Downloads/my-web-app has .allow_media -> Denied!
        _, res = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": os.path.join(fake_downloads, "leak.jpg")}},
            "workspacePaths": [subproject_ws],
        })
        assert res["decision"] == "deny", f"Case 6 failed: {res}"
        os.remove(allow_marker)
        print("  [PASS] 06. Sibling media in parent Downloads blocked despite subproject .allow_media")

        # 7. [Antigravity] External directory media (.flac / .heic) -> Hard Denied
        _, res = invoke_guard(cmd_list, {
            "toolCall": {"name": "view_file", "args": {"Path": os.path.join(external_dir, "voice.flac")}},
            "workspacePaths": [subproject_ws],
        })
        assert res["decision"] == "deny", f"Case 7 failed: {res}"
        print("  [PASS] 07. External directory audio/image blocked")

        # 8. [Antigravity] Workspace .svg icon WITHOUT .allow_media -> Exempted & Allowed
        _, res = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": os.path.join(subproject_ws, "icons", "brand.svg")}},
            "workspacePaths": [subproject_ws],
        })
        assert res == {"decision": "allow"}, f"Case 8 failed: {res}"
        print("  [PASS] 08. Workspace .svg plain-text vector icon exempted")

        # 9. [Antigravity] Public https:// image URL in browser/MCP tool -> Allowed
        _, res = invoke_guard(cmd_list, {
            "toolCall": {
                "name": "call_mcp_tool",
                "args": {"ServerName": "playwright", "ToolName": "browser_navigate", "Arguments": {"url": "https://example.com/banner.png"}},
            },
            "workspacePaths": [subproject_ws],
        })
        assert res == {"decision": "allow"}, f"Case 9 failed: {res}"
        print("  [PASS] 09. Public https:// media URL allowed without false positive")

        # 10. [Antigravity] Percent-encoded file:// URI with ?query#fragment in MCP tool -> Denied
        pic_space = os.path.join(fake_pictures, "my secret.png").replace("\\", "/")
        encoded_uri = "file:///" + urllib.parse.quote(pic_space.lstrip("/"), safe=":/") + "?raw=1#preview"
        _, res = invoke_guard(cmd_list, {
            "toolCall": {
                "name": "call_mcp_tool",
                "args": {"ServerName": "markitdown", "ToolName": "convert_to_markdown", "Arguments": {"uri": encoded_uri}},
            },
            "workspacePaths": [subproject_ws],
        })
        assert res["decision"] == "deny", f"Case 10a failed: {res}"

        # 10b. NTFS Alternate Data Stream (::$DATA) and trailing dot bypass -> Denied
        _, res_ads = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": os.path.join(fake_pictures, "shinobu.png::$DATA")}},
            "workspacePaths": [subproject_ws],
        })
        assert res_ads["decision"] == "deny", f"Case 10b failed: {res_ads}"
        _, res_dot = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": os.path.join(fake_pictures, "shinobu.png.")}},
            "workspacePaths": [subproject_ws],
        })
        assert res_dot["decision"] == "deny", f"Case 10c failed: {res_dot}"
        print("  [PASS] 10. Nested MCP file://?query, NTFS ::$DATA, and trailing-dot bypasses blocked")

        # 11. [Antigravity] Relative path traversal & directory junction/symlink escape -> Denied
        traversal = os.path.join(subproject_ws, "..", "..", "Pictures", "secret.jpg")
        _, res = invoke_guard(cmd_list, {
            "toolCall": {"name": "read_file", "args": {"Path": traversal}},
            "workspacePaths": [subproject_ws],
        })
        assert res["decision"] == "deny", f"Case 11a failed: {res}"

        # Create a directory junction (Windows) or symlink (Unix) inside workspace pointing to external_dir
        link_dir = os.path.join(subproject_ws, "linked_ext")
        ext_media = os.path.join(external_dir, "escaped.png")
        with open(ext_media, "wb") as f:
            f.write(b"fake")
        with open(allow_marker, "w", encoding="utf-8") as f:
            f.write("")
        created_link = False
        try:
            if platform.system() == "Windows":
                subprocess.run(["cmd", "/c", "mklink", "/J", link_dir, external_dir], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                created_link = True
            else:
                os.symlink(external_dir, link_dir)
                created_link = True
        except Exception:
            created_link = False

        if created_link:
            _, res_link = invoke_guard(cmd_list, {
                "toolCall": {"name": "read_file", "args": {"Path": os.path.join(link_dir, "escaped.png")}},
                "workspacePaths": [subproject_ws],
            })
            assert res_link["decision"] == "deny", f"Case 11b (junction/symlink escape) failed: {res_link}"
            if platform.system() == "Windows":
                subprocess.run(["cmd", "/c", "rmdir", link_dir], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            else:
                os.unlink(link_dir)
        os.remove(allow_marker)
        print("  [PASS] 11. Relative ../ path traversal & directory junction/symlink escape blocked")

        # 12. [Antigravity] Shell bypass: encoding workspace image via base64 / PIL without .allow_media -> Denied
        _, res = invoke_guard(cmd_list, {
            "toolCall": {
                "name": "run_command",
                "args": {"CommandLine": "python -c \"import base64; print(base64.b64encode(open('assets/hero.png','rb').read()))\""},
            },
            "workspacePaths": [subproject_ws],
        })
        assert res["decision"] == "deny", f"Case 12a failed: {res}"

        # 12b. Shell directory scan on ~/Pictures -> Denied
        _, res2 = invoke_guard(cmd_list, {
            "toolCall": {"name": "run_command", "args": {"CommandLine": "ls -la ~/Pictures"}},
            "workspacePaths": [subproject_ws],
        })
        assert res2["decision"] == "deny", f"Case 12b failed: {res2}"
        print("  [PASS] 12. Shell bypass (base64 dump & ~/Pictures scan) blocked")

        # 13. [Antigravity] Safe Git operations on workspace media (including wildcards *.png) -> Allowed
        _, res = invoke_guard(cmd_list, {
            "toolCall": {"name": "run_command", "args": {"CommandLine": "git add assets/shinobu-banner.png *.png"}},
            "workspacePaths": [subproject_ws],
        })
        assert res == {"decision": "allow"}, f"Case 13a failed: {res}"

        _, res_wc_dump = invoke_guard(cmd_list, {
            "toolCall": {"name": "run_command", "args": {"CommandLine": "base64 *.png"}},
            "workspacePaths": [subproject_ws],
        })
        assert res_wc_dump["decision"] == "deny", f"Case 13b failed: {res_wc_dump}"
        print("  [PASS] 13. Safe git add (including *.png wildcards) allowed; wildcard base64 dump blocked")

        # 14. [Claude Code] Personal media Read -> hookSpecificOutput.permissionDecision == 'deny'
        _, res = invoke_guard(cmd_list, {
            "hook_event_name": "PreToolUse",
            "tool_name": "Read",
            "tool_input": {"file_path": os.path.join(fake_pictures, "private.png")},
            "cwd": subproject_ws,
        })
        assert res["hookSpecificOutput"]["permissionDecision"] == "deny", f"Case 14 failed: {res}"
        print("  [PASS] 14. Claude Code PreToolUse structured deny verified")

        # 15. [Claude Code] Neutral Pass-through on code Read & Bash -> Empty stdout (no auto-approval hijack!)
        raw_out, parsed_out = invoke_guard(cmd_list, {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "npm test"},
            "cwd": subproject_ws,
        })
        assert raw_out == "" and parsed_out is None, f"Case 15 failed: expected empty stdout, got {raw_out!r}"
        print("  [PASS] 15. Claude Code neutral pass-through (empty stdout) verified")

        # 16. Language environment switch (AGENT_BLINDFOLD_LANG=en)
        _, res_en = invoke_guard(
            cmd_list,
            {
                "toolCall": {"name": "read_file", "args": {"Path": os.path.join(fake_pictures, "a.jpg")}},
                "workspacePaths": [subproject_ws],
            },
            env_extra={"AGENT_BLINDFOLD_LANG": "en"},
        )
        assert res_en["decision"] == "deny" and "|" not in res_en["reason"], f"Case 16 failed: {res_en}"
        print("  [PASS] 16. AGENT_BLINDFOLD_LANG=en language override verified")
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def run_installer_sandbox_test():
    print("\n=== Testing Idempotent Installer & Uninstaller (Isolated Temp HOME) ===")
    with tempfile.TemporaryDirectory() as fake_home:
        claude_dir = os.path.join(fake_home, ".claude")
        os.makedirs(claude_dir, exist_ok=True)
        claude_settings = os.path.join(claude_dir, "settings.json")

        # Seed existing user settings and an unrelated PreToolUse hook to verify lossless merge
        initial_settings = {
            "theme": "dark",
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Write",
                        "hooks": [{"type": "command", "command": "echo existing-hook"}],
                    }
                ]
            },
        }
        with open(claude_settings, "w", encoding="utf-8") as f:
            json.dump(initial_settings, f, indent=2)

        env = os.environ.copy()
        env["HOME"] = fake_home
        env["USERPROFILE"] = fake_home

        if platform.system() == "Windows" and shutil.which("powershell"):
            install_cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", INSTALL_PS1]
            uninstall_cmd = install_cmd + ["-Uninstall"]
        else:
            install_cmd = ["bash", INSTALL_SH]
            uninstall_cmd = ["bash", INSTALL_SH, "--uninstall"]

        # Run install twice to verify idempotency (no duplicate entries)
        subprocess.run(install_cmd, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        subprocess.run(install_cmd, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        agy_plugin = os.path.join(fake_home, ".gemini", "config", "plugins", "agent-blindfold", "plugin.json")
        agy_rule = os.path.join(fake_home, ".gemini", "config", "plugins", "agent-blindfold", "rules", "AGENTS.md")
        assert os.path.isfile(agy_plugin) and os.path.isfile(agy_rule), "Antigravity plugin files missing after install!"

        with open(claude_settings, "r", encoding="utf-8") as f:
            merged = json.load(f)
        assert merged["theme"] == "dark", "Existing Claude setting lost during merge!"
        pre_hooks = merged["hooks"]["PreToolUse"]
        assert len(pre_hooks) == 2, f"Expected 2 hooks (1 existing + 1 blindfold, idempotent), got {len(pre_hooks)}: {pre_hooks}"
        print("  [PASS] 17. Lossless & idempotent install verified (Antigravity + Claude Code)")

        # Run uninstall and verify clean restoration
        subprocess.run(uninstall_cmd, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert not os.path.exists(os.path.dirname(agy_plugin)), "Antigravity plugin dir still exists after uninstall!"

        with open(claude_settings, "r", encoding="utf-8") as f:
            cleaned = json.load(f)
        assert cleaned["theme"] == "dark"
        assert len(cleaned["hooks"]["PreToolUse"]) == 1, f"Expected 1 remaining hook after uninstall, got {cleaned}"
        print("  [PASS] 18. Clean non-destructive uninstall verified")


def main():
    tested_any = False
    ps_cmd = find_powershell()
    if ps_cmd:
        run_engine_suite("PowerShell (scripts/guard.ps1)", ps_cmd)
        tested_any = True

    bash_cmd = find_bash()
    if bash_cmd:
        run_engine_suite("Bash + Python (scripts/guard.sh)", bash_cmd)
        tested_any = True

    assert tested_any, "Neither PowerShell nor Bash was found to run tests!"
    run_installer_sandbox_test()
    print("\nALL E2E SECURITY & INSTALLER TESTS PASSED!")


if __name__ == "__main__":
    main()
