#!/usr/bin/env bash
# check-hub-bootstrap-failclosed.sh -- hermetic gate for manifest.sh `bootstrap_all_hubs` host-side
# FAIL-CLOSED contract (the F01 cross-check surface; the INV-10 client gate never exercises it).
#
# Guards the load-bearing host-cutover contract: a nexus bootstrap failure must be FATAL (rc=1, so
# `setup.sh --host` aborts under `set -e` and `sync.sh` warns via its `|| warn`), while already-live
# courier/calendar failures are warn-only (rc=0) and the OTHER hubs still get bootstrapped; a MALFORMED,
# NON-ARRAY, or NON-OBJECT-element registry fails closed rather than silently serving nothing; and the
# `NEXUS_REMOTED` staging gate skips nexus serving pre-cutover while still serving the rest. These
# regressed repeatedly during the cross-check (the `jq|while` subshell LOST rc; the process-sub fix then
# fail-OPENed on a parse error; a top-level object slipped past the parse capture).
#
# Hermetic: stubs the per-hub bootstrap (which LOGS the hub names it was asked to serve, so we assert the
# actual call SET, not just rc) + fixture registries; no network, no real host, no mutation. Runs
# `bootstrap_all_hubs` inside a STANDALONE subshell with genuine `set -euo pipefail` (mirroring
# `setup.sh --host`). `--revert-test` PROVES the gate bites by reverting the nexus-fatal `rc=1` to
# fail-open and showing the first assertion flips. The macOS/tailscale ps1 host path is PARITY_EXEMPT.
set -uo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$DOTFILES_DIR/manifest.sh"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
chk() { if eval "$2"; then echo -e "  ${GREEN}\xe2\x9c\x93${NC} $1"; pass=$((pass+1)); else echo -e "  ${RED}\xe2\x9c\x97${NC} $1"; fail=$((fail+1)); fi; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hub-bootstrap.XXXXXX")"; trap 'rm -rf "$SANDBOX"' EXIT
BOOT_LOG="$SANDBOX/boot.log"; export BOOT_LOG

cat > "$SANDBOX/ok.json" <<'EOF'
[{"name":"courier","port":8765,"serve_path":"/courier","mcp_path":"/mcp","token_file":"~/x","run_cmd":"x"},
 {"name":"nexus","port":8767,"serve_path":"/nexus","mcp_path":"/mcp","token_file":"~/x","run_cmd":"x"}]
EOF
printf '%s' '[{"name":"courier","port":8765,"serve_path":"/c","mcp_path":"/mcp","token_file":"~/x","run_cmd":"x"}, "stray-string", {"name":"nexus","port":8767,"serve_path":"/n","mcp_path":"/mcp","token_file":"~/x","run_cmd":"x"}]' > "$SANDBOX/nonobj.json"
printf '%s' '{ this is not valid json [[' > "$SANDBOX/malformed.json"
printf '%s' '{"nexus":{"port":8767},"courier":{"port":8765}}' > "$SANDBOX/object.json"   # top-level OBJECT, not array
printf '%s' '{"hubs":[{"name":"nexus","port":8767,"serve_path":"/n","mcp_path":"/mcp","token_file":"~/x","run_cmd":"x"}]}' > "$SANDBOX/wrapped.json"  # array under a key, not top-level
printf '%s' '[]' > "$SANDBOX/empty.json"                                                  # empty array
printf '%s' '[{"name":"courier","port":8765,"serve_path":"/c","mcp_path":"/mcp","token_file":"~/x","run_cmd":"x"}]' > "$SANDBOX/nonexus.json"  # valid array MISSING nexus
# Stub bootstrap: LOG the hub name it was asked to serve (so we assert the call set), then exit 0/1.
printf '#!/usr/bin/env bash\necho "$1" >> "$BOOT_LOG"\nexit 0\n'                          > "$SANDBOX/ok.sh"
printf '#!/usr/bin/env bash\necho "$1" >> "$BOOT_LOG"\n[ "$1" = nexus ] && exit 1\nexit 0\n'   > "$SANDBOX/nexusfail.sh"
printf '#!/usr/bin/env bash\necho "$1" >> "$BOOT_LOG"\n[ "$1" = courier ] && exit 1\nexit 0\n' > "$SANDBOX/courierfail.sh"
chmod +x "$SANDBOX"/*.sh
# A NON-executable bootstrap (no .sh suffix so the chmod above skips it) + a path that does not exist.
printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/noexec-bootstrap"   # intentionally left non-+x

# Run bootstrap_all_hubs the way `setup.sh --host` does: a STANDALONE subshell under genuine errexit (NOT
# `( ... ) || rc=$?`, which neuters -e). Sets BOOT_RC and BOOT_HUBS (the sorted set of hubs the stub served).
BOOT_RC=0; BOOT_HUBS=""
boot() {  # <hubs.json> <bootstrap> <NEXUS_REMOTED-value> [manifest-path]
    : > "$BOOT_LOG"
    local manifest="${4:-$MANIFEST}" rc=0
    (
        set -euo pipefail
        ok() { :; }; warn() { :; }
        # shellcheck source=/dev/null
        source "$manifest"
        NEXUS_REMOTED="$3"
        bootstrap_all_hubs "$1" "$2"
    ) < /dev/null >/dev/null 2>&1
    rc=$?
    BOOT_RC=$rc
    BOOT_HUBS="$(sort -u "$BOOT_LOG" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
}

# ── --revert-test: PROVE the gate bites (mirror check-fresh-client-setup.sh) ──────────────────────────
if [ "${1:-}" = "--revert-test" ]; then
    echo "==> hub-bootstrap revert-test: the gate DETECTS a reverted (fail-open) nexus bootstrap failure"
    BROKEN="$SANDBOX/manifest-broken.sh"
    # Revert the nexus-fatal branch to fail-open: after the nexus FAILED warn, neuter the `rc=1`.
    sed '/hub host bootstrap (nexus) FAILED/{n;s/rc=1/: # reverted: fail-open/;}' "$MANIFEST" > "$BROKEN"
    if grep -q 'reverted: fail-open' "$BROKEN"; then echo "  (patched a copy: nexus-fatal rc=1 reverted to fail-open)"
    else echo "  WARN: revert patch did not apply - the sed target drifted; revert-test is INVALID"; fi
    boot "$SANDBOX/ok.json" "$SANDBOX/nexusfail.sh" true "$BROKEN"; rc_broken=$BOOT_RC
    boot "$SANDBOX/ok.json" "$SANDBOX/nexusfail.sh" true;           rc_ok=$BOOT_RC
    chk "reverted (fail-open) manifest returns rc=0 on a nexus failure - the gate's nexus-fatal assertion would catch this" "[ $rc_broken -eq 0 ]"
    chk "real (fail-closed) manifest returns rc=1 on a nexus failure"                                                       "[ $rc_ok -eq 1 ]"
    echo; echo "revert-test: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

echo "==> bootstrap_all_hubs host-side fail-closed gate"
boot "$SANDBOX/ok.json" "$SANDBOX/nexusfail.sh"   true
chk "nexus bootstrap failure is FATAL (rc=1 -> setup.sh --host aborts)"        "[ $BOOT_RC -eq 1 ]"
boot "$SANDBOX/ok.json" "$SANDBOX/courierfail.sh" true
chk "courier failure is warn-only (rc=0) AND nexus still bootstrapped"         "[ $BOOT_RC -eq 0 ] && printf '%s' \"\$BOOT_HUBS\" | grep -q nexus"
boot "$SANDBOX/ok.json" "$SANDBOX/ok.sh"          true
chk "all hubs ok -> rc=0 AND both courier+nexus actually bootstrapped"         "[ $BOOT_RC -eq 0 ] && printf '%s' \"\$BOOT_HUBS\" | grep -q courier && printf '%s' \"\$BOOT_HUBS\" | grep -q nexus"
boot "$SANDBOX/malformed.json" "$SANDBOX/ok.sh"   true
chk "MALFORMED registry fails CLOSED (rc=1, served nothing)"                   "[ $BOOT_RC -eq 1 ] && [ -z \"\$BOOT_HUBS\" ]"
boot "$SANDBOX/object.json" "$SANDBOX/ok.sh"      true
chk "top-level OBJECT (not array) fails CLOSED (rc=1, served nothing)"         "[ $BOOT_RC -eq 1 ] && [ -z \"\$BOOT_HUBS\" ]"
boot "$SANDBOX/nonobj.json" "$SANDBOX/ok.sh"      true
chk "non-object element skipped; courier+nexus still served (rc=0)"            "[ $BOOT_RC -eq 0 ] && printf '%s' \"\$BOOT_HUBS\" | grep -q courier && printf '%s' \"\$BOOT_HUBS\" | grep -q nexus"
boot "$SANDBOX/ok.json" "$SANDBOX/nexusfail.sh"   false
chk "NEXUS_REMOTED=false: nexus SKIPPED (not served) but courier still served (rc=0)" "[ $BOOT_RC -eq 0 ] && ! printf '%s' \"\$BOOT_HUBS\" | grep -q nexus && printf '%s' \"\$BOOT_HUBS\" | grep -q courier"
boot "$SANDBOX/wrapped.json" "$SANDBOX/ok.sh"     true
chk "array-under-a-key {\"hubs\":[...]} fails CLOSED (rc=1, served nothing) - pins the type==array guard" "[ $BOOT_RC -eq 1 ] && [ -z \"\$BOOT_HUBS\" ]"
boot "$SANDBOX/empty.json" "$SANDBOX/ok.sh"       true
chk "EMPTY array [] while remoted fails CLOSED (rc=1: nexus absent from registry)"    "[ $BOOT_RC -eq 1 ] && [ -z \"\$BOOT_HUBS\" ]"
boot "$SANDBOX/nonexus.json" "$SANDBOX/ok.sh"     true
chk "array MISSING nexus while remoted fails CLOSED (rc=1) even though courier served" "[ $BOOT_RC -eq 1 ] && printf '%s' \"\$BOOT_HUBS\" | grep -q courier && ! printf '%s' \"\$BOOT_HUBS\" | grep -q nexus"
boot "$SANDBOX/empty.json" "$SANDBOX/ok.sh"       false
chk "EMPTY array [] while NOT remoted is an accepted no-op (rc=0; nexus not required pre-cutover)" "[ $BOOT_RC -eq 0 ] && [ -z \"\$BOOT_HUBS\" ]"
boot "$SANDBOX/does-not-exist.json" "$SANDBOX/ok.sh" true
chk "MISSING registry while remoted fails CLOSED (rc=1) - early-return no longer bypasses the cutover gate" "[ $BOOT_RC -eq 1 ]"
boot "$SANDBOX/does-not-exist.json" "$SANDBOX/ok.sh" false
chk "MISSING registry while NOT remoted is a harmless skip (rc=0)"                    "[ $BOOT_RC -eq 0 ]"
boot "$SANDBOX/ok.json" "$SANDBOX/noexec-bootstrap" true
chk "NON-executable bootstrap while remoted fails CLOSED (rc=1)"                      "[ $BOOT_RC -eq 1 ]"

echo; echo "hub-bootstrap fail-closed gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
