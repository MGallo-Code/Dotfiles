#!/usr/bin/env bash
set -uo pipefail

# AUTO_GIT_ENTRYPOINT
# Conservative document sync: pull/push already-committed work only.

DOTFILES_DIR="${DOTFILES_DIR_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "$DOTFILES_DIR/manifest.sh"

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

source "$DOTFILES_DIR/scripts/git-sync-lock.sh"

if [ -z "${AUTO_GIT_NO_SELF_SNAPSHOT:-}" ] && [ -z "${AUTO_GIT_SNAPSHOT_RUNNING:-}" ]; then
    tmp_script="$(mktemp "${TMPDIR:-/tmp}/auto-git.XXXXXX")"
    cp "${BASH_SOURCE[0]}" "$tmp_script"
    chmod +x "$tmp_script"
    export AUTO_GIT_SNAPSHOT_RUNNING=1
    export DOTFILES_DIR_OVERRIDE="$DOTFILES_DIR"
    exec bash "$tmp_script" "$@"
fi

repo_name() {
    basename "$1"
}

repo_paths() { # AUTO_GIT_REPO_UNION
    if [ -n "${AUTO_GIT_REPO_LIST_FILE:-}" ]; then
        while IFS= read -r repo; do
            [ -n "$repo" ] && printf '%s\n' "$repo"
        done < "$AUTO_GIT_REPO_LIST_FILE"
        return
    fi
    local entry
    if declare -p REPOS >/dev/null 2>&1 && [ "${#REPOS[@]}" -gt 0 ]; then
        for entry in "${REPOS[@]}"; do
            expand "${entry##*|}"
        done
    fi
    printf '%s\n' "$DOTFILES_DIR"
}

git_path() {
    local repo="$1"
    local marker="$2"
    local path
    path="$(git -C "$repo" rev-parse --path-format=absolute --git-path "$marker" 2>/dev/null \
        || git -C "$repo" rev-parse --git-path "$marker" 2>/dev/null \
        || true)"
    case "$path" in
        '') return 1 ;;
        /*) printf '%s\n' "$path" ;;
        *) printf '%s/%s\n' "$repo" "$path" ;;
    esac
}

git_path_exists() {
    local repo="$1"
    local marker="$2"
    local path
    path="$(git_path "$repo" "$marker" 2>/dev/null || true)"
    [ -n "$path" ] && [ -e "$path" ]
}

git_abs_dir() {
    local repo="$1"
    local flag="$2"
    local path
    path="$(git -C "$repo" rev-parse --path-format=absolute "$flag" 2>/dev/null \
        || git -C "$repo" rev-parse "$flag" 2>/dev/null \
        || true)"
    case "$path" in
        '') return 1 ;;
        /*) printf '%s\n' "$path" ;;
        *) printf '%s/%s\n' "$repo" "$path" ;;
    esac
}

git_lockfile_in_progress() {
    local repo="$1"
    local marker dir git_dir git_common lock
    for marker in index.lock HEAD.lock config.lock packed-refs.lock shallow.lock; do
        if git_path_exists "$repo" "$marker"; then
            return 0
        fi
    done
    git_dir="$(git_abs_dir "$repo" --git-dir 2>/dev/null || true)"
    git_common="$(git_abs_dir "$repo" --git-common-dir 2>/dev/null || true)"
    for dir in "$git_dir" "$git_common"; do
        [ -n "$dir" ] && [ -d "$dir" ] || continue
        while IFS= read -r lock; do
            [ -n "$lock" ] || continue
            if [ "$(basename "$lock")" = "dotfiles-git-sync.lock" ]; then
                continue
            fi
            return 0
        done < <(find "$dir" -name '*.lock' -type f -print 2>/dev/null)
    done
    return 1
}

git_operation_in_progress() {
    local repo="$1"
    local marker
    for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
        if git_path_exists "$repo" "$marker"; then
            return 0
        fi
    done
    if git_lockfile_in_progress "$repo"; then
        return 0
    fi
    return 1
}

repo_dirty_or_unreadable() {
    local status
    if ! status="$(git -C "$1" status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
        return 0
    fi
    [ -n "$status" ]
}

current_branch() {
    git -C "$1" symbolic-ref --short HEAD 2>/dev/null || true
}

remote_default_branch() {
    local repo="$1"
    local remote="$2"
    git -C "$repo" ls-remote --symref "$remote" HEAD 2>/dev/null \
        | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }'
}

remote_ref_oid() {
    local repo="$1"
    local remote="$2"
    local merge_ref="$3"
    git -C "$repo" ls-remote "$remote" "$merge_ref" 2>/dev/null \
        | awk -v ref="$merge_ref" '$2 == ref { print $1; exit }'
}

incoming_ignored_collision() {
    local repo="$1"
    local local_rev="$2"
    local remote_rev="$3"
    local path check
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        check="$path"
        while [ -n "$check" ] && [ "$check" != "." ]; do
            if git -C "$repo" ls-files --others --ignored --exclude-standard -- "$check" 2>/dev/null | grep -q .; then
                return 0
            fi
            case "$check" in
                */*) check="${check%/*}" ;;
                *) break ;;
            esac
        done
    done < <(git -C "$repo" diff --name-only --diff-filter=ACMRT "$local_rev" "$remote_rev" -- 2>/dev/null)
    return 1
}

