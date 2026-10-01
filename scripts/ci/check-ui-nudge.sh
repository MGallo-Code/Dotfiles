#!/usr/bin/env bash
# check-ui-nudge.sh - INV-19: the UI-workflow nudge.
#   - claude-config/global-hooks/ui-nudge.py reminds a chat once per session when it edits a UI file,
#     stays silent for other files, repeats and bad input, and always exits 0 (fail open);
#   - manifest.sh ensure_claude_hook registers it once by exact command, keeping unrelated hooks.
# Windows twin for the registration: check-ui-nudge.ps1. Hermetic: throwaway HOME and state dir.
# --revert-test swaps in a do-nothing hook and a do-nothing helper; the fixtures must then FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVERT=0; [ "${1:-}" = "--revert-test" ] && REVERT=1
PY="$(command -v python3)"

run_fixtures() {
    local T rc=0
    T="$(mktemp -d)"
    (
        export HOME="$T/home" UI_NUDGE_STATE="$T/state"
        HOOK="$ROOT/claude-config/global-hooks/ui-nudge.py"
        if [ "$REVERT" = 1 ]; then printf 'import sys\nsys.exit(0)\n' > "$T/noop.py"; HOOK="$T/noop.py"; fi
        fire() { printf '%s' "$1" | "$PY" "$HOOK"; }
        check() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1')"; exit 1; fi; }

        out="$(fire '{"session_id":"s1","tool_input":{"file_path":"/x/app/Button.tsx"}}')"; rc=$?
        check "$(printf '%s' "$out" | grep -c additionalContext)" "1" "UI file: one reminder"
        check "$rc" "0" "UI file: exit 0"
        check "$(fire '{"session_id":"s1","tool_input":{"file_path":"/x/app/styles.css"}}')" "" "same session: silent"
        check "$(fire '{"session_id":"s2","tool_input":{"file_path":"/x/server/api.py"}}')" "" "non-UI file: silent"
        check "$(fire '{"tool_input":{"file_path":"/x/a.html"}}')" "" "no session id: silent"
        check "$(fire 'not json')" "" "bad input: silent"
        printf 'not json' | "$PY" "$HOOK" >/dev/null 2>&1; check "$?" "0" "bad input: exit 0"

        mkdir -p "$HOME/.claude"
        printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"}]}]}}\n' > "$HOME/.claude/settings.json"
        ok() { :; }; warn() { :; }; expand() { echo "${1/#\~/$HOME}"; }
        # shellcheck source=/dev/null
        source "$ROOT/manifest.sh"
        if [ "$REVERT" = 1 ]; then ensure_claude_hook() { :; }; fi
        ensure_claude_hook PostToolUse "Edit|Write|MultiEdit" "$UI_NUDGE_HOOK_CMD" "UI-workflow nudge"
        ensure_claude_hook PostToolUse "Edit|Write|MultiEdit" "$UI_NUDGE_HOOK_CMD" "UI-workflow nudge"
        check "$(jq --arg c "$UI_NUDGE_HOOK_CMD" '[.hooks.PostToolUse[]?.hooks[]? | select(.command == $c)] | length' "$HOME/.claude/settings.json")" "1" "registered exactly once"
        check "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOME/.claude/settings.json")" "guard.sh" "unrelated hook kept"
        check "$(jq -r '.hooks.PostToolUse[0].matcher' "$HOME/.claude/settings.json")" "Edit|Write|MultiEdit" "matcher set"
    ) || rc=1
    rm -rf "$T"
    return "$rc"
}

if [ "$REVERT" = 1 ]; then
    if run_fixtures >/dev/null 2>&1; then echo "revert-test FAILED: a do-nothing hook still passes"; exit 1; fi
    echo "revert-test ok: a do-nothing hook fails the fixtures"; exit 0
fi
echo "check-ui-nudge: fixtures"
run_fixtures || { echo "check-ui-nudge: FAILED"; exit 1; }
echo "check-ui-nudge OK"
