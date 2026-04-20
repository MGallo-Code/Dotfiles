#!/usr/bin/env bash
set -uo pipefail

# Sync all managed repos - pull updates, detect local changes, hand off to Claude for commits

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DOTFILES_DIR/manifest.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[ok]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[error]${NC} $1"; }
info() { echo -e "${CYAN}[info]${NC} $1"; }

expand() { echo "${1/#\~/$HOME}"; }

UPDATED=()
PUSHED=()
DIRTY=()
DIVERGED=()
MISSING=()

sync_repo() {
    local target="$1"
    local name="$(basename "$target")"

    if [ ! -d "$target/.git" ]; then
        MISSING+=("$name")
        warn "$name: not found at $target"
        return
    fi

    cd "$target"

    # Fetch latest
    git fetch origin 2>/dev/null || { err "$name: fetch failed"; return; }

    local LOCAL=$(git rev-parse @)
    local REMOTE=$(git rev-parse @{u} 2>/dev/null || echo "none")
    local BASE=$(git merge-base @ @{u} 2>/dev/null || echo "none")
    local DIRTY_STATUS=$(git status --porcelain)

    if [ -n "$DIRTY_STATUS" ]; then
        # Has uncommitted changes
        DIRTY+=("$name")
        info "$name: has uncommitted changes"
        git status --short
        return
    fi

    if [ "$REMOTE" = "none" ]; then
        warn "$name: no upstream set"
        return
    fi

    if [ "$LOCAL" = "$REMOTE" ]; then
        ok "$name: up to date"
    elif [ "$LOCAL" = "$BASE" ]; then
        # Behind remote - pull
        git pull --ff-only 2>/dev/null
        if [ $? -eq 0 ]; then
            UPDATED+=("$name")
            ok "$name: pulled updates"
        else
            DIVERGED+=("$name")
            err "$name: pull failed"
        fi
    elif [ "$REMOTE" = "$BASE" ]; then
        # Ahead of remote - push
        git push 2>/dev/null
        if [ $? -eq 0 ]; then
            PUSHED+=("$name")
            ok "$name: pushed to remote"
        else
            err "$name: push failed"
        fi
    else
        DIVERGED+=("$name")
        err "$name: diverged from remote - manual resolution needed"
    fi
}

# ── Sync dotfiles repo itself ────────────────────────────────────────
echo -e "\n${GREEN}==>${NC} Syncing dotfiles"
sync_repo "$DOTFILES_DIR"

# ── Sync manifest repos ─────────────────────────────────────────────
echo -e "\n${GREEN}==>${NC} Syncing managed repos"
for entry in "${REPOS[@]}"; do
    target="$(expand "${entry##*|}")"
    sync_repo "$target"
done

# ── Verify symlinks ─────────────────────────────────────────────────
echo -e "\n${GREEN}==>${NC} Checking symlinks"
for entry in "${SYMLINKS[@]}"; do
    source_path="$(expand "${entry%%|*}")"
    target_path="$(expand "${entry##*|}")"

    if [ -L "$target_path" ] && [ "$(readlink "$target_path")" = "$source_path" ]; then
        ok "$(basename "$target_path"): linked correctly"
    elif [ -e "$target_path" ]; then
        warn "$(basename "$target_path"): exists but wrong symlink"
    else
        warn "$(basename "$target_path"): missing"
    fi
done

# ── Summary ──────────────────────────────────────────────────────────
echo -e "\n${GREEN}==>${NC} Summary"
[ ${#UPDATED[@]} -gt 0 ]  && ok "Updated: ${UPDATED[*]}"
[ ${#PUSHED[@]} -gt 0 ]   && ok "Pushed: ${PUSHED[*]}"
[ ${#DIVERGED[@]} -gt 0 ] && err "Diverged (manual fix): ${DIVERGED[*]}"
[ ${#MISSING[@]} -gt 0 ]  && warn "Missing: ${MISSING[*]}"

# ── Handle dirty repos with Claude ──────────────────────────────────
if [ ${#DIRTY[@]} -gt 0 ]; then
    echo ""
    warn "Dirty repos: ${DIRTY[*]}"
    echo ""

    if command -v claude &>/dev/null; then
        echo "Launch Claude to commit and push changes? (y/n)"
        read -r LAUNCH_CLAUDE
        if [[ "$LAUNCH_CLAUDE" == "y" ]]; then
            # Build summary of dirty repos
            SUMMARY="The following repos have uncommitted changes that need to be committed and pushed:\n"
            for name in "${DIRTY[@]}"; do
                for entry in "${REPOS[@]}"; do
                    target="$(expand "${entry##*|}")"
                    if [[ "$(basename "$target")" == "$name" ]]; then
                        cd "$target"
                        DIFF=$(git diff --stat 2>/dev/null)
                        UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
                        SUMMARY+="\n$name ($target):\n  Changes: $DIFF"
                        [ -n "$UNTRACKED" ] && SUMMARY+="\n  New files: $UNTRACKED"
                        break
                    fi
                done
                # Check dotfiles too
                if [[ "$name" == "$(basename "$DOTFILES_DIR")" ]]; then
                    cd "$DOTFILES_DIR"
                    DIFF=$(git diff --stat 2>/dev/null)
                    SUMMARY+="\n$name ($DOTFILES_DIR):\n  Changes: $DIFF"
                fi
            done

            echo -e "$SUMMARY"
            echo ""

            # Hand off to Claude in the first dirty repo
            for name in "${DIRTY[@]}"; do
                for entry in "${REPOS[@]}"; do
                    target="$(expand "${entry##*|}")"
                    if [[ "$(basename "$target")" == "$name" ]]; then
                        cd "$target"
                        claude -p "These repos have uncommitted changes: ${DIRTY[*]}. For this repo ($name), review the changes with git diff and git status, commit with a clear message, and push. Then tell me which other repos still need attention."
                        break 2
                    fi
                done
            done
        fi
    else
        echo "Claude Code not available. Commit and push manually:"
        for name in "${DIRTY[@]}"; do
            echo "  - $name"
        done
    fi
fi

echo ""
