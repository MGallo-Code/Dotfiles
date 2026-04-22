#!/usr/bin/env bash
set -euo pipefail

# Cross-platform dev environment setup (macOS)
# Usage: setup.sh [--full|--dev|--minimal]

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:---full}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[ok]${NC} $1"; }
warn() { echo -e "${YELLOW}[skip]${NC} $1"; }
err()  { echo -e "${RED}[error]${NC} $1"; }
step() { echo -e "\n${GREEN}==>${NC} $1"; }

# Platform check
if [[ "$(uname)" != "Darwin" ]]; then
    err "This script is for macOS. Use setup.ps1 for Windows."
    exit 1
fi

source "$DOTFILES_DIR/manifest.sh"

# Expand ~ in a path
expand() { echo "${1/#\~/$HOME}"; }

# ── Git Config ────────────────────────────────────────────────────────
step "Git config"

CURRENT_NAME=$(git config --global user.name 2>/dev/null || echo "")
CURRENT_EMAIL=$(git config --global user.email 2>/dev/null || echo "")

if [ -n "$CURRENT_NAME" ] && [ -n "$CURRENT_EMAIL" ]; then
    ok "Git user: $CURRENT_NAME <$CURRENT_EMAIL>"
else
    if [ -z "$CURRENT_NAME" ]; then
        echo "Enter your Git name (e.g. Michael Gallo):"
        read -r GIT_NAME
        git config --global user.name "$GIT_NAME"
    fi
    if [ -z "$CURRENT_EMAIL" ]; then
        echo "Enter your Git email:"
        read -r GIT_EMAIL
        git config --global user.email "$GIT_EMAIL"
    fi
    ok "Git config set"
fi

# ── SSH Key ──────────────────────────────────────────────────────────
step "SSH key setup"

if [ -f ~/.ssh/id_ed25519 ]; then
    ok "SSH key already exists"
else
    echo "Generating SSH key..."
    mkdir -p ~/.ssh
    ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f ~/.ssh/id_ed25519 -N ""

    # Copy to clipboard and open GitHub
    cat ~/.ssh/id_ed25519.pub | pbcopy
    ok "Public key copied to clipboard"

    open "https://github.com/settings/ssh/new"
    echo ""
    echo "Paste your key on GitHub, then press Enter to continue..."
    read -r
fi

# SSH config - create if missing, or ensure github alias exists
if [ ! -f ~/.ssh/config ]; then
    cp "$DOTFILES_DIR/ssh/config.template" ~/.ssh/config
    chmod 600 ~/.ssh/config
    ok "SSH config created from template (edit IPs in ~/.ssh/config)"
else
    if grep -q "^Host github$" ~/.ssh/config 2>/dev/null; then
        ok "SSH config has github alias"
    else
        cat >> ~/.ssh/config << 'EOF'

# Dotfiles setup
Host github
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
EOF
        chmod 600 ~/.ssh/config
        ok "Added github alias to existing SSH config"
    fi
fi

