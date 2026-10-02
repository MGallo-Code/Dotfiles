#!/usr/bin/env bash
# workspace-rollback.sh - undo the ADR-0007 move on this machine (INV-21). Replays the migration
# journal (~/.local/share/dotfiles/workspace-migration.journal) in reverse: path rewrites, Claude
# memory keys, repo moves (with git worktree repair), parked clones and the code-root switch file.
# Then check out the dotfiles commit before ADR-0007 and run sync, or the next sync moves them again.
# Windows twin: workspace-rollback.ps1.
set -uo pipefail
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok()   { printf '[ok] %s\n' "$1"; }
warn() { printf '[!] %s\n' "$1"; }
err()  { printf '[error] %s\n' "$1"; }
expand() { echo "${1/#\~/$HOME}"; }
# shellcheck source=../manifest.sh
source "$DOTFILES_DIR/manifest.sh"
rollback_workspace_migration
