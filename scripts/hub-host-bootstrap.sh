#!/usr/bin/env bash
# hub-host-bootstrap.sh  --  HUB-HOST-BOOTSTRAP (ADR-0002, remote-hubs Phase A)
#
# Idempotent, RE-RUNNABLE bootstrap of ONE HTTP MCP hub ON THE MCP HOST. Generalized from the
# old courier-host-bootstrap.sh: courier is now ONE invocation of this script (driven from
# hubs.json by manifest.sh's bootstrap_all_hubs). Stands up everything a client needs to reach
# the hub over Tailscale:
#   1. a mandatory bearer token (mode 600; generated once, never rotated silently),
#   2. a LaunchAgent that runs the hub on 127.0.0.1:PORT in the GUI/Aqua session (so a hub that
#      needs the login keychain - e.g. courier/himalaya - can read it),
#   3. `tailscale serve` fronting it tailnet-only with TLS (root path, or `--set-path <serve_path>`),
#   4. a fail-closed self-test (no-token -> 401, with-token -> not-401) at <mcp_path>.
#
# Usage:  hub-host-bootstrap.sh <name> <port> <run-cmd> <token-file> <serve_path> <mcp_path>
#   name        hub name (e.g. courier) -> LABEL com.ea.<name>-http, log <name>-http.log, env
#               prefix <NAME-UPPER>_ (so the hub's server reads <PREFIX>_HTTP_PORT etc.)
#   port        loopback port the hub binds (e.g. 8765)
#   run-cmd     the FULL launch command (ProgramArguments), $HOME-expanded then word-split. Carries
#               its own PYTHONPATH via `/usr/bin/env PYTHONPATH=... python -m <module>` since the
#               venv editable install is inert and the plist sets no PYTHONPATH key.
#   token-file  mode-600 bearer file outside any repo (e.g. ~/.config/courier/auth-token)
#   serve_path  the `tailscale serve --set-path` prefix; EMPTY string = serve at root
#   mcp_path    the app mount path == in-process self-test == LOOPBACK probe path (e.g. /mcp).
#               `tailscale serve --set-path <serve_path>` STRIPS the prefix before forwarding, so even a
#               path-mounted hub mounts at /mcp (post-strip), NOT serve_path+/mcp. The CLIENT URL is
#               https://<host><serve_path>/mcp (tailscale strips serve_path back to /mcp).
#
# Re-run any time (token rotation: delete the file first; a plist/env change; a hub code update;
# the Mac-mini migration: set MCP_HOST in manifest.sh, run there). Deliberately SEPARATE from
# `sync` per the ADR-0002 cross-check: the host bootstrap is its OWN idempotent repair path.
set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "usage: hub-host-bootstrap.sh <name> <port> <run-cmd> <token-file> <serve_path> <mcp_path>" >&2
    exit 2
fi
NAME="$1"; PORT="$2"; RUN_CMD="$3"; TOKEN_ARG="$4"; SERVE_PATH="$5"; MCP_PATH="$6"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
# shellcheck source=/dev/null
source "$SCRIPT_DIR/manifest.sh"   # MCP_HOST, TAILNET (host identity); the wiring fns are unused here

