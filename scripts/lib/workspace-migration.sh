# workspace-migration.sh - ADR-0007: the synced repos leave ~/Documents for ~/Workspace (INV-21).
# Sourced by manifest.sh; uses its WORKSPACE_* settings, is_mcp_host, expand, ok and warn.
# Windows twin: workspace-migration.ps1. Path rewriting is shared: ws_paths.py.
#
# migrate_to_workspace          move each repo once (all or nothing), repair worktrees, rewrite git
#                               config, Codex paths and Claude memory keys, drop venvs that name the old
#                               path, park retired clones; journal every step; non-zero on any skip
# apply_pending_workspace_paths point this run's repo lists at the old home while a move is pending
#                               (the MCP host until its window), so nothing dangles or is re-cloned
# workspace_home NAME           where repo NAME lives on this machine right now
# rollback_workspace_migration  replay the journal in reverse (scripts/workspace-rollback.sh)

WS_PATHS_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ws_paths.py"

# Every machine moves only when armed: its WORKSPACE_MOVE_GATE says "now" (written over SSH per
# machine, and on the MCP host at its window). Until then nothing moves or retires there, and every
# list points at the real old home.
workspace_move_deferred() {
    [ "$(cat "$(expand "$WORKSPACE_MOVE_GATE")" 2>/dev/null)" != "now" ]
}

# macOS: give ~/Workspace the ACL ~/Documents carries, so nothing can rename the root away.
_ws_protect_root() {
    local root; root="$(expand "$WORKSPACE_DIR")"
    mkdir -p "$root"
    [ "$(uname -s)" = Darwin ] || return 0
    ls -led "$root" 2>/dev/null | grep -q "group:everyone deny delete" && return 0
    chmod +a "group:everyone deny delete" "$root" 2>/dev/null && ok "workspace: $root protected against delete and rename" \
        || warn "workspace: could not set the delete-protection ACL on $root"
}

# The old home wins while it still holds the repo: a stray clone or an empty folder at the new home
# never switches anything (the live services keep running from the old home until its window).
workspace_home() {
    local new old
    new="$(expand "$WORKSPACE_DIR")/$1"; old="$(expand "$LEGACY_REPO_HOME")/$1"
    if [ -e "$old/.git" ]; then echo "$old"; else echo "$new"; fi
}

# Rewrite "~/Workspace/NAME" to "~/Documents/NAME" in this run's lists for every move still pending.
apply_pending_workspace_paths() {
    local spec name from to
    for spec in "${WORKSPACE_MOVES[@]}"; do
        name="${spec%%|*}"
        [ "$(workspace_home "$name")" = "$(expand "$LEGACY_REPO_HOME")/$name" ] || continue
        from="$WORKSPACE_DIR/$name"; to="$LEGACY_REPO_HOME/$name"
        REPOS=("${REPOS[@]//"$from"/$to}")
        EA_REPOS=("${EA_REPOS[@]//"$from"/$to}")
        HOST_REPOS=("${HOST_REPOS[@]//"$from"/$to}")
        CODEX_PROJECT_SKILLS=("${CODEX_PROJECT_SKILLS[@]//"$from"/$to}")
    done
}

_ws_journal() {
    local j; j="$(expand "$WORKSPACE_JOURNAL")"
    mkdir -p "$(dirname "$j")" && printf '%s\n' "$1" >> "$j"
}

_ws_same_remote() {
    local url; url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
    [ "$(python3 "$WS_PATHS_PY" owner-repo "$url")" = "$(python3 "$WS_PATHS_PY" owner-repo "$2")" ]
}

