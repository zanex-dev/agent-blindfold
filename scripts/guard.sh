#!/usr/bin/env bash
# ==============================================================================
# agent-blindfold (Codename: Heart-Under-Blade / 刃下心) v1.1
# Zero-trust local media privacy & anti-ban PreToolUse Hook
# Supports: Google Antigravity & Claude Code (macOS / Linux / Git Bash)
# Includes Tier 0 Engineering Sandbox Auto-Exemption, Timed/Permanent Passes & Anti-Tamper Guard
# Author: 琢玹 (zanex-dev) - https://github.com/zanex-dev
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
import glob
import json
import os
import re
import sys
import time
import urllib.parse

MEDIA_EXTS = {
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".ico", ".heic", ".heif", ".avif",
    ".mp4", ".mkv", ".avi", ".mov", ".webm", ".flv", ".wmv",
    ".mp3", ".wav", ".flac", ".m4a", ".ogg", ".aac",
}
HARD_VAULT_DIRS = {"pictures", "videos", "music", "appdata"}
PERSONAL_CONTAINER_DIRS = {"desktop", "downloads", "documents"}
PROTECTED_CONTROL_LEAVES = {".allow_media", "agent-blindfold.json"}
READ_ONLY_TOOLS = {
    "read_file", "view_file", "read_resource", "list_dir", "find_by_name", "grep_search",
    "Read", "View", "NotebookRead", "Glob", "Grep", "LS",
}
PURE_WRITE_CREATE_TOOLS = {
    "write_file", "write_to_file", "edit_file", "replace_file_content", "multi_replace_file_content",
    "Write", "Edit", "MultiEdit", "NotebookEdit",
}

EN_PERSONAL = "Blocked by agent-blindfold (Heart-Under-Blade): Access to personal or external media files is strictly forbidden."
ZH_PERSONAL = "触发全局媒体隐私隔离铁律：严禁读取或触碰个人目录及外部目录的图片与音视频文件。"

EN_WS = "Blocked by agent-blindfold (Heart-Under-Blade): Workspace media is isolated by default. Ask the user to grant a timed or permanent \x27.allow_media\x27 pass via the unlock script (Agents must never create it themselves)."
ZH_WS = "触发全局媒体隐私隔离铁律：工作区内媒体文件默认隔离拦截（如需放行，请提示用户在本地运行 unlock 脚本下发限时或永久 .allow_media 通行证，严禁 Agent 自行创建）。"

EN_EXPIRED = "Blocked by agent-blindfold (Heart-Under-Blade): Workspace \x27.allow_media\x27 timed pass has expired and was automatically cleaned up. Ask the user to renew it if still needed."
ZH_EXPIRED = "触发全局媒体隐私隔离铁律：当前工作区的 .allow_media 限时豁免通行证已到期失效并自动回收（如仍需读取，请提示用户重新下发）。"

EN_TAMPER = "Blocked by agent-blindfold (Heart-Under-Blade): AI Agents are strictly forbidden from creating, modifying, or forging \x27.allow_media\x27 passes or firewall policy files."
ZH_TAMPER = "触发全局媒体隐私隔离铁律：严禁 AI 智能体自行创建、修改或伪造 .allow_media 豁免通行证及防火墙策略配置。"

lang = os.environ.get("AGENT_BLINDFOLD_LANG", "bilingual").strip().lower()
if lang == "en":
    REASON_PERSONAL = EN_PERSONAL
    REASON_WS = EN_WS
    REASON_EXPIRED = EN_EXPIRED
    REASON_TAMPER = EN_TAMPER
elif lang == "zh":
    REASON_PERSONAL = ZH_PERSONAL
    REASON_WS = ZH_WS
    REASON_EXPIRED = ZH_EXPIRED
    REASON_TAMPER = ZH_TAMPER
else:
    REASON_PERSONAL = f"{EN_PERSONAL} | {ZH_PERSONAL}"
    REASON_WS = f"{EN_WS} | {ZH_WS}"
    REASON_EXPIRED = f"{EN_EXPIRED} | {ZH_EXPIRED}"
    REASON_TAMPER = f"{EN_TAMPER} | {ZH_TAMPER}"


