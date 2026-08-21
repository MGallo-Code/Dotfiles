# EA-specific shell commands

# ── Agent runner ─────────────────────────────────────────────────────
# Named Michael Workspace launchers are the trust boundary. Direct calls to this internal
# helper fail closed, and permission-policy overrides use the raw agent CLIs instead.
typeset -g _MICHAEL_WORKSPACE_DOTFILES="${${(%):-%N}:A:h:h}"
typeset -g _MICHAEL_WORKSPACE_DIAGNOSTIC="$_MICHAEL_WORKSPACE_DOTFILES/scripts/workspace-access-diagnostics.py"

_ws_is_trusted_root() {
    case "$1" in
        "$HOME/.dotfiles"|"$HOME/Documents/EA"|"$HOME/Documents/Wiki"|"$HOME/Documents/SBIC") return 0 ;;
        *) return 1 ;;
    esac
}

_ws_trusted_root_is_redirected() {
    local dir="$1"
    [[ -L "$HOME" ]] && return 0
    case "$dir" in
        "$HOME/.dotfiles") [[ -L "$dir" ]] ;;
        "$HOME/Documents/"*) [[ -L "$HOME/Documents" || -L "$dir" ]] ;;
        *) return 0 ;;
    esac
}

_ws_is_safe_trusted_root() {
    _ws_is_trusted_root "$1" && ! _ws_trusted_root_is_redirected "$1"
}

_ws_policy_override_present() {
    local cli="$1"; shift
    local arg
    for arg in "$@"; do
        case "$cli:$arg" in
            claude:--permission-mode|claude:--permission-mode=*|claude:--dangerously-skip-permissions|claude:--safe-mode) return 0 ;;
            codex:--sandbox|codex:--sandbox=*|codex:-s|codex:-s?*|codex:--ask-for-approval|codex:--ask-for-approval=*|codex:-a|codex:-a?*|codex:--dangerously-bypass-approvals-and-sandbox) return 0 ;;
        esac
    done
    return 1
}

_ws_scope_override_present() {
    local cli="$1"; shift
    local arg
    for arg in "$@"; do
        case "$cli:$arg" in
            codex:-C|codex:-C?*|codex:--cd|codex:--cd=*|codex:--add-dir|codex:--add-dir=*|\
            codex:-c|codex:-c?*|codex:--config|codex:--config=*|codex:-p|codex:-p?*|codex:--profile|codex:--profile=*|\
            codex:--remote|codex:--remote=*) return 0 ;;
        esac
    done
    return 1
}

_agent_run() {
    local cli="$1"; shift
    if [[ "${MICHAEL_WORKSPACE_TRUSTED_LAUNCH:-0}" != 1 ]] ||
       [[ -z "${MICHAEL_WORKSPACE_TRUSTED_ROOT:-}" ]] ||
       ! _ws_is_safe_trusted_root "$MICHAEL_WORKSPACE_TRUSTED_ROOT" ||
       [[ "$PWD" != "$MICHAEL_WORKSPACE_TRUSTED_ROOT" ]]; then
        print -u2 -- "workspace launcher: refusing autonomous $cli outside a named trusted root"
        return 64
    fi
    if _ws_policy_override_present "$cli" "$@"; then
        print -u2 -- "workspace launcher: permission-policy overrides are not accepted; invoke $cli directly"
        return 64
    fi
    if _ws_scope_override_present "$cli" "$@"; then
        print -u2 -- "workspace launcher: cwd, writable-root, profile, config, and remote overrides require raw $cli"
        return 64
    fi
    case "$cli" in
        claude) claude --permission-mode bypassPermissions "$@" ;;
        codex)  codex --sandbox danger-full-access --ask-for-approval never "$@" ;;
        gemini) gemini --yolo "$@" ;;
        *)      print -u2 -- "workspace launcher: unsupported agent: $cli"; return 64 ;;
    esac
}

_ws_requested_policy() {
    case "$1" in
        claude) print -r -- "bypassPermissions" ;;
        codex)  print -r -- "sandbox=danger-full-access,approval=never" ;;
        gemini) print -r -- "yolo" ;;
        *)      print -r -- "unverified" ;;
    esac
}

