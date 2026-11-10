#!/usr/bin/env bash
# ==============================================================================
# One-click installer & uninstaller for agent-blindfold (Heart-Under-Blade / 刃下心)
# Supports: Google Antigravity & Claude Code on macOS / Linux
# Author: 琢玹 (zanex-dev) - https://github.com/zanex-dev
# ==============================================================================

set -euo pipefail

TARGET="all"
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|-t)
            TARGET="${2:-all}"
            shift 2
            ;;
        --uninstall|-u)
            UNINSTALL=1
            shift
            ;;
        --help|-h)
            echo "Usage: ./install.sh [--target all|antigravity|claude] [--uninstall]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGY_PLUGIN_DIR="${HOME}/.gemini/config/plugins/agent-blindfold"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_HOOK_DIR="${CLAUDE_DIR}/hooks/agent-blindfold"
CLAUDE_SETTINGS="${CLAUDE_DIR}/settings.json"

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
fi

echo "================================================================"
echo "  agent-blindfold | Codename: Heart-Under-Blade (刃下心)"
if [[ "$UNINSTALL" -eq 1 ]]; then
    echo "  Mode: UNINSTALL"
else
    echo "  Mode: INSTALL (Target: ${TARGET})"
fi
echo "================================================================"

# ------------------------------------------------------------------------------
# 1. Google Antigravity
# ------------------------------------------------------------------------------
if [[ "$TARGET" == "all" || "$TARGET" == "antigravity" ]]; then
    if [[ "$UNINSTALL" -eq 1 ]]; then
        if [[ -d "$AGY_PLUGIN_DIR" ]]; then
            rm -rf "$AGY_PLUGIN_DIR"
            echo "[-] Removed Antigravity plugin: ${AGY_PLUGIN_DIR}"
        else
            echo "[i] Antigravity plugin not found (already clean)."
        fi
    else
        mkdir -p "${AGY_PLUGIN_DIR}/scripts" "${AGY_PLUGIN_DIR}/rules"
        cp "${REPO_ROOT}/plugin.json" "${AGY_PLUGIN_DIR}/plugin.json"
        cp "${REPO_ROOT}/rules/AGENTS.md" "${AGY_PLUGIN_DIR}/rules/AGENTS.md"
        cp "${REPO_ROOT}/scripts/guard.sh" "${AGY_PLUGIN_DIR}/scripts/guard.sh"
        cp "${REPO_ROOT}/scripts/guard.ps1" "${AGY_PLUGIN_DIR}/scripts/guard.ps1"
        chmod +x "${AGY_PLUGIN_DIR}/scripts/guard.sh"

        cat > "${AGY_PLUGIN_DIR}/hooks.json" << 'EOF'
{
  "agent-blindfold": {
    "PreToolUse": [
      {
        "matcher": "read_file|view_file|read_resource|run_command|call_mcp_tool|mcp_markitdown_.*|mcp_filesystem_.*|mcp_playwright_browser_navigate|mcp_chrome.*navigate.*|Read|View|NotebookRead|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/guard.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF
        echo "[+] Installed Antigravity Global Plugin (Hook + Rule): ${AGY_PLUGIN_DIR}"
    fi
fi

# ------------------------------------------------------------------------------
# 2. Claude Code
# ------------------------------------------------------------------------------
if [[ "$TARGET" == "all" || "$TARGET" == "claude" ]]; then
    if [[ "$UNINSTALL" -eq 1 ]]; then
        if [[ -d "$CLAUDE_HOOK_DIR" ]]; then
            rm -rf "$CLAUDE_HOOK_DIR"
            echo "[-] Removed Claude Code hook scripts: ${CLAUDE_HOOK_DIR}"
        fi
        if [[ -f "$CLAUDE_SETTINGS" && -n "$PYTHON_BIN" ]]; then
            "$PYTHON_BIN" - "$CLAUDE_SETTINGS" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    pre = cfg.get("hooks", {}).get("PreToolUse")
    if isinstance(pre, list):
        cfg["hooks"]["PreToolUse"] = [
            e for e in pre
            if not any("agent-blindfold" in str(h.get("command", "")) for h in (e.get("hooks") or []))
        ]
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"[-] Cleaned agent-blindfold entry from: {path}")
except Exception as exc:
    print(f"[!] Could not auto-clean {path}: {exc}")
PYEOF
        fi
    else
        if [[ -d "$CLAUDE_DIR" || "$TARGET" == "claude" ]]; then
            mkdir -p "$CLAUDE_HOOK_DIR"
            cp "${REPO_ROOT}/scripts/guard.sh" "${CLAUDE_HOOK_DIR}/guard.sh"
            chmod +x "${CLAUDE_HOOK_DIR}/guard.sh"

            if [[ -n "$PYTHON_BIN" ]]; then
                "$PYTHON_BIN" - "$CLAUDE_SETTINGS" "${CLAUDE_HOOK_DIR}/guard.sh" << 'PYEOF'
import json, os, shutil, sys
settings_path, guard_sh = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.isfile(settings_path):
    shutil.copy2(settings_path, settings_path + ".bak")
    with open(settings_path, "r", encoding="utf-8") as f:
        raw = f.read().strip()
        if raw:
            cfg = json.loads(raw)

hooks = cfg.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])
pre = [
    e for e in pre
    if not any("agent-blindfold" in str(h.get("command", "")) for h in (e.get("hooks") or []))
]
pre.append({
    "matcher": "Read|View|NotebookRead|Bash|mcp__.*",
    "hooks": [{"type": "command", "command": f'"{guard_sh}"'}],
})
hooks["PreToolUse"] = pre

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"[+] Merged PreToolUse hook into Claude Code settings: {settings_path}")
PYEOF
            else
                echo "[+] Copied Claude Code hook to ${CLAUDE_HOOK_DIR}/guard.sh (install python3 to auto-merge settings.json)."
            fi
        else
            echo "[i] ~/.claude not detected; skipped Claude Code setup (pass '--target claude' to force)."
        fi
    fi
fi

echo ""
if [[ "$UNINSTALL" -eq 1 ]]; then
    echo "[OK] agent-blindfold has been cleanly uninstalled."
else
    echo "[OK] agent-blindfold is active! Your private stash is physically shielded."
fi
