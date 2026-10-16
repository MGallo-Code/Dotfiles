#!/usr/bin/env bash
# check-pick-python.sh - INV-27: every dotfiles python3 caller survives a python3 that does not run.
#   - claude-config/global-hooks/pick-python.sh picks python3 when it runs (the Mac mini has only
#     python3), python when python3 is the Windows Store alias stub, and fails when neither runs;
#   - the Builder and Challenger agents' guard commands, run as written in their frontmatter,
#     reach the guard past a stub python3; with no Python the Builder fails closed and the
#     Challenger fails open, as documented;
#   - no shell hook calls a bare python3.
# Hermetic: fake interpreters in a throwaway dir, wrapping the real one. Portable (macOS, Git Bash).
# --revert-test swaps in a helper that trusts python3 blindly; the fixtures must then FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVERT=0; [ "${1:-}" = "--revert-test" ] && REVERT=1
HELPER="$ROOT/claude-config/global-hooks/pick-python.sh"
REAL=""
for c in python3 python; do "$c" -c "" >/dev/null 2>&1 && { REAL="$(command -v "$c")"; break; }; done
[ -n "$REAL" ] || { echo "check-pick-python: no Python on this machine to wrap" >&2; exit 2; }

run_fixtures() {
    local T fails=0
    T="$(mktemp -d)"
    if [ "$REVERT" = 1 ]; then printf 'pick_python() { PY=python3; }\n' > "$T/naive.sh"; HELPER="$T/naive.sh"; fi
    mkdir -p "$T/WindowsApps" "$T/StoreReal" "$T/real" "$T/mac" "$T/home/.claude/hooks"
    # The Store stub: on PATH, does not run, exit 9009 as on Windows.
    printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 9009\n' > "$T/WindowsApps/python3"
    # A working Store alias (the real Store Python) also lives under WindowsApps.
    mkdir -p "$T/StoreReal/WindowsApps"; printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL" > "$T/StoreReal/WindowsApps/python3"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL" > "$T/real/python"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL" > "$T/mac/python3"
    chmod +x "$T/WindowsApps/python3" "$T/StoreReal/WindowsApps/python3" "$T/real/python" "$T/mac/python3"

    pick() { PATH="$1" "$BASH" -c '. "$0" && pick_python; echo "$?:${PY:-}"' "$HELPER" 2>/dev/null; }
    check() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1')"; fails=1; fi; }

    check "$(pick "$T/WindowsApps:$T/real")" "0:python" "Store stub python3 ahead of python: picks python"
    check "$(pick "$T/mac")" "0:python3" "only python3 (the Mac mini): picks python3"
    check "$(pick "$T/StoreReal/WindowsApps:$T/real")" "0:python3" "a working python3 under WindowsApps: keeps python3"
    check "$(pick "$T/WindowsApps")" "1:" "only the stub: fails, PY empty"

    # The agent guards, run exactly as their frontmatter registers them, against a fake guard.
    cp "$HELPER" "$T/home/.claude/hooks/pick-python.sh"
    printf 'import sys\nprint("guard ran", sys.argv[1])\nsys.exit(0)\n' > "$T/home/.claude/hooks/context-card.py"
    agent_cmd() { sed -n "s/^ *command: '\\(.*\\)'\$/\\1/p" "$ROOT/claude-config/global-agents/$1.md" | head -1; }
    guard() { { HOME="$T/home" PATH="$1" "$BASH" -c "$(agent_cmd "$2")" 2>/dev/null; echo "rc=$?"; } | tr -d '\r'; }
    for a in builder builder-high; do
        check "$(guard "$T/WindowsApps:$T/real" "$a" | tr '\n' ' ')" "guard ran builder-guard rc=0 " "$a guard runs past a Store stub python3"
        check "$(guard "$T/WindowsApps" "$a")" "rc=2" "$a guard with no Python fails closed"
    done
    check "$(guard "$T/WindowsApps:$T/real" challenger | tr '\n' ' ')" "guard ran challenger-guard rc=0 " "challenger guard runs past a Store stub python3"
    check "$(guard "$T/WindowsApps" challenger)" "rc=0" "challenger guard with no Python fails open"

    # No shell hook calls a bare python3 (comments and the helper itself aside).
    local bare
    bare="$(grep -n -E '(^|[^A-Za-z0-9_./-])python3([^A-Za-z0-9_.-]|$)' "$ROOT"/claude-config/global-hooks/*.sh \
        | grep -v '/pick-python\.sh:' | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
    check "$bare" "" "no shell hook calls a bare python3"
    rm -rf "$T"
    return "$fails"
}

if [ "$REVERT" = 1 ]; then
    if run_fixtures >/dev/null; then echo "check-pick-python --revert-test: the naive helper PASSED - the gate is toothless" >&2; exit 1; fi
    echo "check-pick-python --revert-test: the naive helper fails the fixtures (good)"; exit 0
fi
run_fixtures || { echo "check-pick-python: FAILED" >&2; exit 1; }
echo "check-pick-python: ok"
