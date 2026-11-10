#!/usr/bin/env bash
# ==============================================================================
# One-click installer & uninstaller for agent-blindfold v1.1 (Heart-Under-Blade / 刃下心)
# Supports: Google Antigravity & Claude Code on macOS / Linux
# Author: 琢玹 (zanex-dev) - https://github.com/zanex-dev
# ==============================================================================

set -euo pipefail

TARGET="all"
AUTO_GRANT="timed"
DEFAULT_TTL="2h"
EXPLICIT_POLICY=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|-t)
            TARGET="${2:-all}"
            shift 2
            ;;
        --auto-grant)
            AUTO_GRANT="${2:-timed}"
            EXPLICIT_POLICY=1
            shift 2
            ;;
        --ttl)
            DEFAULT_TTL="${2:-2h}"
            EXPLICIT_POLICY=1
            shift 2
            ;;
        --uninstall|-u)
            UNINSTALL=1
            shift
            ;;
        --help|-h)
            echo "Usage: ./install.sh [--target all|antigravity|claude] [--auto-grant timed|permanent|off] [--ttl 2h] [--uninstall]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

case "$AUTO_GRANT" in
    timed|permanent|off) ;;
    *)
        echo "Invalid --auto-grant mode '$AUTO_GRANT' (must be timed, permanent, or off)." >&2
        exit 1
        ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEMINI_CONFIG_DIR="${HOME}/.gemini/config"
POLICY_FILE="${GEMINI_CONFIG_DIR}/agent-blindfold.json"
AGY_PLUGIN_DIR="${GEMINI_CONFIG_DIR}/plugins/agent-blindfold"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_HOOK_DIR="${CLAUDE_DIR}/hooks/agent-blindfold"
CLAUDE_SETTINGS="${CLAUDE_DIR}/settings.json"

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
fi

if [[ "$UNINSTALL" -eq 0 && -z "$PYTHON_BIN" ]]; then
    echo "[ERROR] Python 3 ('python3' or 'python') is required by agent-blindfold Unix hooks." >&2
    exit 1
fi

echo "================================================================"
echo "  agent-blindfold v1.1 | Codename: Heart-Under-Blade (刃下心)"
if [[ "$UNINSTALL" -eq 1 ]]; then
    echo "  Mode: UNINSTALL"
else
    echo "  Mode: INSTALL (Target: ${TARGET}, AutoGrant: ${AUTO_GRANT}, TTL: ${DEFAULT_TTL})"
fi
echo "================================================================"

# ------------------------------------------------------------------------------
# 0. Global SessionStart Auto-Exemption Policy (~/.gemini/config/agent-blindfold.json)
# ------------------------------------------------------------------------------
if [[ "$UNINSTALL" -eq 0 ]]; then
    if [[ ! -f "$POLICY_FILE" || "$EXPLICIT_POLICY" -eq 1 ]]; then
        mkdir -p "$GEMINI_CONFIG_DIR"
        NOW_TS="$(date +%s)"
        cat > "$POLICY_FILE" << EOF
{
  "sessionAutoGrant": "${AUTO_GRANT}",
  "defaultTTL": "${DEFAULT_TTL}",
  "updatedAt": ${NOW_TS}
}
EOF
        echo "[+] Configured SessionStart auto-exemption policy (${AUTO_GRANT} / ${DEFAULT_TTL}): ${POLICY_FILE}"
    else
        echo "[i] Preserved existing SessionStart policy: ${POLICY_FILE}"
    fi
