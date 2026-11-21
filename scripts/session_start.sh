#!/usr/bin/env bash
set -eu
script_path=${BASH_SOURCE[0]}
case "$script_path" in */*) dir=${script_path%/*} ;; *) dir=. ;; esac
if source "$dir/python_runtime.sh" && blindfold_select_python; then
    exec "$PYTHON_BIN" -E -s -S -B "$dir/session_start.py" "$@"
else
    echo "agent-blindfold: a working Python 3.9+ interpreter is required." >&2
fi
exit 1