# Test GitHub SSH access
step "Testing GitHub SSH access"
if ssh -T git@github 2>&1 | grep -q "successfully authenticated"; then
    ok "GitHub SSH access works"

    # Switch dotfiles remote from HTTPS to SSH if needed
    CURRENT_REMOTE=$(git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null || echo "")
    if [[ "$CURRENT_REMOTE" == https://* ]]; then
        git -C "$DOTFILES_DIR" remote set-url origin git@github:MGallo-Code/Dotfiles.git
        ok "Switched dotfiles remote to SSH"
    fi
else
    warn "GitHub SSH test inconclusive - clone steps may fail"
fi

# ── Homebrew Packages ────────────────────────────────────────────────
if [[ "$MODE" != "--minimal" ]]; then
    step "Homebrew packages"

    if ! command -v brew &>/dev/null; then
        warn "Homebrew not installed. Install it first: https://brew.sh"
    else
        echo "Install packages from Brewfile? (y/n)"
        read -r INSTALL_BREW
        if [[ "$INSTALL_BREW" == "y" ]]; then
            brew bundle --file="$DOTFILES_DIR/packages/Brewfile"
            ok "Packages installed"
        else
            warn "Skipped Homebrew packages"
        fi
    fi
fi

# ── Directories ──────────────────────────────────────────────────────
step "Creating directories"

for dir in "${DIRECTORIES[@]}"; do
    dir_expanded="$(expand "$dir")"
    if [ -d "$dir_expanded" ]; then
        ok "$dir already exists"
    else
        mkdir -p "$dir_expanded"
        ok "Created $dir"
    fi
done

# ── Clone Repos ──────────────────────────────────────────────────────
if [[ "$MODE" != "--minimal" ]]; then
    step "Cloning repos"

    for entry in "${REPOS[@]}"; do
        remote="${entry%%|*}"
        target="$(expand "${entry##*|}")"

        # Skip EA-only repos if --dev
        if [[ "$MODE" == "--dev" ]]; then
            is_ea=false
            for ea_entry in "${EA_REPOS[@]}"; do
                if [[ "$ea_entry" == "$entry" ]]; then
                    is_ea=true
                    break
                fi
            done
            if $is_ea; then
                warn "Skipping $remote (--dev mode)"
                continue
            fi
        fi

        if [ -d "$target/.git" ]; then
            ok "$target already cloned"
        elif [ -d "$target" ]; then
            warn "$target exists but is not a git repo - skipping"
        else
            mkdir -p "$(dirname "$target")"
            git clone "$remote" "$target"
            ok "Cloned to $target"
        fi
    done
fi

# ── Nexus MCP Server ────────────────────────────────────────────────
if [[ "$MODE" == "--full" ]]; then
    step "Setting up Nexus MCP server"
    NEXUS_PATH="$(expand "~/Documents/EA/nexus")"
    if [ -f "$NEXUS_PATH/package.json" ]; then
        cd "$NEXUS_PATH"
        npm install --silent 2>/dev/null
        npm run build 2>/dev/null
        if [ -f "$NEXUS_PATH/migrate.js" ] && [ ! -f "$NEXUS_PATH/nexus.db" ]; then
            node migrate.js 2>/dev/null
            ok "Nexus: installed, built, and migrated"
        else
            ok "Nexus: installed and built"
        fi
        cd - >/dev/null
    else
        warn "Nexus: package.json not found at $NEXUS_PATH"
    fi
fi

# ── Symlinks ─────────────────────────────────────────────────────────
if [[ "$MODE" == "--full" ]]; then
    step "Creating symlinks"

    for entry in "${SYMLINKS[@]}"; do
        source_path="$(expand "${entry%%|*}")"
        target_path="$(expand "${entry##*|}")"

        if [ -L "$target_path" ] && [ "$(readlink "$target_path")" = "$source_path" ]; then
            ok "$target_path already linked correctly"
        elif [ -e "$target_path" ]; then
            warn "$target_path exists but is not the expected symlink - skipping"
        else
            mkdir -p "$(dirname "$target_path")"
            ln -s "$source_path" "$target_path"
            ok "Linked $target_path -> $source_path"
        fi
    done
fi

# ── Shell Commands ───────────────────────────────────────────────────
if [[ "$MODE" != "--minimal" ]]; then
    step "Shell commands"

    CUSTOM_DIR="$HOME/.custom_zshrc"
    mkdir -p "$CUSTOM_DIR"

    # Symlink core commands
    if [ -L "$CUSTOM_DIR/core.zsh" ] && [ "$(readlink "$CUSTOM_DIR/core.zsh")" = "$DOTFILES_DIR/$SHELL_CORE" ]; then
        ok "core.zsh already linked"
    else
        ln -sf "$DOTFILES_DIR/$SHELL_CORE" "$CUSTOM_DIR/core.zsh"
        ok "Linked core.zsh"
    fi

    # Symlink EA commands if --full
    if [[ "$MODE" == "--full" ]]; then
        if [ -L "$CUSTOM_DIR/ea.zsh" ] && [ "$(readlink "$CUSTOM_DIR/ea.zsh")" = "$DOTFILES_DIR/$SHELL_EA" ]; then
            ok "ea.zsh already linked"
        else
            ln -sf "$DOTFILES_DIR/$SHELL_EA" "$CUSTOM_DIR/ea.zsh"
            ok "Linked ea.zsh"
        fi
    fi

    # Remove old custom_commands file if it's not a symlink (migrated to split files)
    if [ -f "$CUSTOM_DIR/custom_commands" ] && [ ! -L "$CUSTOM_DIR/custom_commands" ]; then
        warn "Old custom_commands file found - keeping as backup at custom_commands.bak"
        mv "$CUSTOM_DIR/custom_commands" "$CUSTOM_DIR/custom_commands.bak"
    fi

    # Ensure .zshrc sources the custom directory
    ZSHRC="$HOME/.zshrc"
    SOURCE_LINE='for f in ~/.custom_zshrc/*.zsh; do source "$f"; done'
    if [ -f "$ZSHRC" ] && grep -qF 'custom_zshrc' "$ZSHRC"; then
        ok ".zshrc already sources custom commands"
    else
        echo "" >> "$ZSHRC"
        echo "# Dotfiles custom commands" >> "$ZSHRC"
        echo "$SOURCE_LINE" >> "$ZSHRC"
        ok "Added source line to .zshrc"
    fi
fi

# ── Claude Code ──────────────────────────────────────────────────────
step "Claude Code"

if command -v claude &>/dev/null; then
    ok "Claude Code is installed"
    echo "    Run 'claude' to authenticate if needed"
else
    if command -v brew &>/dev/null; then
        echo "Installing Claude Code..."
        brew install claude
        ok "Claude Code installed. Run 'claude' to authenticate."
    else
        warn "Claude Code not found - install via: brew install claude"
    fi
fi

# ── Practice Environment ─────────────────────────────────────────────
if [[ "$MODE" == "--full" ]]; then
    step "Practice environment"

    EXERCISE_DIR="$(expand "~/Documents/EA/exercises")"
    VENV_DIR="$EXERCISE_DIR/.venv"
    WORKSPACE_DIR="$EXERCISE_DIR/workspace"

    if [ -d "$EXERCISE_DIR" ]; then
        mkdir -p "$WORKSPACE_DIR"

        if [ -d "$VENV_DIR" ]; then
            ok "Practice venv already exists"
        else
            if command -v python3 &>/dev/null; then
                echo "Setting up practice venv..."
                python3 -m venv "$VENV_DIR"
                "$VENV_DIR/bin/pip" install pytest
                ok "Practice environment ready"
            else
                warn "Python3 not found - install via brew, then run setup again for practice env"
            fi
        fi
    else
        warn "EA not cloned yet - practice environment skipped"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────
step "Setup complete!"
echo ""
echo "What's next:"
echo "  - Edit SSH config IPs: ~/.ssh/config"
echo "  - Authenticate Claude Code: claude"
echo "  - Restart your shell or run: source ~/.zshrc"
echo ""