_ws_probe() {
    local dir="$1"
    local mode="${2:-full}"
    command python3 "$_MICHAEL_WORKSPACE_DIAGNOSTIC" probe \
        --path "$dir" --mode "$mode" --timeout 3 >/dev/null 2>&1
}

_ws_capture() {
    local dir="$1" phase="$2" cli="$3" policy="$4" agent_status="${5:-}" symptom="${6:-filesystem}"
    local -a args
    args=(capture --path "$dir" --home "$HOME" --phase "$phase" --agent "$cli"
          --requested-policy "$policy" --symptom "$symptom" --timeout 3)
    [[ -n "${HISTFILE:-}" ]] && args+=(--history-file "$HISTFILE")
    [[ -n "$agent_status" ]] && args+=(--agent-status "$agent_status")
    command python3 "$_MICHAEL_WORKSPACE_DIAGNOSTIC" "${args[@]}"
}

_ws_recover_home() {
    if builtin cd -q -- "$HOME" 2>/dev/null; then
        print -u2 -- "workspace launcher: access failed; recovered the parent shell to HOME"
        return 0
    fi
    print -u2 -- "workspace launcher: access failed and HOME is inaccessible; open a fresh shell and run wsdoctor"
    return 1
}

# ── Workspace launchers ──────────────────────────────────────────────
# cd into a workspace root and open an agent. An optional FIRST flag picks the CLI:
#   --claude (default) | --codex | --gemini ; any remaining args pass through.
#   e.g.  ea            -> Claude in ~/Documents/EA
#         wiki --codex  -> Codex in ~/Documents/Wiki
_ws_launch() {
    local dir="$1"; shift
    local cli="claude"
    case "${1:-}" in
        --claude) cli="claude"; shift ;;
        --codex)  cli="codex";  shift ;;
        --gemini) cli="gemini"; shift ;;
    esac
    if ! _ws_is_safe_trusted_root "$dir"; then
        print -u2 -- "workspace launcher: refusing unnamed or redirected root: $dir"
        return 64
    fi
    if ! _ws_probe "$dir" full; then
        _ws_capture "$dir" preflight "$cli" "$(_ws_requested_policy "$cli")" || true
        _ws_recover_home || true
        return 74
    fi

    # TRUSTED_WORKSPACE_SUBSHELL: the agent's cd can never strand the parent shell in this root.
    (
        builtin cd -q -- "$dir" || exit 74
        export MICHAEL_WORKSPACE_TRUSTED_LAUNCH=1
        export MICHAEL_WORKSPACE_TRUSTED_ROOT="$dir"
        _agent_run "$cli" "$@"
    )
    local agent_status=$?
    local policy="$(_ws_requested_policy "$cli")"

    if ! _ws_probe "$dir" full; then
        _ws_capture "$dir" exit "$cli" "$policy" "$agent_status" || true
        _ws_recover_home || true
        return 74
    fi
    if _ws_is_safe_trusted_root "$PWD" && ! _ws_probe "$PWD" enumerate; then
        _ws_capture "$PWD" exit "$cli" "$policy" "$agent_status" || true
        _ws_recover_home || true
        return 74
    fi
    return "$agent_status"
}

ea()   { _ws_launch ~/Documents/EA "$@"; }        # active personal ops + MCP tools
wiki() { _ws_launch ~/Documents/Wiki "$@"; }      # LLM-curated research
sbic() { _ws_launch ~/Documents/SBIC "$@"; }      # employer-only work (SBIC)

# Update the Michael Workspace SYSTEM: open an agent in the dotfiles control plane (manifest.sh
# is the map of every managed root + its role). For Claude (default) we add the EA + agent-skills
# source roots it distributes; Codex/Gemini already see the whole workspace via the
# michael_workspace profile. Same --claude/--codex/--gemini flag.
sysupdate() {
    case "${1:-}" in
        --codex)  shift; _ws_launch "$HOME/.dotfiles" --codex "$@" ;;
        --gemini) shift; _ws_launch "$HOME/.dotfiles" --gemini "$@" ;;
        --claude) shift; _ws_launch "$HOME/.dotfiles" --claude --add-dir "$HOME/Documents/EA" --add-dir "$HOME/Documents/agent-skills" "$@" ;;
        *)               _ws_launch "$HOME/.dotfiles" --claude --add-dir "$HOME/Documents/EA" --add-dir "$HOME/Documents/agent-skills" "$@" ;;
    esac
}

