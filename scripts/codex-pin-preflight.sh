#!/usr/bin/env bash
# codex-pin-preflight.sh <candidate-version>
#
# Sandbox compatibility test for a Codex pin bump (manifest.sh CODEX_PIN). Proves a
# candidate version is safe BEFORE it touches any machine: every check runs against a
# throwaway CLONE of ~/.codex (via CODEX_HOME) and the candidate binary comes from npx,
# so the global install and the real config are never modified.
#
# Why this exists: codex's config.toml MCP schema has drifted across versions before
# (a newer codex wrote a `transport` field an older one rejected; `codex mcp remove`
# could not load the file, deadlocking re-wiring - see the 20db221 self-heal in
# setup/sync). The pin is only bumpable when BOTH directions still parse.
#
# Checks:
#   1. installed codex parses a clone of the real config       (baseline)
#   2. candidate parses that same config                       (forward compat)
#   3. candidate `mcp add`s a stdio + an http server           (sync wiring surface)
#   4. installed codex parses the candidate-written config     (backward compat - the
#      direction that broke in June 2026)
#   5. `codex exec --help` / `codex mcp add --help` diff       (flag parity; any diff
#      is printed for human review - additive changes are fine, removals are not)
#
# NOT covered (verify live right after upgrading):
#   - hook trust hashes: [hooks.state] keys embed the real config path, so a clone
#     cannot exercise them. Run a codex turn that uses Bash and confirm the PreToolUse
#     guards fire without a re-trust prompt.
#   - `exec -s read-only` end-to-end (needs auth + burns tokens):
#     codex exec -s read-only "Reply with exactly: ok"
#
# On PASS: bump CODEX_PIN in manifest.sh + $CodexPin in manifest.ps1, re-stamp
# ~/Documents/agent-skills/coding-mastermind/MANIFEST.md, then on every machine:
#   npm install -g @openai/codex@<pin>

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ok]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

CANDIDATE="${1:?usage: codex-pin-preflight.sh <candidate-version, e.g. 0.144.1>}"
REAL_CONFIG="$HOME/.codex/config.toml"

command -v codex >/dev/null 2>&1 || fail "no installed codex on PATH to test against"
command -v npx   >/dev/null 2>&1 || fail "npx not found (needed to run the candidate without installing it)"
[ -f "$REAL_CONFIG" ] || fail "no $REAL_CONFIG to clone"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CLONE="$WORK/home"
mkdir -p "$CLONE"
# config only - deliberately NOT auth.json (no tokens in tmp; mcp subcommands don't need auth)
cp "$REAL_CONFIG" "$CLONE/config.toml"
for f in version.json installation_id; do
    [ -f "$HOME/.codex/$f" ] && cp "$HOME/.codex/$f" "$CLONE/$f"
done

installed_ver="$(codex --version | awk '{print $2}')"
candidate=(npx -y "@openai/codex@$CANDIDATE")
echo "preflight: installed $installed_ver  vs  candidate $CANDIDATE"
echo

# 1. baseline: installed codex parses the cloned config
CODEX_HOME="$CLONE" codex mcp list >/dev/null 2>&1 \
    || fail "baseline: installed $installed_ver cannot parse its own config clone"
ok "1/5 baseline: $installed_ver parses the config clone"

# 2. forward compat: candidate parses the current config
CODEX_HOME="$CLONE" "${candidate[@]}" mcp list >/dev/null 2>&1 \
    || fail "forward: candidate $CANDIDATE cannot parse the current config"
ok "2/5 forward: $CANDIDATE parses the current config"

# 3. candidate writes MCP entries through the same surface sync.sh uses
CODEX_HOME="$CLONE" "${candidate[@]}" mcp add pinpreflight_stdio -- echo preflight >/dev/null 2>&1 \
    || fail "wiring: candidate $CANDIDATE stdio 'mcp add' failed (sync.sh _hub_stdio_add surface)"
CODEX_HOME="$CLONE" "${candidate[@]}" mcp add pinpreflight_http \
        --url "https://example.invalid/mcp" --bearer-token-env-var PINPREFLIGHT_TOKEN >/dev/null 2>&1 \
    || fail "wiring: candidate $CANDIDATE http 'mcp add' failed (sync.sh _hub_http_add surface)"
ok "3/5 wiring: candidate 'mcp add' stdio + http both work"

# 4. backward compat: installed codex parses what the candidate wrote
CODEX_HOME="$CLONE" codex mcp list >/dev/null 2>&1 \
    || fail "backward: installed $installed_ver cannot parse config written by $CANDIDATE - machines must NOT drift; upgrade all at once or do not bump"
ok "4/5 backward: $installed_ver parses config written by $CANDIDATE"

# 5. flag parity on the surfaces sync.sh + the cross-check skill call
flag_drift=0
for sub in "exec --help" "mcp add --help"; do
    # shellcheck disable=SC2086
    codex $sub >"$WORK/old.txt" 2>/dev/null || true
    # shellcheck disable=SC2086
    CODEX_HOME="$CLONE" "${candidate[@]}" $sub >"$WORK/new.txt" 2>/dev/null || true
    if ! diff -u "$WORK/old.txt" "$WORK/new.txt" >"$WORK/help.diff"; then
        flag_drift=1
        warn "5/5 'codex $sub' changed between $installed_ver and $CANDIDATE - review:"
        cat "$WORK/help.diff"
    fi
done
[ "$flag_drift" -eq 0 ] && ok "5/5 flags: exec/mcp-add help identical"

echo
ok "PREFLIGHT PASSED for $CANDIDATE (help-diff above needs eyes if shown)"
echo "next: bump CODEX_PIN (manifest.sh) + \$CodexPin (manifest.ps1), re-stamp the kit"
echo "      MANIFEST, then: npm install -g @openai/codex@$CANDIDATE on every machine"