# Minimal helpers (this script runs standalone, not only sourced by setup.sh).
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}\xe2\x9c\x93${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
err()  { echo -e "  ${RED}\xe2\x9c\x97${NC} $*" >&2; }
expand() { echo "${1/#\~/$HOME}"; }

# bash 3.2 (macOS) has no ${NAME^^}; use tr.
PREFIX="$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]')"
LABEL="com.ea.${NAME}-http"
TOKEN_FILE="$(expand "$TOKEN_ARG")"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/${NAME}-http.log"
ALLOWED_HOST="$MCP_HOST.$TAILNET"
UID_NUM="$(id -u)"

# Testability: HUB_BOOTSTRAP_DRY_RUN=<path> writes the generated plist to <path> and exits BEFORE
# any side effect (no token write, no launchctl, no tailscale serve, no self-test). Lets a test
# diff the would-be plist against the live one without disturbing a running hub.
DRY="${HUB_BOOTSTRAP_DRY_RUN:-}"
[ -n "$DRY" ] && PLIST="$DRY"

# ProgramArguments: $HOME-expand the run-cmd (a controlled substitution, not eval) then word-split.
# Hub paths under ~/Documents/EA have no spaces, matching the rest of this repo's assumptions.
RUN_EXPANDED="${RUN_CMD//\$HOME/$HOME}"
IFS=' ' read -ra PROG_ARGS <<< "$RUN_EXPANDED"
if [ "${#PROG_ARGS[@]}" -eq 0 ]; then err "empty run-cmd for hub '$NAME'"; exit 1; fi

echo "==> hub host bootstrap: $NAME (MCP_HOST=$MCP_HOST, port $PORT, serve '${SERVE_PATH:-/}', mount $MCP_PATH)"

# --- 0. Sanity: must be macOS, and must actually BE the MCP host -------------
# (ADR-0002 review: fail LOUD, never silently degrade a host into a client.)
if [ "$(uname -s)" != "Darwin" ]; then
    err "hub host bootstrap is macOS-only (login-keychain / launchd requirement). This is $(uname -s)."
    exit 1
fi
LOCAL_HOST_NORM="$(scutil --get LocalHostName 2>/dev/null | tr '[:upper:]' '[:lower:]')"
if [ "$LOCAL_HOST_NORM" != "$MCP_HOST" ]; then
    err "this machine's LocalHostName ('$LOCAL_HOST_NORM') != MCP_HOST ('$MCP_HOST')."
    err "Refusing to bootstrap a hub host here (it would shadow the real MCP host)."
    err "If this SHOULD be the host, set MCP_HOST in manifest.sh to '$LOCAL_HOST_NORM'"
    err "(or fix the Local hostname in System Settings > General > Sharing), then re-run."
    exit 1
fi

# --- 1. Bearer token (generate once; never rotate silently) ------------------
if [ -n "$DRY" ]; then
    warn "DRY RUN: skipping token generation"
else
    mkdir -p "$(dirname "$TOKEN_FILE")"
    chmod 700 "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
    if [ ! -s "$TOKEN_FILE" ]; then
        ( umask 177; openssl rand -base64 32 | tr -d '\n' > "$TOKEN_FILE" )
        chmod 600 "$TOKEN_FILE"
        ok "generated a new $NAME bearer token at $TOKEN_FILE (mode 600)"
        warn "to wire a CLIENT machine: run its setup and paste the value of:  cat $TOKEN_FILE"
    else
        chmod 600 "$TOKEN_FILE"
        ok "$NAME bearer token present at $TOKEN_FILE (mode 600, kept as-is)"
    fi
fi

# --- 2. LaunchAgent plist (regenerated every run) ----------------------------
# NOTE: interpolated paths land directly in XML <string> values, so they must be XML-safe
# (no & < >). Hub paths/args are home/venv/EA paths + flags; guard if that ever changes.
PROG_XML=""
for a in "${PROG_ARGS[@]}"; do
    PROG_XML="${PROG_XML}        <string>${a}</string>"$'\n'
done
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- GENERATED by dotfiles/scripts/hub-host-bootstrap.sh (HUB-HOST-BOOTSTRAP, ADR-0002). HTTP MCP
     hub '$NAME': runs in the GUI/Aqua session so a keychain-backed hub can read the login
     keychain; binds 127.0.0.1:$PORT ONLY; the tailnet boundary is \`tailscale serve\`; auth is a
     mandatory bearer token from ${PREFIX}_AUTH_TOKEN_FILE. Re-run the script to refresh. -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
$PROG_XML    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>$HOME</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>${PREFIX}_HTTP_HOST</key><string>127.0.0.1</string>
        <key>${PREFIX}_HTTP_PORT</key><string>$PORT</string>
        <key>${PREFIX}_AUTH_TOKEN_FILE</key><string>$TOKEN_FILE</string>
        <key>${PREFIX}_HTTP_ALLOWED_HOSTS</key><string>$ALLOWED_HOST</string>
    </dict>
    <key>WorkingDirectory</key><string>$HOME</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST_EOF
ok "wrote LaunchAgent plist $PLIST"
if [ -n "$DRY" ]; then
    ok "DRY RUN: plist written to $PLIST; skipping launchctl + tailscale serve + self-test"
    exit 0
fi

# --- 3. (Re)load the LaunchAgent in the GUI domain (race-safe) ----------------
# launchctl bootstrap fails with EIO(5) if it races a just-issued bootout (the old instance not
# yet fully torn down). So: bootout, WAIT for it to disappear, then bootstrap with a short retry,
# and accept "already loaded" as success (idempotent).
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
done
boot_ok=""
for _ in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then boot_ok=1; break; fi
    sleep 1
done
if [ -z "$boot_ok" ] && launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    boot_ok=1
fi
if [ -z "$boot_ok" ]; then
    err "launchctl bootstrap failed for $LABEL - see 'launchctl print gui/$UID_NUM/$LABEL'"
    exit 1
fi
launchctl kickstart -k "gui/$UID_NUM/$LABEL" 2>/dev/null || true
ok "$NAME LaunchAgent (re)loaded"

# --- 4. tailscale serve (tailnet-only TLS front) ------------------------------
# Root hub -> `serve --bg <port>`; path-mounted hub -> `serve --set-path <serve_path> --bg <port>`
# (tailscale serve STRIPS the --set-path prefix before forwarding, so a path hub's app mounts at /mcp,
#  post-strip; the prefix only lives on the tunnel URL the client uses).
TS_BIN="$(command -v tailscale || true)"
[ -n "$TS_BIN" ] || TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
if [ -x "$TS_BIN" ]; then
    serve_ok=""
    if [ -n "$SERVE_PATH" ]; then
        "$TS_BIN" serve --set-path "$SERVE_PATH" --bg "$PORT" >/dev/null 2>&1 && serve_ok=1
    else
        "$TS_BIN" serve --bg "$PORT" >/dev/null 2>&1 && serve_ok=1
    fi
    if [ -n "$serve_ok" ]; then
        ok "tailscale serve -> 127.0.0.1:$PORT  (client URL: https://$ALLOWED_HOST$SERVE_PATH$MCP_PATH)"
    else
        warn "tailscale serve failed - check 'tailscale serve status' and that MagicDNS + HTTPS certs are enabled for the tailnet"
    fi
else
    warn "tailscale CLI not found - run by hand:  tailscale serve ${SERVE_PATH:+--set-path $SERVE_PATH }--bg $PORT"
fi

# --- 5. Fail-closed self-test (the INV-7 boundary, checked externally) --------
# The hub under launchd may not be listening for a beat after kickstart, so the no-auth probe can
# transiently return 000 (connection refused). Retry until we get a REAL HTTP status before judging.
# NB: the fallback must be OUTSIDE the $() - curl's -w already prints "000" on a refused connection,
# so `curl ... || echo 000` would print it TWICE and defeat the "is it a real status yet?" check.
PROBE_URL="http://127.0.0.1:$PORT$MCP_PATH"
code_noauth=000
for _ in 1 2 3 4 5 6 7 8 9 10; do
    code_noauth="$(curl -s -o /dev/null -w '%{http_code}' "$PROBE_URL" 2>/dev/null)" || code_noauth=000
    [ "$code_noauth" != "000" ] && break
    sleep 1
done
# Read the token into a mode-600 curl config so it never lands in a process argv.
tmpcfg="$(mktemp)"; chmod 600 "$tmpcfg"
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" > "$tmpcfg"
code_auth="$(curl -s -o /dev/null -w '%{http_code}' -K "$tmpcfg" "$PROBE_URL" 2>/dev/null)" || code_auth=000
rm -f "$tmpcfg"
# with-token must indicate the request REACHED THE APP (auth + Host + path OK + a working server): a
# 2xx or a benign non-SSE 4xx (405/406/400/415), i.e. 200 <= code < 500 AND not 401 (auth) / 403/421
# (Host-allowlist: TS SDK 403, FastMCP 421) / 404 (wrong mount/path). A 3xx redirect or a 5xx (the server
# threw - createNexusServer/getDb/handler) must NOT pass: the `>= 200 && < 500` band rejects 3xx/5xx/000,
# so a broken-but-authenticated backend can't be reported healthy (cross-check). The 404 rejection is
# DEFENSIVE here: the LOOPBACK probe hits 127.0.0.1:$PORT$MCP_PATH directly (no strip), so the path is
# always MCP_PATH; the strip/mount 404 is the SECTION-6 PUBLIC probe's job to catch.
if [ "$code_noauth" = "401" ] && [ "$code_auth" -ge 200 ] && [ "$code_auth" -lt 500 ] \
        && { [ "$code_auth" -lt 300 ] || [ "$code_auth" -ge 400 ]; } \
        && [ "$code_auth" != "401" ] && [ "$code_auth" != "403" ] \
        && [ "$code_auth" != "421" ] && [ "$code_auth" != "404" ]; then
    ok "self-test: no-token -> 401, with-token -> $code_auth (fail-closed loopback gate verified)"
else
    err "self-test FAILED: no-token=$code_noauth (want 401), with-token=$code_auth (want 2xx/benign-4xx; not 401/403/421/404, not 3xx/5xx/000)."
    err "$NAME may still be starting (or a Host-allowlist/path mismatch, or a server error) - check $LOG and re-run."
    exit 1
fi

# --- 6. PUBLIC-tunnel self-test (PROP-2) — verify the FULL serve/strip/Host path, not just loopback --
# The loopback probe above can't see a serve/--set-path/Host-allowlist mismatch: the calendar
# `--set-path` STRIP bug surfaced only at manual deploy because bootstrap probed 127.0.0.1 ONLY. So
# ALSO probe the PUBLIC URL the client actually uses (https://<host><serve_path>/mcp) through
# `tailscale serve`: no-token -> 401, with-token -> not-401. This fails the BOOTSTRAP closed on any
# serve/mount/strip/Host-allowlist drift (e.g. NEXUS_HTTP_ALLOWED_HOSTS missing the MagicDNS FQDN, which
# the TS SDK matches EXACTLY). Retry for a real status: MagicDNS/TLS can lag a beat after serve.
PUBLIC_URL="https://$ALLOWED_HOST$SERVE_PATH$MCP_PATH"
pub_noauth=000
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pub_noauth="$(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL" 2>/dev/null)" || pub_noauth=000
    [ "$pub_noauth" != "000" ] && break
    sleep 1
done
tmpcfg="$(mktemp)"; chmod 600 "$tmpcfg"
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" > "$tmpcfg"
pub_auth="$(curl -s -o /dev/null -w '%{http_code}' -K "$tmpcfg" "$PUBLIC_URL" 2>/dev/null)" || pub_auth=000
rm -f "$tmpcfg"
# CRITICAL: the authed request must indicate it REACHED THE APP - a 2xx or benign non-SSE 4xx, i.e.
# 200 <= code < 500 AND not 401/403/421/404. A Host-allowlist / --set-path mismatch yields 403 (TS SDK) /
# 421 (FastMCP) / 404 (wrong mount: backend sees /nexus/mcp not /mcp) - all must be rejected or the probe
# fails OPEN on the very drift it exists to catch (the calendar `--set-path` strip class). The `>= 200 &&
# < 500` band ALSO rejects a 3xx redirect and a 5xx (the backend threw) / 000 (refused), so a broken or
# misrouted tunnel can't pass (cross-check: the probe accepted authed 404 AND 500 as success). A correct
# tunnel returns 200 (or a non-SSE 4xx like 405/406), never 3xx/403/421/404/5xx.
if [ "$pub_noauth" = "401" ] && [ "$pub_auth" -ge 200 ] && [ "$pub_auth" -lt 500 ] \
        && { [ "$pub_auth" -lt 300 ] || [ "$pub_auth" -ge 400 ]; } \
        && [ "$pub_auth" != "401" ] && [ "$pub_auth" != "403" ] \
        && [ "$pub_auth" != "421" ] && [ "$pub_auth" != "404" ]; then
    ok "public self-test: $PUBLIC_URL no-token -> 401, with-token -> $pub_auth (tunnel path verified)"
else
    err "PUBLIC self-test FAILED for $PUBLIC_URL: no-token=$pub_noauth (want 401), with-token=$pub_auth (want 2xx/benign-4xx; not 3xx/401/403/421/404/5xx/000)."
    err "A serve/--set-path/mount/Host-allowlist mismatch (403/421) or MagicDNS/HTTPS not enabled - the"
    err "tunnel URL clients use is NOT correctly fronting 127.0.0.1:$PORT$MCP_PATH. Check 'tailscale serve"
    err "status' and ${PREFIX}_HTTP_ALLOWED_HOSTS=$ALLOWED_HOST, then re-run."
    exit 1
fi
echo "==> hub host bootstrap complete: $NAME"
