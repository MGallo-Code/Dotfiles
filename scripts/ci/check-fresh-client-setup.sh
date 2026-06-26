#!/usr/bin/env bash
# check-fresh-client-setup.sh  --  INV-10 enforcer: a fresh/headless CLIENT wires to exit 0 AND a
# FUNCTIONAL client. Hermetic; no network, no real $HOME, no real agent CLIs.
#
# Guards the recurring class that bit silently 4-5x across remote-hubs A-C: a step that aborts the
# whole run under `set -euo pipefail` on an EXPECTED non-zero, OR a client left non-functional
# (bearers not exported, hubs wired stdio/literal-token instead of http+${*_BEARER}). The brittle
# surface is manifest.sh's register_all_hub_mcp / provision_all_client_tokens / ensure_client_bearer_exports,
# which setup.sh + sync.sh both call. This runs THOSE functions exactly as a fresh non-TTY client would
# (GENUINE errexit, stubbed agent CLIs whose `mcp remove` of an UNREGISTERED server returns rc1 - the
# real abort trigger), then asserts exit 0 + the functional-client signals.
#
# ERREXIT CORRECTNESS (the subtle part this gate MUST get right, found by the build cross-check): the
# wiring is measured in a subshell that runs with errexit ACTUALLY active. `( set -e; ... ) || rc=$?`
# does NOT work - a subshell on the left of `||` runs with errexit NEUTERED even if it re-runs `set -e`
# internally (verified on bash 3.2 AND 5.2). So we drop the parent's -e (`set +e`), run the subshell as
# a STANDALONE command (its own `set -e` is then genuinely in force), and capture `$?`. An earlier
# version used `( set -e; ... ) || rc=$?` and was a TAUTOLOGY (it passed even with the `|| true` guard
# deleted from manifest.sh). The `--revert-test` now PROVES detection by patching the real manifest.
#
# Modes:
#   (default)        run the client wiring; assert exit 0 + bearer exports + http+${*_BEARER} wiring (no literals)
#   --revert-test    PROVE the gate bites: patch a copy of the REAL manifest (drop `|| true` on the
#                    mcp-remove loop) and show the wiring ABORTS, while the unpatched manifest completes
#
# CI: a fresh Ubuntu runner (we force a throwaway $HOME below). The macOS setup.ps1/host-only surface is
# PARITY_EXEMPT (this gate is a Linux client check; see check-parity.py).
set -uo pipefail   # NOT -e at top: we control errexit explicitly around each measurement.

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass=0; fail=0
chk()  { if eval "$2"; then echo -e "  ${GREEN}\xe2\x9c\x93${NC} $1"; pass=$((pass+1)); else echo -e "  ${RED}\xe2\x9c\x97${NC} $1"; fail=$((fail+1)); fi; }

# ── Throwaway sandbox: a fresh $HOME + a stub-CLI dir on the front of PATH ────────────────────────
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/fresh-client.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
STUBBIN="$SANDBOX/bin"; mkdir -p "$STUBBIN"
MCP_LOG="$SANDBOX/mcp-calls.log"; : > "$MCP_LOG"
export MCP_LOG SANDBOX

# Stub agent CLI: models the REAL exit codes that bit us. `mcp remove <name>` of a server that was
# never added returns 1 (claude + gemini do); `mcp add` records its argv and returns 0; everything
# else returns 0. State (which names are "registered") is per-CLI so the remove rc is realistic.
make_stub() {
    local cli="$1"
    cat > "$STUBBIN/$cli" <<STUB
#!/usr/bin/env bash
state="$SANDBOX/.registered-$cli"; touch "\$state"
if [ "\${1:-}" = "mcp" ]; then
    sub="\${2:-}"; shift 2 || true
    case "\$sub" in
        remove)
            name=""; for a in "\$@"; do case "\$a" in --*) ;; *) name="\$a";; esac; done
            if grep -qx "\$name" "\$state"; then grep -vx "\$name" "\$state" > "\$state.tmp" && mv "\$state.tmp" "\$state"; exit 0
            else exit 1; fi   # <-- UNREGISTERED remove returns 1: the real \`set -e\` abort trigger
            ;;
        add)
            name=""; for a in "\$@"; do case "\$a" in --*|-*) ;; *) [ -z "\$name" ] && name="\$a";; esac; done
            echo "$cli mcp add \$*" >> "$MCP_LOG"
            echo "\$name" >> "\$state"
            exit 0 ;;
        list) exit 0 ;;
        *) exit 0 ;;
    esac
