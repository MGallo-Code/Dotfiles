#!/usr/bin/env bash
set -euo pipefail

# Cross-platform dev environment setup (macOS + Linux/WSL clients).
# Usage: setup.sh [--full|--dev|--minimal] [--host|--client]
#   --full|--dev|--minimal  MODE - scope of what gets configured (default --full).
#   --host                  ROLE - this machine RUNS + SERVES the MCP hubs. macOS-only (fails loud
#                           off Darwin). Auto-selected when this box IS the MCP host (is_mcp_host).
#   --client                ROLE - thin HTTP+bearer CLIENT of the hubs on the MCP host. Runs on
#                           Linux/WSL (and any non-host Mac). Auto-selected on a non-host machine.
# MODE (scope) and ROLE (host vs client) are ORTHOGONAL: any mode can run as host or client.

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse args: MODE (the scope) + an orthogonal ROLE flag (host/client). Order-independent; the old
# positional `setup.sh --dev` still works (no caller passes anything else - verified).
MODE="--full"
ROLE_FLAG=""
for arg in "$@"; do
    case "$arg" in
        --full|--dev|--minimal) MODE="$arg" ;;
        --host)   ROLE_FLAG="host" ;;
        --client) ROLE_FLAG="client" ;;
        *) echo "usage: setup.sh [--full|--dev|--minimal] [--host|--client]" >&2; exit 2 ;;
    esac
done

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[ok]${NC} $1"; }
warn() { echo -e "${YELLOW}[skip]${NC} $1"; }
err()  { echo -e "${RED}[error]${NC} $1"; }
step() { echo -e "\n${GREEN}==>${NC} $1"; }

# Expand ~ in a path (manifest.sh functions use it at call time; define BEFORE sourcing manifest).
expand() { echo "${1/#\~/$HOME}"; }

# manifest.sh is pure declarations (no top-level execution), so sourcing it here - before the
# role/platform decision - is side-effect-free and makes is_mcp_host available for auto-detect.
source "$DOTFILES_DIR/manifest.sh"

# ── Role: host (runs + serves hubs) vs client (thin HTTP+bearer consumer) ─────
# Explicit --host/--client wins; else auto-detect from CAPABILITY (is_mcp_host: this box's macOS
# LocalHostName == MCP_HOST). Host is macOS-only.
if [ -n "$ROLE_FLAG" ]; then
    ROLE="$ROLE_FLAG"
elif is_mcp_host; then
    ROLE="host"
else
    ROLE="client"
fi

# ROLE_HOST_GUARD: the host role is macOS-only (login keychain / launchd / tailscale serve). Fail
# LOUD if asked to be a host off Darwin - never silently degrade. A non-Darwin box with no --host
# (auto -> client, or explicit --client) falls through here and runs as a Linux/WSL client. This is
# the gate that replaced the old unconditional "macOS only" exit. (parity: setup.ps1 rejects
# -Role host because Windows is always a client.)
if [ "$ROLE" = "host" ] && [ "$(uname)" != "Darwin" ]; then
    err "The --host role is macOS-only (login keychain / launchd / tailscale serve). This is $(uname)."
    err "Run as a client instead:  bash setup.sh ${MODE} --client"
    exit 1
fi

# Visibility: on the actual MCP host, --client cannot make this box a client of ITSELF. Hub WIRING
# keys on capability (is_mcp_host), so courier/calendar stay host-stdio; AND the host-serving block
# below still runs (is_mcp_host), which (re-)bootstraps the hub LaunchAgents. So --client here is
# IGNORED, not a no-op - this box runs as the host. Surface that instead of silently overriding intent.
if is_mcp_host && [ "$ROLE" = "client" ]; then
    warn "This machine IS the MCP host; --client is IGNORED - it runs as the host (hubs stay host-wired"
    warn "and the hub services are (re-)bootstrapped). To set up a client, run on a non-host machine."
