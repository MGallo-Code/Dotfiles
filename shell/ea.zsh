# EA-specific shell commands

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
    cd "$dir" && "$cli" "$@"
}

ea()   { _ws_launch ~/Documents/EA "$@"; }        # active personal ops + MCP tools
wiki() { _ws_launch ~/Documents/Wiki "$@"; }      # LLM-curated research
it()   { _ws_launch ~/Documents/IT-Worker "$@"; } # legacy archive (deprecated write target)

# Update the Michael Workspace SYSTEM: open an agent in the dotfiles control plane (manifest.sh
# is the map of every managed root + its role). For Claude (default) we add the EA + agent-skills
# source roots it distributes; Codex/Gemini already see the whole workspace via the
# michael_workspace profile. Same --claude/--codex/--gemini flag.
sysupdate() {
    cd ~/.dotfiles || return
    case "${1:-}" in
        --codex)  shift; codex "$@" ;;
        --gemini) shift; gemini "$@" ;;
        --claude) shift; claude --add-dir ~/Documents/EA --add-dir ~/Documents/agent-skills "$@" ;;
        *)               claude --add-dir ~/Documents/EA --add-dir ~/Documents/agent-skills "$@" ;;
    esac
}

# Tab-complete the agent flags for the workspace launchers.
_ws_agent_completion() { compadd -- --claude --codex --gemini; }
compdef _ws_agent_completion ea wiki it sysupdate

# courier remote (ADR-0002): expose the bearer token to MCP clients. claude/gemini
# reference it as ${COURIER_BEARER} in their courier http header; codex reads it via
# --bearer-token-env-var. Sourced from the one mode-600 file (never on a command line).
# On the mail host this is harmless/redundant (host courier is stdio, no token).
# NOTE: this path must track manifest.sh COURIER_TOKEN_FILE (ea.zsh can't source the
# manifest array cleanly; keep them in sync if the token location ever moves).
[ -r "$HOME/.config/courier/auth-token" ] && export COURIER_BEARER="$(< "$HOME/.config/courier/auth-token")"

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