# 0 when any process has its working directory inside $1: a shell, editor or agent there, including
# the one that started this sync (migrate_to_workspace runs from $HOME, so this process never counts).
# Fails closed (0) when there is no way to look (no /proc, no lsof).
_ws_busy() {
    local dir p cwd
    dir="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
    if [ -d /proc/self ]; then
        for p in /proc/[0-9]*; do
            cwd="$(readlink "$p/cwd" 2>/dev/null)" || continue
            case "$cwd" in "$dir"|"$dir"/*) return 0 ;; esac
        done
        return 1
    fi
    if command -v lsof >/dev/null 2>&1; then
        # lsof exits 1 whenever some process can't be read; capture first so pipefail can't mask a hit.
        local listing; listing="$(lsof -a -d cwd -F n 2>/dev/null || true)"
        printf '%s\n' "$listing" | awk -v d="$dir" '
            /^n/ { n = substr($0, 2); if (n == d || index(n, d "/") == 1) f = 1 }
            END { exit f ? 0 : 1 }'
        return $?
    fi
    warn "workspace: no /proc and no lsof, so no way to see who is working in $1 - not moving it"
    return 0
}

# 0 when $1 holds an iCloud-only (dataless) file, or when that can't be checked (fails closed: a
# permissions error over SSH must block, not pass). macOS's own find; elsewhere there is no iCloud.
_ws_dataless() {
    local hit
    [ "$(uname -s)" = Darwin ] || return 1
    hit="$(/usr/bin/find "$1" -flags +dataless -print -quit 2>/dev/null)" || return 0
    [ -n "$hit" ]
}

_ws_rewrite() {
    local n
    [ -f "$1" ] || return 0
    n="$(python3 "$WS_PATHS_PY" rewrite "$1" "$2" "$3")" || { warn "workspace: could not rewrite paths in $1"; return 1; }
    [ "${n:-0}" -gt 0 ] && _ws_journal "rewrite|$1|$2|$3" && ok "workspace: $n path(s) in $1 point at $3"
    return 0
}

_ws_move_one() {
    local old="$1" new="$2" wt gold="" inside=() line f v
    # The first entry is the repo itself, in git's own spelling of $old (C:/... under Git Bash, not /c/...).
    while IFS= read -r line; do
        case "$line" in "worktree "*)
            wt="${line#worktree }"
            if [ -z "$gold" ]; then gold="$wt"
            elif [ "${wt#"$gold"/}" != "$wt" ]; then inside+=("$new/${wt#"$gold"/}"); fi ;;
        esac
    done < <(git -C "$old" worktree list --porcelain 2>/dev/null)
    mkdir -p "$(dirname "$new")"
    mv "$old" "$new" || { warn "workspace: could not move $old"; return 1; }
    _ws_journal "repo|$old|$new"; ok "workspace: moved $old -> $new"
    git -C "$new" worktree repair ${inside[@]+"${inside[@]}"} >/dev/null 2>&1 \
        || warn "workspace: git worktree repair reported a problem in $new (run it there by hand)"
    for f in "$new/.git/config" "$new"/.git/worktrees/*/config.worktree; do _ws_rewrite "$f" "$old" "$new" || true; done
    _ws_rewrite "$HOME/.codex/config.toml" "$old" "$new" || true
    while IFS= read -r line; do
        case "$line" in
            memory\|*) _ws_journal "$line"; ok "workspace: Claude memory ${line##*/}" ;;
            warn\|*) warn "workspace: ${line#warn|}" ;;
        esac
    done < <(python3 "$WS_PATHS_PY" memory "$HOME/.claude/projects" "$old" "$new")
    while IFS= read -r v; do
        v="${v%$'\r'}"   # Windows Python ends lines with CRLF
        if [ -n "$v" ]; then rm -rf "$v" && ok "workspace: removed $v (it named the old path; it rebuilds on next use)"; fi
    done < <(python3 "$WS_PATHS_PY" venvs "$new" "$old")
    return 0
}

