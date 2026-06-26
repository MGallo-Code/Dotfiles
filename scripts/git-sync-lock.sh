#!/usr/bin/env bash
# Shared git-sync lock for manual sync.sh and auto-git.sh.
# GIT_SYNC_SHARED_LOCK

git_sync_lock_runtime() {
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

git_sync_lock_default_dir() {
    local git_common
    git_common="$(git -C "$DOTFILES_DIR" rev-parse --git-common-dir 2>/dev/null || printf '%s/.git' "$DOTFILES_DIR")"
    case "$git_common" in
        /*) ;;
        *) git_common="$DOTFILES_DIR/$git_common" ;;
    esac
    printf '%s\n' "${DOTFILES_GIT_SYNC_LOCK_DIR:-$git_common/dotfiles-git-sync.owner}"
}

git_sync_lock_json_value() {
    local file="$1"
    local key="$2"
    sed -nE 's/.*"'$key'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$file" 2>/dev/null | head -1
}

git_sync_lock_pid_alive() {
    local pid="$1"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null
}

git_sync_lock_process_start() {
    local pid="$1"
    ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
}

git_sync_lock_pid_matches_owner() {
    local pid="$1"
    local owner_process_start="$2"
    local live_process_start
    git_sync_lock_pid_alive "$pid" || return 1
    live_process_start="$(git_sync_lock_process_start "$pid")"
    if [ "$owner_process_start" != "unknown" ] && [ -n "$owner_process_start" ] && [ -n "$live_process_start" ] \
        && [ "$owner_process_start" != "$live_process_start" ]; then
        return 1
    fi
    return 0
}

git_sync_lock_valid_owner() {
    local owner="$1"
    local owner_pid="$2"
    local owner_host="$3"
    local owner_runtime="$4"
    local owner_started="$5"
    local owner_heartbeat="$6"
    local owner_process_start="$7"
    case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$owner_host" ] || return 1
    [ -n "$owner_runtime" ] || return 1
    case "$owner_started" in ''|*[!0-9]*) return 1 ;; esac
    case "$owner_heartbeat" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$owner_process_start" ] || return 1
    [ -s "$owner" ] || return 1
}

git_sync_lock_write_owner_file() {
    local owner_file="$1"
    local host runtime now process_start
    host="$(hostname 2>/dev/null || echo unknown)"
    runtime="$(git_sync_lock_runtime)"
    now="$(date +%s)"
    process_start="$(git_sync_lock_process_start "$$")"
    [ -n "$process_start" ] || process_start="unknown"
    cat > "$owner_file" <<EOF
{"pid":"$$","host":"$host","runtime":"$runtime","started_at":"$now","heartbeat_at":"$now","process_start":"$process_start"}
EOF
}

git_sync_lock_owner_path() {
    local lock_path="$1"
    if [ -d "$lock_path" ]; then
        printf '%s\n' "$lock_path/owner.json"
    else
        printf '%s\n' "$lock_path"
    fi
}

git_sync_lock_create() {
    local lock_path="$1"
    local parent base tmp_owner
    parent="$(dirname "$lock_path")"
    base="$(basename "$lock_path")"
    tmp_owner="$parent/.$base.$$.$RANDOM.tmp"
    if [ -e "$lock_path" ] || [ -L "$lock_path" ]; then
        return 1
    fi
    git_sync_lock_write_owner_file "$tmp_owner"
    if ln "$tmp_owner" "$lock_path" 2>/dev/null; then
        rm -f "$tmp_owner"
        return 0
    fi
    rm -f "$tmp_owner"
    return 1
}

git_sync_lock_release() {
    if [ "${GIT_SYNC_LOCK_ACQUIRED:-0}" != 1 ]; then
        return 0
    fi
    local owner
    owner="$(git_sync_lock_owner_path "$GIT_SYNC_LOCK_DIR_PATH")"
    if [ -f "$owner" ] && [ "$(git_sync_lock_json_value "$owner" pid)" = "$$" ]; then
        if [ -d "$GIT_SYNC_LOCK_DIR_PATH" ]; then
            rm -rf "$GIT_SYNC_LOCK_DIR_PATH"
        else
            rm -f "$GIT_SYNC_LOCK_DIR_PATH"
        fi
    fi
    GIT_SYNC_LOCK_ACQUIRED=0
}

git_sync_lock_release_and_exit() {
    local code="$1"
    git_sync_lock_release
    exit "$code"
}

git_sync_lock_try_reclaim() {
    local lock_dir="$1"
    local owner
    owner="$(git_sync_lock_owner_path "$lock_dir")"
    local owner_pid owner_host owner_runtime owner_started owner_heartbeat owner_process_start this_host this_runtime
    if [ ! -s "$owner" ]; then
        warn "git-sync lock: incomplete owner metadata at $lock_dir; not reclaiming automatically"
        return 1
    fi
    owner_pid="$(git_sync_lock_json_value "$owner" pid)"
    owner_host="$(git_sync_lock_json_value "$owner" host)"
    owner_runtime="$(git_sync_lock_json_value "$owner" runtime)"
    owner_started="$(git_sync_lock_json_value "$owner" started_at)"
    owner_heartbeat="$(git_sync_lock_json_value "$owner" heartbeat_at)"
    owner_process_start="$(git_sync_lock_json_value "$owner" process_start)"
    if ! git_sync_lock_valid_owner "$owner" "$owner_pid" "$owner_host" "$owner_runtime" "$owner_started" "$owner_heartbeat" "$owner_process_start"; then
        warn "git-sync lock: invalid owner metadata at $lock_dir; not reclaiming automatically"
        return 1
    fi
    this_host="$(hostname 2>/dev/null || echo unknown)"
    this_runtime="$(git_sync_lock_runtime)"
    if [ "$owner_host" != "$this_host" ] || [ "$owner_runtime" != "$this_runtime" ]; then
        warn "git-sync lock: held by $owner_host/$owner_runtime pid $owner_pid; not reclaiming across host/runtime"
        return 1
    fi
    if git_sync_lock_pid_matches_owner "$owner_pid" "$owner_process_start"; then
        warn "git-sync lock: already held by live pid $owner_pid; skipping"
        return 1
    fi
    case "$lock_dir" in
        *dotfiles-git-sync.owner|*dotfiles-git-sync.lock|*dotfiles-git-sync.lock.d)
            if [ -d "$lock_dir" ]; then
                rm -rf "$lock_dir"
            else
                rm -f "$lock_dir"
            fi
            ;;
        *) warn "git-sync lock: refusing to remove unexpected lock path $lock_dir"; return 1 ;;
    esac
    return 0
}

git_sync_lock_acquire() {
    local label="${1:-git-sync}"
    local lock_dir
    lock_dir="$(git_sync_lock_default_dir)"
    mkdir -p "$(dirname "$lock_dir")"
    if git_sync_lock_create "$lock_dir"; then
        GIT_SYNC_LOCK_DIR_PATH="$lock_dir"
        GIT_SYNC_LOCK_ACQUIRED=1
        trap git_sync_lock_release EXIT
        trap 'git_sync_lock_release_and_exit 130' INT
        trap 'git_sync_lock_release_and_exit 143' TERM
        ok "git-sync lock acquired ($label)"
        return 0
    fi
    if git_sync_lock_try_reclaim "$lock_dir" && git_sync_lock_create "$lock_dir"; then
        GIT_SYNC_LOCK_DIR_PATH="$lock_dir"
        GIT_SYNC_LOCK_ACQUIRED=1
        trap git_sync_lock_release EXIT
        trap 'git_sync_lock_release_and_exit 130' INT
        trap 'git_sync_lock_release_and_exit 143' TERM
        ok "git-sync lock reclaimed and acquired ($label)"
        return 0
    fi
    warn "git-sync lock unavailable ($label); another sync is running or manual cleanup is needed"
    return 1
}