fi
exit 0
STUB
    chmod +x "$STUBBIN/$cli"
}
make_stub claude; make_stub codex; make_stub gemini
export PATH="$STUBBIN:$PATH"

# Helpers the manifest fns need (quiet); inherited by the measurement subshells.
ok()   { :; }
warn() { :; }
expand() { echo "${1/#\~/$HOME}"; }
# Per-server path vars that setup.sh/sync.sh set in their MCP section BEFORE calling the wiring fns
# (manifest.sh references them under set -u). The stub CLIs only record argv, so placeholders suffice.
EA="$SANDBOX/ea"
NEXUS_SERVER="$EA/nexus/dist/server.js"
COURIER_PATH="$EA/courier"; COURIER_SRC="$COURIER_PATH/src"
DOCGEN_PATH="$EA/docgen";   DOCGEN_SRC="$DOCGEN_PATH/src"; DOCGEN_BROWSERS="$DOCGEN_PATH/.playwright-browsers"
CALENDAR_PATH="$EA/calendar"; CALENDAR_SRC="$CALENDAR_PATH/src"
mkdir -p "$(dirname "$NEXUS_SERVER")"; : > "$NEXUS_SERVER"

reset_state() { rm -f "$SANDBOX"/.registered-*; : > "$MCP_LOG"; : > "$HOME/.bashrc"; }

# Run the fresh-client wiring sourcing $1 (a manifest path) under GENUINE errexit; return its exit code.
# A fresh client state is reset first (so the stub's first `mcp remove` is of an UNREGISTERED server).
run_wiring_rc() {
    local manifest="$1" rc=0
    reset_state
    # The gate runs with errexit OFF (top `set -uo pipefail`), so this subshell is a STANDALONE command:
    # its own `set -e` is genuinely in force (not a ||-left context that would neuter it), and its
    # non-zero exit does NOT abort the parent - we just capture it. Do NOT add `set +e`/`set -e` here:
    # leaking errexit into the caller makes the function's own non-zero return abort the gate.
    (
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$manifest"
        is_mcp_host() { return 1; }                         # force CLIENT role regardless of this box
        # HERMETIC: force the cutover flag to EXACTLY the gate var, overriding the just-sourced manifest
        # value. Both the pre-cutover (stdio) and post-cutover (http) wiring must be testable regardless
        # of where the live manifest currently sits - else flipping the manifest breaks this gate.
        NEXUS_REMOTED="${GATE_NEXUS_REMOTED:-false}"
        provision_all_client_tokens
        register_all_hub_mcp claude
        register_all_hub_mcp codex
        register_all_hub_mcp gemini
    ) < /dev/null
    rc=$?
    return "$rc"
}

if [ "${1:-}" = "--revert-test" ]; then
    echo "==> INV-10 revert-test: the gate DETECTS the real mcp-remove abort regression"
    # Patch a COPY of the REAL manifest: drop the `|| true` guard on the mcp-remove loop ONLY.
    BROKEN="$SANDBOX/manifest-broken.sh"
    sed '/mcp remove .*|| true; done/ s/ || true; done/; done/' "$DOTFILES_DIR/manifest.sh" > "$BROKEN"
    if grep -q 'mcp remove.*2>&1; done' "$BROKEN"; then echo "  (patched a copy: '|| true' removed from the remove loop)";
    else echo "  WARN: patch did not apply - the sed target drifted; revert-test is INVALID"; fi
    run_wiring_rc "$BROKEN"; rc_broken=$?
    run_wiring_rc "$DOTFILES_DIR/manifest.sh"; rc_ok=$?
    chk "broken manifest (no '|| true') ABORTS a fresh client (rc!=0) - gate catches it" "[ $rc_broken -ne 0 ]"
    chk "real (guarded) manifest completes a fresh client (rc=0)"                          "[ $rc_ok -eq 0 ]"
    echo; echo "revert-test: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