def get_effective_home() -> str:
    if os.environ.get("USERPROFILE", "").strip() and os.name == "nt":
        return os.environ["USERPROFILE"].strip()
    if os.environ.get("HOME", "").strip():
        return os.environ["HOME"].strip()
    return os.path.expanduser("~")


def parse_duration_seconds(spec: str):
    if not spec or not spec.strip():
        return None
    m = re.match(r"^(\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)?$", spec.strip().lower())
    if not m:
        return None
    val = int(m.group(1))
    unit = m.group(2) or "s"
    if unit.startswith("s"):
        return val
    if unit.startswith("m"):
        return val * 60
    if unit.startswith("h"):
        return val * 3600
    if unit.startswith("d"):
        return val * 86400
    return None


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

    home = get_effective_home()
    cleaned = re.sub(r"^\$HOME(?=[\\/]|$)", home.replace("\\", "/"), cleaned)
    cleaned = re.sub(r"^\$env:USERPROFILE(?=[\\/]|$)", home.replace("\\", "/"), cleaned, flags=re.I)
    if cleaned.startswith("~") and (len(cleaned) == 1 or cleaned[1] in ("/", "\\")):
        cleaned = os.path.join(home, cleaned[1:].lstrip("/\\"))
    cleaned = os.path.expandvars(cleaned)

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


def is_subpath(target_norm: str, ws_norm: str) -> bool:
    t = target_norm.rstrip("\\/").lower()
    w = ws_norm.rstrip("\\/").lower()
    if not t or not w:
        return False
    if t == w:
        return True
    return t.startswith(w + "/") or t.startswith(w + "\\")


def is_valid_project_workspace(ws: str) -> bool:
    if not ws or not ws.strip():
        return False
    norm_ws = normalize_local_path(ws).rstrip("\\/")
    if not norm_ws or re.match(r"^[a-z]:$", norm_ws, re.I):
        return False
    home_norm = normalize_local_path(get_effective_home()).rstrip("\\/")
    if is_subpath(home_norm, norm_ws):
        return False
    gemini_root = os.path.join(home_norm, ".gemini")
    claude_root = os.path.join(home_norm, ".claude")
    if norm_ws.lower() == gemini_root.lower():
        return False
    if is_subpath(norm_ws, os.path.join(gemini_root, "config")):
        return False
    if is_subpath(norm_ws, claude_root):
        return False
    for fl in ("antigravity", "antigravity-cli", "antigravity-ide"):
        agy_dir = os.path.join(gemini_root, fl)
        if norm_ws.lower() == agy_dir.lower():
            return False
        if is_subpath(norm_ws, os.path.join(agy_dir, "brain")):
            return False
    if in_hard_vault(norm_ws):
        return False
    leaf = os.path.basename(norm_ws).lower()
    if leaf in PERSONAL_CONTAINER_DIRS:
        return False
    return True


def is_protected_control_target(raw_target: str, base_dir: str) -> bool:
    if is_web_uri(raw_target):
        return False
    norm = normalize_local_path(raw_target, base_dir).rstrip("\\/")
    if not norm:
        return False
    leaf = os.path.basename(norm).lower()
    if leaf in PROTECTED_CONTROL_LEAVES:
        return True
    home_norm = normalize_local_path(get_effective_home()).rstrip("\\/")
    agy_plugin = os.path.join(home_norm, ".gemini", "config", "plugins", "agent-blindfold")
    agy_hooks = os.path.join(home_norm, ".gemini", "config", "hooks.json")
    claude_hook = os.path.join(home_norm, ".claude", "hooks", "agent-blindfold")
    claude_cfg = os.path.join(home_norm, ".claude", "settings.json")
    claude_lcfg = os.path.join(home_norm, ".claude", "settings.local.json")
    if is_subpath(norm, agy_plugin) or is_subpath(norm, claude_hook):
        return True
    if norm.lower() in {agy_hooks.lower(), claude_cfg.lower(), claude_lcfg.lower()}:
        return True
    if leaf == "hooks.json" and os.path.basename(os.path.dirname(norm)).lower() == ".agents":
        return True
    return False


