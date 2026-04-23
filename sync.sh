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

# ── Checkpoint Nexus DB (flush WAL into main file before syncing) ────
NEXUS_DB="$(expand "~/Documents/EA/nexus/nexus.db")"
if [ -f "$NEXUS_DB" ] && command -v sqlite3 &>/dev/null; then
    sqlite3 "$NEXUS_DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
    ok "Nexus DB: WAL checkpointed"
fi

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

# ── Rebuild Nexus if EA was updated ──────────────────────────────────
NEXUS_PATH="$(expand "~/Documents/EA/nexus")"
if [ -f "$NEXUS_PATH/package.json" ]; then
    cd "$NEXUS_PATH"
    npm install --silent 2>/dev/null
    npm run build 2>/dev/null
    ok "Nexus: rebuilt"
    cd - >/dev/null
fi

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

    HAS_CLAUDE=false
    command -v claude &>/dev/null && HAS_CLAUDE=true

    for name in "${DIRTY[@]}"; do
        # Find the repo path
        repo_path=""
        for entry in "${REPOS[@]}"; do
            target="$(expand "${entry##*|}")"
            if [[ "$(basename "$target")" == "$name" ]]; then
                repo_path="$target"
                break
            fi
        done
        if [[ "$name" == "$(basename "$DOTFILES_DIR")" ]]; then
            repo_path="$DOTFILES_DIR"
        fi
        [ -z "$repo_path" ] && continue

        cd "$repo_path"

        # Build a changes summary for this repo
        CHANGES=""
        DIFF_STAT=$(git diff --stat 2>/dev/null)
        UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
        [ -n "$DIFF_STAT" ] && CHANGES+="Modified:\n$DIFF_STAT\n"
        [ -n "$UNTRACKED" ] && CHANGES+="New files:\n$UNTRACKED\n"

        echo ""
        info "$name changes:"
        echo -e "$CHANGES"

        # Pull remote changes before committing to avoid non-fast-forward
        git stash -q 2>/dev/null
        git pull --ff-only 2>/dev/null
        git stash pop -q 2>/dev/null

        if $HAS_CLAUDE; then
            # Ask Claude for a commit message (or a review flag)
            PROMPT="You are a commit message generator. Given these changes in the '$name' repo:

$CHANGES

Respond with ONLY one of:
1. A single-line commit message (no quotes, no prefix) if the changes are safe to commit
2. REVIEW: <reason> if the changes need human review (e.g. secrets, large deletions, config that looks wrong)

Nothing else. No explanation."

            info "$name: asking Claude for commit message..."
            MSG=$(claude -p "$PROMPT" 2>/dev/null)

            if [ -z "$MSG" ]; then
                warn "$name: Claude returned empty response - skipping"
                continue
            fi

            if [[ "$MSG" == REVIEW:* ]]; then
                warn "$name: ${MSG}"
                continue
            fi

            # Commit and push
            ok "$name: committing with message: $MSG"
            git add -A
            git commit -m "$MSG"
            git push 2>/dev/null
            if [ $? -eq 0 ]; then
                ok "$name: pushed"
            else
                err "$name: push failed"
            fi
        else
            warn "$name: Claude Code not available - commit manually"
        fi
    done
fi

echo ""