run_test_before_mutate_hook() {
    if [ -n "${AUTO_GIT_TEST_BEFORE_MUTATE_HOOK:-}" ] && [ -x "$AUTO_GIT_TEST_BEFORE_MUTATE_HOOK" ]; then
        "$AUTO_GIT_TEST_BEFORE_MUTATE_HOOK" "$@" >/dev/null 2>&1 || true
    fi
}

revalidate_repo_state() {
    local repo="$1"
    local name="$2"
    local branch="$3"
    local remote="$4"
    local merge_ref="$5"
    local local_rev="$6"
    local remote_rev="$7"
    local current_branch current_remote current_merge_ref current_local_rev current_remote_rev

    if repo_dirty_or_unreadable "$repo"; then
        warn "$name: became dirty or unreadable before mutation - skipped"
        return 1
    fi
    if git_operation_in_progress "$repo"; then
        warn "$name: git operation appeared before mutation - skipped"
        return 1
    fi
    current_branch="$(current_branch "$repo")"
    if [ "$current_branch" != "$branch" ]; then
        warn "$name: branch changed before mutation - skipped"
        return 1
    fi
    current_remote="$(git -C "$repo" config "branch.$branch.remote" 2>/dev/null || true)"
    current_merge_ref="$(git -C "$repo" config "branch.$branch.merge" 2>/dev/null || true)"
    if [ "$current_remote" != "$remote" ] || [ "$current_merge_ref" != "$merge_ref" ]; then
        warn "$name: upstream config changed before mutation - skipped"
        return 1
    fi
    current_local_rev="$(git -C "$repo" rev-parse @ 2>/dev/null || true)"
    current_remote_rev="$(git -C "$repo" rev-parse '@{u}' 2>/dev/null || true)"
    if [ "$current_local_rev" != "$local_rev" ] || [ "$current_remote_rev" != "$remote_rev" ]; then
        warn "$name: ref state changed before mutation - skipped"
        return 1
    fi
    return 0
}

revalidate_remote_default_branch() {
    local repo="$1"
    local name="$2"
    local remote="$3"
    local expected_default_branch="$4"
    local current_default_branch

    current_default_branch="$(remote_default_branch "$repo" "$remote")"
    if [ -z "$current_default_branch" ] || [ "$current_default_branch" != "$expected_default_branch" ]; then
        warn "$name: remote default branch changed before push - skipped"
        return 1
    fi
    return 0
}

revalidate_remote_ref_oid() {
    local repo="$1"
    local name="$2"
    local remote="$3"
    local merge_ref="$4"
    local expected_oid="$5"
    local current_oid

    current_oid="$(remote_ref_oid "$repo" "$remote" "$merge_ref")"
    if [ -z "$current_oid" ] || [ "$current_oid" != "$expected_oid" ]; then
        warn "$name: remote ref changed after fetch - skipped"
        return 1
    fi
    return 0
}

