import grant_store as store
import json
import os
import re
import sys
import urllib.parse

HARD_VAULT_DIRS = {"pictures", "videos", "music", "appdata"}
PERSONAL_CONTAINER_DIRS = {"desktop", "downloads", "documents"}


def get_effective_home() -> str:
    if os.environ.get("USERPROFILE", "").strip() and os.name == "nt":
        return os.environ["USERPROFILE"].strip()
    if os.environ.get("HOME", "").strip():
        return os.environ["HOME"].strip()
    return os.path.expanduser("~")


def emit_session(is_claude: bool, notice: str = "") -> None:
    if is_claude:
        sys.exit(0)
    if not notice:
        out = "{}\n"
    else:
        payload = {
            "injectSteps": [
                {
                    "systemMessage": {
                        "systemMessage": notice
                    }
                }
            ]
        }
        out = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    sys.stdout.buffer.write(out.encode("utf-8"))
    sys.stdout.buffer.flush()
    sys.exit(0)


def normalize_local_path(raw: str) -> str:
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
    if cleaned.startswith("~") and (len(cleaned) == 1 or cleaned[1] in ("/", "\\")):
        cleaned = os.path.join(home, cleaned[1:].lstrip("/\\"))
    cleaned = os.path.expandvars(cleaned)
    return os.path.normcase(os.path.realpath(os.path.abspath(cleaned)))


def is_subpath(target_norm: str, ws_norm: str) -> bool:
    t = target_norm.rstrip("\\/").lower()
    w = ws_norm.rstrip("\\/").lower()
    if not t or not w:
        return False
    if t == w:
        return True
    return t.startswith(w + "/") or t.startswith(w + "\\")


def is_valid_engineering_workspace(ws: str) -> bool:
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
    segs = [seg.lower() for seg in re.split(r"[\\/]+", norm_ws) if seg]
    if any(seg in HARD_VAULT_DIRS for seg in segs):
        return False
    leaf = os.path.basename(norm_ws).lower()
    if leaf in PERSONAL_CONTAINER_DIRS:
        return False
    if not os.path.isdir(norm_ws):
        return False
    if leaf == "chat":
        return False
    for rf in ("AGENTS.md", "GEMINI.md"):
        rp = os.path.join(norm_ws, rf)
        if os.path.isfile(rp):
            try:
                with open(rp, "r", encoding="utf-8", errors="ignore") as f:
                    txt = f.read()
                if re.search(r"(?i)(chat-only|read-only mode|纯日常对话|纯聊天|严格只读)", txt):
                    return False
            except Exception:
                pass
    return True


def main() -> None:
    try:
        raw_in = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        if not raw_in.strip():
            emit_session(False)
        data = json.loads(raw_in)
    except Exception:
        emit_session(False)

    is_claude = (("hook_event_name" in data) or ("session_id" in data)) and ("conversationId" not in data)

    auto_mode, default_ttl, source, _ = store.policy()
    if source == "invalid policy":
        print("agent-blindfold: unreadable or invalid configuration. New grants paused.", file=sys.stderr)
    if auto_mode == "off":
        emit_session(is_claude)

    raw_ws = [w for w in (data.get("workspacePaths") or []) if isinstance(w, str) and w.strip()]
    if isinstance(data.get("cwd"), str) and data["cwd"].strip():
        raw_ws.append(data["cwd"])

    granted = []
    summary_mode = auto_mode

    for w in raw_ws:
        if not is_valid_engineering_workspace(w):
            continue
        norm_ws = normalize_local_path(w).rstrip("\\/")
        if norm_ws in granted:
            continue
        try:
            token = store.issue(norm_ws, auto_mode, default_ttl, "session_start")
            summary_mode = token["mode"]
            granted.append(norm_ws)
        except (OSError, ValueError) as exc:
            print(f"agent-blindfold: could not issue local workspace grant: {exc}", file=sys.stderr)

    if granted:
        notice = (
            f"[agent-blindfold] Engineering media exemption automatically granted at session start "
            f"(mode: {summary_mode}). Reading, generating, and editing/processing media assets "
            f"(including via PIL/cv2/ffmpeg/scripts), .svg files, current-session brain/<id> files, "
            f"and Playwright/sandbox screenshots inside exempted scopes are permitted; personal "
            f"directories, cross-session uploads, and modifying local privacy controls remain strictly blocked."
        )
        emit_session(is_claude, notice)

    emit_session(is_claude)


if __name__ == "__main__":
    main()