# Catch a cwd that becomes inaccessible outside an agent launch. The bounded enumerate probe only
# runs only at named root directories; healthy prompts stay silent. A failing prompt is captured
# before recovery. Descendants are excluded so this maintenance hook never enters project trees.
_workspace_prompt_access_guard() {
    [[ "${_MICHAEL_WORKSPACE_PROMPT_GUARD_ACTIVE:-0}" == 1 ]] && return 0
    case "$PWD" in
        "$HOME/.dotfiles"|"$HOME/Documents/EA"|"$HOME/Documents/Wiki"|"$HOME/Documents/SBIC") ;;
        *) return 0 ;;
    esac
    typeset -g _MICHAEL_WORKSPACE_PROMPT_GUARD_ACTIVE=1
    if ! _ws_probe "$PWD" enumerate; then
        _ws_capture "$PWD" prompt shell unverified || true
        _ws_recover_home || true
    fi
    typeset -g _MICHAEL_WORKSPACE_PROMPT_GUARD_ACTIVE=0
}

autoload -Uz add-zsh-hook
if (( ${precmd_functions[(Ie)_workspace_prompt_access_guard]:-0} == 0 )); then
    add-zsh-hook precmd _workspace_prompt_access_guard
fi

wsdoctor() {
    case "${1:-latest}" in
        latest) command python3 "$_MICHAEL_WORKSPACE_DIAGNOSTIC" latest --home "$HOME" ;;
        agent-read-only)
            _ws_capture "$PWD" manual shell unverified "" agent-read-only
            ;;
        shell-message)
            _ws_capture "$PWD" manual shell unverified "" shell-message
            ;;
        *) print -u2 -- "usage: wsdoctor [latest|agent-read-only|shell-message]"; return 2 ;;
    esac
}

# Tab-complete the agent flags for the workspace launchers.
_ws_agent_completion() { compadd -- --claude --codex --gemini; }
compdef _ws_agent_completion ea wiki sbic sysupdate

# Hub remotes (ADR-0002 / remote-hubs): expose each per-hub bearer token to MCP clients. claude/gemini
# reference it as ${<HUB>_BEARER} in their http header; codex reads it via --bearer-token-env-var.
# Sourced from the one mode-600 file per hub (never on a command line). On the MCP host these are
# harmless/redundant (host hubs are stdio, no token). NOTE: these paths must track manifest.sh
# COURIER_TOKEN_FILE / CALENDAR_TOKEN_FILE / NEXUS_TOKEN_FILE (ea.zsh can't source the manifest
# cleanly; keep in sync if a token location ever moves). The NEXUS line is intentionally NOT gated on
# NEXUS_REMOTED (unlike the bash side's ~/.bashrc export): it is INERT pre-cutover because no box has
# ~/.config/nexus/auth-token until the cutover provisions it, so the export simply no-ops - the zsh
# runtime env stays identical to today without a flag check (cross-check: the asymmetry is harmless).
[ -r "$HOME/.config/courier/auth-token" ]  && export COURIER_BEARER="$(< "$HOME/.config/courier/auth-token")"
[ -r "$HOME/.config/calendar/auth-token" ] && export CALENDAR_BEARER="$(< "$HOME/.config/calendar/auth-token")"
[ -r "$HOME/.config/nexus/auth-token" ]    && export NEXUS_BEARER="$(< "$HOME/.config/nexus/auth-token")"

# Drop into practice workspace with venv active
practice() {
    mkdir -p ~/Documents/EA/exercises/workspace
    if [ ! -d ~/Documents/EA/exercises/.venv ]; then
        echo "Setting up practice environment..."
        python3 -m venv ~/Documents/EA/exercises/.venv
        ~/Documents/EA/exercises/.venv/bin/pip install pytest
        echo "Done!"
    fi
    source ~/Documents/EA/exercises/.venv/bin/activate
    cd ~/Documents/EA/exercises/workspace
    nvim .
}