# Park a clone that retires instead of moving (agent-skills everywhere; GalloGrid on a client), only
# when nothing in it is uncommitted, unpushed or stashed, nothing is iCloud-only, and (with $3, the
# commit dotfiles imported) nothing in it or on its origin is newer than that import. Never deleted.
_ws_retire_clone() {
    local remote="$1" old="$2" imported="${3:-}" dest ref
    [ -e "$old/.git" ] || return 0
    _ws_same_remote "$old" "$remote" || { warn "workspace: $old is not a clone of $remote - left as is"; return 1; }
    git -C "$old" fetch -q 2>/dev/null || true
    if [ -n "$imported" ]; then
        for ref in HEAD refs/remotes/origin/main; do
            git -C "$old" rev-parse -q --verify "$ref" >/dev/null 2>&1 || continue
            if ! git -C "$old" merge-base --is-ancestor "$ref" "$imported" 2>/dev/null; then
                warn "workspace: $old has commits after the dotfiles import ($imported) on $ref - kept; fold them in (git subtree pull), then re-run sync"
                return 1
            fi
        done
    fi
    if _ws_dataless "$old"; then warn "workspace: $old has iCloud-only files (or could not be checked) - kept; download them, then re-run sync"; return 1; fi
    if [ -n "$(git -C "$old" status --porcelain 2>/dev/null | head -1)" ] \
        || [ -n "$(git -C "$old" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ] \
        || [ -n "$(git -C "$old" stash list 2>/dev/null | head -1)" ]; then
        warn "workspace: $old has uncommitted, unpushed or stashed work - kept; push or clear it, then re-run sync"
        return 1
    fi
    if _ws_busy "$old"; then warn "workspace: a process is working in $old - kept; close it, then re-run sync"; return 1; fi
    dest="$(expand "$RETIRED_CLONE_DIR")/$(basename "$old")-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$(dirname "$dest")"
    mv "$old" "$dest" || { warn "workspace: could not park $old"; return 1; }
    _ws_journal "park|$old|$dest"; ok "workspace: retired $old -> $dest (its ignored files came along; check them before deleting it)"
}

migrate_to_workspace() {
    local spec name remote scope imported old new entry blocked=0 pending=() retire=() switch
    cd "$HOME" || return 1
    for spec in "${WORKSPACE_MOVES[@]}"; do
        IFS='|' read -r name remote scope <<< "$spec"
        old="$(expand "$LEGACY_REPO_HOME")/$name"; new="$(expand "$WORKSPACE_DIR")/$name"
        if [ "$scope" = host ] && ! is_mcp_host; then [ -e "$old/.git" ] && retire+=("$remote|$old|"); continue; fi
        [ -e "$old/.git" ] || continue
        if [ -e "$new" ]; then
            warn "workspace: both $old and $new exist - left as is; keep one and move or remove the other by hand"
            blocked=1; continue
        fi
        _ws_same_remote "$old" "$remote" || { warn "workspace: $old is not a clone of $remote - not moved"; blocked=1; continue; }
        pending+=("$old|$new")
    done
    for spec in "${WORKSPACE_RETIRED_CLONES[@]}"; do
        IFS='|' read -r name remote imported <<< "$spec"
        old="$(expand "$LEGACY_REPO_HOME")/$name"
        [ -e "$old/.git" ] && retire+=("$remote|$old|$imported")
    done
    if workspace_move_deferred; then
        if [ $(( ${#pending[@]} + ${#retire[@]} )) -gt 0 ]; then
            ok "workspace: waiting for this machine's move ($(( ${#pending[@]} + ${#retire[@]} )) repo(s) still in $(expand "$LEGACY_REPO_HOME")); arm it with: echo now > $WORKSPACE_MOVE_GATE"
        fi
        [ "$blocked" = 0 ]; return
    fi
    if [ ${#pending[@]} -gt 0 ]; then
        local preflight=0
        for entry in "${pending[@]}"; do
            old="${entry%%|*}"
            if _ws_busy "$old"; then warn "workspace: a process is working in $old - close it (or cd out), then re-run"; preflight=1; fi
            if _ws_dataless "$old"; then warn "workspace: $old has iCloud-only files - download them (Finder: Download Now), then re-run"; preflight=1; fi
        done
        if [ "$preflight" = 0 ]; then
            _ws_protect_root
            for entry in "${pending[@]}"; do _ws_move_one "${entry%%|*}" "${entry##*|}" || blocked=1; done
        else
            warn "workspace: nothing moved (the repos move together or not at all)"; blocked=1
        fi
    fi
    if [ ${#retire[@]} -gt 0 ]; then
        for entry in "${retire[@]}"; do
            IFS='|' read -r remote old imported <<< "$entry"
            _ws_retire_clone "$remote" "$old" "$imported" || blocked=1
        done
    fi
    # The switch file goes only once nothing here is still waiting to move.
    switch="$(expand "$RETIRED_CODE_ROOT_SWITCH")"
    if [ -f "$switch" ] && [ "$blocked" = 0 ]; then
        _ws_journal "switch|$switch|$(cat "$switch")"; rm -f "$switch" && ok "workspace: retired the code-root switch file"
    fi
    [ "$blocked" = 0 ]
}

rollback_workspace_migration() {
    local j kind a b c
    j="$(expand "$WORKSPACE_JOURNAL")"
    [ -f "$j" ] || { warn "workspace rollback: no journal at $j - nothing to undo"; return 1; }
    cd "$HOME" || return 1
    while IFS='|' read -r kind a b c; do
        case "$kind" in
            rewrite) python3 "$WS_PATHS_PY" rewrite "$a" "$c" "$b" >/dev/null && ok "rollback: paths in $a back to $b" ;;
            memory) if [ -d "$b" ] && [ ! -e "$a" ]; then mv "$b" "$a" && ok "rollback: Claude memory ${a##*/}"; fi ;;
            repo) if [ -d "$b" ] && [ ! -e "$a" ]; then
                      mv "$b" "$a" && git -C "$a" worktree repair >/dev/null 2>&1; ok "rollback: moved $b -> $a"
                  else warn "rollback: $b missing or $a exists - $a not restored"; fi ;;
            park) if [ -d "$b" ] && [ ! -e "$a" ]; then mv "$b" "$a" && ok "rollback: restored $a"; fi ;;
            switch) printf '%s\n' "$b" > "$a" && ok "rollback: restored $a" ;;
        esac
    done < <(awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' "$j")
    mv "$j" "$j.rolled-back-$(date +%Y%m%d-%H%M%S)"
    warn "rollback: inside-repo worktrees need 'git worktree repair <path>' if listed broken; removed venvs rebuild on use"
}