def in_other_brain_session(norm_target: str, artifact_dir_norm: str, conversation_id: str) -> bool:
    if artifact_dir_norm and is_subpath(norm_target, artifact_dir_norm):
        return False
    home_norm = normalize_local_path(get_effective_home()).rstrip("\\/")
    for flavor in ("antigravity", "antigravity-cli", "antigravity-ide"):
        brain_root = os.path.join(home_norm, ".gemini", flavor, "brain")
        if is_subpath(norm_target, brain_root):
            rel = norm_target[len(brain_root):].lstrip("\\/")
            rel_parts = [p for p in re.split(r"[\\/]+", rel) if p]
            if rel_parts and conversation_id and rel_parts[0].lower() == conversation_id.strip().lower():
                return False
            return True
    return False


def is_auto_exempt_engineering_sandbox(
    norm_target: str,
    matched_ws: list[str],
    artifact_dir_norm: str,
    conversation_id: str,
) -> bool:
    segs = get_segments(norm_target)
    has_user_uploaded = ".user_uploaded" in segs

    if artifact_dir_norm and is_subpath(norm_target, artifact_dir_norm):
        return True

    home_norm = normalize_local_path(get_effective_home()).rstrip("\\/")
    for flavor in ("antigravity", "antigravity-cli", "antigravity-ide"):
        agy_base = os.path.join(home_norm, ".gemini", flavor)

        scratch_root = os.path.join(agy_base, "scratch")
        if is_subpath(norm_target, scratch_root):
            rel = norm_target[len(scratch_root):].lstrip("\\/")
            rel_parts = [p for p in re.split(r"[\\/]+", rel) if p]
            if len(rel_parts) >= 2 and not has_user_uploaded:
                return True

        brain_root = os.path.join(agy_base, "brain")
        if is_subpath(norm_target, brain_root):
            rel = norm_target[len(brain_root):].lstrip("\\/")
            rel_parts = [p for p in re.split(r"[\\/]+", rel) if p]
            if len(rel_parts) >= 2 and conversation_id and rel_parts[0].lower() == conversation_id.strip().lower():
                return True

    for ws in matched_ws:
        if len(norm_target) > len(ws):
            rel_ws = norm_target[len(ws):].lstrip("\\/")
            if ".playwright-mcp" in get_segments(rel_ws):
                return True

    return False


def evaluate_allow_media_pass(marker_path: str) -> str:
    if not os.path.isfile(marker_path):
        return "missing"
    now_sec = int(time.time())
    try:
        mtime_sec = int(os.path.getmtime(marker_path))
        with open(marker_path, "r", encoding="utf-8", errors="replace") as f:
            raw_content = f.read().strip()
    except Exception:
        return "missing"

    def expire_and_remove() -> str:
        try:
            os.remove(marker_path)
        except OSError:
            pass
        return "expired"

    if not raw_content:
        empty_spec = os.environ.get("AGENT_BLINDFOLD_EMPTY_TTL", "2h").strip().lower()
        if empty_spec in ("permanent", "forever", "0"):
            return "valid"
        ttl_sec = parse_duration_seconds(empty_spec)
        if ttl_sec is None:
            ttl_sec = 7200
        return "valid" if now_sec <= (mtime_sec + ttl_sec) else expire_and_remove()

    if raw_content.startswith("{"):
        try:
            tok = json.loads(raw_content)
            if not isinstance(tok, dict):
                return "missing"
            mode = str(tok.get("mode", "")).strip().lower()
            if mode in ("permanent", "forever"):
                return "valid"
            if tok.get("expires_at") is not None:
                exp = int(float(tok["expires_at"]))
                if exp > 100000000000:
                    exp //= 1000
                return "valid" if now_sec <= exp else expire_and_remove()
            if mode == "timed" and tok.get("ttl_seconds") is not None:
                ttl = int(float(tok["ttl_seconds"]))
                base = int(float(tok.get("issued_at", mtime_sec)))
                return "valid" if now_sec <= (base + ttl) else expire_and_remove()
        except Exception:
            return "missing"
        return "missing"

    lower_text = raw_content.lower()
    if lower_text in ("permanent", "forever"):
        return "valid"
    dur_sec = parse_duration_seconds(lower_text)
    if dur_sec is not None:
        if dur_sec > 0 and now_sec <= (mtime_sec + dur_sec):
            return "valid"
        return expire_and_remove()

    return "missing"


