#!/usr/bin/env bash
# ==============================================================================
# agent-blindfold (Codename: Heart-Under-Blade / 刃下心) v1.1
# SessionStart Auto-Exemption Hook (macOS / Linux / Git Bash)
# Automatically issues a timed (TTL) or permanent '.allow_media' pass at startup
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
    if printf '%s' "$INPUT_RAW" | grep -q '"hook_event_name"'; then
        exit 0
    fi
    printf '{}\n'
    exit 0
fi

exec "$PYTHON_BIN" -c '
import json
import os
import re
import sys
import time
import urllib.parse

HARD_VAULT_DIRS = {"pictures", "videos", "music", "appdata"}
PERSONAL_CONTAINER_DIRS = {"desktop", "downloads", "documents"}


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


def ensure_git_local_exclude(ws_norm: str) -> None:
    excl = os.path.join(ws_norm, ".git", "info", "exclude")
    if os.path.isfile(excl):
        try:
            with open(excl, "r", encoding="utf-8", errors="replace") as f:
                existing = f.read()
            if not re.search(r"(?m)^\s*\.allow_media\s*$", existing):
                prefix = "\n" if (existing and not existing.endswith("\n")) else ""
                with open(excl, "a", encoding="utf-8") as f:
                    f.write(f"{prefix}.allow_media\n")
        except Exception:
            pass


def main() -> None:
    try:
        raw_in = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        if not raw_in.strip():
            emit_session(False)
        data = json.loads(raw_in)
    except Exception:
        emit_session(False)

    is_claude = (("hook_event_name" in data) or ("session_id" in data)) and ("conversationId" not in data)

    auto_mode = "timed"
    default_ttl = "2h"
    policy_path = os.path.join(get_effective_home(), ".gemini", "config", "agent-blindfold.json")
    if os.path.isfile(policy_path):
        try:
            with open(policy_path, "r", encoding="utf-8") as f:
                pol = json.load(f)
            if isinstance(pol, dict):
                if str(pol.get("sessionAutoGrant", "")).strip():
                    auto_mode = str(pol["sessionAutoGrant"]).strip().lower()
                if str(pol.get("defaultTTL", "")).strip():
                    default_ttl = str(pol["defaultTTL"]).strip().lower()
        except Exception:
            pass

    if os.environ.get("AGENT_BLINDFOLD_AUTO_GRANT", "").strip():
        auto_mode = os.environ["AGENT_BLINDFOLD_AUTO_GRANT"].strip().lower()
    if os.environ.get("AGENT_BLINDFOLD_DEFAULT_TTL", "").strip():
        default_ttl = os.environ["AGENT_BLINDFOLD_DEFAULT_TTL"].strip().lower()

    if auto_mode in ("off", "false", "none", "manual", "sandbox_only"):
        emit_session(is_claude)

    raw_ws = [w for w in (data.get("workspacePaths") or []) if isinstance(w, str) and w.strip()]
    if isinstance(data.get("cwd"), str) and data["cwd"].strip():
        raw_ws.append(data["cwd"])

    granted = []
    summary_mode = auto_mode
    now_sec = int(time.time())

    for w in raw_ws:
        if not is_valid_engineering_workspace(w):
            continue
        norm_ws = normalize_local_path(w).rstrip("\\/")
        if norm_ws in granted:
            continue
        marker = os.path.join(norm_ws, ".allow_media")

        already_perm = False
        if os.path.isfile(marker):
            try:
                with open(marker, "r", encoding="utf-8", errors="replace") as f:
                    ex = f.read().strip()
                if ex.lower() in ("permanent", "forever"):
                    already_perm = True
                elif ex.startswith("{"):
                    obj = json.loads(ex)
                    if isinstance(obj, dict) and str(obj.get("mode", "")).strip().lower() in ("permanent", "forever"):
                        already_perm = True
            except Exception:
                pass

        if already_perm:
            summary_mode = "permanent"
            granted.append(norm_ws)
            continue

        if auto_mode in ("permanent", "forever"):
            token = {
                "version": 1,
                "mode": "permanent",
                "issued_at": now_sec,
                "issued_by": "session_start",
            }
            summary_mode = "permanent"
        else:
            ttl_sec = parse_duration_seconds(default_ttl)
            if not ttl_sec or ttl_sec <= 0:
                ttl_sec = 7200
                default_ttl = "2h"
            token = {
                "version": 1,
                "mode": "timed",
                "ttl": default_ttl,
                "ttl_seconds": ttl_sec,
                "issued_at": now_sec,
                "expires_at": now_sec + ttl_sec,
                "issued_by": "session_start",
            }
            summary_mode = f"timed ({default_ttl})"

        try:
            with open(marker, "w", encoding="utf-8") as f:
                json.dump(token, f, indent=2, ensure_ascii=False)
                f.write("\n")
            ensure_git_local_exclude(norm_ws)
            granted.append(norm_ws)
        except Exception:
            pass

    if granted:
        notice = (
            f"[agent-blindfold] Engineering media exemption automatically granted at session start "
            f"(mode: {summary_mode}). Reading, generating, and editing/processing media assets "
            f"(including via PIL/cv2/ffmpeg/scripts), .svg files, current-session brain/<id> files, "
            f"and Playwright/sandbox screenshots inside exempted scopes are permitted; personal "
            f"directories, cross-session uploads, and modifying .allow_media remain strictly blocked."
        )
        emit_session(is_claude, notice)

    emit_session(is_claude)


if __name__ == "__main__":
    main()
'
