#!/usr/bin/env bash
# check-workspace-migration.sh - INV-21 enforcer (ADR-0007): the move out of ~/Documents keeps every
# repo whole and every pointer working, never makes a second copy, waits on the host, and rolls back.
# Hermetic: a throwaway $HOME with real git repos, driven through the real manifest.sh. Windows twin:
# check-workspace-migration.ps1.
#   --revert-test  plants a cwd probe that never sees a busy repo; the fixtures must then FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVERT=0; [ "${1:-}" = "--revert-test" ] && REVERT=1

run_fixtures() {
    local T rc=0
    T="$(cd "$(mktemp -d)" && pwd -P)"
    (
        export HOME="$T/home"; mkdir -p "$HOME"
        export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_SSH_COMMAND=false
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
        ok()     { :; }
        warn()   { :; }
        err()    { :; }
        expand() { echo "${1/#\~/$HOME}"; }
        # shellcheck source=/dev/null
        source "$ROOT/manifest.sh"
        HOSTMODE=0; is_mcp_host() { [ "$HOSTMODE" = 1 ]; }
        [ "$REVERT" = 1 ] && _ws_busy() { return 1; }
        check() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got '$1')"; exit 1; fi; }
        yes_no() { if eval "$1"; then echo yes; else echo no; fi; }
        key() { python3 "$ROOT/scripts/lib/ws_paths.py" key "$1"; }
        D="$HOME/Documents"; W="$HOME/Workspace"; M="$HOME/.claude/projects"

        mkrepo() {   # name remote: a bare origin, and a clone at ~/Documents/<name> whose origin is <remote>
            git -c init.defaultBranch=main init -q --bare "$T/origin/$1.git"
            git clone -q "$T/origin/$1.git" "$D/$1" 2>/dev/null
            (cd "$D/$1" && echo x > f && git add f && git commit -qm one && git push -q origin HEAD:main) 2>/dev/null
            git -C "$D/$1" branch -q --set-upstream-to=origin/main 2>/dev/null
            git -C "$D/$1" remote set-url origin "$2"
        }
        unacl() { [ "$(uname -s)" = Darwin ] && chmod -a "group:everyone deny delete" "$W" 2>/dev/null; return 0; }
        fixture() {
            unacl; rm -rf "$HOME" "$T/origin"; mkdir -p "$HOME/.codex" "$M" "$HOME/.config/dotfiles"
            mkrepo EA git@github:MGallo-Code/EA.git
            mkrepo Wiki git@github:MGallo-Code/Wiki.git
            mkrepo Notes https://github.com/mgallo-code/notes
            mkrepo GalloGrid git@github.com:MGallo-Code/GalloGrid.git
            mkrepo agent-skills git@github:MGallo-Code/agent-skills.git
            WORKSPACE_RETIRED_CLONES=("agent-skills|git@github:MGallo-Code/agent-skills.git|$(git -C "$D/agent-skills" rev-parse HEAD)")
            # EA: ignored data, worktrees outside and inside, an absolute hooksPath, a venv naming the old path
            printf 'secret/\n.venv/\n.worktrees/\n.githooks/\n' > "$D/EA/.gitignore"; git -C "$D/EA" add .gitignore; git -C "$D/EA" commit -qm ig
            git -C "$D/EA" push -q origin HEAD:main 2>/dev/null; git -C "$D/EA" update-ref refs/remotes/origin/main HEAD
            mkdir -p "$D/EA/secret" "$D/EA/sub" "$D/EA/.githooks" "$D/EA/exercises/.venv/bin"; echo s > "$D/EA/secret/health.txt"
            printf '#!/bin/sh\ntouch "$HOME/hook-fired"\n' > "$D/EA/.githooks/post-commit"; chmod +x "$D/EA/.githooks/post-commit"
            git -C "$D/EA" config core.hooksPath "$D/EA/.githooks"
            echo "VIRTUAL_ENV=$D/EA/exercises/.venv" > "$D/EA/exercises/.venv/bin/activate"
            git -C "$D/EA" worktree add -q "$HOME/.claude-worktrees/w/EA" -b wt-out 2>/dev/null
            git -C "$D/EA" worktree add -q "$D/EA/.worktrees/in" -b wt-in 2>/dev/null
            # Claude memory for EA and EA/sub, plus an iCloud-style sibling "EA 2" that must stay put
            mkdir -p "$M/$(key "$D/EA")" "$M/$(key "$D/EA/sub")" "$M/$(key "$D/EA 2")"
            printf '[projects."%s"]\n"%s/sub" = 1\n"%s-backing" = 2\n' "$D/EA" "$D/EA" "$D/EA" > "$HOME/.codex/config.toml"
            echo GalloGrid > "$HOME/.config/dotfiles/code-root"
            echo now > "$HOME/.config/dotfiles/workspace-move"   # armed; the unarmed cases remove it
        }

        echo "-- unarmed: nothing moves or retires anywhere"
        fixture; rm -f "$HOME/.config/dotfiles/workspace-move"
        migrate_to_workspace; check "$?" "0" "an unarmed client succeeds"
        check "$(yes_no '[ -d "$D/EA/.git" ] && [ -d "$D/agent-skills/.git" ] && [ -d "$D/GalloGrid/.git" ] && [ ! -e "$W" ]')" yes "and moves, parks and creates nothing"
        check "$(yes_no '[ -f "$HOME/.config/dotfiles/code-root" ]')" yes "and keeps the switch file"

        echo "-- client: everything moves, retires and is re-pointed"
        fixture
        migrate_to_workspace; check "$?" "0" "migration succeeds"
        check "$(yes_no '[ -d "$W/EA/.git" ] && [ ! -e "$D/EA" ]')" yes "EA moved to ~/Workspace"
        if [ "$(uname -s)" = Darwin ]; then
            check "$(ls -led "$W" | grep -c 'group:everyone deny delete')" 1 "~/Workspace carries the delete-protection ACL"
        fi
        check "$(yes_no '[ -d "$W/Wiki/.git" ] && [ -d "$W/Notes/.git" ]')" yes "Wiki and Notes moved (remote forms compared as owner/repo)"
        check "$(cat "$W/EA/secret/health.txt")" s "ignored data moved with the repo"
        check "$(git -C "$HOME/.claude-worktrees/w/EA" rev-parse --abbrev-ref HEAD 2>&1)" wt-out "a worktree outside the repo still works"
        check "$(git -C "$W/EA/.worktrees/in" rev-parse --abbrev-ref HEAD 2>&1)" wt-in "a worktree inside the repo still works"
        check "$(git -C "$W/EA" config core.hooksPath)" "$W/EA/.githooks" "hooksPath points at the new home"
        (cd "$W/EA" && echo y >> f && git commit -qam two) 2>/dev/null
        check "$(yes_no '[ -f "$HOME/hook-fired" ]')" yes "the git hook still fires"
        check "$(yes_no '[ ! -e "$W/EA/exercises/.venv" ]')" yes "a venv naming the old path is removed"
        check "$(yes_no '[ -d "$M/$(key "$W/EA")" ] && [ -d "$M/$(key "$W/EA/sub")" ]')" yes "Claude memory follows EA and its subfolder"
        check "$(yes_no '[ -d "$M/$(key "$D/EA 2")" ]')" yes "a sibling's memory is left alone"
        check "$(grep -c "$W/EA" "$HOME/.codex/config.toml")" 2 "Codex paths re-pointed"
        check "$(grep -c "$D/EA-backing" "$HOME/.codex/config.toml")" 1 "a sibling path in Codex is left alone"
        check "$(yes_no '[ ! -e "$D/GalloGrid" ] && ls "$HOME/.local/share/dotfiles/retired-clones" | grep -q "^GalloGrid-"')" yes "a client's GalloGrid is parked"
        check "$(yes_no '[ ! -e "$D/agent-skills" ] && ls "$HOME/.local/share/dotfiles/retired-clones" | grep -q "^agent-skills-"')" yes "the agent-skills clone is parked"
        check "$(yes_no '[ ! -e "$HOME/.config/dotfiles/code-root" ]')" yes "the code-root switch file is retired"
        lines="$(wc -l < "$HOME/.local/share/dotfiles/workspace-migration.journal" | tr -d ' ')"
        migrate_to_workspace; check "$?" "0" "a second run succeeds"
        check "$(wc -l < "$HOME/.local/share/dotfiles/workspace-migration.journal" | tr -d ' ')" "$lines" "a second run changes nothing"

        echo "-- rollback: the journal replays in reverse"
        rollback_workspace_migration
        check "$(yes_no '[ -d "$D/EA/.git" ] && [ ! -e "$W/EA" ]')" yes "EA is back"
        check "$(git -C "$HOME/.claude-worktrees/w/EA" rev-parse --abbrev-ref HEAD 2>&1)" wt-out "its outside worktree works again"
        check "$(git -C "$D/EA" config core.hooksPath)" "$D/EA/.githooks" "hooksPath is back"
        check "$(yes_no '[ -d "$M/$(key "$D/EA")" ]')" yes "Claude memory is back"
        check "$(grep -c "$D/EA" "$HOME/.codex/config.toml")" 3 "Codex paths are back"
        check "$(yes_no '[ -d "$D/agent-skills/.git" ] && [ -d "$D/GalloGrid/.git" ]')" yes "parked clones are back"
        check "$(cat "$HOME/.config/dotfiles/code-root")" GalloGrid "the switch file is back"

        echo "-- never a second copy, never a busy repo, never a dirty retire"
        fixture; mkdir -p "$W/Wiki/.git"
        migrate_to_workspace; check "$?" "1" "both homes present: the run fails"
        check "$(yes_no '[ -d "$D/Wiki/.git" ]')" yes "and the old Wiki stays"
        fixture
        (cd "$D/Notes" && exec sleep 30) & busy=$!; sleep 1
        migrate_to_workspace; rc=$?; kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null
        check "$rc" "1" "a busy repo fails the run"
        check "$(yes_no '[ -d "$D/Notes/.git" ] && [ -d "$D/EA/.git" ] && [ ! -e "$W/EA" ]')" yes "and nothing moves (all or nothing)"
        fixture; echo dirty > "$D/agent-skills/new.txt"
        migrate_to_workspace; check "$?" "1" "a dirty clone fails the run"
        check "$(yes_no '[ -f "$D/agent-skills/new.txt" ]')" yes "and is kept in place"
        fixture; git -C "$D/Wiki" remote set-url origin git@github:someone/else.git
        migrate_to_workspace; check "$?" "1" "a different repo at the old home fails the run"
        fixture; (cd "$D/agent-skills" && echo z > g && git add g && git commit -qm two && git update-ref refs/remotes/origin/main HEAD) 2>/dev/null
        migrate_to_workspace; check "$?" "1" "an agent-skills clone newer than the import fails the run"
        check "$(yes_no '[ -d "$D/agent-skills/.git" ]')" yes "and is kept in place"
        fixture
        cat > "$T/run.sh" <<RUN
export HOME="$HOME" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_SSH_COMMAND=false
ok() { :; }; warn() { :; }; err() { :; }; expand() { echo "\${1/#\~/\$HOME}"; }
source "$ROOT/manifest.sh"
is_mcp_host() { return 1; }
WORKSPACE_RETIRED_CLONES=("${WORKSPACE_RETIRED_CLONES[0]}")
migrate_to_workspace
RUN
        (cd "$D/EA" && bash "$T/run.sh"; echo "rc=$?" > "$T/rc")
        check "$(cat "$T/rc")" "rc=1" "a sync started from a shell inside EA fails the run"
        check "$(yes_no '[ -d "$D/EA/.git" ] && [ ! -e "$W/EA" ]')" yes "and EA stays where that shell is"

        echo "-- host: waits for its window, then moves GalloGrid too"
        fixture; HOSTMODE=1; rm -f "$HOME/.config/dotfiles/workspace-move"
        migrate_to_workspace; check "$?" "0" "a deferred host succeeds"
        check "$(yes_no '[ -d "$D/EA/.git" ] && [ ! -e "$W/EA" ]')" yes "and moves nothing"
        check "$(resolve_code_root)" "$D/GalloGrid" "the code root stays at the old home"
        check "$(yes_no '[ -f "$HOME/.config/dotfiles/code-root" ]')" yes "the switch file stays while the host waits"
        mkdir -p "$W/GalloGrid/.git"
        check "$(resolve_code_root)" "$D/GalloGrid" "a stray clone at the new home switches nothing"
        migrate_to_workspace; check "$?" "1" "and the run flags it"
        rm -rf "$W/GalloGrid"
        apply_pending_workspace_paths
        check "$(printf '%s\n' "${REPOS[@]}" | grep -c '~/Documents/')" 3 "this run's repo list points at the old homes"
        check "$(printf '%s\n' "${CODEX_PROJECT_SKILLS[@]}" | grep -c '~/Documents/')" 2 "so do the project-skill sources"
        echo now > "$HOME/.config/dotfiles/workspace-move"
        migrate_to_workspace; check "$?" "0" "the window run succeeds"
        check "$(yes_no '[ -d "$W/GalloGrid/.git" ] && [ -d "$W/EA/.git" ]')" yes "GalloGrid and EA moved on the host"
        check "$(resolve_code_root)" "$W/GalloGrid" "the code root follows"

        echo "-- sync and setup call it first, and fail on a skip"
        check "$(grep -c '^migrate_to_workspace || WORKSPACE_MOVE_FAIL=1' "$ROOT/sync.sh")" 1 "sync migrates"
        check "$(awk '/^migrate_to_workspace \|\|/{m=NR} /^retarget_moved_links$/{r=NR} /bootstrap_all_hubs "\$DOTFILES_DIR/{b=NR} END{print (m && r && b && m<r && r<b) ? "in order" : "out of order"}' "$ROOT/sync.sh")" "in order" "sync migrates before it retargets links and bootstraps the hubs"
        check "$(grep -c 'is_mcp_host && \[ "\${WORKSPACE_MOVE_FAIL:-0}" = 1 \]' "$ROOT/sync.sh")" 1 "sync skips the hub bootstrap after a blocked move"
        check "$(grep -c 'migrate_to_workspace || WORKSPACE_MOVE_FAIL=1' "$ROOT/setup.sh")" 1 "setup migrates"
        check "$(awk '/migrate_to_workspace \|\|/{m=NR} /step "Cloning repos"/{c=NR} END{print (m && c && m<c) ? "before" : "after"}' "$ROOT/setup.sh")" before "setup migrates before cloning"
    ) || rc=1
    [ "$(uname -s)" = Darwin ] && chmod -a "group:everyone deny delete" "$T/home/Workspace" 2>/dev/null
    rm -rf "$T"
    return "$rc"
}

if [ "$REVERT" = 1 ]; then
    if run_fixtures >/dev/null 2>&1; then echo "revert-test FAILED: a blind cwd probe still passes"; exit 1; fi
    echo "revert-test ok: a blind cwd probe fails the fixtures"; exit 0
fi
echo "check-workspace-migration: fixtures"
run_fixtures || { echo "check-workspace-migration: FAILED"; exit 1; }
echo "check-workspace-migration OK"
