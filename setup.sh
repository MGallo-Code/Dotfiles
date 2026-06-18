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

ensure_agent_defaults() { # AGENT_DEFAULTS_CONFIG
    local codex_config="$HOME/.codex/config.toml"
    mkdir -p "$HOME/.codex"
    touch "$codex_config"

    set_codex_toml_key() {
        local key="$1"
        local value="$2"
        if grep -q "^${key} =" "$codex_config"; then
            perl -0pi -e "s/^${key} = \"[^\"]*\"/${key} = \"${value}\"/m" "$codex_config"
        else
            printf '%s = "%s"\n' "$key" "$value" >> "$codex_config"
        fi
    }

    set_codex_toml_key model_reasoning_effort xhigh
    set_codex_toml_key approval_policy on-request
    set_codex_toml_key approvals_reviewer auto_review
    ok "Codex: defaults set (xhigh reasoning + auto-review approvals)"

    # Stacked-push guard for Codex (PreToolUse), mirroring the Claude hook: the
    # SAME script + protocol (reads .tool_input.command, emits hookSpecificOutput
    # .permissionDecision "ask") so a stacked `git push` pauses for confirmation
    # and never auto-approves. Registration is machine-local in config.toml; the
    # script is the one the Claude guard already deploys to ~/.claude/hooks. Trust
    # it once via the Codex `/hooks` TUI. Idempotent via a marker comment.
    local codex_guard_marker="# dotfiles: flat-PR stacked-push guard"
    local codex_guard="$HOME/.claude/hooks/warn-stacked-git-push.sh"
    if ! grep -qF "$codex_guard_marker" "$codex_config"; then
        cat >> "$codex_config" <<EOF

$codex_guard_marker
[[hooks.PreToolUse]]
matcher = "^Bash\$"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = "$codex_guard"
  timeout = 30
EOF
        ok "Codex: wired stacked-push guard (run /hooks once to trust it)"
    else
        ok "Codex stacked-push guard already wired"
    fi

    local gemini_settings="$HOME/.gemini/settings.json"
    mkdir -p "$HOME/.gemini"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$gemini_settings" <<'PYJSON'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
except json.JSONDecodeError:
    data = {}
if not isinstance(data, dict):
    data = {}
general = data.setdefault("general", {})
if not isinstance(general, dict):
    general = {}
    data["general"] = general
general["defaultApprovalMode"] = "auto_edit"
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYJSON
        ok "Gemini: default approval mode set to auto_edit"
    else
        warn "Gemini defaults: python3 not found - skipping settings.json update"
    fi
}

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

# Generate a key only if GitHub SSH doesn't already work. The old guard checked
# the default path (~/.ssh/id_ed25519) and so regenerated on a machine that uses
# a differently-named key (e.g. ~/.ssh/id_ed25519_github), creating a stray
# unused key and pausing setup. Test the actual goal — can we auth to GitHub.
if ssh -T -o BatchMode=yes -o ConnectTimeout=5 git@github 2>&1 | grep -q 'successfully authenticated'; then
    ok "GitHub SSH already works (skipping key generation)"
elif [ -f ~/.ssh/id_ed25519 ]; then
    ok "SSH key already exists (add its public key to GitHub if you haven't)"
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

# ── Nvim-adjacent configs ───────────────────────────────────────────
NVIM_SETUP="$(expand "~/.config/nvim/setup.sh")"
if [ -x "$NVIM_SETUP" ]; then
    step "Nvim-adjacent configs"
    "$NVIM_SETUP"
fi

