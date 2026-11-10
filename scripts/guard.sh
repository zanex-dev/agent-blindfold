#!/usr/bin/env bash
# ==============================================================================
# agent-blindfold (Codename: Heart-Under-Blade / 刃下心)
# Zero-trust local media privacy & anti-ban PreToolUse Hook
# Supports: Google Antigravity & Claude Code (macOS / Linux)
# Author: 琢玹 (zanex) - https://github.com/zanex
# License: MIT License - Copyright (c) 2026 琢玹 (zanex)
# ==============================================================================

set -euo pipefail

# Prefer python3 for zero-dependency reliable JSON parsing & path normalization on macOS/Linux
PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
fi

if [ -z "$PYTHON_BIN" ]; then
    printf '{"decision":"allow"}\n'
    exit 0
fi

exec "$PYTHON_BIN" -c '
import json, os, re, sys

MEDIA_EXTS = {
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".ico",
    ".mp4", ".mkv", ".avi", ".mov", ".webm", ".flv",
    ".mp3", ".wav", ".flac",
}
FORBIDDEN_DIRS = {"pictures", "videos", "desktop", "downloads", "documents", "appdata"}

REASON_PERSONAL_OR_EXT = "触发全局媒体隐私隔离铁律 (agent-blindfold)：严禁读取个人目录或外部目录的图片与音视频文件。"
REASON_WS_DEFAULT = "触发全局媒体隐私隔离铁律 (agent-blindfold)：工作区内媒体文件默认隔离拦截（如需临时放行，请在当前工作区根目录创建 .allow_media 标记文件）。"

def emit(decision, reason="", is_claude=False):
    if is_claude:
        if decision == "deny":
            payload = {
                "decision": "block",
                "reason": reason,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                },
            }
        else:
            payload = {"decision": "approve"}
    else:
        payload = {"decision": decision}
        if reason:
            payload["reason"] = reason
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    sys.exit(0)

def norm(p):
    cleaned = re.sub(r"^file:///+", "/", p.strip().strip("\"").strip("\x27"), flags=re.I)
    return os.path.normcase(os.path.abspath(os.path.expandvars(os.path.expanduser(cleaned))))

def is_subpath(target, parent):
    try:
        return os.path.commonpath([norm(target), norm(parent)]) == norm(parent)
    except ValueError:
        return False

def in_forbidden_dir(target):
    parts = [ seg.lower() for seg in re.split(r"[\\/]+", norm(target)) if seg ]
    return any(seg in FORBIDDEN_DIRS for seg in parts)

try:
    raw = sys.stdin.read()
    if not raw.strip():
        emit("allow")
    data = json.loads(raw)
except Exception:
    emit("allow")

is_claude = ("tool_name" in data) and ("toolCall" not in data)
args = (data.get("toolCall") or {}).get("args") if not is_claude else data.get("tool_input")
if not isinstance(args, dict):
    emit("allow", is_claude=is_claude)

keys = ("Path", "path", "file_path", "filePath", "FilePath", "AbsolutePath", "absolutePath", "TargetFile", "targetFile", "File", "file", "Uri", "uri", "notebook_path")
targets = [ args[k].strip() for k in keys if isinstance(args.get(k), str) and args[k].strip() ]
for ak in ("Paths", "paths", "Files", "files"):
    if isinstance(args.get(ak), list):
        targets.extend([ x.strip() for x in args[ak] if isinstance(x, str) and x.strip() ])

if not targets:
    emit("allow", is_claude=is_claude)

workspaces = [ w for w in (data.get("workspacePaths") or []) if isinstance(w, str) and w.strip() ]
if isinstance(data.get("cwd"), str) and data["cwd"].strip():
    workspaces.append(data["cwd"].strip())

for t in targets:
    _, ext = os.path.splitext(t)
    ext = ext.lower()
    in_personal = in_forbidden_dir(t)
    if ext not in MEDIA_EXTS and not (ext == ".svg" and in_personal):
        continue
    if in_personal or not workspaces:
        emit("deny", REASON_PERSONAL_OR_EXT, is_claude)
    matched = [ ws for ws in workspaces if is_subpath(t, ws) ]
    if not matched:
        emit("deny", REASON_PERSONAL_OR_EXT, is_claude)
    if not any(os.path.isfile(os.path.join(ws, ".allow_media")) for ws in matched):
        emit("deny", REASON_WS_DEFAULT, is_claude)

emit("allow", is_claude=is_claude)
'