sync_one_repo() {
    local repo="$1"
    local name
    name="$(repo_name "$repo")"

    if [ ! -d "$repo" ] || ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        warn "$name: missing or not a git worktree - skipped"
        return 0
    fi
    if repo_dirty_or_unreadable "$repo"; then
        warn "$name: dirty or unreadable worktree - skipped"
        return 0
    fi
    if git_operation_in_progress "$repo"; then
        warn "$name: git operation in progress - skipped"
        return 0
    fi

    local branch upstream remote merge_ref default_branch
    branch="$(current_branch "$repo")"
    if [ -z "$branch" ]; then
        warn "$name: detached HEAD - skipped"
        return 0
    fi
    upstream="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    remote="$(git -C "$repo" config "branch.$branch.remote" 2>/dev/null || true)"
    merge_ref="$(git -C "$repo" config "branch.$branch.merge" 2>/dev/null || true)"
    if [ -z "$upstream" ] || [ -z "$remote" ] || [ -z "$merge_ref" ]; then
        warn "$name: no configured upstream - skipped"
        return 0
    fi

    if ! git -C "$repo" fetch "$remote" >/dev/null 2>&1; then
        err "$name: fetch failed - skipped"
        return 0
    fi
    if repo_dirty_or_unreadable "$repo"; then
        warn "$name: became dirty or unreadable after fetch - skipped"
        return 0
    fi
    if git_operation_in_progress "$repo"; then
        warn "$name: git operation appeared after fetch - skipped"
        return 0
    fi

    local local_rev remote_rev base_rev
    local_rev="$(git -C "$repo" rev-parse @ 2>/dev/null || true)"
    remote_rev="$(git -C "$repo" rev-parse '@{u}' 2>/dev/null || true)"
    base_rev="$(git -C "$repo" merge-base @ '@{u}' 2>/dev/null || true)"
    if [ -z "$local_rev" ] || [ -z "$remote_rev" ] || [ -z "$base_rev" ]; then
        warn "$name: cannot classify history - skipped"
        return 0
    fi

    if [ "$local_rev" = "$remote_rev" ]; then
        ok "$name: up to date"
    elif [ "$local_rev" = "$base_rev" ]; then
        run_test_before_mutate_hook "$repo" pull "$branch" "$local_rev" "$remote_rev" "$merge_ref"
        if ! revalidate_repo_state "$repo" "$name" "$branch" "$remote" "$merge_ref" "$local_rev" "$remote_rev"; then
            return 0
        fi
        if incoming_ignored_collision "$repo" "$local_rev" "$remote_rev"; then
            warn "$name: incoming tracked path collides with ignored local file - skipped"
            return 0
        fi
        if ! revalidate_repo_state "$repo" "$name" "$branch" "$remote" "$merge_ref" "$local_rev" "$remote_rev"; then
            return 0
        fi
        if ! revalidate_remote_ref_oid "$repo" "$name" "$remote" "$merge_ref" "$remote_rev"; then
            return 0
        fi
        if git -C "$repo" merge --ff-only "$remote_rev" >/dev/null 2>&1; then
            ok "$name: pulled updates"
        else
            err "$name: fast-forward failed - skipped"
        fi
    elif [ "$remote_rev" = "$base_rev" ]; then
        default_branch="$(remote_default_branch "$repo" "$remote")"
        if [ -z "$default_branch" ]; then
            warn "$name: cannot determine $remote default branch - skipped"
            return 0
        fi
        if [ "$branch" != "$default_branch" ]; then
            warn "$name: ahead on non-default branch $branch - skipped"
            return 0
        fi
        if [ "$merge_ref" != "refs/heads/$default_branch" ]; then
            warn "$name: upstream $merge_ref is not $remote default branch - skipped"
            return 0
        fi
        run_test_before_mutate_hook "$repo" push "$branch" "$local_rev" "$remote_rev" "$merge_ref"
        if ! revalidate_repo_state "$repo" "$name" "$branch" "$remote" "$merge_ref" "$local_rev" "$remote_rev"; then
            return 0
        fi
        if ! revalidate_remote_default_branch "$repo" "$name" "$remote" "$default_branch"; then
            return 0
        fi
        if ! revalidate_remote_ref_oid "$repo" "$name" "$remote" "$merge_ref" "$remote_rev"; then
            return 0
        fi
        if git -C "$repo" push --force-with-lease="$merge_ref:$remote_rev" "$remote" "$local_rev:$merge_ref" >/dev/null 2>&1; then
            ok "$name: pushed committed work"
        else
            err "$name: push failed - skipped"
        fi
    else
        warn "$name: diverged from upstream - skipped"
    fi
}

git_sync_lock_acquire "auto-git" || exit 0

while IFS= read -r repo; do
    sync_one_repo "$repo"
done < <(repo_paths)
