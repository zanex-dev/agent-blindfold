"""Install/remove our exact commands while retaining other hooks in the same matcher."""
import json
from pathlib import Path
import shlex
import shutil
import sys
import grant_store as store


def retained(entries, commands):
    result = []
    for group in entries:
        hooks = group.get("hooks") if isinstance(group, dict) else None
        if not isinstance(hooks, list) or not hooks:
            result.append(group)
            continue
        def ours(hook):
            return isinstance(hook, dict) and hook.get("type") == "command" and hook.get("command") in commands
        remaining = [hook for hook in hooks if not ours(hook)]
        if remaining:
            result.append(dict(group, hooks=remaining))
    return result


def merge(action, settings, guard, session):
    if settings.exists():
        if action == "install":
            shutil.copy2(settings, str(settings) + ".bak")
        cfg = json.loads(settings.read_text(encoding="utf-8-sig").strip() or "{}")
    else:
        if action == "uninstall":
            return
        cfg = {}
    hooks = cfg.setdefault("hooks", {})
    for event, script in (("PreToolUse", guard), ("SessionStart", session)):
        if event not in hooks and action == "uninstall":
            continue
        legacy = '"' + script + '"'
        command = shlex.quote(script) + (" claude" if event == "PreToolUse" else "")
        groups = retained(hooks.get(event, []), {legacy, command})
        if action == "install":
            group = {"hooks": [{"type": "command", "command": command}]}
            if event == "PreToolUse":
                group["matcher"] = "Read|View|NotebookRead|Write|Edit|MultiEdit|NotebookEdit|Bash|mcp__.*"
            groups.append(group)
        if groups or event == "PreToolUse":
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    store.atomic_json(settings, cfg)


if __name__ == "__main__":
    merge(sys.argv[1], Path(sys.argv[2]), sys.argv[3], sys.argv[4])
