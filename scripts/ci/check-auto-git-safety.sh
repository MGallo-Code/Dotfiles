#!/usr/bin/env bash
# INV-12 enforcer: auto-git never creates commits or touches dirty human work.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUTO_SH="${AUTO_GIT_SH:-$ROOT/auto-git.sh}"
AUTO_PS1="${AUTO_GIT_PS1:-$ROOT/auto-git.ps1}"
TEST_TMP_PARENT="${AUTO_GIT_TEST_TMP_PARENT:-$ROOT/.auto-git-test-tmp}"
pass=0
fail=0

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_XDG=/dev/null
mkdir -p "$TEST_TMP_PARENT"
export TMPDIR="$TEST_TMP_PARENT"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$TEST_TMP_PARENT/xdg}"
if [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/git ]; then
    mkdir -p "$TEST_TMP_PARENT/bin"
    cat > "$TEST_TMP_PARENT/bin/git" <<'EOF'
#!/usr/bin/env bash
exec /Applications/Xcode.app/Contents/Developer/usr/bin/git "$@"
EOF
    chmod +x "$TEST_TMP_PARENT/bin/git"
    export PATH="$TEST_TMP_PARENT/bin:$PATH"
fi

ok() { printf '  ok - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL - %s\n' "$1" >&2; fail=$((fail + 1)); }
assert() {
    local label="$1"
    shift
    if "$@"; then ok "$label"; else bad "$label"; fi
}

not_grep() {
    ! grep -q "$@"
}

no_unconditional_task_disable() {
    local file="$1"
    ! sed -n '/Register-ScheduledTask/,/if (\$Disable)/p' "$file" \
        | sed '$d' \
        | grep -q "Disable-ScheduledTask -TaskName"
}

scan_file() {
    local file="$1"
    local stripped line
    stripped="$(sed -E '/^[[:space:]]*#/d; s/#.*$//' "$file")"
    if printf '%s\n' "$stripped" | grep -En '(^|[[:space:];|&])(command[[:space:]]+)?git([[:space:]]+(-[A-Za-z]|--[A-Za-z-]+)([= ][^[:space:];|&]+)?)*[[:space:]]+(add|commit|stash|reset|clean|checkout|restore|rm|pull|rebase|switch)\b|claude[[:space:]]+-p|--autostash' >/tmp/auto-git-scan.$$; then
        cat /tmp/auto-git-scan.$$ >&2
        rm -f /tmp/auto-git-scan.$$
        return 1
    fi
    while IFS= read -r line; do
        if printf '%s\n' "$line" | grep -Eq '(^|[[:space:];|&])(command[[:space:]]+)?git([[:space:]]+(-[A-Za-z]|--[A-Za-z-]+)([= ][^[:space:];|&]+)?)*[[:space:]]+merge([[:space:]]|$)'; then
            if ! printf '%s\n' "$line" | grep -Eq 'git[[:space:]]+-C[[:space:]]+"?\$([Rr]epo)"?[[:space:]]+merge[[:space:]]+--ff-only[[:space:]]+"?\$(remote_rev|remoteRev)"?'; then
                printf '%s\n' "$line" >&2
                rm -f /tmp/auto-git-scan.$$
                return 1
            fi
        fi
    done <<< "$stripped"
    rm -f /tmp/auto-git-scan.$$
    return 0
}

run_auto_git() {
    local list_file="$1"
    local lock_dir="$2"
    AUTO_GIT_NO_SELF_SNAPSHOT=1 \
    AUTO_GIT_TEST_BEFORE_MUTATE_HOOK="${AUTO_GIT_TEST_BEFORE_MUTATE_HOOK:-}" \
    AUTO_GIT_REPO_LIST_FILE="$list_file" \
    DOTFILES_GIT_SYNC_LOCK_DIR="$lock_dir" \
    bash "$ROOT/auto-git.sh" >/dev/null 2>&1
}

run_auto_git_as_dotfiles() {
    local dotfiles_dir="$1"
    AUTO_GIT_NO_SELF_SNAPSHOT=1 \
    AUTO_GIT_TEST_BEFORE_MUTATE_HOOK="${AUTO_GIT_TEST_BEFORE_MUTATE_HOOK:-}" \
    DOTFILES_DIR_OVERRIDE="$dotfiles_dir" \
    bash "$ROOT/auto-git.sh" >/dev/null 2>&1
}

git_config() {
    git -C "$1" config user.email "auto-git-test@example.invalid"
    git -C "$1" config user.name "Auto Git Test"
}

make_fixture() {
    local base="$1"
    mkdir -p "$base"
    git init --bare "$base/remote.git" >/dev/null
    git init -b main "$base/seed" >/dev/null
    git_config "$base/seed"
    printf 'one\n' > "$base/seed/file.txt"
    git -C "$base/seed" add file.txt
    git -C "$base/seed" commit -m "seed" >/dev/null
    git -C "$base/seed" remote add origin "$base/remote.git"
    git -C "$base/seed" push -u origin main >/dev/null
    git --git-dir="$base/remote.git" symbolic-ref HEAD refs/heads/main
    git clone -b main "$base/remote.git" "$base/work" >/dev/null 2>&1
    git clone -b main "$base/remote.git" "$base/other" >/dev/null 2>&1
    git_config "$base/work"
    git_config "$base/other"
}

commit_in_repo() {
    local repo="$1"
    local text="$2"
    printf '%s\n' "$text" >> "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -m "$text" >/dev/null
}

