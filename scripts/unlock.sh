#!/usr/bin/env bash
# ==============================================================================
# agent-blindfold (Codename: Heart-Under-Blade / 刃下心) v1.1
# Pass Issuer & Auto-Grant Policy Controller (macOS / Linux / Git Bash)
# Usage:
#   ./scripts/unlock.sh --timed 2h [--workspace /path/to/app]
#   ./scripts/unlock.sh --permanent [--workspace /path/to/app]
#   ./scripts/unlock.sh --lock [--workspace /path/to/app]
#   ./scripts/unlock.sh --status [--workspace /path/to/app]
#   ./scripts/unlock.sh --global-auto-grant timed|permanent|off [--ttl 2h]
# ==============================================================================

set -euo pipefail

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
else
    echo "Error: python3 is required to run unlock.sh" >&2
    exit 1
fi

exec "$PYTHON_BIN" - "$@" << 'PYEOF'
import argparse
import json
import os
import re
import sys
import time

HARD_VAULT_DIRS = {"pictures", "videos", "music", "appdata"}
PERSONAL_CONTAINER_DIRS = {"desktop", "downloads", "documents"}


def get_home() -> str:
    if os.environ.get("USERPROFILE", "").strip() and os.name == "nt":
        return os.environ["USERPROFILE"].strip()
    if os.environ.get("HOME", "").strip():
        return os.environ["HOME"].strip()
    return os.path.expanduser("~")


def parse_ttl(spec: str):
    m = re.match(r"^(\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)?$", spec.strip().lower())
    if not m:
        return None
    val = int(m.group(1))
    unit = m.group(2) or "s"
    mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit[0]]
    return val * mult


def is_subpath(target_norm: str, ws_norm: str) -> bool:
    t = target_norm.rstrip("\\/").lower()
    w = ws_norm.rstrip("\\/").lower()
    if not t or not w:
        return False
    if t == w:
        return True
    return t.startswith(w + "/") or t.startswith(w + "\\")


def is_valid_ws(ws: str) -> bool:
    full = os.path.realpath(os.path.abspath(ws)).rstrip("\\/")
    if not full or re.match(r"^[a-z]:$", full, re.I):
        return False
    home_full = os.path.realpath(os.path.abspath(get_home())).rstrip("\\/")
    if is_subpath(home_full, full):
        return False
    gemini_root = os.path.join(home_full, ".gemini")
    claude_root = os.path.join(home_full, ".claude")
    if full.lower() == gemini_root.lower():
        return False
    if is_subpath(full, os.path.join(gemini_root, "config")):
        return False
    if is_subpath(full, claude_root):
        return False
    for fl in ("antigravity", "antigravity-cli", "antigravity-ide"):
        agy_dir = os.path.join(gemini_root, fl)
        if full.lower() == agy_dir.lower():
            return False
        if is_subpath(full, os.path.join(agy_dir, "brain")):
            return False
    segs = [s.lower() for s in re.split(r"[\\/]+", full) if s]
    if any(s in HARD_VAULT_DIRS for s in segs):
        return False
    leaf = os.path.basename(full).lower()
    if leaf in PERSONAL_CONTAINER_DIRS:
        return False
    if not os.path.isdir(full):
        return False
    if leaf == "chat":
        return False
    for rf in ("AGENTS.md", "GEMINI.md"):
        rp = os.path.join(full, rf)
        if os.path.isfile(rp):
            try:
                with open(rp, "r", encoding="utf-8", errors="ignore") as f:
                    txt = f.read()
                if re.search(r"(?i)(chat-only|read-only mode|纯日常对话|纯聊天|严格只读)", txt):
                    return False
            except Exception:
                pass
    return True


def ensure_git_exclude(ws_full: str) -> None:
    excl = os.path.join(ws_full, ".git", "info", "exclude")
    if os.path.isfile(excl):
        try:
            with open(excl, "r", encoding="utf-8", errors="replace") as f:
                txt = f.read()
            if not re.search(r"(?m)^\s*\.allow_media\s*$", txt):
                prefix = "\n" if (txt and not txt.endswith("\n")) else ""
                with open(excl, "a", encoding="utf-8") as f:
                    f.write(f"{prefix}.allow_media\n")
        except Exception:
            pass


def set_global_policy(mode: str, ttl: str) -> None:
    cfg_dir = os.path.join(get_home(), ".gemini", "config")
    os.makedirs(cfg_dir, exist_ok=True)
    pol_path = os.path.join(cfg_dir, "agent-blindfold.json")
    data = {
        "sessionAutoGrant": mode,
        "defaultTTL": ttl,
        "updatedAt": int(time.time()),
    }
    with open(pol_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"[OK] Global SessionStart policy saved -> {pol_path} (sessionAutoGrant={mode}, defaultTTL={ttl})")


