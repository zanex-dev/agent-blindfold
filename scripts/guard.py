import grant_store as store
import glob
import json
import os
import re
import sys
import urllib.parse

if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

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

EN_WS = "Blocked by agent-blindfold: Workspace media has no valid local grant. Ask the user to issue one via the unlock controller."
ZH_WS = "工作区媒体缺少有效的本机授权。如有需要，请用户通过本机控制器签发。"

EN_EXPIRED = "Blocked by agent-blindfold: The local workspace grant has expired. Ask the user to renew it if needed."
ZH_EXPIRED = "工作区的本机授权已到期。如有需要，请用户重新签发。"

EN_TAMPER = "Blocked by agent-blindfold: Agents are forbidden from modifying or forging local grants and privacy controls."
ZH_TAMPER = "禁止智能体自行修改或伪造本机授权及隐私策略。"

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


def unwrap_cli_option_value(raw_tok: str) -> str:
    if not raw_tok or not raw_tok.strip():
        return ""
    cur = raw_tok.strip()
    for _ in range(2):
        if len(cur) > 1 and cur.startswith("@"):
            cur = cur[1:].strip()
            continue
        m = re.match(r"^(?:--?[A-Za-z0-9_.-]+|[A-Za-z_][A-Za-z0-9_.-]*)=@?(.+)$", cur)
        if m:
            cur = m.group(1).strip()
            continue
        m = re.match(r"^/[A-Za-z0-9_.-]+:(.+)$", cur)
        if m:
            cur = m.group(1).strip()
            continue
        break
    return cur


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
    elif re.match(r"^file:(.+)$", cleaned, re.I):
        cleaned = re.sub(r"^file:", "", cleaned, count=1, flags=re.I)
        cleaned = re.sub(r"[?#].*$", "", cleaned)
        cleaned = urllib.parse.unquote(cleaned)

    home = get_effective_home()
    cleaned = re.sub(r"^\$HOME(?=[\\/]|$)", home.replace("\\", "/"), cleaned)
    cleaned = re.sub(r"^\$env:USERPROFILE(?=[\\/]|$)", home.replace("\\", "/"), cleaned, flags=re.I)
    if cleaned.startswith("~") and (len(cleaned) == 1 or cleaned[1] in ("/", "\\")):
        cleaned = os.path.join(home, cleaned[1:].lstrip("/\\"))
    cleaned = os.path.expandvars(cleaned)

    cleaned = re.sub(r"(?<=.{2})::?[A-Za-z0-9_.$]+$", "", cleaned)
    cleaned = cleaned.rstrip(". ")
    cleaned = cleaned.replace("*", "__WC_STAR__").replace("?", "__WC_Q__")

    has_embedded_drive = bool(re.search(r"(?<!^)[A-Za-z]:[\\/]", cleaned))
    if has_embedded_drive:
        return cleaned.lower()

    if not os.path.isabs(cleaned) and not cleaned.startswith(("/", "\\")) and base_dir:
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
    if not ws or not ws.strip() or (os.path.splitdrive(ws)[0] and not os.path.isabs(ws)):
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
    if is_subpath(norm, str(store.config_dir() / "agent-blindfold-grants")) or is_subpath(norm, agy_plugin) or is_subpath(norm, claude_hook):
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
            if store.state(ws) == "valid":
                return True
    return False


def is_relative_non_traversal_token(raw_tok: str) -> bool:
    if not raw_tok or not raw_tok.strip():
        return False
    t = raw_tok.strip().strip("\"").strip("\x27")
    if re.match(r"^(?:[A-Za-z]:|[\\/]|~|\$HOME|\$env:USERPROFILE|%USERPROFILE%|file:)", t, re.I):
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
        state = store.state(ws)
        if state == "valid":
            return None
        if state == "expired":
            saw_expired = True

    return REASON_EXPIRED if saw_expired else REASON_WS


