"""Local publisher, reader and policy resolver shared by the Unix hooks and CLI."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import time


def home():
    value = os.environ.get("USERPROFILE") if os.name == "nt" else None
    return Path(value or os.environ.get("HOME") or Path.home())


def config_dir():
    return home() / ".gemini" / "config"


def duration(spec):
    match = re.fullmatch(r"(\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)?", spec)
    if not match:
        return 0
    multiplier = {"s": 1, "m": 60, "h": 3600, "d": 86400}[(match[2] or "s")[0]]
    if len(match[1]) > 18:
        return 0
    seconds = int(match[1]) * multiplier
    return seconds if seconds <= 9223372036854775807 - int(time.time()) else 0


def policy():
    path = config_dir() / "agent-blindfold.json"
    try:
        data = json.loads(checked(path).read_text(encoding="utf-8-sig"))
        if not isinstance(data, dict):
            raise ValueError("policy is not an object")
    except FileNotFoundError:
        data = {}
    except (ValueError, OSError, UnicodeError):
        return "off", "", "invalid policy", "invalid policy"
    def option(file_key, env_key, default):
        env = os.environ.get(env_key, "").strip().lower()
        if env:
            return env, "environment"
        if file_key in data:
            val = data[file_key]
            return (val.strip().lower() if isinstance(val, str) else ""), "file"
        return default, "default"
    mode, source = option("sessionAutoGrant", "AGENT_BLINDFOLD_AUTO_GRANT", "timed")
    ttl, ttl_source = option("defaultTTL", "AGENT_BLINDFOLD_DEFAULT_TTL", "2h")
    mode = {"false":"off", "none":"off", "manual":"off", "sandbox_only":"off",
            "forever":"permanent"}.get(mode, mode)
    if not ttl or mode not in ("timed", "permanent", "off") or (mode == "timed" and not duration(ttl)):
        return "off", ttl, "invalid policy", ttl_source
    return mode, ttl, source, ttl_source


def grant_path(workspace):
    supplied = os.fspath(workspace)
    if not supplied.strip() or not os.path.isabs(supplied):
        raise ValueError("A fully qualified project directory is required")
    key = os.path.realpath(os.path.abspath(supplied))
    if Path(key).parent == Path(key):
        raise ValueError("Filesystem roots cannot hold workspace grants")
    if os.name == "nt":
        key = key.replace(chr(92), "/").translate(str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz"))
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
    return config_dir() / "agent-blindfold-grants" / (digest + ".json")


def checked(path, create=False):
    # Only trusted profile descendants are used for state. Reject redirected components.
    relative = path.relative_to(home())
    current = home()
    for part in relative.parts:
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            if create and current != path:
                current.mkdir(mode=0o700, exist_ok=True)
                info = current.lstat()
            else:
                continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 1024:
            raise OSError("Redirected agent-blindfold configuration path")
    return path


def atomic_json(path, obj):
    checked(path, create=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(obj, out, ensure_ascii=False)
            out.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


@contextlib.contextmanager
def locked(path):
    lock = checked(path.with_suffix(".lock"), create=True)
    with open(lock, "a+b") as file:
        file.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(file.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.lockf(file, fcntl.LOCK_EX, 1)
        try:
            yield
        finally:
            file.seek(0)
            if os.name == "nt":
                msvcrt.locking(file.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.lockf(file, fcntl.LOCK_UN, 1)


def read(path):
    try:
        token = json.loads(checked(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    if not isinstance(token, dict) or token.get("mode") not in ("timed", "permanent"):
        raise ValueError("Invalid local media grant")
    if token["mode"] == "timed" and type(token.get("expires_at")) is not int:
        raise ValueError("Invalid local media grant expiry")
    return token


def expired(token):
    return token and token["mode"] == "timed" and time.time() >= token["expires_at"]


def state(workspace):
    path = grant_path(workspace)
    token = read(path)
    if expired(token):
        with locked(path):
            token = read(path)
            if expired(token):
                path.unlink()
                return "expired"
    return "valid" if token else "missing"


def issue(workspace, mode, ttl, issuer):
    path = grant_path(workspace)
    now = int(time.time())
    token = {"version": 2, "mode": mode, "issued_by": issuer, "issued_at": now}
    if mode == "timed":
        seconds = duration(ttl)
        if not seconds:
            raise ValueError("Invalid grant duration")
        token.update(ttl=ttl, ttl_seconds=seconds, expires_at=now + seconds)
    with locked(path):
        if issuer == "session_start":
            old = read(path)
            if old and old["mode"] == "permanent":
                return old
        atomic_json(path, token)
    return token


def revoke(workspace):
    path = grant_path(workspace)
    if not checked(path).exists():
        return
    with locked(path):
        path.unlink(missing_ok=True)


def clear_uninstalled_grants():
    directory = checked(config_dir() / "agent-blindfold-grants")
    if not directory.is_dir():
        return
    for entry in directory.iterdir():
        if re.fullmatch(r"[0-9a-f]{64}\.(json|lock)", entry.name):
            checked(entry).unlink()
    if not any(directory.iterdir()):
        directory.rmdir()


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["--clear-uninstalled-grants"]:
        if (config_dir() / "plugins/agent-blindfold").exists() or (home() / ".claude/hooks/agent-blindfold").exists():
            sys.exit("A host still uses this grant store")
        clear_uninstalled_grants()
    else:
        sys.exit("Internal grant store helper")
