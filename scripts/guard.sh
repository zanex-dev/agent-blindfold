#!/usr/bin/env bash
# ==============================================================================
# agent-blindfold (Codename: Heart-Under-Blade / 刃下心)
# Zero-trust local media privacy & anti-ban PreToolUse Hook
# Supports: Google Antigravity & Claude Code (macOS / Linux / Git Bash)
# Author: 琢玹 (zanex) - https://github.com/zanex
# License: MIT License - Copyright (c) 2026 琢玹 (zanex)
# ==============================================================================

set -euo pipefail

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
fi

if [ -z "$PYTHON_BIN" ]; then
    INPUT_RAW="$(cat || true)"
    if printf '%s' "$INPUT_RAW" | grep -q '"tool_name"'; then
        exit 0
    fi
    printf '{"decision":"allow"}\n'
    exit 0
fi

exec "$PYTHON_BIN" -c '
import json
import os
import re
import sys
import urllib.parse

MEDIA_EXTS = {
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".ico", ".heic", ".heif", ".avif",
    ".mp4", ".mkv", ".avi", ".mov", ".webm", ".flv", ".wmv",
    ".mp3", ".wav", ".flac", ".m4a", ".ogg", ".aac",
}
HARD_VAULT_DIRS = {"pictures", "videos", "music", "appdata"}
PERSONAL_CONTAINER_DIRS = {"desktop", "downloads", "documents"}

EN_PERSONAL = "Blocked by agent-blindfold (Heart-Under-Blade): Access to personal or external media files is strictly forbidden."
ZH_PERSONAL = "触发全局媒体隐私隔离铁律：严禁读取或触碰个人目录及外部目录的图片与音视频文件。"

EN_WS = "Blocked by agent-blindfold (Heart-Under-Blade): Workspace media is isolated by default. Create \x27.allow_media\x27 in the workspace root to unlock temporarily."
ZH_WS = "触发全局媒体隐私隔离铁律：工作区内媒体文件默认隔离拦截（如需临时放行，请在当前工作区根目录创建 .allow_media 标记文件）。"

lang = os.environ.get("AGENT_BLINDFOLD_LANG", "bilingual").strip().lower()
if lang == "en":
    REASON_PERSONAL = EN_PERSONAL
    REASON_WS = EN_WS
elif lang == "zh":
    REASON_PERSONAL = ZH_PERSONAL
    REASON_WS = ZH_WS
else:
    REASON_PERSONAL = f"{EN_PERSONAL} | {ZH_PERSONAL}"
    REASON_WS = f"{EN_WS} | {ZH_WS}"


