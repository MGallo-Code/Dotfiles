#!/usr/bin/env bash
# assert-no-client-stdio-nexus.sh  --  Phase-D post-cutover assertion (the runbook's step-7 enforcer).
#
# After the nexus cutover, NO client surface may keep a LOCAL STDIO nexus entry: every client reaches
# nexus over the http+bearer tunnel. A surviving stdio entry = a client silently reading its own stale
# `nexus.db` instead of the host-authoritative one (split-brain). This scans every client surface and
# FAILS (exit 1) on any stdio nexus found. Run it on EACH client (and the host) AFTER the cutover.
#
# Scoped to LIVE configs (which are machine-local, never in CI) - so this is a host/client-side gate,
# like hub-host-bootstrap's self-test, not a CI job. PRE-cutover it is EXPECTED to find stdio nexus
# (that is correct then); it must come back CLEAN only once NEXUS_REMOTED=true and clients are re-set-up.
#
# A nexus entry is STDIO if it has a `command`/`args` (e.g. node .../server.js); it is OK if it is http
# (a `url`/`type=http`/`--transport http`). Findings are CLASSIFIED: the HOST stays `is_mcp_host`, so it
# legitimately keeps a GLOBAL stdio nexus (~/.claude.json / ~/.codex / ~/.gemini) post-cutover - pass
# --host to tolerate THAT. But a PROJECT `.mcp.json` stdio nexus, or an ungated generator, is forbidden
# EVERYWHERE (the host's projects must use the global http client too). So --host allows GLOBAL findings
# only, never project/generator ones.
set -uo pipefail

ALLOW_HOST_STDIO=0
[ "${1:-}" = "--host" ] && ALLOW_HOST_STDIO=1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
# Two classes: GLOBAL agent-config stdio (host-allowed) vs PROJECT/generator stdio (forbidden everywhere).
global_findings=0
project_findings=0
note() { echo -e "  ${YELLOW}!${NC} $*"; }
bad_global()  { echo -e "  ${RED}\xe2\x9c\x97 STDIO nexus (global):${NC} $*";            global_findings=$((global_findings+1)); }
bad_project() { echo -e "  ${RED}\xe2\x9c\x97 STDIO nexus (project/generator):${NC} $*"; project_findings=$((project_findings+1)); }

have_jq() { command -v jq >/dev/null 2>&1; }

# scan_json <file> <global|project>: a nexus entry with a "command" key (mcpServers OR project-scoped
# projects.*.mcpServers) is stdio.
scan_json() {
    local f="$1" category="$2"
    [ -f "$f" ] || return 0
    # jq missing = we cannot verify; treat as a blocking (project) finding in BOTH modes, not a pass.
    have_jq || { note "jq not found - cannot vet $f"; bad_project "$f (jq missing - cannot verify; install jq)"; return; }
    # MALFORMED JSON = we cannot verify either, so it must NOT pass silently. The jq queries below 2>/dev/null
    # a parse error to an empty string (-> no finding under set -uo); flag it as blocking instead (cross-check:
    # a broken config is exactly where a stale stdio nexus could hide, and an unverifiable config is not "clean").
    jq -e . "$f" >/dev/null 2>&1 || { bad_project "$f (not valid JSON - cannot verify; fix the config)"; return; }
    # Classify by JSON LOCATION, not just the caller arg: a top-level .mcpServers.nexus gets the caller's
    # category (a global agent config is host-allowed; a standalone project .mcp.json is not), but a nexus
    # nested under .projects.*.mcpServers is a PROJECT-scoped stdio entry that is forbidden EVERYWHERE -
    # so it must count as project even inside ~/.claude.json (cross-check: it was mis-tolerated as global).
    local top proj
    top="$(jq -r '[ (.mcpServers // {}) ] | map(select(.nexus.command != null)) | length' "$f" 2>/dev/null)"
    if [ "${top:-0}" != "0" ] && [ -n "$top" ]; then
        if [ "$category" = "global" ]; then bad_global "$f (mcpServers.nexus has a command/stdio)";
        else bad_project "$f (mcpServers.nexus has a command/stdio)"; fi
    fi
    proj="$(jq -r '[ (.projects // {}) | to_entries[].value.mcpServers // {} ] | map(select(.nexus.command != null)) | length' "$f" 2>/dev/null)"
    if [ "${proj:-0}" != "0" ] && [ -n "$proj" ]; then
        bad_project "$f (projects.*.mcpServers.nexus is stdio - forbidden on every box)"
    fi
}

