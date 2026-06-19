# EA-specific shell commands

# Navigate to EA and open Claude
ea() {
    cd ~/Documents/EA && claude
}

# Navigate to Wiki and open Claude
wiki() {
    cd ~/Documents/Wiki && claude
}

# Navigate to IT Worker and open Claude
it() {
    cd ~/Documents/IT-Worker && claude
}

# Update the Michael Workspace SYSTEM: launch Claude in the dotfiles control plane (manifest.sh
# is the map of every managed root + its role) with the source roots it distributes (EA =
# rules/commands/skills/MCP) and the skills kit added. Pass-through args go to claude. Codex and
# Gemini already see the whole workspace via the michael_workspace profile, so for those just
# `cd ~/.dotfiles && codex` (or gemini).
sysupdate() {
    cd ~/.dotfiles && claude --add-dir ~/Documents/EA --add-dir ~/Documents/agent-skills "$@"
}

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
