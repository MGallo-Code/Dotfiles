#!/usr/bin/env bash
# check-moved-links.sh - guards ADR-0006's cutover: retarget_moved_links (manifest.sh) repoints
# every managed link left under a MOVED_LINK_SOURCES old prefix, live or dangling, and touches
# nothing else. Windows twin: check-moved-links.ps1.
#
# Hermetic: a throwaway $HOME with an old and a new claude-config tree, driven through the real
# manifest.sh. --revert-test empties MOVED_LINK_SOURCES and requires the fixtures to FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVERT=0; [ "${1:-}" = "--revert-test" ] && REVERT=1

run_fixtures() {
    local T fail=0
    T="$(mktemp -d)"
    (
        export HOME="$T/home"
        ok()     { :; }
        warn()   { echo "warn: $1" >> "$T/warnings"; }
        expand() { echo "${1/#\~/$HOME}"; }
        # shellcheck source=/dev/null
        source "$ROOT/manifest.sh"
        # The fixture brings its own list, so it does not depend on which moves are still live.
        MOVED_LINK_SOURCES=("~/Documents/EA/claude-config|~/.dotfiles/claude-config")   # stale-path-ok (ADR-0006 fixture)
        [ "$REVERT" = 1 ] && MOVED_LINK_SOURCES=()

        OLD="$HOME/Documents/EA/claude-config"; NEW="$HOME/.dotfiles/claude-config"   # stale-path-ok (ADR-0006 fixture)
        for d in global-rules global-hooks global-commands global-skills/calendar; do
            mkdir -p "$OLD/$d" "$NEW/$d"
        done
        mkdir -p "$OLD/global-skills/ghost" "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.claude/agents" "$T/elsewhere"
        ln -s "$OLD/global-rules" "$HOME/.claude/rules"                         # live
        ln -s "$OLD/global-hooks" "$HOME/.claude/hooks"                         # live
        ln -s "$OLD/global-commands" "$HOME/.claude/commands"; rm -rf "$OLD/global-commands"   # dangling
        ln -s "$OLD/global-skills/calendar" "$HOME/.claude/skills/calendar"    # live skill link
        ln -s "$OLD/global-skills/calendar" "$HOME/.codex/skills/calendar"     # live skill link
        ln -s "$OLD/global-skills/ghost" "$HOME/.codex/skills/ghost"           # no counterpart in NEW
        ln -s "$T/elsewhere" "$HOME/.claude/skills/other"                      # unrelated link
        touch "$HOME/.claude/agents/keep.md"                                   # a real dir, never touched

        retarget_moved_links
        retarget_moved_links   # idempotent: a second run changes nothing

        check() { if [ "$(readlink "$1")" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$(readlink "$1")')"; exit 1; fi; }
        check "$HOME/.claude/rules" "$NEW/global-rules" "live link repointed"
        check "$HOME/.claude/hooks" "$NEW/global-hooks" "second live link repointed"
        check "$HOME/.claude/commands" "$NEW/global-commands" "dangling link repointed"
        check "$HOME/.claude/skills/calendar" "$NEW/global-skills/calendar" "Claude skill link repointed"
        check "$HOME/.codex/skills/calendar" "$NEW/global-skills/calendar" "Codex skill link repointed"
        check "$HOME/.codex/skills/ghost" "$OLD/global-skills/ghost" "link with no new counterpart left as is"
        check "$HOME/.claude/skills/other" "$T/elsewhere" "unrelated link untouched"
        if [ -d "$HOME/.claude/agents" ] && [ ! -L "$HOME/.claude/agents" ] && [ -f "$HOME/.claude/agents/keep.md" ]; then
            echo "  ok    real dir untouched"; else echo "  FAIL  real dir untouched"; exit 1; fi
        if [ -d "$OLD/global-rules" ]; then echo "  ok    old target itself kept"; else echo "  FAIL  old target removed"; exit 1; fi
        if grep -q "ghost" "$T/warnings" 2>/dev/null; then echo "  ok    missing counterpart warned"; else echo "  FAIL  missing counterpart not warned"; exit 1; fi
    ) || fail=1
    rm -rf "$T"
    return "$fail"
}

if [ "$REVERT" = 1 ]; then
    if run_fixtures >/dev/null 2>&1; then
        echo "revert-test FAILED: with MOVED_LINK_SOURCES empty the fixtures still pass"; exit 1
    fi
    echo "revert-test ok: an empty MOVED_LINK_SOURCES fails the fixtures"; exit 0
fi
echo "check-moved-links: fixtures"
run_fixtures || { echo "check-moved-links: FAILED"; exit 1; }
echo "check-moved-links OK"
