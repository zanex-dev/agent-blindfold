#!/usr/bin/env bash
# ==============================================================================
# One-click installer for agent-blindfold (Codename: Heart-Under-Blade / 刃下心)
# Supports: Google Antigravity & Claude Code on macOS / Linux
# Author: 琢玹 (zanex) - https://github.com/zanex
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGY_PLUGIN_DIR="${HOME}/.gemini/config/plugins/agent-blindfold"

echo "================================================================"
echo "  agent-blindfold | Codename: Heart-Under-Blade (刃下心)"
echo "  Zero-Trust Media Privacy & Anti-Ban Shield Installer"
echo "================================================================"

mkdir -p "${AGY_PLUGIN_DIR}/scripts"
cp "${REPO_ROOT}/plugin.json" "${AGY_PLUGIN_DIR}/plugin.json"
cp "${REPO_ROOT}/scripts/guard.sh" "${AGY_PLUGIN_DIR}/scripts/guard.sh"
cp "${REPO_ROOT}/scripts/guard.ps1" "${AGY_PLUGIN_DIR}/scripts/guard.ps1"
chmod +x "${AGY_PLUGIN_DIR}/scripts/guard.sh"

cat > "${AGY_PLUGIN_DIR}/hooks.json" << 'EOF'
{
  "agent-blindfold": {
    "PreToolUse": [
      {
        "matcher": "read_file|view_file|read_resource|Read|View|mcp_.*",
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

echo "[+] Installed Antigravity Global Plugin to: ${AGY_PLUGIN_DIR}"

if [ -d "${HOME}/.claude" ]; then
    CLAUDE_HOOK_DIR="${HOME}/.claude/hooks/agent-blindfold"
    mkdir -p "${CLAUDE_HOOK_DIR}"
    cp "${REPO_ROOT}/scripts/guard.sh" "${CLAUDE_HOOK_DIR}/guard.sh"
    chmod +x "${CLAUDE_HOOK_DIR}/guard.sh"
    echo "[+] Copied Claude Code Hook script to: ${CLAUDE_HOOK_DIR}/guard.sh"
fi

echo ""
echo "[OK] agent-blindfold is now active! Your private stash is physically shielded."