def is_tier0_dir_anchor(
    norm_dir: str,
    valid_ws: list[str],
    art_dir_norm: str,
    conv_id: str,
) -> bool:
    if not norm_dir or in_hard_vault(norm_dir) or in_other_brain_session(norm_dir, art_dir_norm, conv_id):
        return False
    matched_ws = [ws for ws in valid_ws if is_subpath(norm_dir, ws)]
    probe = os.path.join(norm_dir, "__tier0_probe__.png")
    return is_auto_exempt_engineering_sandbox(probe, matched_ws, art_dir_norm, conv_id)


def is_unlocked_ws_dir(norm_dir: str, valid_ws: list[str]) -> bool:
    if not norm_dir or in_hard_vault(norm_dir):
        return False
    for ws in valid_ws:
        if is_subpath(norm_dir, ws):
            if evaluate_allow_media_pass(os.path.join(ws, ".allow_media")) == "valid":
                return True
    return False


def is_relative_non_traversal_token(raw_tok: str) -> bool:
    if not raw_tok or not raw_tok.strip():
        return False
    t = raw_tok.strip().strip("\"").strip("\x27")
    if re.match(r"^(?:[A-Za-z]:|[\\/]|~|\$HOME|\$env:USERPROFILE|%USERPROFILE%|file://)", t, re.I):
        return False
    return ".." not in re.split(r"[\\/]+", t)


def evaluate_media_path(
    raw_target: str,
    base_dir: str,
    valid_workspaces: list[str],
    artifact_dir_norm: str = "",
    conversation_id: str = "",
):
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

    if hard_vault or in_other_brain_session(norm_target, artifact_dir_norm, conversation_id):
        if ext == ".svg" or ext in MEDIA_EXTS:
            return REASON_PERSONAL
        return None

    if (ext == ".svg" or ext in MEDIA_EXTS) and is_auto_exempt_engineering_sandbox(
        norm_target, matched_ws, artifact_dir_norm, conversation_id
    ):
        return None

    if ext == ".svg":
        if personal_container and not matched_ws:
            return REASON_PERSONAL
        return None

    if ext not in MEDIA_EXTS:
        return None

    if not matched_ws:
        return REASON_PERSONAL

    saw_expired = False
    for ws in matched_ws:
        state = evaluate_allow_media_pass(os.path.join(ws, ".allow_media"))
        if state == "valid":
            return None
        if state == "expired":
            saw_expired = True

    return REASON_EXPIRED if saw_expired else REASON_WS