fi

ensure_agent_defaults() { # AGENT_DEFAULTS_CONFIG
    local codex_config="$HOME/.codex/config.toml"
    mkdir -p "$HOME/.codex"
    touch "$codex_config"

    set_codex_toml_key() {
        local key="$1"
        local value="$2"
        CODEX_TOML_KEY="$key" CODEX_TOML_VALUE="$value" perl -0pi -e '
            my $key = $ENV{"CODEX_TOML_KEY"};
            my $value = $ENV{"CODEX_TOML_VALUE"};
            my $line = qq{$key = "$value"};
            s/^\Q$key\E\s*=\s*"[^"]*"\r?\n?//mg;
            if (s/(^|\n)(\s*\[)/$1$line\n\n$2/s) {
                next;
            }
            $_ .= "\n" if length($_) && $_ !~ /\n\z/;
            $_ .= "$line\n";
        ' "$codex_config"
    }

    ensure_codex_permission_profile() {
        local block

        block=$(cat <<'EOF'
# dotfiles: Codex Michael workspace permission profile
[permissions.michael_workspace]
description = "Michael's local workspace, dotfiles, and agent config"

[permissions.michael_workspace.filesystem]
":minimal" = "read"

[permissions.michael_workspace.filesystem.":workspace_roots"]
"." = "write"

[permissions.michael_workspace.workspace_roots]
"~/Documents" = true
"~/Downloads" = true
"~/.dotfiles" = true
"~/.codex" = true
"~/.claude" = true
"~/.gemini" = true
"~/.config/nvim" = true

[permissions.michael_workspace.network]
enabled = true
allow_local_binding = true
# dotfiles: end Codex Michael workspace permission profile
EOF
)

        # Strip EVERY michael_workspace table group (marked OR unmarked) + our marker
        # comments, then append exactly one canonical block. An unmarked block (e.g.
        # one a machine bootstrap seeded) used to slip past the marker-gated removal
        # and produce a duplicate-key TOML parse error; this self-heals that.
        perl -0pi -e '
            s/^# dotfiles: (?:end )?Codex Michael workspace permission profile[^\n]*\n//mg;
            s/^\[permissions\.michael_workspace(?:\.[^\]]*)?\][^\n]*\n(?:(?!^\[)[^\n]*\n?)*//mg;
            s/\n{3,}/\n\n/g;
        ' "$codex_config"
        printf '\n%s\n' "$block" >> "$codex_config"
    }

    set_codex_toml_key model_reasoning_effort xhigh
    set_codex_toml_key approval_policy never
    set_codex_toml_key approvals_reviewer user
    set_codex_toml_key default_permissions michael_workspace
    ensure_codex_permission_profile
    ok "Codex: defaults set (xhigh reasoning + Michael workspace permissions)"

    # Codex PreToolUse guards. Registration is machine-local in config.toml; scripts ride the
    # Claude global-hooks symlink. Trust once via the Codex `/hooks` TUI. Idempotent by marker.
    ensure_codex_pretooluse_hook() {
        local marker="$1" command="$2" label="$3"
        if ! grep -qF "$marker" "$codex_config"; then
        cat >> "$codex_config" <<EOF

$marker
[[hooks.PreToolUse]]
matcher = "^Bash\$"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = "$command"
  timeout = 30
EOF
            ok "Codex: wired $label (run /hooks once to trust it)"
        else
            ok "Codex $label already wired"
        fi
    }
    ensure_codex_pretooluse_hook "# dotfiles: flat-PR stacked-push guard" "$HOME/.claude/hooks/warn-stacked-git-push.sh" "stacked-push guard"
    ensure_codex_pretooluse_hook "# dotfiles: Forge action guard" "$HOME/.claude/hooks/forge-guard.sh" "Forge action guard"

    local gemini_settings="$HOME/.gemini/settings.json"
    mkdir -p "$HOME/.gemini"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$gemini_settings" <<'PYJSON'
import json
import os
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
# Gemini's persistent multi-root workspace. ONLY genuine project SOURCE roots - NOT the bulky
# parents (~/Documents is 85G incl. Customer-Work, ~/Downloads 47G) or the agent-state dirs
# (~/.codex 496M, ~/.claude 2.2G, ~/.gemini) which carry GB of tmp/logs/caches/cloned-plugins.
# A ~135GB workspace made gemini's file-discovery roam junk (e.g. ~/.codex/.tmp/plugins/.../nvidia)
# and confabulate it into reviews. This mirrors the claude `sysupdate` --add-dir set (EA +
# agent-skills) plus the control-plane roots. Assigned (NOT appended) so a re-run PRUNES any stale
# entry - this list is authoritative for the managed setting.
gemini_workspace_roots = [
    os.path.expanduser("~/Documents/EA"),
    os.path.expanduser("~/Documents/agent-skills"),
    os.path.expanduser("~/.dotfiles"),
    os.path.expanduser("~/.config/nvim"),
]
context = data.setdefault("context", {})
if not isinstance(context, dict):
    context = {}
    data["context"] = context
context["includeDirectories"] = gemini_workspace_roots
tools = data.setdefault("tools", {})
if not isinstance(tools, dict):
    tools = {}
    data["tools"] = tools
tools["sandboxAllowedPaths"] = gemini_workspace_roots
tools["sandboxNetworkAccess"] = True
security = data.setdefault("security", {})
if not isinstance(security, dict):
    security = {}
    data["security"] = security
auth = security.setdefault("auth", {})
if not isinstance(auth, dict):
    auth = {}
    security["auth"] = auth
auth["selectedType"] = "gemini-api-key"
model = data.setdefault("model", {})
if not isinstance(model, dict):
    model = {}
    data["model"] = model
model["name"] = "gemini-3.1-flash-lite"
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYJSON
        ok "Gemini: defaults set (auto_edit + workspace roots + gemini-3.1-flash-lite API-key auth)"
    else
        warn "Gemini defaults: python3 not found - skipping settings.json update"
    fi
}