fi

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
        cp "${REPO_ROOT}/blindfold-control.cmd" "${AGY_PLUGIN_DIR}/blindfold-control.cmd"
        cp "${REPO_ROOT}/rules/AGENTS.md" "${AGY_PLUGIN_DIR}/rules/AGENTS.md"
        cp "${REPO_ROOT}/scripts/guard.sh" "${AGY_PLUGIN_DIR}/scripts/guard.sh"
        cp "${REPO_ROOT}/scripts/guard.ps1" "${AGY_PLUGIN_DIR}/scripts/guard.ps1"
        cp "${REPO_ROOT}/scripts/session_start.sh" "${AGY_PLUGIN_DIR}/scripts/session_start.sh"
        cp "${REPO_ROOT}/scripts/session_start.ps1" "${AGY_PLUGIN_DIR}/scripts/session_start.ps1"
        cp "${REPO_ROOT}/scripts/unlock.sh" "${AGY_PLUGIN_DIR}/scripts/unlock.sh"
        cp "${REPO_ROOT}/scripts/unlock.ps1" "${AGY_PLUGIN_DIR}/scripts/unlock.ps1"
        chmod +x "${AGY_PLUGIN_DIR}/scripts/guard.sh" "${AGY_PLUGIN_DIR}/scripts/session_start.sh" "${AGY_PLUGIN_DIR}/scripts/unlock.sh"

        cat > "${AGY_PLUGIN_DIR}/hooks.json" << 'EOF'
{
  "agent-blindfold": {
    "SessionStart": [
      {
        "type": "command",
        "command": "./scripts/session_start.sh",
        "timeout": 10
      }
    ],
    "PreToolUse": [
      {
        "matcher": "read_file|view_file|read_resource|write_file|write_to_file|edit_file|replace_file_content|multi_replace_file_content|generate_image|run_command|call_mcp_tool|mcp_.*|Read|View|NotebookRead|Write|Edit|MultiEdit|NotebookEdit|Bash",
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
        echo "[+] Installed Antigravity Global Plugin (SessionStart + PreToolUse + Rule): ${AGY_PLUGIN_DIR}"
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
    hooks = cfg.get("hooks", {})
    if isinstance(hooks, dict):
        pre = hooks.get("PreToolUse")
        if isinstance(pre, list):
            hooks["PreToolUse"] = [
                e for e in pre
                if not any("agent-blindfold" in str(h.get("command", "")) for h in (e.get("hooks") or []))
            ]
        ses = hooks.get("SessionStart")
        if isinstance(ses, list):
            filtered_ses = [
                e for e in ses
                if not any("agent-blindfold" in str(h.get("command", "")) for h in (e.get("hooks") or []))
            ]
            if filtered_ses:
                hooks["SessionStart"] = filtered_ses
            else:
                hooks.pop("SessionStart", None)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"[-] Cleaned agent-blindfold entries from: {path}")
except Exception as exc:
    print(f"[!] Could not auto-clean {path}: {exc}")
PYEOF
        fi
    else
        if [[ -d "$CLAUDE_DIR" || "$TARGET" == "claude" ]]; then
            mkdir -p "$CLAUDE_HOOK_DIR"
            cp "${REPO_ROOT}/scripts/guard.sh" "${CLAUDE_HOOK_DIR}/guard.sh"
            cp "${REPO_ROOT}/scripts/session_start.sh" "${CLAUDE_HOOK_DIR}/session_start.sh"
            cp "${REPO_ROOT}/scripts/unlock.sh" "${CLAUDE_HOOK_DIR}/unlock.sh"
            chmod +x "${CLAUDE_HOOK_DIR}/guard.sh" "${CLAUDE_HOOK_DIR}/session_start.sh" "${CLAUDE_HOOK_DIR}/unlock.sh"

            if [[ -n "$PYTHON_BIN" ]]; then
                "$PYTHON_BIN" - "$CLAUDE_SETTINGS" "${CLAUDE_HOOK_DIR}/guard.sh" "${CLAUDE_HOOK_DIR}/session_start.sh" << 'PYEOF'
import json, os, shutil, sys
settings_path, guard_sh, session_sh = sys.argv[1], sys.argv[2], sys.argv[3]
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
    "matcher": "Read|View|NotebookRead|Write|Edit|MultiEdit|NotebookEdit|Bash|mcp__.*",
    "hooks": [{"type": "command", "command": f'"{guard_sh}"'}],
})
hooks["PreToolUse"] = pre

ses = hooks.setdefault("SessionStart", [])
ses = [
    e for e in ses
    if not any("agent-blindfold" in str(h.get("command", "")) for h in (e.get("hooks") or []))
]
ses.append({
    "hooks": [{"type": "command", "command": f'"{session_sh}"'}],
})
hooks["SessionStart"] = ses

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"[+] Merged SessionStart & PreToolUse hooks into Claude Code settings: {settings_path}")
PYEOF
            else
                echo "[+] Copied Claude Code hooks to ${CLAUDE_HOOK_DIR} (install python3 to auto-merge settings.json)."
            fi
        else
            echo "[i] ~/.claude not detected; skipped Claude Code setup (pass '--target claude' to force)."
        fi
    fi
fi

echo ""
if [[ "$UNINSTALL" -eq 1 ]]; then
    if [[ ! -d "$AGY_PLUGIN_DIR" && ! -d "$CLAUDE_HOOK_DIR" && -f "$POLICY_FILE" ]]; then
        rm -f "$POLICY_FILE"
        echo "[-] Removed global policy config: ${POLICY_FILE}"
    fi
    echo "[OK] agent-blindfold has been cleanly uninstalled."
else
    echo "[OK] agent-blindfold v1.1 is active! Private vaults locked; engineering workspaces auto-exempted (${AUTO_GRANT})."
fi
