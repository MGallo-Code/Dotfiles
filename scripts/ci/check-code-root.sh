#!/usr/bin/env bash
# check-code-root.sh - guards the code root's machine side (GalloGrid split; ADR-0007):
#   - resolve_code_root is wherever GalloGrid is on this machine right now: ~/Workspace/GalloGrid, or
#     the old ~/Documents home while the host's move is pending (so a sync never re-renders the live
#     services before their window); a client, with neither, gets the ~/Workspace path and never uses it;
#   - retire_project_mcp_files removes EA's generated docgen-only .mcp.json and keeps any other;
#   - hubs.json names the code root as a token, and hub-host-bootstrap.sh refuses an unresolved one;
#   - clients never build or run the central services (needs_local_nexus, mcp_wiring_ready).
# Windows twin: check-code-root.ps1. Hermetic: a throwaway $HOME driven through the real manifest.sh.
# --revert-test makes resolve_code_root ignore a pending old home (the hazard: the host's live
# services re-rendered at a path that does not exist yet) and requires the fixtures to FAIL.
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
        if [ "$REVERT" = 1 ]; then resolve_code_root() { echo "$(expand "$WORKSPACE_DIR")/GalloGrid"; }; fi
        check() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1')"; exit 1; fi; }
        NEW="$HOME/Workspace/GalloGrid"; PENDING="$HOME/Documents/GalloGrid"; EA="$HOME/Workspace/EA"   # stale-path-ok (pending fixture)

        check "$(resolve_code_root 2>/dev/null)" "$NEW" "no GalloGrid anywhere (a client): the Workspace path"
        mkdir -p "$PENDING/.git" "$PENDING/nexus"
        check "$(resolve_code_root 2>/dev/null)" "$PENDING" "host move pending: the old home, where the services run"
        mkdir -p "$NEW"
        check "$(resolve_code_root 2>/dev/null)" "$PENDING" "an empty folder at the new home switches nothing"
        mkdir -p "$NEW/.git" "$NEW/nexus"
        check "$(resolve_code_root 2>/dev/null)" "$PENDING" "a stray clone at the new home switches nothing"
        rm -rf "$PENDING"
        check "$(resolve_code_root 2>/dev/null)" "$NEW" "moved: ~/Workspace/GalloGrid"
        mkdir -p "$HOME/.config/dotfiles"; echo EA > "$HOME/.config/dotfiles/code-root"
        check "$(resolve_code_root 2>/dev/null)" "$NEW" "a leftover switch file changes nothing"

        OLD="$EA"; mkdir -p "$OLD"
        printf '{"mcpServers":{"docgen":{"command":"uv","args":["run","--project","x","python","-m","docgen.server"]}}}\n' > "$OLD/.mcp.json"
        retire_project_mcp_files >/dev/null
        check "$([ -e "$OLD/.mcp.json" ] && echo kept || echo removed)" "removed" "generated docgen-only .mcp.json removed"
        printf '{"mcpServers":{"docgen":{"args":["docgen.server"]},"mine":{"command":"x"}}}\n' > "$OLD/.mcp.json"
        retire_project_mcp_files >/dev/null
        check "$([ -e "$OLD/.mcp.json" ] && echo kept || echo removed)" "kept" "edited .mcp.json kept"

        STORE="$(expand "$NEXUS_HOST_STORE")"; mkdir -p "$(dirname "$STORE")" "$NEW/nexus"; : > "$STORE"
        ensure_host_store_link "$NEW" >/dev/null 2>&1
        check "$(readlink "$NEW/nexus/nexus.db")" "$STORE" "host store link created in the checkout"
        rm -f "$NEW/nexus/nexus.db"; echo real > "$NEW/nexus/nexus.db"
        out="$(ensure_host_store_link "$NEW" 2>&1)"
        check "$(cat "$NEW/nexus/nexus.db")" "real" "a real nexus.db is never replaced"
        case "$out" in *split-brain*) echo "  ok    a real nexus.db is warned about";; *) echo "  FAIL  no warning for a real nexus.db"; exit 1;; esac
        rm -rf "$NEW"

        # The live services name the store explicitly AND must refuse a missing one (hub session's
        # NEXUS_DB_MUST_EXIST, 2026-10-01): dropping the flag would let nexus create an empty store.
        nx="$(jq -r '.[] | select(.name=="nexus") | .run_cmd' "$ROOT/hubs.json")"
        cr="$(jq -r '.[] | select(.name=="courier") | .run_cmd' "$ROOT/hubs.json")"
        case "$nx" in *NEXUS_DB_MUST_EXIST=1*NEXUS_DB=\$HOME/.local/share/nexus/nexus.db*) echo "  ok    nexus-http names the store and must find it";; *) echo "  FAIL  nexus-http run_cmd lost NEXUS_DB_MUST_EXIST=1 or its explicit store"; exit 1;; esac
        case "$cr" in *COURIER_NEXUS_DB=\$HOME/.local/share/nexus/nexus.db*) echo "  ok    courier-http names the store";; *) echo "  FAIL  courier-http lost COURIER_NEXUS_DB"; exit 1;; esac
        if grep -q '\$HOME/Documents/EA' "$ROOT/hubs.json"; then echo "  FAIL  hubs.json still names EA"; exit 1; else echo "  ok    hubs.json names the code root token"; fi  # stale-path-ok
        sh "$ROOT/scripts/hub-host-bootstrap.sh" courier 8765 '/usr/bin/env $CODE_ROOT/courier/x' "$T/tok" "" /mcp >/dev/null 2>&1
        check "$?" "2" "bootstrap refuses an unresolved \$CODE_ROOT"

        # Clients never build or run the central services (2026-10-01): nexus only where it is stdio,
        # courier and calendar deps only on the host, and a client's wiring needs only docgen.
        yn() { if "$@"; then echo yes; else echo no; fi; }
        is_mcp_host() { return 1; }; NEXUS_REMOTED=true
        check "$(yn needs_local_nexus)" "no" "a remoted client does not build nexus"
        NEXUS_REMOTED=false
        check "$(yn needs_local_nexus)" "yes" "a pre-cutover client builds nexus"
        is_mcp_host() { return 0; }; NEXUS_REMOTED=true
        check "$(yn needs_local_nexus)" "yes" "the host builds nexus"
        is_mcp_host() { return 1; }
        NEXUS_SERVER="$T/none/server.js"; DOCGEN_PATH="$T/docgen"; mkdir -p "$DOCGEN_PATH"
        check "$(yn mcp_wiring_ready)" "yes" "a client wires with docgen and no nexus build"
        rm -rf "$DOCGEN_PATH"
        check "$(yn mcp_wiring_ready)" "no" "a client without docgen skips the wiring"
        for f in sync.sh setup.sh; do
            check "$(grep -B14 'npm run build' "$ROOT/$f" | grep -v '^ *#' | grep -c needs_local_nexus)" "1" "$f builds nexus only under needs_local_nexus"
            check "$(grep -B1 '\[ -d "\$COURIER_PATH" \] && (cd' "$ROOT/$f" | head -1 | grep -c 'if is_mcp_host; then')" "1" "$f syncs courier and calendar deps only on the host"
        done
        check "$(grep -c '^if mcp_wiring_ready; then' "$ROOT/sync.sh")" "1" "sync gates the wiring on mcp_wiring_ready"
    ) || rc=1
    rm -rf "$T"
    return "$rc"
}

if [ "$REVERT" = 1 ]; then
    if run_fixtures >/dev/null 2>&1; then echo "revert-test FAILED: a resolver blind to the pending old home still passes"; exit 1; fi
    echo "revert-test ok: a resolver blind to the pending old home fails the fixtures"; exit 0
fi
echo "check-code-root: fixtures"
run_fixtures || { echo "check-code-root: FAILED"; exit 1; }
echo "check-code-root OK"