ensure_gemini_cross_check_setup() { # GEMINI_CROSS_CHECK_SETUP
    local script="$DOTFILES_DIR/scripts/setup-gemini-cross-check.sh"
    if ! command -v gemini >/dev/null 2>&1; then
        warn "Gemini cross-check: gemini CLI not found - install Gemini, then rerun setup"
        return
    fi
    if [ ! -x "$script" ]; then
        warn "Gemini cross-check: setup script missing at $script"
        return
    fi

    if [ -n "${GEMINI_API_KEY:-}" ]; then
        ok "Gemini cross-check setup present"
        return
    fi
    if command -v security >/dev/null 2>&1 \
        && security find-generic-password -a "${USER:-michael}" -s ea-gemini-api-key -w >/dev/null 2>&1 \
        && [ -x "$HOME/.local/bin/gemini-flash-lite" ]; then
        ok "Gemini cross-check setup present"
        return
    fi

    warn "Gemini cross-check setup incomplete - launching installer"
    "$script" || warn "Gemini cross-check setup incomplete; rerun: $script"
}

# ── Git Config ────────────────────────────────────────────────────────
step "Git config"

CURRENT_NAME=$(git config --global user.name 2>/dev/null || echo "")
CURRENT_EMAIL=$(git config --global user.email 2>/dev/null || echo "")

if [ -n "$CURRENT_NAME" ] && [ -n "$CURRENT_EMAIL" ]; then
    ok "Git user: $CURRENT_NAME <$CURRENT_EMAIL>"