def main() -> None:
    global host
    data = json.load(sys.stdin)
    if not isinstance(data, dict):
        raise ValueError("Invalid hook message")
    if host == "auto":
        host = "claude" if "tool_name" in data else "antigravity"
    is_claude = host == "claude"
    call = data if is_claude else data.get("toolCall")
    if not isinstance(call, dict):
        raise ValueError("Missing tool call")
    tool_name = call.get("tool_name" if is_claude else "name")
    args = call.get("tool_input" if is_claude else "args")
    if not isinstance(tool_name, str) or not tool_name or not isinstance(args, dict):
        raise ValueError("Invalid tool call arguments")

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
                r"(?i)(?:\.allow_media|agent-blindfold\.json|agent-blindfold-grants|[\\/]\.gemini[\\/]config[\\/](?:plugins[\\/]agent-blindfold|hooks\.json)|[\\/]\.claude[\\/](?:hooks[\\/]agent-blindfold|settings(?:\.local)?\.json)|[\\/]\.agents[\\/]hooks\.json)",
                cmd_line,
            ):
                emit("deny", REASON_TAMPER, is_claude)
        if not is_safe_git_repo:
            if re.search(
                r"(?i)(?:blindfold-control(?:\.cmd)?|(?:^|[\s\"\x27`=/\\;|&(>])unlock(?:\.ps1|\.sh|\.py)?(?=$|[\s\"\x27`/\\;|&)<]))",
                cmd_line,
            ):
                emit("deny", REASON_TAMPER, is_claude)

        vault_scan_re = r"(?i)(?:^|[\s\"\x27`=(]|[A-Za-z]:|~|\$HOME|\$env:USERPROFILE|%USERPROFILE%)[\\/](?:Pictures|Videos|Music)(?:[\\/]|[\s\"\x27`;|&)]|$)"
        if re.search(vault_scan_re, cmd_line):
            emit("deny", REASON_PERSONAL, is_claude)

        safe_cd_dirs = []
        unsafe_cd_dirs = []
        cd_re = r"(?i)(?:^|[;|&(\r\n])\s*(?:cd(?:\s+/d)?|chdir|pushd|Set-Location|Push-Location|sl)\s+(?:-(?:Path|LiteralPath)\s+)?(?:\"([^\"\r\n]+)\"|\x27([^\x27\r\n]+)\x27|([^\s\"\x27`;|&<>()\r\n]+))"
        dynamic_var_re = r"(?i)(?:\$(?!HOME(?:[\\/]|$)|env:USERPROFILE(?:[\\/]|$))[A-Za-z_{0-9]|%(?!USERPROFILE%)[A-Za-z_][A-Za-z0-9_]*%)"
        run_base = base_dir
        for cm in re.finditer(cd_re, cmd_line):
            cd_raw = cm.group(1) or cm.group(2) or cm.group(3) or ""
            if not cd_raw.strip() or cd_raw.strip() == "-":
                continue
            if re.search(dynamic_var_re, cd_raw):
                dyn_sentinel = os.path.join(get_effective_home(), "__dynamic_cd_untrusted__")
                if dyn_sentinel not in unsafe_cd_dirs:
                    unsafe_cd_dirs.append(dyn_sentinel)
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
        rooted_prefix_re = r"^(?:[A-Za-z]:[\\/]|~[\\/]|/(?![A-Za-z0-9_.-]+[:=])|\$(?:HOME|env:USERPROFILE)[\\/]|%USERPROFILE%[\\/]|file:(?://)?)"
        for qm in re.finditer(r"\"([^\"\r\n]+)\"", cmd_line):
            qv = unwrap_cli_option_value(qm.group(1) or "")
            if re.match(rooted_prefix_re, qv, re.I):
                anchor_literals.append(qv)
        for qm in re.finditer(r"\x27([^\x27\r\n]+)\x27", cmd_line):
            qv = unwrap_cli_option_value(qm.group(1) or "")
            if re.match(rooted_prefix_re, qv, re.I):
                anchor_literals.append(qv)
        for um in re.finditer(r"(?i)(?<![A-Za-z0-9_.:/-])((?:--?[A-Za-z0-9_.-]+=|/[A-Za-z0-9_.-]+:|@)?(?:[A-Za-z]:[\\/]|~[\\/]|/(?![/])|\$(?:HOME|env:USERPROFILE)[\\/]|%USERPROFILE%[\\/]|file:(?://)?)[^\s\"\x27`;|&<>(),=]+)", cmd_line):
            uv = unwrap_cli_option_value(um.group(1) or "")
            if re.match(rooted_prefix_re, uv, re.I):
                anchor_literals.append(uv)
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
        embedded_rooted_re = rf"(?i)(?:^|(?<=[\s=@:]))((?:[A-Za-z]:[\\/]|~[\\/]|/(?![/])[A-Za-z0-9_.-]+[\\/]|\$(?:HOME|env:USERPROFILE)[\\/]|%USERPROFILE%[\\/]|file:(?://)?)(?:(?![A-Za-z]:[\\/]|\s+/[A-Za-z0-9_.-]+[\\/])[^\"\x27`|;&<>()\r\n])*?\.(?:{ext_grp}))(?![A-Za-z0-9_])"
        compound_sep_re = r"(?i)\s+(?:--?[A-Za-z0-9_.-]+=|/[A-Za-z0-9_.-]+:|@)?(?:[A-Za-z]:[\\/]|~[\\/]|/(?![/])[A-Za-z0-9_.-]+[\\/]|\$(?:HOME|env:USERPROFILE)[\\/]|%USERPROFILE%[\\/]|file:(?://)?)"

        quoted_caps = []
        quoted_caps.extend(re.findall(r"\"([^\"\r\n]+)\"", cmd_line))
        quoted_caps.extend(re.findall(r"\x27([^\x27\r\n]+)\x27", cmd_line))

        for q_raw in quoted_caps:
            for em in re.finditer(embedded_rooted_re, q_raw):
                ev = (em.group(1) or "").strip()
                if ev:
                    tokens.append(ev)
            q_unwrapped = unwrap_cli_option_value(q_raw)
            if re.search(rf"(?i)\.(?:{ext_grp})$", q_unwrapped):
                is_compound = bool(re.search(r"[|;<>`\r\n]|\$\(|@\(", q_unwrapped)) or bool(re.search(compound_sep_re, q_unwrapped))
                if not is_compound:
                    tokens.append(q_unwrapped)

        for um_tok in re.findall(rf"(?i)(?<![A-Za-z0-9_.:/-])([^\s\"\x27`|;&<>(),=]+\.(?:{ext_grp}))(?![A-Za-z0-9_])", cmd_line):
            u_tok = unwrap_cli_option_value(um_tok)
            if u_tok:
                tokens.append(u_tok)

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
    host = sys.argv[1] if len(sys.argv) > 1 else "auto"
    try:
        main()
    except Exception:
        print("agent-blindfold: unable to validate this tool call.", file=sys.stderr)
        emit("deny", "agent-blindfold could not validate this tool call.", host == "claude")

