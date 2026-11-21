#!/usr/bin/env bash
set -eu
script_path=${BASH_SOURCE[0]}
case "$script_path" in */*) dir=${script_path%/*} ;; *) dir=. ;; esac
if source "$dir/python_runtime.sh" && blindfold_select_python; then
    if "$PYTHON_BIN" -E -s -S -B "$dir/guard.py" "$@"; then exit 0; fi
    echo "agent-blindfold: guard process failed." >&2
else
    echo "agent-blindfold: a working Python 3.9+ interpreter is required." >&2
fi
if [[ "${1:-}" == "claude" ]]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"agent-blindfold: guard unavailable."}}'
else
    printf '%s\n' '{"decision":"deny","reason":"agent-blindfold: guard unavailable."}'
fi