# ── MCP servers (nexus + courier + docgen + calendar) ─────────────
# nexus (TS) + docgen (Python; PDF/docx) are written into the project .mcp.json
# of the PRIVATE EA + IT-Worker repos AND wired globally for Claude/Codex/Gemini so they
# reach every project. courier (email) is wired GLOBALLY ONLY and is never written
# into any repo - email must not flow through checked-in/shared config (e.g. the
# SBIC repos Charles can see). MCP spawns via execvp, so ~ and $VARS in args are
# NOT expanded; we bake absolute paths in per machine.
if [[ "$MODE" == "--full" ]]; then
    step "Setting up MCP servers (nexus, courier, docgen, calendar)"
    EA_PATH="$(expand "~/Documents/EA")"
    ITW_PATH="$(expand "~/Documents/IT-Worker")"
    NEXUS_PATH="$EA_PATH/nexus"
    COURIER_PATH="$EA_PATH/courier"
    DOCGEN_PATH="$EA_PATH/docgen"
    CALENDAR_PATH="$EA_PATH/calendar"
    NEXUS_SERVER="$NEXUS_PATH/dist/server.js"
    COURIER_SRC="$COURIER_PATH/src"
    DOCGEN_SRC="$DOCGEN_PATH/src"
    CALENDAR_SRC="$CALENDAR_PATH/src"
    DOCGEN_BROWSERS="$DOCGEN_PATH/.playwright-browsers"

    # Build nexus (TypeScript)
    if [ -f "$NEXUS_PATH/package.json" ]; then
        cd "$NEXUS_PATH"
        npm install --silent 2>/dev/null
        npm run build 2>/dev/null
        ok "Nexus: installed and built"
        cd - >/dev/null
    else
        warn "Nexus: package.json not found at $NEXUS_PATH"
    fi

    # Sync Python deps for courier + docgen + calendar (uv)
    if command -v uv >/dev/null 2>&1; then
        [ -d "$COURIER_PATH" ] && (cd "$COURIER_PATH" && uv sync --quiet 2>/dev/null) && ok "Courier: deps synced"
        [ -d "$CALENDAR_PATH" ] && (cd "$CALENDAR_PATH" && uv sync --quiet 2>/dev/null) && ok "Calendar: deps synced"
        if [ -d "$DOCGEN_PATH" ]; then
            (cd "$DOCGEN_PATH" && uv sync --quiet 2>/dev/null) && ok "Docgen: deps synced"
            PLAYWRIGHT_BROWSERS_PATH="$DOCGEN_BROWSERS" \
                uv run --project "$DOCGEN_PATH" --no-sync playwright install chromium >/dev/null 2>&1 \
                && ok "Docgen: Chromium installed"
        fi
    else
        warn "uv not found - skipping courier/docgen/calendar dep sync"
    fi

    # Project-scope .mcp.json for the PRIVATE EA + IT-Worker repos (nexus + docgen;
    # NOT courier - see header note).
    if [ -f "$NEXUS_SERVER" ]; then
        MCP_JSON=$(cat <<EOF
{
  "mcpServers": {
    "nexus": {
      "command": "node",
      "args": ["$NEXUS_SERVER"]
    },
    "docgen": {
      "command": "uv",
      "args": ["run", "--project", "$DOCGEN_PATH", "--no-sync", "python", "-m", "docgen.server"],
      "env": {
        "PYTHONPATH": "$DOCGEN_SRC",
        "PLAYWRIGHT_BROWSERS_PATH": "$DOCGEN_BROWSERS"
      }
    }
  }
}
EOF
)
        echo "$MCP_JSON" > "$EA_PATH/.mcp.json"
        ok "EA .mcp.json generated (nexus + docgen)"
        if [ -d "$ITW_PATH" ]; then
            echo "$MCP_JSON" > "$ITW_PATH/.mcp.json"
            ok "IT-Worker .mcp.json generated (nexus + docgen)"
        fi
    fi

    # Global wiring: all four servers in EVERY project, for Claude, Codex, and
    # Gemini. Idempotent (remove-then-add); no-ops if the CLI is absent.
    # This is how courier/nexus/docgen/calendar reach SBIC/lab/etc WITHOUT being written
    # into those repos.
    # Courier is per-ROLE, not per-OS (ADR-0002). is_mail_host / register_courier_mcp /
    # provision_courier_client_token are defined in manifest.sh (sourced at the top) so
    # setup AND sync share ONE copy of the host-vs-client decision. is_mail_host keys on the
    # STABLE macOS LocalHostName (not `hostname`, which is "MacBookPro" here); the host
    # bootstrap below re-asserts it and fails loud rather than silently wiring a client.
    register_global_mcp() {
        local cli="$1"
        command -v "$cli" >/dev/null 2>&1 || { warn "$cli not found - skipping its global MCP wiring"; return; }
        local name
        case "$cli" in
            claude)
                for name in nexus courier docgen calendar; do "$cli" mcp remove --scope=user "$name" >/dev/null 2>&1; done
                "$cli" mcp add --scope=user nexus -- node "$NEXUS_SERVER" >/dev/null
                register_courier_mcp "$cli"
                "$cli" mcp add --scope=user docgen --env "PYTHONPATH=$DOCGEN_SRC" \
                    --env "PLAYWRIGHT_BROWSERS_PATH=$DOCGEN_BROWSERS" \
                    -- uv run --project "$DOCGEN_PATH" --no-sync python -m docgen.server >/dev/null
                "$cli" mcp add --scope=user calendar --env "PYTHONPATH=$CALENDAR_SRC" \
                    -- uv run --project "$CALENDAR_PATH" --no-sync python -m ea_calendar.server >/dev/null
                ;;
            codex)
                for name in nexus courier docgen calendar; do "$cli" mcp remove "$name" >/dev/null 2>&1; done
                "$cli" mcp add nexus -- node "$NEXUS_SERVER" >/dev/null
                register_courier_mcp "$cli"
                "$cli" mcp add docgen --env "PYTHONPATH=$DOCGEN_SRC" \
                    --env "PLAYWRIGHT_BROWSERS_PATH=$DOCGEN_BROWSERS" \
                    -- uv run --project "$DOCGEN_PATH" --no-sync python -m docgen.server >/dev/null
                "$cli" mcp add calendar --env "PYTHONPATH=$CALENDAR_SRC" \
                    -- uv run --project "$CALENDAR_PATH" --no-sync python -m ea_calendar.server >/dev/null
                ;;
            gemini)
                for name in nexus courier docgen calendar; do "$cli" mcp remove --scope user "$name" >/dev/null 2>&1; done
                "$cli" mcp add --scope user nexus node "$NEXUS_SERVER" >/dev/null
                register_courier_mcp "$cli"
                "$cli" mcp add --scope user docgen --env "PYTHONPATH=$DOCGEN_SRC" \
                    --env "PLAYWRIGHT_BROWSERS_PATH=$DOCGEN_BROWSERS" \
                    uv run --project "$DOCGEN_PATH" --no-sync python -m docgen.server >/dev/null
                "$cli" mcp add --scope user calendar --env "PYTHONPATH=$CALENDAR_SRC" \
                    uv run --project "$CALENDAR_PATH" --no-sync python -m ea_calendar.server >/dev/null
                ;;
            *)
                warn "$cli: unsupported MCP CLI"
                return
                ;;
        esac
        ok "$cli: global MCP wired (nexus + courier + docgen + calendar)"
    }
    # CLIENT machines: get the token on disk before wiring the http courier entries.
    is_mail_host || provision_courier_client_token
    register_global_mcp claude
    register_global_mcp codex
    register_global_mcp gemini

    # MAIL HOST: stand up / refresh the courier HTTP service that clients connect to.
    # Idempotent + re-runnable on its own (token rotation, plist change, mini migration).
    if is_mail_host; then
        if [ -x "$DOTFILES_DIR/scripts/courier-host-bootstrap.sh" ]; then
            step "Courier host bootstrap (this machine is the mail host: $MAIL_HOST)"
            "$DOTFILES_DIR/scripts/courier-host-bootstrap.sh" \
                || warn "courier host bootstrap reported an issue - see output above"
        fi
    else
        # Fail-LOUD (ADR-0002 review): a macOS box with local mail state but a name that
        # doesn't match MAIL_HOST is probably the host after a rename - don't silently
        # treat it as a client.
        if [ "$(uname -s)" = "Darwin" ] && [ -d "$HOME/Mail" ]; then
            warn "This Mac has a ~/Mail maildir but LocalHostName != MAIL_HOST ('$MAIL_HOST')."
            warn "If this is actually the mail host (e.g. renamed), set MAIL_HOST in manifest.sh and re-run."
            warn "Otherwise ignore - wiring courier as a CLIENT of '$MAIL_HOST'."
        fi
    fi

    check_calendar_health() {
        command -v uv >/dev/null 2>&1 || return
        [ -d "$CALENDAR_PATH" ] || return
        if PYTHONPATH="$CALENDAR_SRC" uv run --project "$CALENDAR_PATH" --no-sync python -m ea_calendar.cli status --check-events --quiet >/dev/null 2>&1; then
            ok "Calendar: authenticated as michaelgallo.va@gmail.com"
        else
            warn "Calendar: not authenticated or health check failed - run: cd ~/Documents/EA/calendar && PYTHONPATH=src uv run --no-sync python -m ea_calendar.cli login"
        fi
    }
    check_calendar_health

    trust_gemini_managed_repos() {
        command -v gemini >/dev/null 2>&1 || return
        command -v jq >/dev/null 2>&1 || { warn "Gemini trust: jq not found - skipping trustedFolders update"; return; }
        local trust_file="$HOME/.gemini/trustedFolders.json"
        local tmp target entry
        mkdir -p "$(dirname "$trust_file")"
        [ -f "$trust_file" ] || printf '{}\n' > "$trust_file"
        tmp="$(mktemp)"
        cp "$trust_file" "$tmp"
        for entry in "${REPOS[@]}"; do
            target="$(expand "${entry##*|}")"
            [ -d "$target" ] || continue
            jq --arg path "$target" '. + {($path): "TRUST_FOLDER"}' "$tmp" > "$tmp.next" && mv "$tmp.next" "$tmp"
        done
        mv "$tmp" "$trust_file"
        ok "Gemini: trusted managed repo folders"
    }
    trust_gemini_managed_repos
fi
ensure_agent_defaults

# ── Symlinks ─────────────────────────────────────────────────────────
if [[ "$MODE" == "--full" ]]; then
    step "Creating symlinks"

    for entry in "${SYMLINKS[@]}"; do
        source_path="$(expand "${entry%%|*}")"
        target_path="$(expand "${entry##*|}")"

        if [ -L "$target_path" ] && [ "$(readlink "$target_path")" = "$source_path" ]; then
            ok "$target_path already linked correctly"
        elif [ -e "$target_path" ] || [ -L "$target_path" ]; then
            rm -rf "$target_path"
            ln -s "$source_path" "$target_path"
            ok "Replaced $target_path with symlink -> $source_path"
        else
            mkdir -p "$(dirname "$target_path")"
            ln -s "$source_path" "$target_path"
            ok "Linked $target_path -> $source_path"
        fi
    done

    # Generate Codex + Gemini single-file rule bundles from global-rules/*
    regen_combined_agent_rules

    # Wire the notify-when-done hook into the per-machine Claude settings.json.
    # The SCRIPT rides the symlink above; the Stop/Notification REGISTRATION lives
    # in settings.json, which is machine-local and NOT symlinked, so merge it
    # idempotently with jq (preserves all existing keys). See global-hooks/README.md.
    settings="$HOME/.claude/settings.json"
    hook_cmd="$HOME/.claude/hooks/notify-claude.sh"
    if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
        if jq -e '.hooks.Stop' "$settings" >/dev/null 2>&1; then
            ok "notify hook already wired in settings.json"
        else
            tmp="$(mktemp)"
            if jq --arg cmd "$hook_cmd" \
                '.hooks.Stop = [{matcher:"", hooks:[{type:"command", command:$cmd}]}]
               | .hooks.Notification = [{matcher:"", hooks:[{type:"command", command:$cmd}]}]' \
                "$settings" > "$tmp" && [ -s "$tmp" ]; then
                cp "$settings" "$settings.bak"
                mv "$tmp" "$settings"
                ok "Wired notify hook into settings.json"
            else
                rm -f "$tmp"
                warn "notify hook: jq merge failed, settings.json left untouched"
            fi
        fi
    else
        warn "notify hook: no jq or no settings.json - wire manually (see global-hooks/README.md)"
    fi

    # Wire the stacked-push guard hook into settings.json. Same rationale as the
    # notify hook above: the SCRIPT rides the global-hooks symlink, the PreToolUse
    # REGISTRATION is machine-local in settings.json, so merge it idempotently.
    # Uses permissionDecision:"ask" (confirm-guard), never auto-approves a push.
    guard_cmd="$HOME/.claude/hooks/warn-stacked-git-push.sh"
    if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
        if jq -e '.hooks.PreToolUse' "$settings" >/dev/null 2>&1; then
            ok "stacked-push guard already wired in settings.json"
        else
            tmp="$(mktemp)"
            if jq --arg cmd "$guard_cmd" \
                '.hooks.PreToolUse = [{matcher:"Bash", hooks:[{type:"command", command:$cmd}]}]' \
                "$settings" > "$tmp" && [ -s "$tmp" ]; then
                cp "$settings" "$settings.bak"
                mv "$tmp" "$settings"
                ok "Wired stacked-push guard into settings.json"
            else
                rm -f "$tmp"
                warn "stacked-push guard: jq merge failed, settings.json left untouched"
            fi
        fi
    fi

    # Wire repo-local git hooks (coding-mastermind pre-commit gate) for managed repos
    # that ship a tracked .githooks/ dir. core.hooksPath is per-clone LOCAL config, so
    # it does NOT travel with the repo and must be set here. Idempotent. Mirror of
    # Wire-RepoHooks in setup.ps1 (parity-checked).
    wire_repo_hooks() {
        local entry path
        for entry in "$DOTFILES_DIR" "${REPOS[@]}"; do
            path="$(expand "${entry##*|}")"
            [ -d "$path/.githooks" ] || continue
            if [ "$(git -C "$path" config --get core.hooksPath 2>/dev/null)" = ".githooks" ]; then
                ok "git hooks already wired in $path"
            else
                git -C "$path" config core.hooksPath .githooks && ok "Wired core.hooksPath in $path"
            fi
        done
    }
    wire_repo_hooks
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
