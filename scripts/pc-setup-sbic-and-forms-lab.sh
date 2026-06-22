#!/usr/bin/env bash
# One-time helper for a second workstation (e.g. the Windows/WSL PC).
#
# Does three things, idempotently, so you don't have to paste fiddly commands:
#   1. Heal the Codex config (drop any duplicate [permissions.michael_workspace]
#      tables, leave exactly one) using the canonical logic from sync.sh.
#   2. Pull SBIC by hand (docs umbrella + platform). SBIC is intentionally NOT in
#      the auto-sync REPOS, so it never auto-commits/pushes employer work - this
#      just brings it current. Tolerant of a dirty tree / feature branch.
#   3. Clone the forms lab from its CLEAN remote (MGallo-Code/sbic-form-ingestion-lab).
#      Never copy the Mac's ~/Downloads copy - it carries contaminated history + PII.
#
# Safe to re-run. Run it with:  bash ~/.dotfiles/scripts/pc-setup-sbic-and-forms-lab.sh
set -uo pipefail

DOTFILES="$HOME/.dotfiles"
LAB_DIR="$HOME/Documents/sbic-form-ingestion-lab"
LAB_REMOTE="git@github:MGallo-Code/sbic-form-ingestion-lab.git"

echo "==> [1/3] Heal Codex config (one michael_workspace profile, valid TOML)"
if [ -f "$DOTFILES/sync.sh" ]; then
    # Source the (already-pulled, fixed) sync.sh - it returns at its own guard
    # before running main, so only functions get defined - then call the real heal.
    if ( source "$DOTFILES/sync.sh" >/dev/null 2>&1 && ensure_agent_defaults >/dev/null 2>&1 ); then
        echo "    OK - codex config healed"
    else
        echo "    WARN - heal failed; run: cd ~/.dotfiles && git pull && bash sync.sh"
    fi
else
    echo "    SKIP - $DOTFILES/sync.sh not found (run 'cd ~/.dotfiles && git pull' first)"
fi

echo "==> [2/3] Pull SBIC (manual; SBIC is never auto-synced)"
for d in "$HOME/Documents/SBIC" "$HOME/Documents/SBIC/platform"; do
    if [ -d "$d/.git" ]; then
        echo "    $d"
        git -C "$d" pull --ff-only 2>&1 | sed 's/^/        /' \
            || echo "        (ff-only pull skipped/failed - resolve by hand)"
    else
        echo "    MISSING: $d"
        case "$d" in
            */SBIC)          echo "        clone: git clone git@github:sbic-platform-corp/sbic-docs.git $d" ;;
            */SBIC/platform) echo "        clone: git clone git@github:sbic-platform-corp/sbic-platform.git $d" ;;
        esac
    fi
done

echo "==> [3/3] Forms lab (clean remote)"
if [ -d "$LAB_DIR/.git" ]; then
    echo "    already present at $LAB_DIR"
else
    if git clone "$LAB_REMOTE" "$LAB_DIR"; then
        echo "    cloned -> $LAB_DIR"
    else
        echo "    clone failed (check the git@github: SSH alias + key)"
    fi
fi

echo "==> done. SBIC and the forms lab are both accessible on this machine."
