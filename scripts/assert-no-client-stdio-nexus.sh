#!/usr/bin/env bash
# assert-no-client-stdio-nexus.sh  --  Phase-D post-cutover assertion (the runbook's step-7 enforcer).
#
# After the hub cutover, NO client surface may keep a LOCAL STDIO entry for a REMOTED hub
# (nexus, courier, calendar): every client reaches them over the http+bearer tunnel. A surviving stdio
# entry = a client silently reading its own stale local state (nexus.db / notmuch index / calendar token)
# instead of the host-authoritative one (split-brain). docgen is NOT remoted (a local doc generator with
# no shared state), so a docgen stdio entry is fine everywhere and is never flagged. This scans every
# client surface and FAILS (exit 1) on any stdio remoted-hub entry. Run it on EACH client (and the host)
# AFTER the cutover. (The legacy filename says "nexus"; the check now covers all three remoted hubs.)
#
# Scoped to LIVE configs (which are machine-local, never in CI) - so this is a host/client-side gate,
# like hub-host-bootstrap's self-test, not a CI job. PRE-cutover it is EXPECTED to find stdio nexus
# (that is correct then); it must come back CLEAN only once NEXUS_REMOTED=true and clients are re-set-up.
# Surfaces scanned: the GLOBAL agent configs (~/.claude.json, ~/.gemini/settings.json, ~/.codex/config.toml)
# AND every PROJECT-local agent config under the managed roots - project `.mcp.json` (claude),
# `<ws>/.codex/config.toml` (codex), `<ws>/.gemini/settings.json` (gemini). Under WSL it also scans the
# native-Windows tree (/mnt/c/Users/*/Documents), so the WSL-side run vets the Windows surface too
# (there is no separate ps1 enforcer - this bash gate is the Linux/macOS/WSL-side check, INV-10 precedent).
#
# A hub entry is STDIO if it has a `command`/`args` (e.g. node .../server.js); it is OK if it is http
# (a `url`/`type=http`/`--transport http`). Findings are CLASSIFIED: the HOST stays `is_mcp_host`, so it
# legitimately keeps a GLOBAL stdio entry (~/.claude.json / ~/.codex / ~/.gemini) post-cutover - pass
# --host to tolerate THAT. But a PROJECT `.mcp.json`/`.codex`/`.gemini` stdio hub, or an ungated generator,
# is forbidden EVERYWHERE (the host's projects must use the global http client too). So --host allows GLOBAL
# findings only, never project/generator ones.
set -uo pipefail

ALLOW_HOST_STDIO=0
[ "${1:-}" = "--host" ] && ALLOW_HOST_STDIO=1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
# Two classes: GLOBAL agent-config stdio (host-allowed) vs PROJECT/generator stdio (forbidden everywhere).
global_findings=0
project_findings=0
note() { echo -e "  ${YELLOW}!${NC} $*"; }
bad_global()  { echo -e "  ${RED}\xe2\x9c\x97 STDIO hub (global):${NC} $*";            global_findings=$((global_findings+1)); }
bad_project() { echo -e "  ${RED}\xe2\x9c\x97 STDIO hub (project/generator):${NC} $*"; project_findings=$((project_findings+1)); }

have_jq() { command -v jq >/dev/null 2>&1; }

# The REMOTED hubs: a STDIO entry for any of these on a client = split-brain (stale local state).
# docgen is intentionally local stdio everywhere (not remoted, no shared state) so it is NOT listed.
REMOTED_HUBS="nexus courier calendar"