def show_status(ws_full: str) -> None:
    pol_path = os.path.join(get_home(), ".gemini", "config", "agent-blindfold.json")
    g_mode, g_ttl = "timed (default)", "2h"
    if os.path.isfile(pol_path):
        try:
            with open(pol_path, "r", encoding="utf-8") as f:
                p = json.load(f)
            g_mode = p.get("sessionAutoGrant", g_mode)
            g_ttl = p.get("defaultTTL", g_ttl)
        except Exception:
            pass
    print(f"Global SessionStart Auto-Grant : {g_mode} (Default TTL: {g_ttl})")
    print(f"Target Workspace               : {ws_full}")
    marker = os.path.join(ws_full, ".allow_media")
    if not os.path.isfile(marker):
        print("Workspace Pass Status          : LOCKED (no .allow_media)")
        return
    with open(marker, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read().strip()
    now = int(time.time())
    if raw.startswith("{"):
        tok = json.loads(raw)
        if str(tok.get("mode", "")).lower() == "permanent":
            print("Workspace Pass Status          : UNLOCKED (PERMANENT)")
            return
        if "expires_at" in tok:
            rem = int(tok["expires_at"]) - now
            if rem > 0:
                print(f"Workspace Pass Status          : UNLOCKED (TIMED, {rem / 60.0:.1f} min remaining)")
            else:
                print("Workspace Pass Status          : EXPIRED")
            return
    elif raw.lower() in ("permanent", "forever"):
        print("Workspace Pass Status          : UNLOCKED (PERMANENT)")
        return
    print(f"Workspace Pass Status          : PRESENT ({raw})")


def issue_pass(ws_full: str, mode: str, ttl_spec: str) -> None:
    if not is_valid_ws(ws_full):
        print(f"Error: Refused — '{ws_full}' is a personal vault/container root or does not exist.", file=sys.stderr)
        sys.exit(1)
    marker = os.path.join(ws_full, ".allow_media")
    now = int(time.time())
    if mode == "permanent":
        tok = {"version": 1, "mode": "permanent", "issued_at": now, "issued_by": "cli_user"}
        label = "PERMANENT"
    else:
        sec = parse_ttl(ttl_spec)
        if not sec or sec <= 0:
            print(f"Error: Invalid TTL '{ttl_spec}'. Use e.g. 30m, 2h, 8h, 1d.", file=sys.stderr)
            sys.exit(1)
        tok = {
            "version": 1,
            "mode": "timed",
            "ttl": ttl_spec.strip().lower(),
            "ttl_seconds": sec,
            "issued_at": now,
            "expires_at": now + sec,
            "issued_by": "cli_user",
        }
        label = f"TIMED ({ttl_spec})"
    with open(marker, "w", encoding="utf-8") as f:
        json.dump(tok, f, indent=2, ensure_ascii=False)
        f.write("\n")
    ensure_git_exclude(ws_full)
    print(f"[OK] {label} media exemption granted -> {marker}")


def main() -> None:
    parser = argparse.ArgumentParser(description="agent-blindfold pass & policy controller")
    parser.add_argument("--mode", choices=["timed", "permanent"], default="")
    parser.add_argument("--timed", metavar="TTL", default="", help="Shorthand for --mode timed --ttl TTL")
    parser.add_argument("--permanent", action="store_true", help="Shorthand for --mode permanent")
    parser.add_argument("--ttl", default="2h")
    parser.add_argument("--workspace", "-w", default="")
    parser.add_argument("--lock", action="store_true")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--global-auto-grant", choices=["timed", "permanent", "off"], default="")
    args = parser.parse_args()

    ws = os.path.realpath(os.path.abspath(args.workspace or os.getcwd())).rstrip("\\/")
    ttl = args.timed if args.timed else args.ttl
    mode = "permanent" if args.permanent else ("timed" if args.timed else args.mode)

    if args.global_auto_grant:
        set_global_policy(args.global_auto_grant, ttl)
        if not (args.lock or args.status or mode):
            return

    if args.status:
        show_status(ws)
        return

    if args.lock:
        marker = os.path.join(ws, ".allow_media")
        if os.path.isfile(marker):
            os.remove(marker)
            print(f"[OK] Workspace media re-locked (removed {marker})")
        else:
            print(f"[i] Already locked ({ws})")
        return

    if mode in ("timed", "permanent"):
        issue_pass(ws, mode, ttl)
        return

    show_status(ws)


if __name__ == "__main__":
    main()
PYEOF
