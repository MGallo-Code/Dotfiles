#!/usr/bin/env bash
# check-code-root.sh - guards the GalloGrid split's machine side (EA docs/plans/gallogrid-split.md):
#   - resolve_code_root picks ~/Documents/GalloGrid only when this machine's switch file says so
#     (written at its cutover), or when EA no longer holds the code; a clone alone never switches.
#     It warns on stderr (never stdout, which callers capture) when neither holds service code;
#   - retire_project_mcp_files removes EA's generated docgen-only .mcp.json and keeps any other;
#   - hubs.json names the code root as a token, and hub-host-bootstrap.sh refuses an unresolved one.
# Windows twin: check-code-root.ps1. Hermetic: a throwaway $HOME driven through the real manifest.sh.
# --revert-test makes resolve_code_root switch as soon as GalloGrid is cloned (the hazard the
# switch file prevents) and requires the fixtures to FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVERT=0; [ "${1:-}" = "--revert-test" ] && REVERT=1

run_fixtures() {
    local T rc=0
    T="$(mktemp -d)"
    (
        export HOME="$T/home"
        ok()     { :; }
        warn()   { echo "warn: $1"; }
        expand() { echo "${1/#\~/$HOME}"; }
        # shellcheck source=/dev/null
        source "$ROOT/manifest.sh"
        if [ "$REVERT" = 1 ]; then resolve_code_root() { if [ -d "$(expand "$CODE_ROOT_NEW")/.git" ]; then expand "$CODE_ROOT_NEW"; else expand "$CODE_ROOT_OLD"; fi; }; fi
        SWITCH="$(expand "$CODE_ROOT_SWITCH")"
        check() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1')"; exit 1; fi; }
        NEW="$HOME/Documents/GalloGrid"; OLD="$HOME/Documents/EA"

        mkdir -p "$OLD/nexus"
        check "$(resolve_code_root 2>/dev/null)" "$OLD" "no GalloGrid: EA"
        mkdir -p "$NEW/nexus" "$NEW/.git"
        check "$(resolve_code_root 2>/dev/null)" "$OLD" "GalloGrid cloned, no switch: still EA"
        mkdir -p "$(dirname "$SWITCH")"; echo GalloGrid > "$SWITCH"
        check "$(resolve_code_root 2>/dev/null)" "$NEW" "switch says GalloGrid: GalloGrid"
        rm -f "$SWITCH"; rm -rf "$OLD/nexus"
        check "$(resolve_code_root 2>/dev/null)" "$NEW" "EA without code, GalloGrid cloned: GalloGrid"
        rm -rf "$NEW"
        out="$(resolve_code_root 2>"$T/err")"
        check "$out" "$OLD" "no code anywhere: stdout is still one path"
        if grep -q "no service code" "$T/err"; then echo "  ok    no code anywhere: warned on stderr"; else echo "  FAIL  no warning on stderr"; exit 1; fi

        mkdir -p "$OLD"
        printf '{"mcpServers":{"docgen":{"command":"uv","args":["run","--project","x","python","-m","docgen.server"]}}}\n' > "$OLD/.mcp.json"
        retire_project_mcp_files >/dev/null
        check "$([ -e "$OLD/.mcp.json" ] && echo kept || echo removed)" "removed" "generated docgen-only .mcp.json removed"
        printf '{"mcpServers":{"docgen":{"args":["docgen.server"]},"mine":{"command":"x"}}}\n' > "$OLD/.mcp.json"
        retire_project_mcp_files >/dev/null
        check "$([ -e "$OLD/.mcp.json" ] && echo kept || echo removed)" "kept" "edited .mcp.json kept"

        if grep -q '\$HOME/Documents/EA' "$ROOT/hubs.json"; then echo "  FAIL  hubs.json still names EA"; exit 1; else echo "  ok    hubs.json names the code root token"; fi
        sh "$ROOT/scripts/hub-host-bootstrap.sh" courier 8765 '/usr/bin/env $CODE_ROOT/courier/x' "$T/tok" "" /mcp >/dev/null 2>&1
        check "$?" "2" "bootstrap refuses an unresolved \$CODE_ROOT"
    ) || rc=1
    rm -rf "$T"
    return "$rc"
}

if [ "$REVERT" = 1 ]; then
    if run_fixtures >/dev/null 2>&1; then echo "revert-test FAILED: a switch-on-clone resolver still passes"; exit 1; fi
    echo "revert-test ok: a switch-on-clone resolver fails the fixtures"; exit 0
fi
echo "check-code-root: fixtures"
run_fixtures || { echo "check-code-root: FAILED"; exit 1; }
echo "check-code-root OK"