git_marker_path() {
    local repo="$1"
    local marker="$2"
    local path
    path="$(git -C "$repo" rev-parse --path-format=absolute --git-path "$marker" 2>/dev/null \
        || git -C "$repo" rev-parse --git-path "$marker")"
    case "$path" in
        /*) printf '%s\n' "$path" ;;
        *) printf '%s/%s\n' "$repo" "$path" ;;
    esac
}

write_list() {
    printf '%s\n' "$1" > "$2"
}

current_bash_runtime() {
    local kernel
    kernel="$(uname -s 2>/dev/null || echo unknown)"
    case "$kernel" in
        Darwin) printf '%s\n' "bash-darwin" ;;
        Linux)
            if [ -r /proc/version ] && grep -qi microsoft /proc/version; then
                printf '%s\n' "bash-wsl"
            else
                printf '%s\n' "bash-linux"
            fi
            ;;
        *) printf '%s\n' "bash-$(printf '%s' "$kernel" | tr '[:upper:]' '[:lower:]')" ;;
    esac
}

main_checks() {
    echo "==> static auto-git safety scan"
    assert "auto-git.sh has no forbidden operative commands" scan_file "$AUTO_SH"
    assert "auto-git.ps1 has no forbidden operative commands" scan_file "$AUTO_PS1"
    assert "bash signal traps exit after releasing lock" grep -q "git_sync_lock_release_and_exit 130" "$ROOT/scripts/git-sync-lock.sh"
    assert "bash lock publishes with atomic hard link" grep -q 'ln "$tmp_owner" "$lock_path"' "$ROOT/scripts/git-sync-lock.sh"
    assert "powershell lock publishes with atomic hard link" grep -q "ItemType HardLink" "$ROOT/scripts/git-sync-lock.ps1"

    local tmp
    tmp="$(mktemp -d "$TEST_TMP_PARENT/run.XXXXXX")"
    AUTO_GIT_CHECK_TMP="$tmp"
    trap 'rm -rf "$AUTO_GIT_CHECK_TMP"' EXIT

    echo "==> behavioral fixtures"

    make_fixture "$tmp/dirty"
    local dirty_head dirty_index
    dirty_head="$(git -C "$tmp/dirty/work" rev-parse HEAD)"
    dirty_index="$(git -C "$tmp/dirty/work" diff --cached --name-only)"
    printf 'human edit\n' >> "$tmp/dirty/work/file.txt"
    write_list "$tmp/dirty/work" "$tmp/dirty/list"
    run_auto_git "$tmp/dirty/list" "$tmp/dirty/lock"
    assert "dirty repo keeps HEAD" test "$(git -C "$tmp/dirty/work" rev-parse HEAD)" = "$dirty_head"
    assert "dirty repo keeps index" test "$(git -C "$tmp/dirty/work" diff --cached --name-only)" = "$dirty_index"
    assert "dirty repo remains dirty" test -n "$(git -C "$tmp/dirty/work" status --porcelain)"

    make_fixture "$tmp/untrackedhidden"
    git -C "$tmp/untrackedhidden/work" config status.showUntrackedFiles no
    printf 'human untracked\n' > "$tmp/untrackedhidden/work/untracked.txt"
    commit_in_repo "$tmp/untrackedhidden/other" "hidden-remote"
    git -C "$tmp/untrackedhidden/other" push >/dev/null
    write_list "$tmp/untrackedhidden/work" "$tmp/untrackedhidden/list"
    run_auto_git "$tmp/untrackedhidden/list" "$tmp/untrackedhidden/lock"
    assert "hidden untracked file keeps repo skipped" sh -c "! grep -q hidden-remote '$tmp/untrackedhidden/work/file.txt'"

    make_fixture "$tmp/behind"
    commit_in_repo "$tmp/behind/other" "behind"
    git -C "$tmp/behind/other" push >/dev/null
    local behind_remote_rev
    behind_remote_rev="$(git --git-dir="$tmp/behind/remote.git" rev-parse main)"
    write_list "$tmp/behind/work" "$tmp/behind/list"
    run_auto_git "$tmp/behind/list" "$tmp/behind/lock"
    assert "clean-behind repo pulls" grep -q "behind" "$tmp/behind/work/file.txt"
    assert "clean-behind fast-forwards exactly to fetched upstream" test "$(git -C "$tmp/behind/work" rev-parse HEAD)" = "$behind_remote_rev"
    assert "clean-behind creates no merge commit" test "$(git -C "$tmp/behind/work" rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" = "2"

    make_fixture "$tmp/ahead"
    commit_in_repo "$tmp/ahead/work" "ahead"
    write_list "$tmp/ahead/work" "$tmp/ahead/list"
    run_auto_git "$tmp/ahead/list" "$tmp/ahead/lock"
    git -C "$tmp/ahead/other" pull --ff-only >/dev/null
    assert "clean-ahead default branch pushes" grep -q "ahead" "$tmp/ahead/other/file.txt"

    make_fixture "$tmp/ignoredcollision"
    printf 'ignored.txt\n' > "$tmp/ignoredcollision/work/.gitignore"
    git -C "$tmp/ignoredcollision/work" add .gitignore
    git -C "$tmp/ignoredcollision/work" commit -m "ignore fixture" >/dev/null
    git -C "$tmp/ignoredcollision/work" push >/dev/null
    git -C "$tmp/ignoredcollision/other" pull --ff-only >/dev/null
    printf 'local ignored\n' > "$tmp/ignoredcollision/work/ignored.txt"
    printf 'remote tracked\n' > "$tmp/ignoredcollision/other/ignored.txt"
    git -C "$tmp/ignoredcollision/other" add -f ignored.txt
    git -C "$tmp/ignoredcollision/other" commit -m "track ignored path" >/dev/null
    git -C "$tmp/ignoredcollision/other" push >/dev/null
    write_list "$tmp/ignoredcollision/work" "$tmp/ignoredcollision/list"
    run_auto_git "$tmp/ignoredcollision/list" "$tmp/ignoredcollision/lock"
    assert "ignored local file blocks colliding pull" grep -q "local ignored" "$tmp/ignoredcollision/work/ignored.txt"
    assert "ignored collision path remains untracked" sh -c "! git -C '$tmp/ignoredcollision/work' ls-files --error-unmatch ignored.txt >/dev/null 2>&1"

    make_fixture "$tmp/ignoreddircollision"
    printf 'ignored-dir/\n' > "$tmp/ignoreddircollision/work/.gitignore"
    git -C "$tmp/ignoreddircollision/work" add .gitignore
    git -C "$tmp/ignoreddircollision/work" commit -m "ignore dir fixture" >/dev/null
    git -C "$tmp/ignoreddircollision/work" push >/dev/null
    git -C "$tmp/ignoreddircollision/other" pull --ff-only >/dev/null
    mkdir "$tmp/ignoreddircollision/work/ignored-dir"
    printf 'local ignored dir data\n' > "$tmp/ignoreddircollision/work/ignored-dir/cache.txt"
    printf 'remote tracked file\n' > "$tmp/ignoreddircollision/other/ignored-dir"
    git -C "$tmp/ignoreddircollision/other" add -f ignored-dir
    git -C "$tmp/ignoreddircollision/other" commit -m "track ignored dir path" >/dev/null
    git -C "$tmp/ignoreddircollision/other" push >/dev/null
    write_list "$tmp/ignoreddircollision/work" "$tmp/ignoreddircollision/list"
    run_auto_git "$tmp/ignoreddircollision/list" "$tmp/ignoreddircollision/lock"
    assert "ignored directory blocks colliding tracked file pull" grep -q "local ignored dir data" "$tmp/ignoreddircollision/work/ignored-dir/cache.txt"
    assert "ignored directory collision path remains untracked" sh -c "! git -C '$tmp/ignoreddircollision/work' ls-files --error-unmatch ignored-dir >/dev/null 2>&1"

    make_fixture "$tmp/ignoredparentcollision"
    printf 'ignored-parent\n' > "$tmp/ignoredparentcollision/work/.gitignore"
    git -C "$tmp/ignoredparentcollision/work" add .gitignore
    git -C "$tmp/ignoredparentcollision/work" commit -m "ignore parent fixture" >/dev/null
    git -C "$tmp/ignoredparentcollision/work" push >/dev/null
    git -C "$tmp/ignoredparentcollision/other" pull --ff-only >/dev/null
    printf 'local ignored parent file\n' > "$tmp/ignoredparentcollision/work/ignored-parent"
    mkdir "$tmp/ignoredparentcollision/other/ignored-parent"
    printf 'remote child\n' > "$tmp/ignoredparentcollision/other/ignored-parent/child.txt"
    git -C "$tmp/ignoredparentcollision/other" add -f ignored-parent/child.txt
    git -C "$tmp/ignoredparentcollision/other" commit -m "track child under ignored parent" >/dev/null
    git -C "$tmp/ignoredparentcollision/other" push >/dev/null
    write_list "$tmp/ignoredparentcollision/work" "$tmp/ignoredparentcollision/list"
    run_auto_git "$tmp/ignoredparentcollision/list" "$tmp/ignoredparentcollision/lock"
    assert "ignored parent file blocks colliding tracked child pull" grep -q "local ignored parent file" "$tmp/ignoredparentcollision/work/ignored-parent"
    assert "ignored parent collision path remains untracked" sh -c "! git -C '$tmp/ignoredparentcollision/work' ls-files --error-unmatch ignored-parent/child.txt >/dev/null 2>&1"

    make_fixture "$tmp/racepull"
    commit_in_repo "$tmp/racepull/other" "race-pull"
    git -C "$tmp/racepull/other" push >/dev/null
    cat > "$tmp/racepull/hook.sh" <<'EOF'
#!/usr/bin/env bash
repo="$1"
mode="$2"
if [ "$mode" = "pull" ]; then
    git -C "$repo" checkout -b race-side >/dev/null 2>&1
fi
EOF
    chmod +x "$tmp/racepull/hook.sh"
    write_list "$tmp/racepull/work" "$tmp/racepull/list"
    AUTO_GIT_TEST_BEFORE_MUTATE_HOOK="$tmp/racepull/hook.sh" run_auto_git "$tmp/racepull/list" "$tmp/racepull/lock"
    assert "branch race blocks pull mutation" sh -c "! grep -q race-pull '$tmp/racepull/work/file.txt'"

    make_fixture "$tmp/racepush"
    commit_in_repo "$tmp/racepush/work" "race-push"
    cat > "$tmp/racepush/hook.sh" <<'EOF'
#!/usr/bin/env bash
repo="$1"
mode="$2"
if [ "$mode" = "push" ]; then
    git -C "$repo" checkout -b race-side >/dev/null 2>&1
fi
EOF
    chmod +x "$tmp/racepush/hook.sh"
    write_list "$tmp/racepush/work" "$tmp/racepush/list"
    AUTO_GIT_TEST_BEFORE_MUTATE_HOOK="$tmp/racepush/hook.sh" run_auto_git "$tmp/racepush/list" "$tmp/racepush/lock"
    assert "branch race blocks push mutation" sh -c "! git --git-dir='$tmp/racepush/remote.git' show main:file.txt | grep -q race-push"

    make_fixture "$tmp/remotedefaultrace"
    git --git-dir="$tmp/remotedefaultrace/remote.git" branch side main
    commit_in_repo "$tmp/remotedefaultrace/work" "remote-default-race"
    cat > "$tmp/remotedefaultrace/hook.sh" <<EOF
#!/usr/bin/env bash
if [ "\$2" = "push" ]; then
    git --git-dir="$tmp/remotedefaultrace/remote.git" symbolic-ref HEAD refs/heads/side
fi
EOF
    chmod +x "$tmp/remotedefaultrace/hook.sh"
    write_list "$tmp/remotedefaultrace/work" "$tmp/remotedefaultrace/list"
    AUTO_GIT_TEST_BEFORE_MUTATE_HOOK="$tmp/remotedefaultrace/hook.sh" run_auto_git "$tmp/remotedefaultrace/list" "$tmp/remotedefaultrace/lock"
    assert "remote default race blocks push mutation" sh -c "! git --git-dir='$tmp/remotedefaultrace/remote.git' show main:file.txt | grep -q remote-default-race"

    make_fixture "$tmp/remoterefdeletepull"
    commit_in_repo "$tmp/remoterefdeletepull/other" "remote-ref-delete"
    git -C "$tmp/remoterefdeletepull/other" push >/dev/null
    cat > "$tmp/remoterefdeletepull/hook.sh" <<EOF
#!/usr/bin/env bash
if [ "\$2" = "pull" ]; then
    git --git-dir="$tmp/remoterefdeletepull/remote.git" update-ref -d refs/heads/main
fi
EOF
    chmod +x "$tmp/remoterefdeletepull/hook.sh"
    write_list "$tmp/remoterefdeletepull/work" "$tmp/remoterefdeletepull/list"
    AUTO_GIT_TEST_BEFORE_MUTATE_HOOK="$tmp/remoterefdeletepull/hook.sh" run_auto_git "$tmp/remoterefdeletepull/list" "$tmp/remoterefdeletepull/lock"
    assert "remote ref delete race blocks pull mutation" sh -c "! grep -q remote-ref-delete '$tmp/remoterefdeletepull/work/file.txt'"

    make_fixture "$tmp/remoterefracepush"
    local remote_ref_seed_rev
    remote_ref_seed_rev="$(git --git-dir="$tmp/remoterefracepush/remote.git" rev-parse main)"
    commit_in_repo "$tmp/remoterefracepush/other" "remote-ref-base"
    git -C "$tmp/remoterefracepush/other" push >/dev/null
    git -C "$tmp/remoterefracepush/work" pull --ff-only >/dev/null
    commit_in_repo "$tmp/remoterefracepush/work" "remote-ref-local"
    cat > "$tmp/remoterefracepush/hook.sh" <<EOF
#!/usr/bin/env bash
if [ "\$2" = "push" ]; then
    git --git-dir="$tmp/remoterefracepush/remote.git" update-ref refs/heads/main "$remote_ref_seed_rev"
fi
EOF
    chmod +x "$tmp/remoterefracepush/hook.sh"
    write_list "$tmp/remoterefracepush/work" "$tmp/remoterefracepush/list"
    AUTO_GIT_TEST_BEFORE_MUTATE_HOOK="$tmp/remoterefracepush/hook.sh" run_auto_git "$tmp/remoterefracepush/list" "$tmp/remoterefracepush/lock"
    assert "remote ref rewind race blocks push mutation" sh -c "! git --git-dir='$tmp/remoterefracepush/remote.git' show main:file.txt | grep -q remote-ref-local"

    make_fixture "$tmp/selfdotfiles"
    mkdir -p "$tmp/selfdotfiles/work/scripts"
    cp "$ROOT/scripts/git-sync-lock.sh" "$tmp/selfdotfiles/work/scripts/git-sync-lock.sh"
    printf 'REPOS=()\n' > "$tmp/selfdotfiles/work/manifest.sh"
    git -C "$tmp/selfdotfiles/work" add manifest.sh scripts/git-sync-lock.sh
    git -C "$tmp/selfdotfiles/work" commit -m "dotfiles shim" >/dev/null
    git -C "$tmp/selfdotfiles/work" push >/dev/null
    commit_in_repo "$tmp/selfdotfiles/work" "selfdotfiles"
    run_auto_git_as_dotfiles "$tmp/selfdotfiles/work"
    git -C "$tmp/selfdotfiles/other" pull --ff-only >/dev/null
    assert "dotfiles repo syncs while holding default shared lock" grep -q "selfdotfiles" "$tmp/selfdotfiles/other/file.txt"

    make_fixture "$tmp/legacydotlock"
    mkdir -p "$tmp/legacydotlock/work/scripts"
    cp "$ROOT/scripts/git-sync-lock.sh" "$tmp/legacydotlock/work/scripts/git-sync-lock.sh"
    printf 'REPOS=()\n' > "$tmp/legacydotlock/work/manifest.sh"
    git -C "$tmp/legacydotlock/work" add manifest.sh scripts/git-sync-lock.sh
    git -C "$tmp/legacydotlock/work" commit -m "dotfiles shim" >/dev/null
    git -C "$tmp/legacydotlock/work" push >/dev/null
    printf 'stale legacy lock\n' > "$tmp/legacydotlock/work/.git/dotfiles-git-sync.lock"
    commit_in_repo "$tmp/legacydotlock/work" "legacy-dot-lock"
    run_auto_git_as_dotfiles "$tmp/legacydotlock/work"
    git -C "$tmp/legacydotlock/other" pull --ff-only >/dev/null
    assert "stale legacy dotfiles lock does not block self-sync" grep -q "legacy-dot-lock" "$tmp/legacydotlock/other/file.txt"

    make_fixture "$tmp/statusfail"
    commit_in_repo "$tmp/statusfail/work" "statusfail"
    printf 'not a git index\n' > "$(git_marker_path "$tmp/statusfail/work" index)"
    write_list "$tmp/statusfail/work" "$tmp/statusfail/list"
    run_auto_git "$tmp/statusfail/list" "$tmp/statusfail/lock"
    assert "status failure does not push" sh -c "! git --git-dir='$tmp/statusfail/remote.git' show main:file.txt | grep -q statusfail"

    make_fixture "$tmp/gitlock"
    commit_in_repo "$tmp/gitlock/work" "gitlock"
    touch "$(git_marker_path "$tmp/gitlock/work" index.lock)"
    write_list "$tmp/gitlock/work" "$tmp/gitlock/list"
    run_auto_git "$tmp/gitlock/list" "$tmp/gitlock/lock"
    assert "active git lockfile does not push" sh -c "! git --git-dir='$tmp/gitlock/remote.git' show main:file.txt | grep -q gitlock"

    make_fixture "$tmp/misupstream"
    git --git-dir="$tmp/misupstream/remote.git" branch side main
    git -C "$tmp/misupstream/work" fetch origin side >/dev/null
    git -C "$tmp/misupstream/work" branch --set-upstream-to=origin/side main >/dev/null
    commit_in_repo "$tmp/misupstream/work" "misupstream"
    write_list "$tmp/misupstream/work" "$tmp/misupstream/list"
    run_auto_git "$tmp/misupstream/list" "$tmp/misupstream/lock"
    assert "default branch tracking non-default ref does not push" sh -c "! git --git-dir='$tmp/misupstream/remote.git' show side:file.txt | grep -q misupstream"

    assert "bash pulls with pinned fast-forward merge" grep -q -- 'merge --ff-only "$remote_rev"' "$ROOT/auto-git.sh"
    assert "powershell pulls with pinned fast-forward merge" grep -q -- 'merge --ff-only $remoteRev' "$ROOT/auto-git.ps1"
    assert "bash auto-git avoids autostash" not_grep "autostash" "$ROOT/auto-git.sh"
    assert "powershell auto-git avoids autostash" not_grep "autostash" "$ROOT/auto-git.ps1"
    assert "bash auto-git never aborts rebase" not_grep "rebase --abort" "$ROOT/auto-git.sh"
    assert "powershell auto-git never aborts rebase" not_grep "rebase --abort" "$ROOT/auto-git.ps1"

    make_fixture "$tmp/nonorigin"
    git -C "$tmp/nonorigin/work" remote rename origin upstream
    git -C "$tmp/nonorigin/work" branch --set-upstream-to=upstream/main main >/dev/null
    commit_in_repo "$tmp/nonorigin/work" "nonorigin"
    write_list "$tmp/nonorigin/work" "$tmp/nonorigin/list"
    run_auto_git "$tmp/nonorigin/list" "$tmp/nonorigin/lock"
    git -C "$tmp/nonorigin/other" pull --ff-only >/dev/null
    assert "non-origin upstream pushes" grep -q "nonorigin" "$tmp/nonorigin/other/file.txt"

    make_fixture "$tmp/diverged"
    local diverged_head
    commit_in_repo "$tmp/diverged/other" "remote"
    git -C "$tmp/diverged/other" push >/dev/null
    commit_in_repo "$tmp/diverged/work" "local"
    diverged_head="$(git -C "$tmp/diverged/work" rev-parse HEAD)"
    write_list "$tmp/diverged/work" "$tmp/diverged/list"
    run_auto_git "$tmp/diverged/list" "$tmp/diverged/lock"
    assert "diverged repo keeps local HEAD" test "$(git -C "$tmp/diverged/work" rev-parse HEAD)" = "$diverged_head"

    make_fixture "$tmp/inprogress"
    commit_in_repo "$tmp/inprogress/other" "blocked"
    git -C "$tmp/inprogress/other" push >/dev/null
    touch "$(git_marker_path "$tmp/inprogress/work" MERGE_HEAD)"
    write_list "$tmp/inprogress/work" "$tmp/inprogress/list"
    run_auto_git "$tmp/inprogress/list" "$tmp/inprogress/lock"
    assert "pre-existing git operation marker remains" test -e "$(git_marker_path "$tmp/inprogress/work" MERGE_HEAD)"
    assert "pre-existing git operation did not pull" sh -c "! grep -q blocked '$tmp/inprogress/work/file.txt'"

    make_fixture "$tmp/inprogressahead"
    commit_in_repo "$tmp/inprogressahead/work" "should-not-push"
    touch "$(git_marker_path "$tmp/inprogressahead/work" MERGE_HEAD)"
    write_list "$tmp/inprogressahead/work" "$tmp/inprogressahead/list"
    run_auto_git "$tmp/inprogressahead/list" "$tmp/inprogressahead/lock"
    assert "in-progress ahead repo does not push" sh -c "! git --git-dir='$tmp/inprogressahead/remote.git' show main:file.txt | grep -q should-not-push"

    make_fixture "$tmp/lockheld"
    commit_in_repo "$tmp/lockheld/other" "locked"
    git -C "$tmp/lockheld/other" push >/dev/null
    mkdir "$tmp/lockheld/lock"
    local owner_start
    owner_start="$(ps -o lstart= -p "$$" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
    [ -n "$owner_start" ] || owner_start="unknown"
    printf '{"pid":"%s","host":"%s","runtime":"%s","started_at":"1","heartbeat_at":"1","process_start":"%s"}\n' "$$" "$(hostname)" "$(current_bash_runtime)" "$owner_start" > "$tmp/lockheld/lock/owner.json"
    write_list "$tmp/lockheld/work" "$tmp/lockheld/list"
    run_auto_git "$tmp/lockheld/list" "$tmp/lockheld/lock"
    assert "live lock holder blocks auto-git" sh -c "! grep -q locked '$tmp/lockheld/work/file.txt'"

    make_fixture "$tmp/partiallock"
    commit_in_repo "$tmp/partiallock/other" "partial"
    git -C "$tmp/partiallock/other" push >/dev/null
    mkdir "$tmp/partiallock/lock"
    write_list "$tmp/partiallock/work" "$tmp/partiallock/list"
    run_auto_git "$tmp/partiallock/list" "$tmp/partiallock/lock"
    assert "partial owner lock is not reclaimed" test -d "$tmp/partiallock/lock"
    assert "partial owner lock blocks auto-git" sh -c "! grep -q partial '$tmp/partiallock/work/file.txt'"

    make_fixture "$tmp/incompletejsonlock"
    commit_in_repo "$tmp/incompletejsonlock/other" "incompletejson"
    git -C "$tmp/incompletejsonlock/other" push >/dev/null
    mkdir "$tmp/incompletejsonlock/dotfiles-git-sync.lock.d"
    printf '{"host":"%s","runtime":"%s","started_at":"1","heartbeat_at":"1","process_start":"dead"}\n' "$(hostname)" "$(current_bash_runtime)" > "$tmp/incompletejsonlock/dotfiles-git-sync.lock.d/owner.json"
    write_list "$tmp/incompletejsonlock/work" "$tmp/incompletejsonlock/list"
    run_auto_git "$tmp/incompletejsonlock/list" "$tmp/incompletejsonlock/dotfiles-git-sync.lock.d"
    assert "incomplete JSON owner lock is not reclaimed" test -d "$tmp/incompletejsonlock/dotfiles-git-sync.lock.d"
    assert "incomplete JSON owner lock blocks auto-git" sh -c "! grep -q incompletejson '$tmp/incompletejsonlock/work/file.txt'"

    make_fixture "$tmp/invalidpidlock"
    commit_in_repo "$tmp/invalidpidlock/other" "invalidpid"
    git -C "$tmp/invalidpidlock/other" push >/dev/null
    mkdir "$tmp/invalidpidlock/dotfiles-git-sync.lock.d"
    printf '{"pid":"not-a-pid","host":"%s","runtime":"%s","started_at":"1","heartbeat_at":"1","process_start":"dead"}\n' "$(hostname)" "$(current_bash_runtime)" > "$tmp/invalidpidlock/dotfiles-git-sync.lock.d/owner.json"
    write_list "$tmp/invalidpidlock/work" "$tmp/invalidpidlock/list"
    run_auto_git "$tmp/invalidpidlock/list" "$tmp/invalidpidlock/dotfiles-git-sync.lock.d"
    assert "invalid-pid owner lock is not reclaimed" test -d "$tmp/invalidpidlock/dotfiles-git-sync.lock.d"
    assert "invalid-pid owner lock blocks auto-git" sh -c "! grep -q invalidpid '$tmp/invalidpidlock/work/file.txt'"

    make_fixture "$tmp/deadlock"
    commit_in_repo "$tmp/deadlock/other" "deadlock"
    git -C "$tmp/deadlock/other" push >/dev/null
    mkdir "$tmp/deadlock/dotfiles-git-sync.lock.d"
    printf '{"pid":"99999999","host":"%s","runtime":"%s","started_at":"1","heartbeat_at":"1","process_start":"dead"}\n' "$(hostname)" "$(current_bash_runtime)" > "$tmp/deadlock/dotfiles-git-sync.lock.d/owner.json"
    write_list "$tmp/deadlock/work" "$tmp/deadlock/list"
    run_auto_git "$tmp/deadlock/list" "$tmp/deadlock/dotfiles-git-sync.lock.d"
    assert "same-runtime dead owner lock is reclaimed" grep -q "deadlock" "$tmp/deadlock/work/file.txt"

    make_fixture "$tmp/foreignlock"
    commit_in_repo "$tmp/foreignlock/other" "foreignlock"
    git -C "$tmp/foreignlock/other" push >/dev/null
    mkdir "$tmp/foreignlock/dotfiles-git-sync.lock.d"
    printf '{"pid":"99999999","host":"%s","runtime":"foreign-runtime","started_at":"1","heartbeat_at":"1","process_start":"dead"}\n' "$(hostname)" > "$tmp/foreignlock/dotfiles-git-sync.lock.d/owner.json"
    write_list "$tmp/foreignlock/work" "$tmp/foreignlock/list"
    run_auto_git "$tmp/foreignlock/list" "$tmp/foreignlock/dotfiles-git-sync.lock.d"
    assert "foreign-runtime lock is not reclaimed" test -d "$tmp/foreignlock/dotfiles-git-sync.lock.d"
    assert "foreign-runtime lock blocks auto-git" sh -c "! grep -q foreignlock '$tmp/foreignlock/work/file.txt'"

    echo "==> dormant trigger artifacts"
    local home_test="$tmp/home"
    mkdir -p "$home_test"
    GIT_AUTOSYNC_BOOTSTRAP_TEST_OS=Darwin GIT_AUTOSYNC_TEST_HOME="$home_test" bash "$ROOT/scripts/git-autosync-bootstrap.sh" >/dev/null
    assert "launchd artifact is disabled by default" grep -q "<key>Disabled</key><true/>" "$home_test/Library/LaunchAgents/com.ea.git-autosync.plist"
    GIT_AUTOSYNC_BOOTSTRAP_TEST_OS=Linux GIT_AUTOSYNC_TEST_HOME="$home_test" XDG_CONFIG_HOME="$tmp/config" XDG_STATE_HOME="$tmp/state" bash "$ROOT/scripts/git-autosync-bootstrap.sh" >/dev/null
    assert "linux dormant timer file exists" test -f "$tmp/config/systemd/user/git-autosync.timer"
    assert "powershell scheduled task registers disabled atomically" grep -q "<Enabled>false</Enabled>" "$ROOT/scripts/git-autosync-bootstrap.ps1"
    assert "powershell bootstrap does not register then disable" no_unconditional_task_disable "$ROOT/scripts/git-autosync-bootstrap.ps1"

    local cron_bin cron_state cron_home
    cron_bin="$tmp/cronbin"
    cron_state="$tmp/crontab.state"
    cron_home="$tmp/cronhome"
    mkdir -p "$cron_bin" "$cron_home"
    cat > "$cron_bin/crontab" <<'EOF'
#!/usr/bin/env bash
state="${GIT_AUTOSYNC_TEST_CRONTAB_STATE:?}"
if [ "${1:-}" = "-l" ]; then
    [ -f "$state" ] && cat "$state" || exit 1
    exit 0
fi
tmp="$state.tmp.$$"
cat > "$tmp"
mv "$tmp" "$state"
EOF
    chmod +x "$cron_bin/crontab"
    printf '0 0 * * * echo keep\n' > "$cron_state"
    GIT_AUTOSYNC_BOOTSTRAP_TEST_OS=Linux GIT_AUTOSYNC_TEST_NO_SYSTEMD=1 GIT_AUTOSYNC_TEST_HOME="$cron_home" \
        GIT_AUTOSYNC_TEST_CRONTAB_STATE="$cron_state" XDG_CONFIG_HOME="$tmp/cronconfig" XDG_STATE_HOME="$tmp/cronstate" \
        PATH="$cron_bin:$PATH" bash "$ROOT/scripts/git-autosync-bootstrap.sh" --enable >/dev/null
    assert "cron fallback installs tagged auto-git block" grep -q "# dotfiles git-autosync begin" "$cron_state"
    GIT_AUTOSYNC_BOOTSTRAP_TEST_OS=Linux GIT_AUTOSYNC_TEST_NO_SYSTEMD=1 GIT_AUTOSYNC_TEST_HOME="$cron_home" \
        GIT_AUTOSYNC_TEST_CRONTAB_STATE="$cron_state" XDG_CONFIG_HOME="$tmp/cronconfig" XDG_STATE_HOME="$tmp/cronstate" \
        PATH="$cron_bin:$PATH" bash "$ROOT/scripts/git-autosync-bootstrap.sh" --disable >/dev/null
    assert "cron fallback disable removes tagged auto-git block" sh -c "! grep -q '# dotfiles git-autosync begin' '$cron_state'"
    assert "cron fallback disable preserves unrelated cron entries" grep -q "echo keep" "$cron_state"

    local before_status after_status
    before_status="$(git -C "$ROOT" status --porcelain --untracked-files=all | grep 'dotfiles-git-sync' || true)"
    AUTO_GIT_NO_SELF_SNAPSHOT=1 AUTO_GIT_REPO_LIST_FILE="$tmp/ahead/list" bash "$ROOT/auto-git.sh" >/dev/null 2>&1
    after_status="$(git -C "$ROOT" status --porcelain --untracked-files=all | grep 'dotfiles-git-sync' || true)"
    assert "default lock path does not dirty dotfiles worktree" test "$before_status$after_status" = ""
}

revert_test() {
    local tmp
    tmp="$(mktemp -d "$TEST_TMP_PARENT/revert.XXXXXX")"
    AUTO_GIT_CHECK_TMP="$tmp"
    trap 'rm -rf "$AUTO_GIT_CHECK_TMP"' EXIT
    cp "$ROOT/auto-git.sh" "$tmp/auto-git.sh"
    printf '\ngit commit -m bad\n' >> "$tmp/auto-git.sh"
    if AUTO_GIT_SH="$tmp/auto-git.sh" AUTO_GIT_PS1="$ROOT/auto-git.ps1" bash "$0" --static-only >/dev/null 2>&1; then
        bad "revert-test forbidden operation was not caught"
    else
        ok "revert-test forbidden operation is caught"
    fi
    cp "$ROOT/auto-git.sh" "$tmp/auto-git-reset.sh"
    printf '\ngit reset --hard\n' >> "$tmp/auto-git-reset.sh"
    if AUTO_GIT_SH="$tmp/auto-git-reset.sh" AUTO_GIT_PS1="$ROOT/auto-git.ps1" bash "$0" --static-only >/dev/null 2>&1; then
        bad "revert-test destructive reset was not caught"
    else
        ok "revert-test destructive reset is caught"
    fi
    cp "$ROOT/auto-git.ps1" "$tmp/auto-git-clean.ps1"
    printf '\ngit clean -fd\n' >> "$tmp/auto-git-clean.ps1"
    if AUTO_GIT_SH="$ROOT/auto-git.sh" AUTO_GIT_PS1="$tmp/auto-git-clean.ps1" bash "$0" --static-only >/dev/null 2>&1; then
        bad "revert-test destructive clean was not caught"
    else
        ok "revert-test destructive clean is caught"
    fi
    cp "$ROOT/auto-git.ps1" "$tmp/auto-git-commit.ps1"
    printf '\ngit commit -m bad\n' >> "$tmp/auto-git-commit.ps1"
    if AUTO_GIT_SH="$ROOT/auto-git.sh" AUTO_GIT_PS1="$tmp/auto-git-commit.ps1" bash "$0" --static-only >/dev/null 2>&1; then
        bad "revert-test PowerShell commit was not caught"
    else
        ok "revert-test PowerShell commit is caught"
    fi
    cp "$ROOT/auto-git.sh" "$tmp/auto-git-pull.sh"
    printf '\ngit pull\n' >> "$tmp/auto-git-pull.sh"
    if AUTO_GIT_SH="$tmp/auto-git-pull.sh" AUTO_GIT_PS1="$ROOT/auto-git.ps1" bash "$0" --static-only >/dev/null 2>&1; then
        bad "revert-test plain pull was not caught"
    else
        ok "revert-test plain pull is caught"
    fi
    cp "$ROOT/auto-git.sh" "$tmp/auto-git-rebase.sh"
    printf '\ngit rebase @{u}\n' >> "$tmp/auto-git-rebase.sh"
    if AUTO_GIT_SH="$tmp/auto-git-rebase.sh" AUTO_GIT_PS1="$ROOT/auto-git.ps1" bash "$0" --static-only >/dev/null 2>&1; then
        bad "revert-test rebase was not caught"
    else
        ok "revert-test rebase is caught"
    fi
    cp "$ROOT/auto-git.sh" "$tmp/auto-git-switch.sh"
    printf '\ngit switch main\n' >> "$tmp/auto-git-switch.sh"
    if AUTO_GIT_SH="$tmp/auto-git-switch.sh" AUTO_GIT_PS1="$ROOT/auto-git.ps1" bash "$0" --static-only >/dev/null 2>&1; then
        bad "revert-test switch was not caught"
    else
        ok "revert-test switch is caught"
    fi
    cp "$ROOT/auto-git.sh" "$tmp/auto-git-merge.sh"
    printf '\ngit merge origin/main\n' >> "$tmp/auto-git-merge.sh"
    if AUTO_GIT_SH="$tmp/auto-git-merge.sh" AUTO_GIT_PS1="$ROOT/auto-git.ps1" bash "$0" --static-only >/dev/null 2>&1; then
        bad "revert-test non-ff merge was not caught"
    else
        ok "revert-test non-ff merge is caught"
    fi
    mkdir -p "$tmp/scripts" "$tmp/home"
    cp "$ROOT/scripts/git-autosync-bootstrap.sh" "$tmp/scripts/git-autosync-bootstrap.sh"
    sed 's#<key>Disabled</key><true/>#<key>Disabled</key><false/>#' \
        "$tmp/scripts/git-autosync-bootstrap.sh" > "$tmp/scripts/git-autosync-bootstrap.sh.next"
    mv "$tmp/scripts/git-autosync-bootstrap.sh.next" "$tmp/scripts/git-autosync-bootstrap.sh"
    GIT_AUTOSYNC_BOOTSTRAP_TEST_OS=Darwin GIT_AUTOSYNC_TEST_HOME="$tmp/home" bash "$tmp/scripts/git-autosync-bootstrap.sh" >/dev/null
    if grep -q "<key>Disabled</key><true/>" "$tmp/home/Library/LaunchAgents/com.ea.git-autosync.plist"; then
        bad "revert-test enabled launchd source was not caught"
    else
        ok "revert-test enabled launchd source is caught"
    fi
    cp "$ROOT/scripts/git-autosync-bootstrap.ps1" "$tmp/git-autosync-bootstrap.ps1"
    sed 's#<Enabled>false</Enabled>#<Enabled>true</Enabled>#' \
        "$tmp/git-autosync-bootstrap.ps1" > "$tmp/git-autosync-bootstrap.ps1.next"
    mv "$tmp/git-autosync-bootstrap.ps1.next" "$tmp/git-autosync-bootstrap.ps1"
    if grep -q "<Enabled>false</Enabled>" "$tmp/git-autosync-bootstrap.ps1"; then
        bad "revert-test enabled scheduled-task source was not caught"
    else
        ok "revert-test enabled scheduled-task source is caught"
    fi
}

if [ "${1:-}" = "--static-only" ]; then
    scan_file "$AUTO_SH" && scan_file "$AUTO_PS1"
    exit $?
fi

if [ "${1:-}" = "--revert-test" ]; then
    revert_test
else
    main_checks
fi

echo "auto-git safety: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
