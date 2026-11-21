# Locate a working Python 3.9+ before starting any hook or installer action.
# Redirect the version probe from /dev/null so the selected hook receives the whole host event.
blindfold_try_python() {
    local resolved
    resolved=$("$@" -E -s -S -c '
import os
import sys
if sys.version_info < (3, 9):
    raise SystemExit(1)
sys.stdout.buffer.write(os.fsencode(sys.executable))
' </dev/null 2>/dev/null) || return 1
    [[ -n "$resolved" ]] || return 1
    case "$OSTYPE" in
        msys*|cygwin*) resolved=${resolved//\\//} ;;
    esac
    [[ -x "$resolved" ]] || return 1
    PYTHON_BIN=$resolved
}

blindfold_select_python() {
    local name candidate env_dir
    PYTHON_BIN=""
    if [[ -n "${VIRTUAL_ENV:-}" ]]; then
        env_dir=${VIRTUAL_ENV//\\//}
        for candidate in "$env_dir/bin/python3" "$env_dir/bin/python" "$env_dir/Scripts/python.exe"; do
            if [[ -x "$candidate" ]] && blindfold_try_python "$candidate"; then return 0; fi
        done
    fi
    for name in python3 python; do
        while IFS= read -r candidate; do
            case "$OSTYPE:$candidate" in
                msys*:*/[Ww]indows[Aa]pps/*|cygwin*:*/[Ww]indows[Aa]pps/*) continue ;;
            esac
            if blindfold_try_python "$candidate"; then return 0; fi
        done < <(type -aP "$name" 2>/dev/null)
    done
    case "$OSTYPE" in
        msys*|cygwin*)
            while IFS= read -r candidate; do
                case "$candidate" in */[Ww]indows[Aa]pps/*) continue ;; esac
                if blindfold_try_python "$candidate" -3; then return 0; fi
            done < <(type -aP py 2>/dev/null)
            ;;
    esac
    return 1
}