# scan_json <file> <global|project>: a remoted-hub entry with a "command" key (mcpServers OR project-scoped
# projects.*.mcpServers) is stdio. Loops over every remoted hub. Covers claude .mcp.json/.claude.json AND
# gemini settings.json (both key MCP servers under .mcpServers).
scan_json() {
    local f="$1" category="$2"
    [ -f "$f" ] || return 0
    # jq missing = we cannot verify; treat as a blocking (project) finding in BOTH modes, not a pass.
    have_jq || { note "jq not found - cannot vet $f"; bad_project "$f (jq missing - cannot verify; install jq)"; return; }
    # MALFORMED JSON = we cannot verify either, so it must NOT pass silently. The jq queries below 2>/dev/null
    # a parse error to an empty string (-> no finding under set -uo); flag it as blocking instead (cross-check:
    # a broken config is exactly where a stale stdio hub could hide, and an unverifiable config is not "clean").
    jq -e . "$f" >/dev/null 2>&1 || { bad_project "$f (not valid JSON - cannot verify; fix the config)"; return; }
    # Classify by JSON LOCATION, not just the caller arg: a top-level .mcpServers.<hub> gets the caller's
    # category (a global agent config is host-allowed; a standalone project .mcp.json is not), but a hub
    # nested under .projects.*.mcpServers is a PROJECT-scoped stdio entry that is forbidden EVERYWHERE -
    # so it must count as project even inside ~/.claude.json (cross-check: it was mis-tolerated as global).
    local hub top proj
    for hub in $REMOTED_HUBS; do
        top="$(jq -r --arg h "$hub" '[ (.mcpServers // {}) ] | map(select(.[$h].command != null)) | length' "$f" 2>/dev/null)"
        if [ "${top:-0}" != "0" ] && [ -n "$top" ]; then
            if [ "$category" = "global" ]; then bad_global "$f (mcpServers.$hub has a command/stdio)";
            else bad_project "$f (mcpServers.$hub has a command/stdio)"; fi
        fi
        proj="$(jq -r --arg h "$hub" '[ (.projects // {}) | to_entries[].value.mcpServers // {} ] | map(select(.[$h].command != null)) | length' "$f" 2>/dev/null)"
        if [ "${proj:-0}" != "0" ] && [ -n "$proj" ]; then
            bad_project "$f (projects.*.mcpServers.$hub is stdio - forbidden on every box)"
        fi
    done
}