def main() -> None:
    try:
        raw_input = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        if not raw_input.strip():
            emit("allow")
        data = json.loads(raw_input)
    except Exception:
        emit("allow")

    is_claude = ("tool_name" in data) and ("toolCall" not in data)
    tool_name = str((data.get("toolCall") or {}).get("name", "") if not is_claude else data.get("tool_name", ""))
    args = (data.get("toolCall") or {}).get("args") if not is_claude else data.get("tool_input")
    if not isinstance(args, dict):
        emit("allow", is_claude=is_claude)

    conv_id = ""
    if isinstance(data.get("conversationId"), str):
        conv_id = data["conversationId"]
    elif isinstance(data.get("session_id"), str):
        conv_id = data["session_id"]

    art_dir_norm = ""
    if isinstance(data.get("artifactDirectoryPath"), str) and data["artifactDirectoryPath"].strip():
        cand = normalize_local_path(data["artifactDirectoryPath"]).rstrip("\\/")
        if cand and not in_hard_vault(cand):
            art_dir_norm = cand

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
        has_chain = bool(re.search(r"[;|&<>`\r\n]|\$\(|@\(", cmd_line))
        is_pure_git_read = (not has_chain) and bool(re.match(r"^\s*git\s+(?:status|log|diff|branch)\b", cmd_line))
        is_safe_git_repo = (not has_chain) and bool(re.match(r"^\s*git\s+(?:add|mv|commit|status|log|diff|branch|tag|push|pull|fetch)\b", cmd_line))

        if not is_pure_git_read:
            if re.search(
                r"(?i)(?:\.allow_media|agent-blindfold\.json|[\\/]\.gemini[\\/]config[\\/](?:plugins[\\/]agent-blindfold|hooks\.json)|[\\/]\.claude[\\/](?:hooks[\\/]agent-blindfold|settings(?:\.local)?\.json)|[\\/]\.agents[\\/]hooks\.json)",
                cmd_line,
            ):
                emit("deny", REASON_TAMPER, is_claude)
        if not is_safe_git_repo:
            if re.search(
                r"(?i)(?:blindfold-control(?:\.cmd)?|(?:^|[\s\"\x27`=/\\;|&(>])unlock(?:\.ps1|\.sh)?(?=$|[\s\"\x27`/\\;|&)<]))",
                cmd_line,
            ):
                emit("deny", REASON_TAMPER, is_claude)

        vault_scan_re = r"(?i)(?:^|[\s\"\x27`=(]|[A-Za-z]:|~|\$HOME|\$env:USERPROFILE|%USERPROFILE%)[\\/](?:Pictures|Videos|Music)(?:[\\/]|[\s\"\x27`;|&)]|$)"
        if re.search(vault_scan_re, cmd_line):
            emit("deny", REASON_PERSONAL, is_claude)

        safe_cd_dirs = []
        unsafe_cd_dirs = []
        cd_re = r"(?i)(?:^|[;|&(\r\n])\s*(?:cd(?:\s+/d)?|chdir|pushd|Set-Location|Push-Location|sl)\s+(?:-(?:Path|LiteralPath)\s+)?(?:\"([^\"\r\n]+)\"|\x27([^\x27\r\n]+)\x27|([^\s\"\x27`;|&<>()\r\n]+))"
        run_base = base_dir
        for cm in re.finditer(cd_re, cmd_line):
            cd_raw = cm.group(1) or cm.group(2) or cm.group(3) or ""
            if not cd_raw.strip() or cd_raw.strip() == "-":
                continue
            cd_norm = normalize_local_path(cd_raw, run_base).rstrip("\\/")
            if not cd_norm:
                continue
            run_base = cd_norm
            if is_tier0_dir_anchor(cd_norm, valid_ws, art_dir_norm, conv_id) or is_unlocked_ws_dir(cd_norm, valid_ws):
                if cd_norm not in safe_cd_dirs:
                    safe_cd_dirs.append(cd_norm)
            else:
                if cd_norm not in unsafe_cd_dirs:
                    unsafe_cd_dirs.append(cd_norm)

        tier0_anchor_dirs = []
        anchor_literals = []
        rooted_prefix_re = r"^(?:[A-Za-z]:[\\/]|~[\\/]|/|\$(?:HOME|env:USERPROFILE)[\\/]|%USERPROFILE%[\\/]|file://)"
        for qm in re.finditer(r"\"([^\"\r\n]+)\"|\x27([^\x27\r\n]+)\x27", cmd_line):
            qv = (qm.group(1) or qm.group(2) or "").strip()
            if re.match(rooted_prefix_re, qv, re.I):
                anchor_literals.append(qv)
        for um in re.finditer(r"(?i)(?<![A-Za-z0-9_])((?:[A-Za-z]:[\\/]|~[\\/]|\$(?:HOME|env:USERPROFILE)[\\/]|%USERPROFILE%[\\/]|file://)[^\s\"\x27`;|&<>(),=]+)", cmd_line):
            anchor_literals.append(um.group(1).strip())
        for al in anchor_literals:
            al_norm = normalize_local_path(al, base_dir).rstrip("\\/")
            if not al_norm:
                continue
            cands = [al_norm]
            parent_al = os.path.dirname(al_norm).rstrip("\\/")
            if parent_al:
                cands.append(parent_al)
            for cd_cand in cands:
                if is_tier0_dir_anchor(cd_cand, valid_ws, art_dir_norm, conv_id):
                    if cd_cand not in tier0_anchor_dirs:
                        tier0_anchor_dirs.append(cd_cand)
                    break

        ext_grp = "jpg|jpeg|png|gif|webp|bmp|ico|heic|heif|avif|mp4|mkv|avi|mov|webm|flv|wmv|mp3|wav|flac|m4a|ogg|aac|svg"
        tokens = []
        tokens.extend(re.findall(rf"(?i)\"([^\"\r\n]+\.(?:{ext_grp}))\"", cmd_line))
        tokens.extend(re.findall(rf"(?i)\x27([^\x27\r\n]+\.(?:{ext_grp}))\x27", cmd_line))
        tokens.extend(re.findall(rf"(?i)(?<![A-Za-z0-9_.:/-])([^\s\"\x27`|;&<>(),=]+\.(?:{ext_grp}))(?![A-Za-z0-9_])", cmd_line))

        is_safe_git = (not has_chain) and bool(re.match(r"^\s*git\s+(?:commit|status|log|branch|tag|push|pull|fetch)\b", cmd_line))
        is_dumper = (not is_safe_git_repo) and bool(re.search(
            r"(?i)\b(?:base64|certutil|xxd|hexdump|od|Format-Hex|AsByteStream|ReadAllBytes|ToBase64String|PIL|Pillow|Image\.open|cv2|imread|imageio|pytesseract|tesseract|easyocr|ffmpeg|ffprobe|magick|identify|exiftool|sips|markitdown|cp|mv|scp|rsync|Copy-Item|Move-Item|xcopy|robocopy|copy|move)\b|-Encoding\s+Byte",
            cmd_line,
        ))
        effective_base = safe_cd_dirs[-1] if (safe_cd_dirs and not unsafe_cd_dirs) else base_dir

        for tok in tokens:
            if is_web_uri(tok):
                continue
            if is_safe_git and not re.search(r"[\\/]", tok):
                continue

            is_rel_non_trav = is_relative_non_traversal_token(tok)
            if is_rel_non_trav and unsafe_cd_dirs:
                for u_dir in unsafe_cd_dirs:
                    u_verdict = evaluate_media_path(tok, u_dir, valid_ws, art_dir_norm, conv_id)
                    if u_verdict == REASON_PERSONAL:
                        emit("deny", REASON_PERSONAL, is_claude)
                    elif u_verdict in (REASON_WS, REASON_EXPIRED) and is_dumper:
                        emit("deny", u_verdict, is_claude)

            verdict = evaluate_media_path(tok, effective_base, valid_ws, art_dir_norm, conv_id)
            if verdict is not None and is_rel_non_trav and not unsafe_cd_dirs and tier0_anchor_dirs:
                is_template = bool(re.search(r"\{[^}]+\}|%[0-9]*[sdxX]", tok))
                exists_in_locked = False
                if effective_base:
                    cand_locked = os.path.join(effective_base, tok)
                    if "*" in tok or "?" in tok:
                        exists_in_locked = bool(glob.glob(cand_locked))
                    else:
                        exists_in_locked = os.path.exists(cand_locked)
                if (not effective_base or is_template) and not exists_in_locked:
                    verdict = evaluate_media_path(tok, tier0_anchor_dirs[0], valid_ws, art_dir_norm, conv_id)

            if verdict == REASON_PERSONAL:
                emit("deny", REASON_PERSONAL, is_claude)
            elif verdict in (REASON_WS, REASON_EXPIRED) and is_dumper:
                emit("deny", verdict, is_claude)

    # Branch B: Direct File / Resource / Write / Edit / MCP Tool Arguments
    sources = [args]
    for nk in ("Arguments", "arguments"):
        if isinstance(args.get(nk), dict):
            sources.append(args[nk])

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
        for ak in ("Paths", "paths", "Files", "files", "ImagePaths", "imagePaths", "image_paths"):
            arr = src.get(ak)
            if isinstance(arr, list):
                targets.extend([x.strip() for x in arr if isinstance(x, str) and x.strip()])

    is_read_only = tool_name in READ_ONLY_TOOLS
    is_pure_write = tool_name in PURE_WRITE_CREATE_TOOLS

    for t in targets:
        if not is_read_only and is_protected_control_target(t, base_dir):
            emit("deny", REASON_TAMPER, is_claude)
        if not is_pure_write:
            verdict = evaluate_media_path(t, base_dir, valid_ws, art_dir_norm, conv_id)
            if verdict is not None:
                emit("deny", verdict, is_claude)

    emit("allow", is_claude=is_claude)


if __name__ == "__main__":
    main()
'