elif [ -t 0 ]; then
    # The read AND its git-config consumer must BOTH sit inside the [ -t 0 ] guard: under `set -u`
    # a wrapped read with an unwrapped `git config "$GIT_NAME"` would reference an unbound var and abort.
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
else
    warn "Git user.name/email unset and no TTY to prompt - set them manually:"
    warn "  git config --global user.name '...'  &&  git config --global user.email '...'"
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

    # Clipboard + auto-open are macOS-only (pbcopy/open). Under `set -euo pipefail` a missing
    # pbcopy returns 127 and would abort, so on non-Darwin just print the key + URL to paste, and
    # only block on an interactive read when a TTY is present (a headless client must not hang).
    if [ "$(uname)" = "Darwin" ]; then
        # pbcopy/open need a GUI session; on a HEADLESS Mac (CI runner, ssh-in) they can fail with no
        # window server -> under `set -e` that would abort. Make them non-fatal (same "no clipboard"
        # class as the non-Darwin branch): print the key if the clipboard is unavailable.
        if cat ~/.ssh/id_ed25519.pub | pbcopy 2>/dev/null; then
            ok "Public key copied to clipboard"
        else
            warn "clipboard unavailable (headless?) - add this key to GitHub manually:"
            cat ~/.ssh/id_ed25519.pub
        fi
        open "https://github.com/settings/ssh/new" 2>/dev/null || true
        echo "Paste your key on GitHub (https://github.com/settings/ssh/new), then press Enter to continue..."
        if [ -t 0 ]; then read -r || true; fi
    else
        echo "Add this public key to GitHub (https://github.com/settings/ssh/new):"
        cat ~/.ssh/id_ed25519.pub
    fi
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
        # Guard the prompt + seed the var on the non-TTY path so the `[[ ]]` consumer below stays
        # bound under `set -u` (a headless run skips the install, same as answering "n").
        if [ -t 0 ]; then
            echo "Install packages from Brewfile? (y/n)"
            read -r INSTALL_BREW
        else
            INSTALL_BREW="n"
        fi
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

    # Build nexus (TypeScript). nexus is stdio-wired on EVERY machine until it is remoted (Phase D),
    # so a client needs it built too. Two `set -euo pipefail` aborts to avoid so a client run COMPLETES:
    # (1) a MISSING npm returns 127 -> gate on `command -v npm`; (2) a present-but-FAILING install/build
    # returns non-zero (the 2>/dev/null hides stderr, not the exit code) -> warn-and-continue, never
    # abort. An unbuilt nexus is surfaced loudly, not silently fatal to the whole setup.
    if [ -f "$NEXUS_PATH/package.json" ]; then
        if command -v npm >/dev/null 2>&1; then
            cd "$NEXUS_PATH"
            if npm install --silent 2>/dev/null && npm run build 2>/dev/null; then
                ok "Nexus: installed and built"
            else
                warn "Nexus: npm install/build failed - nexus stdio won't run until fixed (setup continues)"
            fi
            cd - >/dev/null
        else
            warn "Nexus: npm not found - skipping build (install Node + re-run; nexus stdio needs it)"
        fi
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

    # Project-scope .mcp.json for the PRIVATE EA + IT-Worker repos: docgen ONLY. nexus, like
    # courier, is wired GLOBALLY ONLY (host stdio / client http+bearer via register_all_hub_mcp)
    # and is NEVER written into any project .mcp.json - a project stdio nexus would let a client
    # read its own stale nexus.db (split-brain), and assert-no-client-stdio-nexus.sh forbids it on
    # every box. docgen is not remoted, so it is the only project-scoped server.
    if [ -f "$NEXUS_SERVER" ]; then
        MCP_JSON=$(cat <<EOF
{
  "mcpServers": {
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
        MCP_DESC="docgen; nexus is global-only (never in project .mcp.json, like courier)"
        echo "$MCP_JSON" > "$EA_PATH/.mcp.json"
        ok "EA .mcp.json generated ($MCP_DESC)"
        if [ -d "$ITW_PATH" ]; then
            echo "$MCP_JSON" > "$ITW_PATH/.mcp.json"
            ok "IT-Worker .mcp.json generated ($MCP_DESC)"
        fi
    fi

    # Global wiring: all four servers in EVERY project, for Claude, Codex, and Gemini.
    # Idempotent (remove-then-add); no-ops if the CLI is absent. This is how
    # courier/nexus/docgen/calendar reach SBIC/lab/etc WITHOUT being written into those repos.
    # Hubs are wired per-ROLE through the shared register_all_hub_mcp / register_hub_mcp in
    # manifest.sh (sourced at the top), so setup AND sync share ONE copy of the host-vs-client
    # decision and check-hub-wiring (INV-5) can prove no script wires a hub directly. Courier's
    # host/client WIRING keys on is_mcp_host (CAPABILITY: a box wires courier host-stdio ONLY if it
    # CAN be the host - same predicate as before); the ROLE flag (intent) governs only the
    # host-SERVING block below, never the wiring - so --client never re-wires the live courier on
    # the host, and a Linux/WSL box (is_mcp_host false) correctly wires the HTTP client.
    # CLIENT machines: get every hub's token on disk before wiring the http entries (courier + calendar).
    is_mcp_host || provision_all_client_tokens
    register_all_hub_mcp claude
    register_all_hub_mcp codex
    register_all_hub_mcp gemini

    # HOST: stand up / refresh the HTTP service(s) clients connect to - one per hub in hubs.json
    # (courier today). Idempotent + re-runnable (token rotation, plist change, mini migration).
    # Keyed on CAPABILITY (is_mcp_host) so the real host always (re)serves on a plain `setup.sh`,
    # OR on explicit --host (intent) so `setup.sh --host` on a renamed/misnamed Mac REACHES
    # hub-host-bootstrap's LOUD "LocalHostName != MCP_HOST" refusal instead of silently degrading.
    if is_mcp_host || [ "$ROLE" = "host" ]; then
        step "Hub host bootstrap (MCP host: $MCP_HOST)"
        bootstrap_all_hubs "$DOTFILES_DIR/hubs.json" "$DOTFILES_DIR/scripts/hub-host-bootstrap.sh"
    fi
    # Fail-LOUD safety net (ADR-0002 review), independent of ROLE: a macOS box with local mail state
    # whose LocalHostName != MCP_HOST is probably the host after a rename. Always warn so a renamed
    # host is never silently treated as a client (the default no-flag run resolves ROLE=client there).
    if [ "$(uname -s)" = "Darwin" ] && [ -d "$HOME/Mail" ] && ! is_mcp_host; then
        warn "This Mac has a ~/Mail maildir but LocalHostName != MCP_HOST ('$MCP_HOST')."
        warn "If this is actually the host (e.g. renamed), set MCP_HOST in manifest.sh and re-run,"
        warn "or run 'bash setup.sh --host' to force the host bootstrap (it names the exact fix)."
        warn "Otherwise ignore - wiring courier as a CLIENT of '$MCP_HOST'."
    fi

    check_calendar_health() {
        # `return 0` (not bare `return`): a bare return propagates `command -v`'s non-zero exit, and
        # this advisory fn is called as a plain statement under `set -e` - so on a client without uv
        # it would ABORT setup. (Latent until Phase B made setup.sh run past the old Darwin exit.)
        command -v uv >/dev/null 2>&1 || return 0
        [ -d "$CALENDAR_PATH" ] || return 0
        if PYTHONPATH="$CALENDAR_SRC" uv run --project "$CALENDAR_PATH" --no-sync python -m ea_calendar.cli status --check-events --quiet >/dev/null 2>&1; then
            ok "Calendar: authenticated as michaelgallo.va@gmail.com"
        else
            warn "Calendar: not authenticated or health check failed - run: cd ~/Documents/EA/calendar && PYTHONPATH=src uv run --no-sync python -m ea_calendar.cli login"
        fi
    }
    check_calendar_health

    trust_gemini_managed_repos() {
        # `return 0` for the same reason as check_calendar_health: bare `return` would propagate a
        # non-zero `command -v` status and abort this advisory fn under `set -e` on a client.
        command -v gemini >/dev/null 2>&1 || return 0
        command -v jq >/dev/null 2>&1 || { warn "Gemini trust: jq not found - skipping trustedFolders update"; return 0; }
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
        for target in "$HOME/Documents" "$HOME/Downloads" "$HOME/.dotfiles" "$HOME/.codex" "$HOME/.claude" "$HOME/.gemini" "$HOME/.config/nvim"; do
            [ -d "$target" ] || continue
            jq --arg path "$target" '. + {($path): "TRUST_FOLDER"}' "$tmp" > "$tmp.next" && mv "$tmp.next" "$tmp"
        done
        mv "$tmp" "$trust_file"
        ok "Gemini: trusted managed repo + workspace folders"
    }
    trust_gemini_managed_repos
fi
ensure_agent_defaults
# Darwin-gate (cosmetic, not a safety fix - the call is already non-fatal via `|| warn` inside it):
# the gemini cross-check keys its API key off the macOS keychain, so on a Linux/WSL client it can
# only emit a confusing keychain warning. Skip it off Darwin to keep client output clean.
if [ "$(uname)" = "Darwin" ]; then
    ensure_gemini_cross_check_setup
fi

# ── Symlinks ─────────────────────────────────────────────────────────
if [[ "$MODE" == "--full" ]]; then
    step "Creating symlinks"

    for entry in "${SYMLINKS[@]}"; do
        source_path="$(expand "${entry%%|*}")"
        target_path="$(expand "${entry##*|}")"

        if [ -L "$target_path" ] && [ "$(readlink "$target_path")" = "$source_path" ]; then
            ok "$target_path already linked correctly"
        elif [ -L "$target_path" ]; then
            rm -f "$target_path"
            ln -s "$source_path" "$target_path"
            ok "Replaced $target_path with symlink -> $source_path"
        elif [ -e "$target_path" ]; then
            warn "$target_path exists but is not the expected symlink - skipping to avoid deleting local content"
        elif [ ! -e "$source_path" ]; then
            warn "$target_path source missing at $source_path"
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

    # Wire PreToolUse guards into settings.json. Same rationale as the notify hook above:
    # scripts ride the global-hooks symlink; registration is machine-local, so merge each
    # specific command idempotently instead of treating any PreToolUse entry as sufficient.
    ensure_claude_pretooluse_hook() {
        local hook_cmd="$1" label="$2" tmp
        if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
            if jq -e --arg cmd "$hook_cmd" 'any(.hooks.PreToolUse[]?.hooks[]?; .command == $cmd)' "$settings" >/dev/null 2>&1; then
                ok "$label already wired in settings.json"
                return
            fi
            tmp="$settings.tmp.$$"
            if jq --arg cmd "$hook_cmd" '
                .hooks = (.hooks // {})
              | .hooks.PreToolUse = (
                  ((.hooks.PreToolUse // []) | if type == "array" then . else [] end) as $pre
                  | $pre + [{matcher:"Bash", hooks:[{type:"command", command:$cmd}]}]
                )' "$settings" > "$tmp" && [ -s "$tmp" ]; then
                cp "$settings" "$settings.bak"
                mv "$tmp" "$settings"
                ok "Wired $label into settings.json"
            else
                rm -f "$tmp"
                warn "$label: jq merge failed, settings.json left untouched"
            fi
        else
            warn "$label: no jq or no settings.json - wire manually"
        fi
    }
    ensure_claude_pretooluse_hook "$HOME/.claude/hooks/warn-stacked-git-push.sh" "stacked-push guard"
    ensure_claude_pretooluse_hook "$HOME/.claude/hooks/forge-guard.sh" "Forge action guard"

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
