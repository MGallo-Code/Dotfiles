# pick-python.sh - sourced (sh or bash), never run: `. pick-python.sh && pick_python && "$PY" ...`
#
# INV-27. Sets PY to the first of `python3`, `python` that is on PATH and actually runs.
# `python3` stays first because the Mac mini has only `python3`. `python` is the fallback for
# Windows, where `python3` can be the Microsoft Store alias stub: it is on PATH, prints
# "Python was not found", and exits 9009. That broke every hook after the 2026-10-15
# Windows 11 upgrade.
#
# Only a command under WindowsApps is probed, because only the Store stub can be present
# without running. Elsewhere this costs nothing beyond `command -v`.
# Returns 1, with PY empty, when neither runs. The caller decides whether that fails open
# or closed.
pick_python() {
    PY=""
    for _pick_python_name in python3 python; do
        _pick_python_path="$(command -v "$_pick_python_name" 2>/dev/null)" || continue
        case "$_pick_python_path" in
            *WindowsApps*) "$_pick_python_name" -c "" >/dev/null 2>&1 || continue ;;
        esac
        PY="$_pick_python_name"
        unset _pick_python_name _pick_python_path
        return 0
    done
    unset _pick_python_name _pick_python_path
    return 1
}
