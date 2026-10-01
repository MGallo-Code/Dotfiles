#!/usr/bin/env bash
# check-sync-commit.sh - INV-20 enforcer: sync's dirty-repo commit path (sync.sh, via manifest.sh)
#   - pull_keeping_changes pops only a stash it made: an older stash survives an untracked-only
#     pull, and a tracked local edit comes back after the fast-forward;
#   - usable_commit_message accepts only a clean exit with one non-empty line, so a logged-out
#     `claude -p` ("Not logged in · Please run /login", exit 1) is never committed;
#   - sync.sh calls both helpers and carries no bare stash pop.
# Windows twin: check-sync-commit.ps1. Hermetic: throwaway repos and a bare origin, real manifest.sh.
# --revert-test swaps in the old bare stash/pop and the old empty-only message check and requires
# the fixtures to FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVERT=0; [ "${1:-}" = "--revert-test" ] && REVERT=1

run_fixtures() {
    local T rc=0
    T="$(mktemp -d)"
    (
        export HOME="$T/home"; mkdir -p "$HOME"
        export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
        ok()     { :; }
        warn()   { :; }
        expand() { echo "${1/#\~/$HOME}"; }
        # shellcheck source=/dev/null
        source "$ROOT/manifest.sh"
        if [ "$REVERT" = 1 ]; then
            pull_keeping_changes() { git stash -q 2>/dev/null; git pull -q --ff-only 2>/dev/null; git stash pop -q 2>/dev/null; }
            usable_commit_message() { [ -n "$1" ]; }
        fi
        check() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1')"; exit 1; fi; }
        yn() { if "$@"; then echo yes; else echo no; fi; }
        g() { git -c init.defaultBranch=main "$@"; }

        g init -q --bare "$T/origin.git"
        g clone -q "$T/origin.git" "$T/work" 2>/dev/null
        g clone -q "$T/origin.git" "$T/other" 2>/dev/null
        cd "$T/work" || exit 1
        echo base > f; git add f; git commit -qm one; git push -q origin HEAD:main 2>/dev/null
        git branch -q --set-upstream-to=origin/main 2>/dev/null
        upstream() { (cd "$T/other" && git pull -q origin main 2>/dev/null; echo "$1" > "$1"; git add "$1"; git commit -qm "$1"; git push -q origin HEAD:main 2>/dev/null); }

        # An older stash plus untracked-only changes: the stash is left alone.
        echo set-aside > f; git stash push -q -m older; older="$(git rev-parse refs/stash)"
        echo new > untracked.txt
        upstream g1
        pull_keeping_changes
        check "$(git rev-parse -q --verify refs/stash)" "$older" "an older stash survives an untracked-only pull"
        check "$(cat f)" "base" "the older stash is not applied"
        check "$([ -f g1 ] && echo pulled)" "pulled" "the pull fast-forwarded"
        check "$([ -f untracked.txt ] && echo kept)" "kept" "untracked changes are kept"

        # A tracked edit: stashed, pulled, and restored; the older stash is still the only one.
        echo local > f
        upstream g2
        pull_keeping_changes
        check "$(cat f)" "local" "a tracked edit comes back after the pull"
        check "$([ -f g2 ] && echo pulled)" "pulled" "the pull fast-forwarded past a tracked edit"
        check "$(git stash list | wc -l | tr -d ' ')" "1" "only the older stash remains"

        check "$(yn usable_commit_message 'Not logged in · Please run /login' 1)" "no" "a logged-out claude is not a message"
        check "$(yn usable_commit_message 'Not logged in · Please run /login' 0)" "yes" "a clean one-line reply is a message"
        check "$(yn usable_commit_message '' 0)" "no" "an empty reply is not a message"
        check "$(yn usable_commit_message '   ' 0)" "no" "a blank reply is not a message"
        check "$(yn usable_commit_message $'line one\nline two' 0)" "no" "a multi-line reply is not a message"

        check "$(grep -c '^ *pull_keeping_changes$' "$ROOT/sync.sh")" "1" "sync pulls through pull_keeping_changes"
        check "$(grep -c 'usable_commit_message "\$MSG" "\$MSG_RC"' "$ROOT/sync.sh")" "1" "sync checks the message and its exit code"
        check "$(grep -c 'git stash pop' "$ROOT/sync.sh")" "0" "sync has no bare stash pop"
    ) || rc=1
    rm -rf "$T"
    return "$rc"
}

if [ "$REVERT" = 1 ]; then
    if run_fixtures >/dev/null 2>&1; then echo "revert-test FAILED: the old stash/pop and message check still pass"; exit 1; fi
    echo "revert-test ok: the old stash/pop and message check fail the fixtures"; exit 0
fi
echo "check-sync-commit: fixtures"
run_fixtures || { echo "check-sync-commit: FAILED"; exit 1; }
echo "check-sync-commit OK"