# codex config.toml stdio nexus. Covers the form register_hub_mcp / `codex mcp add` actually WRITE (the
# `[mcp_servers.nexus]` SECTION, optionally indented) PLUS the common hand-edit forms - an inline table
# `nexus = {...}` or `mcp_servers.nexus = {...}` (single OR multi-line) and the dotted leaf
# `mcp_servers.nexus.command = ...` - each carrying a `command` (a stdio spawn), ignoring a trailing `#`
# comment. A `command` is flagged REGARDLESS of any `url` also present: the invariant is "no stdio nexus",
# and a command can still spawn the process even in a malformed command+url entry (cross-check). It does NOT
# claim to parse EVERY possible TOML expression of the key (only a real TOML lib would); the GENERATED
# surface - its actual job - is fully covered, and the most dangerous hand-edit form
# (`mcp_servers.nexus = {command}`) self-announces as a duplicate-key TOML parse error once
# register_all_hub_mcp re-adds the section, so codex fails LOUDLY rather than running split-brain (cross-check).
scan_toml() {
    local f="$1" category="$2"
    [ -f "$f" ] || return 0
    local hit
    hit="$(awk '
        function nc(s){ sub(/#.*/, "", s); return s }   # drop a trailing TOML comment for the field checks
        # [mcp_servers.nexus] SECTION (leading indent allowed): a command anywhere before the next [section]/EOF
        /^[[:space:]]*\[mcp_servers\.nexus\]/ {innexus=1; cmd=0; next}
        /^[[:space:]]*\[/ {if(innexus && cmd){print "hit"}; innexus=0}
        innexus { l=nc($0); if(l ~ /^[[:space:]]*command[[:space:]]*=/) cmd=1 }
        # inline table nexus = { ... } OR dotted-key inline mcp_servers.nexus = { ... }: open until }, any command
        /^[[:space:]]*(mcp_servers\.)?nexus[[:space:]]*=[[:space:]]*\{/ {
            inline=1; icmd=0; l=nc($0)
            if (l ~ /command[[:space:]]*=/) icmd=1
            if (l ~ /\}/) {if(icmd) print "hit"; inline=0}
            next
        }
        inline {
            l=nc($0)
            if (l ~ /command[[:space:]]*=/) icmd=1
            if (l ~ /\}/) {if(icmd) print "hit"; inline=0}
        }
        # dotted-key LEAF form: mcp_servers.nexus.command = ... (no section, no inline {)
        /^[[:space:]]*mcp_servers\.nexus\.command[[:space:]]*=/ {dotcmd=1}
        END {
            if(innexus && cmd) print "hit"
            if(dotcmd) print "hit"
        }
    ' "$f" 2>/dev/null)"
    if printf '%s' "$hit" | grep -q hit; then
        if [ "$category" = "global" ]; then bad_global "$f ([mcp_servers.nexus] is stdio: command, no url)";
        else bad_project "$f ([mcp_servers.nexus] is stdio: command, no url)"; fi
    fi
}

# A generator (setup.sh/setup.ps1) must GATE any emitted stdio nexus behind the cutover flag. STRUCTURAL
# check, NOT a whole-file keyword grep: `! grep NEXUS_REMOTED` was a TAUTOLOGY because the keyword also
# lives in nearby COMMENTS, so an ungated `"nexus"` heredoc still passed (cross-check). Here a real GATE =
# the flag used in an `if`/`[`/`test` CONDITIONAL (not a comment); every quoted `"nexus"` config key must
# have such a gate within WINDOW lines above it (the enclosing if + the docgen block). A nearby explanatory
# comment mentioning the flag no longer satisfies it. WINDOW=50 (the real gate->nexus-key distance is ~21
# lines in setup.sh; 50 leaves generous margin for the docgen branch to grow without a false-FAIL, while a
# truly ungated heredoc has NO conditional above it at all - cross-check: the 30-line window was thin).
check_generator_gated() {
    local g="$1" kw="$2" out
    [ -f "$g" ] || return 0
    out="$(awk -v kw="$kw" -v win=50 '
        $0 ~ kw && $0 !~ /^[[:space:]]*#/ && $0 ~ /(if[ (]|\[ |test )/ { lastgate = NR }
        /"nexus"/ && $0 !~ /^[[:space:]]*#/ {
            if (lastgate == 0 || NR - lastgate > win) print NR
        }
    ' "$g" 2>/dev/null)"
    if [ -n "$out" ]; then
        bad_project "$g emits a \"nexus\" entry with no $kw conditional within 50 lines above (line(s): $(printf '%s' "$out" | tr '\n' ' '))"
    fi
}

echo "==> post-cutover assertion: no client stdio nexus"

# 1. Global agent configs (the host legitimately keeps stdio nexus here post-cutover; --host tolerates it).
scan_json "$HOME/.claude.json" global
scan_json "$HOME/.gemini/settings.json" global
scan_toml "$HOME/.codex/config.toml" global

# 2. Every project .mcp.json under the managed roots - NOT just ~/Documents (cross-check: managed roots
#    also live in ~/.dotfiles and ~/Downloads). Scan $HOME with the heavy/irrelevant dirs pruned.
while IFS= read -r f; do
    scan_json "$f" project
done < <(find "$HOME" \
            \( -path '*/node_modules' -o -path '*/.venv' -o -path '*/.git' -o -path "$HOME/Library" \
               -o -path '*/.Trash' -o -path '*/Caches' -o -path '*/.cache' -o -path '*/.npm' \
               -o -path '*/.claude/plugins' -o -path '*/.codex/.tmp' -o -path '*/.codex/plugins' \) -prune \
            -o -name '.mcp.json' -type f -print 2>/dev/null)

# 3. The setup generators must GATE any emitted stdio nexus behind the cutover flag (structural check).
DF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_generator_gated "$DF/setup.sh"  NEXUS_REMOTED
check_generator_gated "$DF/setup.ps1" NexusRemoted

total=$((global_findings + project_findings))
if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}OK${NC} - no stdio nexus found; every surface reaches nexus over the tunnel."
    exit 0
fi
if [ "$ALLOW_HOST_STDIO" = "1" ]; then
    # Host: a GLOBAL stdio nexus is role-allowed; a PROJECT/generator stdio nexus is NOT.
    if [ "$project_findings" -eq 0 ]; then
        note "ran with --host: $global_findings global host-stdio nexus entr(y/ies) allowed (this box is the MCP host)."
        echo -e "${GREEN}OK (host)${NC} - no PROJECT/generator stdio nexus survives; the global host-stdio is role-allowed."
        exit 0
    fi
    echo -e "${RED}FAIL (host)${NC} - $project_findings project/generator stdio nexus surface(s) survive."
    echo -e "  (A global host-stdio nexus is allowed on --host, but project .mcp.json + the generators must drop nexus.)"
    exit 1
fi
echo -e "${RED}FAIL${NC} - $total stdio nexus surface(s) survive ($global_findings global, $project_findings project/generator)."
echo -e "  Re-run 'setup.sh --full --client' on this box (NOT just 'sync')."
exit 1