# ── The gate: run the fresh-client wiring (genuine errexit) and assert the functional-client signals ─
echo "==> INV-10: fresh non-TTY client wiring (NEXUS_REMOTED=${GATE_NEXUS_REMOTED:-false})"
run_wiring_rc "$DOTFILES_DIR/manifest.sh"; rc=$?

chk "client wiring ran to completion (exit 0; no set -e abort)" "[ $rc -eq 0 ]"
chk "~/.bashrc got the bearer-export marker block" "grep -q 'dotfiles: hub bearer tokens' '$HOME/.bashrc'"
chk "~/.bashrc exports COURIER_BEARER"  "grep -q 'COURIER_BEARER'  '$HOME/.bashrc'"
chk "~/.bashrc exports CALENDAR_BEARER" "grep -q 'CALENDAR_BEARER' '$HOME/.bashrc'"
# nexus export is GATED on the cutover flag (so a pre-cutover client's ~/.bashrc is identical to today);
# the gate verifies the gating BOTH ways.
if [ "${GATE_NEXUS_REMOTED:-false}" = "true" ]; then
    chk "~/.bashrc exports NEXUS_BEARER (post-cutover)" "grep -q 'NEXUS_BEARER' '$HOME/.bashrc'"
else
    chk "~/.bashrc does NOT export NEXUS_BEARER (pre-cutover; gated)" "! grep -q 'NEXUS_BEARER' '$HOME/.bashrc'"
fi
# Functional client: courier + calendar (and post-cutover nexus) wired http+bearer for EACH agent CLI
# with the ENV-VAR REF, never a literal token. Each CLI has its OWN add syntax (claude/gemini:
# --header/-H "...Bearer ${ENV}"; codex: --bearer-token-env-var ENV), so the prior `claude`-only grep would
# have GREEN-lit a codex/gemini-only stdio regression (cross-check). Assert all three positively.
http_wired() {  # <cli> <hub> <ENVVAR>: that CLI emitted an `mcp add` line naming the hub AND its env ref
    grep -E "^$1 mcp add" "$MCP_LOG" | grep -F "$2" | grep -q "$3"
}
nexus_stdio() { # <cli>: that CLI wired nexus stdio (node exec, no bearer/http)
    grep -E "^$1 mcp add" "$MCP_LOG" | grep -F nexus | grep -q node \
        && ! { grep -E "^$1 mcp add" "$MCP_LOG" | grep -F nexus | grep -qE '_BEARER|--transport|--url'; }
}
for cli in claude codex gemini; do
    chk "$cli wired courier http with \${COURIER_BEARER} ref"   "http_wired $cli courier COURIER_BEARER"
    chk "$cli wired calendar http with \${CALENDAR_BEARER} ref" "http_wired $cli calendar CALENDAR_BEARER"
done
# No literal bearer: a real token is base64 (openssl rand -base64) OR could carry -/_/= - reject any
# long opaque run after Bearer that is NOT a ${...} env ref. (At-REST literals in ~/.gemini/settings.json
# are a separate surface owned by check-hub-wiring.py --host; this gate covers the wiring-time argv.)
chk "no literal bearer token in any mcp add (only \${*_BEARER} refs)" "! grep -Eq 'Bearer [A-Za-z0-9+/_=-]{16,}' '$MCP_LOG'"
# Pre-cutover nexus is stdio host; post-cutover it is an http client. Assert per the gate var, per CLI.
if [ "${GATE_NEXUS_REMOTED:-false}" = "true" ]; then
    for cli in claude codex gemini; do
        chk "$cli wired nexus http with \${NEXUS_BEARER} ref (post-cutover)" "http_wired $cli nexus NEXUS_BEARER"
    done
else
    for cli in claude codex gemini; do
        chk "$cli wired nexus stdio (pre-cutover; node, no bearer)" "nexus_stdio $cli"
    done
fi

echo; echo "INV-10 gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