# codex config.toml stdio hub. Covers the form register_hub_mcp / `codex mcp add` actually WRITE (the
# `[mcp_servers.<hub>]` SECTION, optionally indented) PLUS the common hand-edit forms - an inline table
# `<hub> = {...}` or `mcp_servers.<hub> = {...}` (single OR multi-line) and the dotted leaf
# `mcp_servers.<hub>.command = ...` - each carrying a `command` (a stdio spawn), ignoring a trailing `#`
# comment. A `command` is flagged REGARDLESS of any `url` also present: the invariant is "no stdio hub",
# and a command can still spawn the process even in a malformed command+url entry (cross-check). It does NOT
# claim to parse EVERY possible TOML expression of the key (only a real TOML lib would); the GENERATED
# surface - its actual job - is fully covered, and the most dangerous hand-edit form
# (`mcp_servers.<hub> = {command}`) self-announces as a duplicate-key TOML parse error once
# register_all_hub_mcp re-adds the section, so codex fails LOUDLY rather than running split-brain (cross-check).
# Loops over every remoted hub (the awk patterns are parameterized by the hub name).
scan_toml() {
    local f="$1" category="$2"
    [ -f "$f" ] || return 0
    local hub hit
    for hub in $REMOTED_HUBS; do
        hit="$(awk -v hub="$hub" '
            function nc(s){ sub(/#.*/, "", s); return s }   # drop a trailing TOML comment for the field checks
            # [mcp_servers.<hub>] SECTION (leading indent allowed): a command anywhere before the next [section]/EOF
            $0 ~ ("^[[:space:]]*\\[mcp_servers\\." hub "\\]") {insec=1; cmd=0; next}
            /^[[:space:]]*\[/ {if(insec && cmd){print "hit"}; insec=0}
            insec { l=nc($0); if(l ~ /^[[:space:]]*command[[:space:]]*=/) cmd=1 }
            # inline table <hub> = { ... } OR dotted-key inline mcp_servers.<hub> = { ... }: open until }, any command
            $0 ~ ("^[[:space:]]*(mcp_servers\\.)?" hub "[[:space:]]*=[[:space:]]*\\{") {
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
            # dotted-key LEAF form: mcp_servers.<hub>.command = ... (no section, no inline {)
            $0 ~ ("^[[:space:]]*mcp_servers\\." hub "\\.command[[:space:]]*=") {dotcmd=1}
            END {
                if(insec && cmd) print "hit"
                if(dotcmd) print "hit"
            }
        ' "$f" 2>/dev/null)"
        if printf '%s' "$hit" | grep -q hit; then
            if [ "$category" = "global" ]; then bad_global "$f ([mcp_servers.$hub] is stdio: command, no url)";
            else bad_project "$f ([mcp_servers.$hub] is stdio: command, no url)"; fi
        fi
    done
}

# A generator (setup.sh/setup.ps1) must GATE any emitted stdio nexus behind the cutover flag. STRUCTURAL
# check, NOT a whole-file keyword grep: `! grep NEXUS_REMOTED` was a TAUTOLOGY because the keyword also
# lives in nearby COMMENTS, so an ungated `"nexus"` heredoc still passed (cross-check). Here a real GATE =
# the flag used in an `if`/`[`/`test` CONDITIONAL (not a comment); every quoted `"nexus"` config key must
# have such a gate within WINDOW lines above it (the enclosing if + the docgen block). A nearby explanatory
# comment mentioning the flag no longer satisfies it. WINDOW=50 (the real gate->nexus-key distance is ~21
# lines in setup.sh; 50 leaves generous margin for the docgen branch to grow without a false-FAIL, while a
# truly ungated heredoc has NO conditional above it at all - cross-check: the 30-line window was thin).
# (Scoped to nexus: it was the last hub remoted, the only one whose generator path emits a raw heredoc;
# courier/calendar are wired only through the shared manifest fns, never a project-config heredoc.)
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

echo "==> post-cutover assertion: no client stdio hub (nexus/courier/calendar)"

# 1. Global agent configs (the host legitimately keeps stdio here post-cutover; --host tolerates it).
scan_json "$HOME/.claude.json" global
scan_json "$HOME/.gemini/settings.json" global
scan_toml "$HOME/.codex/config.toml" global

# 2. Every PROJECT-local agent config under the managed roots - project `.mcp.json` (claude),
#    `<ws>/.codex/config.toml` (codex), `<ws>/.gemini/settings.json` (gemini). NOT just ~/Documents
#    (cross-check: managed roots also live in ~/.dotfiles and ~/Downloads). Scan $HOME with the
#    heavy/irrelevant dirs pruned, AND the GLOBAL ~/.codex + ~/.gemini pruned (already scanned as global
#    in step 1). Under WSL also scan the native-Windows tree so the WSL run vets that surface too.
SCAN_ROOTS="$HOME"
if [ -d /mnt/c/Users ]; then
    for d in /mnt/c/Users/*/Documents; do [ -d "$d" ] && SCAN_ROOTS="$SCAN_ROOTS $d"; done
fi
while IFS= read -r f; do
    case "$f" in
        *.toml) scan_toml "$f" project ;;   # <ws>/.codex/config.toml
        *)      scan_json "$f" project ;;   # .mcp.json and <ws>/.gemini/settings.json
    esac
done < <(find $SCAN_ROOTS \
            \( -path '*/node_modules' -o -path '*/.venv' -o -path '*/.git' -o -path "$HOME/Library" \
               -o -path '*/.Trash' -o -path '*/Caches' -o -path '*/.cache' -o -path '*/.npm' \
               -o -path '*/.claude/plugins' -o -path '*/.codex/.tmp' -o -path '*/.codex/plugins' \
               -o -path "$HOME/.codex" -o -path "$HOME/.gemini" \) -prune \
            -o \( -name '.mcp.json' -o -path '*/.codex/config.toml' -o -path '*/.gemini/settings.json' \) \
               -type f -print 2>/dev/null)

# 3. The setup generators must GATE any emitted stdio nexus behind the cutover flag (structural check).
DF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_generator_gated "$DF/setup.sh"  NEXUS_REMOTED
check_generator_gated "$DF/setup.ps1" NexusRemoted

total=$((global_findings + project_findings))
if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}OK${NC} - no stdio hub found; every surface reaches nexus/courier/calendar over the tunnel."
    exit 0
fi
if [ "$ALLOW_HOST_STDIO" = "1" ]; then
    # Host: a GLOBAL stdio hub is role-allowed; a PROJECT/generator stdio hub is NOT.
    if [ "$project_findings" -eq 0 ]; then
        note "ran with --host: $global_findings global host-stdio hub entr(y/ies) allowed (this box is the MCP host)."
        echo -e "${GREEN}OK (host)${NC} - no PROJECT/generator stdio hub survives; the global host-stdio is role-allowed."
        exit 0
    fi
    echo -e "${RED}FAIL (host)${NC} - $project_findings project/generator stdio hub surface(s) survive."
    echo -e "  (A global host-stdio hub is allowed on --host, but project configs + the generators must drop nexus/courier/calendar.)"
    exit 1
fi
echo -e "${RED}FAIL${NC} - $total stdio hub surface(s) survive ($global_findings global, $project_findings project/generator)."
echo -e "  Re-run 'setup.sh --full --client' on this box (NOT just 'sync')."
exit 1