def emit(decision: str, reason: str = "", is_claude: bool = False) -> None:
    if is_claude:
        if decision == "deny":
            payload = {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
            out = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
            sys.stdout.buffer.write(out.encode("utf-8"))
            sys.stdout.buffer.flush()
        sys.exit(0)
    else:
        payload = {"decision": decision}
        if reason:
            payload["reason"] = reason
        out = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
        sys.stdout.buffer.write(out.encode("utf-8"))
        sys.stdout.buffer.flush()
        sys.exit(0)


def is_web_uri(raw: str) -> bool:
    if not raw or not raw.strip():
        return True
    t = raw.strip().strip("\"").strip("\x27")
    return bool(re.match(r"^(https?|wss?|data|mailto|about|chrome|javascript|blob):", t, re.I))


def normalize_local_path(raw: str, base_dir: str = "") -> str:
    if not raw or not raw.strip():
        return ""
    cleaned = raw.strip().strip("\"").strip("\x27")
    if re.match(r"^file://", cleaned, re.I):
        cleaned = re.sub(r"[?#].*$", "", cleaned)
        cleaned = urllib.parse.unquote(cleaned)
        m = re.match(r"^file:///+([A-Za-z]:.*)$", cleaned, re.I)
        if m:
            cleaned = m.group(1)
        else:
            cleaned = re.sub(r"^file://+", "/", cleaned, flags=re.I)

    home = os.path.expanduser("~")
    cleaned = re.sub(r"^\$HOME(?=[\\/]|$)", home.replace("\\", "/"), cleaned)
    cleaned = re.sub(r"^\$env:USERPROFILE(?=[\\/]|$)", home.replace("\\", "/"), cleaned, flags=re.I)
    cleaned = os.path.expandvars(os.path.expanduser(cleaned))

    # Strip Windows NTFS Alternate Data Streams (e.g. foo.png::$DATA) and trailing dots/spaces
    cleaned = re.sub(r"(?<=.{2})::?[A-Za-z0-9_.$]+$", "", cleaned)
    cleaned = cleaned.rstrip(". ")
    cleaned = cleaned.replace("*", "__WC_STAR__").replace("?", "__WC_Q__")

    if not os.path.isabs(cleaned) and base_dir:
        cleaned = os.path.join(base_dir, cleaned)

    return os.path.normcase(os.path.realpath(os.path.abspath(cleaned)))


def get_segments(norm_path: str) -> list[str]:
    return [seg.lower() for seg in re.split(r"[\\/]+", norm_path) if seg]


def in_hard_vault(norm_path: str) -> bool:
    return any(seg in HARD_VAULT_DIRS for seg in get_segments(norm_path))


def in_personal_container(norm_path: str) -> bool:
    return any(seg in PERSONAL_CONTAINER_DIRS for seg in get_segments(norm_path))


def is_valid_project_workspace(ws: str) -> bool:
    if not ws or not ws.strip():
        return False
    norm_ws = normalize_local_path(ws).rstrip("\\/")
    if not norm_ws or re.match(r"^[a-z]:$", norm_ws, re.I):
        return False
    home_norm = normalize_local_path(os.path.expanduser("~")).rstrip("\\/")
    if norm_ws == home_norm:
        return False
    if in_hard_vault(norm_ws):
        return False
    leaf = os.path.basename(norm_ws).lower()
    if leaf in PERSONAL_CONTAINER_DIRS:
        return False
    return True


def is_subpath(target_norm: str, ws_norm: str) -> bool:
    try:
        return os.path.commonpath([target_norm, ws_norm]) == ws_norm
    except ValueError:
        return False


def evaluate_media_path(raw_target: str, base_dir: str, valid_workspaces: list[str]):
    if is_web_uri(raw_target):
        return None
    norm_target = normalize_local_path(raw_target, base_dir)
    if not norm_target:
        return None

    _, ext = os.path.splitext(norm_target)
    ext = ext.lower()
    hard_vault = in_hard_vault(norm_target)
    personal_container = in_personal_container(norm_target)
    matched_ws = [ws for ws in valid_workspaces if is_subpath(norm_target, ws)]

    if ext == ".svg":
        if hard_vault:
            return REASON_PERSONAL
        if personal_container and not matched_ws:
            return REASON_PERSONAL
        return None

    if ext not in MEDIA_EXTS:
        return None

    if hard_vault:
        return REASON_PERSONAL

    if not matched_ws:
        return REASON_PERSONAL

    for ws in matched_ws:
        if os.path.isfile(os.path.join(ws, ".allow_media")):
            return None

    return REASON_WS


def main() -> None:
    try:
        raw_input = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        if not raw_input.strip():
            emit("allow")
        data = json.loads(raw_input)
    except Exception:
        emit("allow")

    is_claude = ("tool_name" in data) and ("toolCall" not in data)
    args = (data.get("toolCall") or {}).get("args") if not is_claude else data.get("tool_input")
    if not isinstance(args, dict):
        emit("allow", is_claude=is_claude)

    raw_ws = [w for w in (data.get("workspacePaths") or []) if isinstance(w, str) and w.strip()]
    base_dir = ""
    if isinstance(data.get("cwd"), str) and data["cwd"].strip():
        base_dir = normalize_local_path(data["cwd"])
        raw_ws.append(data["cwd"])
    elif raw_ws:
        base_dir = normalize_local_path(raw_ws[0])

    valid_ws = []
    for w in raw_ws:
        if is_valid_project_workspace(w):
            nw = normalize_local_path(w).rstrip("\\/")
            if nw not in valid_ws:
                valid_ws.append(nw)

    # Branch A: Shell Command Guard
    cmd_line = ""
    for ck in ("CommandLine", "command", "cmd"):
        if isinstance(args.get(ck), str) and args[ck].strip():
            cmd_line = args[ck]
            break

    if cmd_line:
        vault_scan_re = r"(?i)(?:^|[\s\"\x27`=(]|[A-Za-z]:|~|\$HOME|\$env:USERPROFILE|%USERPROFILE%)[\\/](?:Pictures|Videos|Music)(?:[\\/]|[\s\"\x27`;|&)]|$)"
        if re.search(vault_scan_re, cmd_line):
            emit("deny", REASON_PERSONAL, is_claude)

        ext_grp = "jpg|jpeg|png|gif|webp|bmp|ico|heic|heif|avif|mp4|mkv|avi|mov|webm|flv|wmv|mp3|wav|flac|m4a|ogg|aac|svg"
        tokens = []
        tokens.extend(re.findall(rf"(?i)\"([^\"\r\n]+\.(?:{ext_grp}))\"", cmd_line))
        tokens.extend(re.findall(rf"(?i)\x27([^\x27\r\n]+\.(?:{ext_grp}))\x27", cmd_line))
        tokens.extend(re.findall(rf"(?i)(?<![A-Za-z0-9_.:/-])([^\s\"\x27`|;&<>()]+\.(?:{ext_grp}))(?![A-Za-z0-9_])", cmd_line))

        is_safe_git = bool(re.match(r"^\s*git\s+(?:commit|status|log|branch|tag|push|pull|fetch)\b", cmd_line))
        is_dumper = bool(re.search(
            r"(?i)\b(?:base64|certutil|xxd|hexdump|od|Format-Hex|AsByteStream|ReadAllBytes|ToBase64String|PIL|Pillow|Image\.open|cv2|imread|imageio|pytesseract|tesseract|easyocr|ffmpeg|ffprobe|magick|identify|exiftool|sips|markitdown)\b|-Encoding\s+Byte",
            cmd_line,
        ))

        for tok in tokens:
            if is_web_uri(tok):
                continue
            if is_safe_git and not re.search(r"[\\/]", tok):
                continue
            verdict = evaluate_media_path(tok, base_dir, valid_ws)
            if verdict == REASON_PERSONAL:
                emit("deny", REASON_PERSONAL, is_claude)
            elif verdict == REASON_WS and is_dumper:
                emit("deny", REASON_WS, is_claude)

    # Branch B: Direct File / Resource / MCP Tool Arguments
    sources = [args]
    if isinstance(args.get("Arguments"), dict):
        sources.append(args["Arguments"])

    cand_keys = (
        "Path", "path", "file_path", "filePath", "FilePath",
        "AbsolutePath", "absolutePath", "TargetFile", "targetFile",
        "File", "file", "Uri", "uri", "url", "Url", "notebook_path",
        "source", "destination",
    )
    targets = []
    for src in sources:
        for k in cand_keys:
            val = src.get(k)
            if isinstance(val, str) and val.strip():
                targets.append(val.strip())
        for ak in ("Paths", "paths", "Files", "files"):
            arr = src.get(ak)
            if isinstance(arr, list):
                targets.extend([x.strip() for x in arr if isinstance(x, str) and x.strip()])

    for t in targets:
        verdict = evaluate_media_path(t, base_dir, valid_ws)
        if verdict is not None:
            emit("deny", verdict, is_claude)

    emit("allow", is_claude=is_claude)


if __name__ == "__main__":
    main()
'
