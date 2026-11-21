import grant_store as store
import argparse
import json
import os
import re
import sys
import time

for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

HARD_VAULT_DIRS = {"pictures", "videos", "music", "appdata"}
PERSONAL_CONTAINER_DIRS = {"desktop", "downloads", "documents"}


def get_home() -> str:
    if os.environ.get("USERPROFILE", "").strip() and os.name == "nt":
        return os.environ["USERPROFILE"].strip()
    if os.environ.get("HOME", "").strip():
        return os.environ["HOME"].strip()
    return os.path.expanduser("~")


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


def set_global_policy(mode: str, ttl: str) -> None:
    cfg_dir = os.path.join(get_home(), ".gemini", "config")
    pol_path = os.path.join(cfg_dir, "agent-blindfold.json")
    data = {
        "sessionAutoGrant": mode,
        "defaultTTL": ttl,
        "updatedAt": int(time.time()),
    }
    if mode == "timed" and not store.duration(ttl):
        raise ValueError("Invalid policy duration")
    store.atomic_json(store.config_dir() / "agent-blindfold.json", data)
    print(f"[OK] Global SessionStart policy saved -> {pol_path} (sessionAutoGrant={mode}, defaultTTL={ttl})")


def show_status(ws_full: str) -> None:
    mode, ttl, source, ttl_source = store.policy()
    print(f"Global SessionStart Auto-Grant : {mode} ({source}); TTL: {ttl} ({ttl_source})")
    print(f"Target Workspace               : {ws_full}")
    token = store.read(store.grant_path(ws_full))
    if not token:
        print("Workspace Pass Status          : LOCKED")
    elif store.expired(token):
        print("Workspace Pass Status          : EXPIRED")
    elif token["mode"] == "permanent":
        print("Workspace Pass Status          : UNLOCKED (PERMANENT)")
    else:
        print(f"Workspace Pass Status          : UNLOCKED (TIMED, until {token['expires_at']} UTC epoch)")
    if os.path.lexists(os.path.join(ws_full, ".allow_media")):
        print("Legacy project marker ignored. Confirm via --timed or --permanent to grant locally.")


def issue_pass(ws_full: str, mode: str, ttl_spec: str) -> None:
    if not is_valid_ws(ws_full):
        print(f"Error: Refused — '{ws_full}' is a personal vault/container root or does not exist.", file=sys.stderr)
        sys.exit(1)
    token = store.issue(ws_full, mode, ttl_spec.lower().strip(), "cli_user")
    print(f"[OK] Local workspace grant: {token['mode']} -> {ws_full}")


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

    if args.workspace and os.path.splitdrive(args.workspace)[0] and not os.path.isabs(args.workspace):
        parser.error("A drive-relative workspace selector is ambiguous")
    ws = os.path.realpath(os.path.abspath(args.workspace or os.getcwd()))
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
        store.revoke(ws)
        print(f"[OK] Workspace locked: {ws}")
        return

    if mode in ("timed", "permanent"):
        issue_pass(ws, mode, ttl)
        return

    show_status(ws)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as exc:
        print(f"agent-blindfold: {exc}", file=sys.stderr)
        sys.exit(1)
