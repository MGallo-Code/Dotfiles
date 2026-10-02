#!/usr/bin/env bash
set -uo pipefail

# Sync all managed repos - pull updates, detect local changes, hand off to Claude for commits

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # BASH_SOURCE (not $0) so the
source "$DOTFILES_DIR/manifest.sh"                            # path is right when SOURCED too

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

ensure_agent_defaults() { # AGENT_DEFAULTS_CONFIG
    local codex_config="$HOME/.codex/config.toml"
    mkdir -p "$HOME/.codex"

    if ! command -v python3 >/dev/null 2>&1; then
        err "Agent defaults require python3; refusing partial configuration"
        return 1
    fi
    if ! python3 "$DOTFILES_DIR/scripts/configure-codex-defaults.py" --home "$HOME" >/dev/null; then
        err "Codex settings are unsupported or inaccessible; defaults were not changed"
        return 1
    fi

    ok "Codex: defaults set (xhigh reasoning + full-access permissions)"

    # CODEX_PIN drift check (pin is canonical in manifest.sh; parity: sync.ps1 $CodexPin).
    # Warn-only: sync can't fix a version mismatch itself, and a blocked sync is worse.
    if command -v codex >/dev/null 2>&1 && [ -n "${CODEX_PIN:-}" ]; then
        local codex_installed
        codex_installed="$(codex --version 2>/dev/null | awk '{print $2}')"
        if [ "$codex_installed" != "$CODEX_PIN" ]; then
            warn "Codex $codex_installed drifts from pin $CODEX_PIN - preflight (scripts/codex-pin-preflight.sh), then: npm install -g @openai/codex@$CODEX_PIN"
        fi
    fi

    # Codex PreToolUse guards. Registration is machine-local in config.toml; scripts ride the
    # Claude global-hooks symlink. Trust once via the Codex `/hooks` TUI. Idempotent by the
    # COMMAND path, not the marker comment: Codex rewrites config.toml and strips the comment
    # (the block/command survive), so keying on the marker re-appended a duplicate block each sync.
    ensure_codex_pretooluse_hook() {
        local marker="$1" command="$2" label="$3"
        if ! grep -qF "$command" "$codex_config"; then
        cat >> "$codex_config" <<EOF

$marker
[[hooks.PreToolUse]]
matcher = "^Bash\$"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = "$command"
  timeout = 30
EOF
            ok "Codex: wired $label (run /hooks once to trust it)"
        else
            ok "Codex $label already wired"
        fi
    }
    ensure_codex_pretooluse_hook "# dotfiles: flat-PR stacked-push guard" "$HOME/.claude/hooks/warn-stacked-git-push.sh" "stacked-push guard"

    if ! python3 "$DOTFILES_DIR/scripts/configure-claude-defaults.py" --home "$HOME" >/dev/null; then
        err "Claude settings are malformed or inaccessible; defaults were not changed"
        return 1
    fi
    ok "Claude: user default permission mode set (auto)"

    local gemini_settings="$HOME/.gemini/settings.json"
    mkdir -p "$HOME/.gemini"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$gemini_settings" <<'PYJSON'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
except json.JSONDecodeError:
    data = {}
if not isinstance(data, dict):
    data = {}
general = data.setdefault("general", {})
if not isinstance(general, dict):
    general = {}
    data["general"] = general
general["defaultApprovalMode"] = "auto_edit"
# Keep Gemini focused on source/control-plane roots. Do not append broad parents or
# agent-state dirs; that caused reviews to roam caches, downloads, and stale generated
# content after sync.
gemini_workspace_roots = [
    os.path.expanduser("~/.dotfiles"),
    os.path.expanduser("~/.config/nvim"),
]
# EA everywhere, GalloGrid on the host: wherever each is now (ADR-0007: the old ~/Documents home
# while it still holds the repo, else ~/Workspace). A missing dir is never listed.
def _ws_home(name):
    old = os.path.join(os.path.expanduser("~"), "Documents", name)
    new = os.path.join(os.path.expanduser("~"), "Workspace", name)
    if os.path.isdir(os.path.join(old, ".git")):
        return old
    return new if os.path.isdir(new) else None
gemini_workspace_roots = [p for p in [_ws_home("EA")] if p] + gemini_workspace_roots
gemini_workspace_roots += [p for p in [_ws_home("GalloGrid")] if p]
context = data.setdefault("context", {})
if not isinstance(context, dict):
    context = {}
    data["context"] = context
context["includeDirectories"] = gemini_workspace_roots
tools = data.setdefault("tools", {})
if not isinstance(tools, dict):
    tools = {}
    data["tools"] = tools
tools["sandboxAllowedPaths"] = gemini_workspace_roots
tools["sandboxNetworkAccess"] = True
security = data.setdefault("security", {})
if not isinstance(security, dict):
    security = {}
    data["security"] = security
auth = security.setdefault("auth", {})
if not isinstance(auth, dict):
    auth = {}
    security["auth"] = auth
auth["selectedType"] = "gemini-api-key"
model = data.setdefault("model", {})
if not isinstance(model, dict):
    model = {}
    data["model"] = model
model["name"] = "gemini-3.1-flash-lite"
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYJSON
        ok "Gemini: defaults set (auto_edit + workspace roots + gemini-3.1-flash-lite API-key auth)"
    else
        warn "Gemini defaults: python3 not found - skipping settings.json update"
    fi
}

ensure_gemini_cross_check_setup() { # GEMINI_CROSS_CHECK_SETUP
    local script="$DOTFILES_DIR/scripts/setup-gemini-cross-check.sh"
    if ! command -v gemini >/dev/null 2>&1; then
        warn "Gemini cross-check: gemini CLI not found - install Gemini, then rerun sync"
        return
    fi
    if [ ! -x "$script" ]; then
        warn "Gemini cross-check: setup script missing at $script"
        return
    fi

    if [ -n "${GEMINI_API_KEY:-}" ]; then
        ok "Gemini cross-check setup present"
        return
    fi
    if command -v security >/dev/null 2>&1 \
        && security find-generic-password -a "${USER:-michael}" -s ea-gemini-api-key -w >/dev/null 2>&1 \
        && [ -x "$HOME/.local/bin/gemini-flash-lite" ]; then
        ok "Gemini cross-check setup present"
        return
    fi

    warn "Gemini cross-check setup incomplete - launching installer"
    "$script" || warn "Gemini cross-check setup incomplete; rerun: $script"
}

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
        # The live nexus DB is intentionally tracked but churns every sync (the
        # WAL checkpoint rewrites it). When a MODIFICATION of it is the SOLE change,
        # auto-commit it and fall through to the normal push path - anything else needs review.
        # ONLY a modification (` M`/`M `/`MM`) is the legit churn: a DELETION (` D`/`D `), addition, or
        # rename of nexus.db is NEVER auto-committed (cross-check: the Phase-D cutover's `mv nexus.db
        # nexus.db.pre-cutover` leaves a tracked-deletion as a single dirty line, which the old
        # `grep nexus/nexus.db$` would have staged + pushed as a deletion of the LIVE serving DB = data
        # loss). Match BOTH unstaged ` M` and staged `M `/`MM` so a manually-`git add`ed churn still
        # auto-commits (cross-check: `^[ M]M` missed the staged `M ` form and would have aborted the push).
        local db_status db_integrity
        db_status="$(printf '%s\n' "$DIRTY_STATUS" | wc -l | tr -d ' ')"
        if [ "$db_status" = "1" ] \
           && printf '%s' "$DIRTY_STATUS" | grep -qE '^( M|M |MM) nexus/nexus\.db$'; then
            # Never auto-commit (and push) a CORRUPT or UNVERIFIABLE db: a truncated/corrupt nexus.db is
            # still ` M` and must NOT propagate to origin + every client. FAIL CLOSED if sqlite3 is absent
            # too (cross-check: defaulting integrity to "ok" when sqlite3 was missing was fail-OPEN and
            # contradicted "a corrupt db is never auto-pushed" - the data-safe choice is to leave it for
            # manual review). pre-cutover only; this whole auto-commit block is removed at step 6.
            if ! command -v sqlite3 >/dev/null 2>&1; then
                warn "$name: sqlite3 not found - cannot verify nexus.db integrity; NOT auto-committing (install sqlite3, or commit by hand after verifying)"
                DIRTY+=("$name")
                return
            fi
            db_integrity="$(sqlite3 nexus/nexus.db 'PRAGMA integrity_check;' 2>/dev/null || echo "check-failed")"
            if [ "$db_integrity" != "ok" ]; then
                warn "$name: nexus.db failed integrity_check ('$db_integrity') - NOT auto-committing a corrupt DB; needs manual review"
                DIRTY+=("$name")
                return
            fi
            git add nexus/nexus.db
            git commit -q -m "Update nexus.db"
            ok "$name: auto-committed nexus.db (live DB churn)"
            LOCAL=$(git rev-parse @)
        else
            DIRTY+=("$name")
            info "$name: has uncommitted changes"
            git status --short
            return
        fi
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

# ════════════════════════════════════════════════════════════════════
#  Skill links into each agent. The agent-skills fork itself is synced like any
#  origin repo; upstream is no longer merged automatically (ADR-0004).
# ════════════════════════════════════════════════════════════════════

# Link each skill subdir of $1 into every target dir ($3..) as $2<name> ($2 = namespace
# prefix). Idempotent; never clobbers a real (non-symlink) dir. (mac/linux uses symlinks;
# the ps1 mirror uses Junctions because Windows Dev Mode is off - parity-checked.)
link_skill_dirs() {
    local src_root="$1" prefix="$2"; shift 2
    src_root="$(expand "$src_root")"
    [ -d "$src_root" ] || { warn "skills: no source dir $src_root - skipping"; return; }
    local tgt_root skill sname link
    for tgt_root in "$@"; do
        tgt_root="$(expand "$tgt_root")"
        mkdir -p "$tgt_root"
        for skill in "$src_root"/*/; do
            [ -d "$skill" ] || continue
            sname="$(basename "$skill")"
            case "$sname" in .*) continue ;; esac   # skip .system etc.
            link="$tgt_root/${prefix}${sname}"
            if [ -L "$link" ]; then
                [ "$(readlink "$link")" = "${skill%/}" ] || ln -sfn "${skill%/}" "$link"
            elif [ -e "$link" ]; then
                warn "skills: $link exists as a real path - left untouched"
            else
                ln -s "${skill%/}" "$link" && ok "skills: linked ${prefix}${sname} -> $(basename "$tgt_root")"
            fi
        done
    done
}

materialize_project_skill() {
    # marker MUST be a SEPARATE `local`: referencing $dst in the same `local` that declares it
    # expands to UNBOUND under `set -u` (bash evaluates the RHS before the just-declared local
    # is visible), which crashed sync mid-regen and aborted everything after it. (fix 2026-06-18)
    local src="$1" dst="$2" namespaced="$3" rewrite_name="$4"
    local marker="$dst/.dotfiles-skill-source"
    if [ -L "$dst" ]; then
        rm -f "$dst"
    elif [ -e "$dst" ]; then
        if [ ! -f "$marker" ] || [ "$(cat "$marker" 2>/dev/null)" != "$src" ]; then
            warn "skills: $dst exists as a real path - left untouched"
            return
        fi
        rm -rf "$dst"
    fi

    mkdir -p "$(dirname "$dst")"
    cp -R "$src" "$dst"
    printf '%s\n' "$src" > "$marker"
    if [ "$rewrite_name" = true ] && [ -f "$dst/SKILL.md" ] && command -v python3 >/dev/null 2>&1; then
        python3 - "$dst/SKILL.md" "$namespaced" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
name = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
if lines and lines[0].strip() == "---":
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            break
        if lines[i].startswith("name:"):
            lines[i] = f"name: {name}\n"
            path.write_text("".join(lines), encoding="utf-8")
            break
PY
    fi
    ok "skills: materialized ${namespaced} -> $(basename "$(dirname "$dst")")"
}

# Prune generated links or materialized copies whose recorded source is gone, or lies inside
# an ARCHIVED_PROJECT_SKILLS dir (repo kept, skills retired). Real user-authored directories
# have no .dotfiles-skill-source marker and are never touched.
skill_source_archived() {
    local src="$1" entry dir
    for entry in "${ARCHIVED_PROJECT_SKILLS[@]+"${ARCHIVED_PROJECT_SKILLS[@]}"}"; do
        dir="$(expand "${entry#*|}")"
        case "$src" in "$dir"/*) return 0 ;; esac
    done
    return 1
}
clean_stale_skill_symlinks() {
    local tgt_root link marker source
    for tgt_root in "${AGENT_SKILLS_TARGETS[@]}" "${PROJECT_SKILLS_TARGETS[@]}"; do
        tgt_root="$(expand "$tgt_root")"
        [ -d "$tgt_root" ] || continue
        for link in "$tgt_root"/*; do
            if [ -L "$link" ] && { [ ! -e "$link" ] || skill_source_archived "$(readlink "$link")"; }; then
                rm -f "$link" && ok "skills: pruned stale link $(basename "$link") (source archived/removed)"
            elif [ -d "$link" ] && [ -f "$link/.dotfiles-skill-source" ]; then
                marker="$link/.dotfiles-skill-source"
                source="$(cat "$marker" 2>/dev/null || true)"
                if [ -z "$source" ] || [ ! -d "$source" ] || skill_source_archived "$source"; then
                    rm -rf "$link" && ok "skills: pruned stale materialized skill $(basename "$link") (source archived/removed)"
                fi
            fi
        done
    done
    # Retired targets (ADR-0004): drop every generated link or marked copy (never a user-authored
    # real dir), then the dir itself once nothing is left in it.
    for tgt_root in ${RETIRED_SKILL_TARGETS[@]+"${RETIRED_SKILL_TARGETS[@]}"}; do
        tgt_root="$(expand "$tgt_root")"
        [ -d "$tgt_root" ] || continue
        for link in "$tgt_root"/*; do
            if [ -L "$link" ]; then
                rm -f "$link" && ok "skills: removed $(basename "$link") from retired $(dirname "$link")"
            elif [ -d "$link" ] && [ -f "$link/.dotfiles-skill-source" ]; then
                rm -rf "$link" && ok "skills: removed $(basename "$link") from retired $(dirname "$link")"
            fi
        done
        rmdir "$tgt_root" 2>/dev/null && ok "skills: removed empty retired dir $tgt_root"
    done
}

# Wire vendor/global skills into all agents, then project skills from each agent's
# declared native source. Codex-native (copy-mode) skills are materialized so suppressing the
# repo-local duplicate cannot also hide a symlink that resolves to the same file.
regen_agent_skills_links() {
    link_skill_dirs "$AGENT_SKILLS_DIR/skills" "" "${AGENT_SKILLS_TARGETS[@]}"
    link_skill_dirs "$GLOBAL_SKILLS_DIR" "" "${AGENT_SKILLS_TARGETS[@]}"
    local entry label rest dir mode src skill sname target
    target="$(expand "~/.codex/skills")"
    for entry in "${CODEX_PROJECT_SKILLS[@]}"; do
        label="${entry%%|*}"
        rest="${entry#*|}"
        dir="${rest%%|*}"
        mode="${rest##*|}"
        if [ "$mode" = copy ]; then
            src="$(expand "$dir")"
            [ -d "$src" ] || { warn "skills: no source dir $src - skipping"; continue; }
            for skill in "$src"/*/; do
                [ -d "$skill" ] || continue
                sname="$(basename "$skill")"
                case "$sname" in .*) continue ;; esac
                materialize_project_skill "${skill%/}" "$target/${label}-${sname}" "${label}-${sname}" false
            done
        else
            link_skill_dirs "$dir" "${label}-" "$target"
        fi
    done
    clean_stale_skill_symlinks   # prune links whose source was removed/archived (idempotent)
}

# Sourceable for tests and targeted runs: when this file is SOURCED (to call one of the
# functions above) instead of executed, stop here - do NOT run the sync flow. `sync` invokes us
# with `bash sync.sh` (executed), so this is a no-op in production. (BASH_SOURCE != $0 = sourced)
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then return 0 2>/dev/null || exit 0; fi

# GIT_SYNC_SHARED_LOCK: serialize manual sync with auto-git timers.
# shellcheck source=scripts/git-sync-lock.sh
source "$DOTFILES_DIR/scripts/git-sync-lock.sh"
git_sync_lock_acquire "manual-sync" || exit 0

# ── Move repos out of ~/Documents (ADR-0007, INV-21) ─────────────────
# First, so every later step sees the repos where they now are. A blocked move moves nothing and
# fails the run at the end; a move still pending (the host before its window) keeps the old paths.
echo -e "\n${GREEN}==>${NC} Workspace layout"
migrate_to_workspace || WORKSPACE_MOVE_FAIL=1
is_mcp_host && REPOS+=("${HOST_REPOS[@]}")
apply_pending_workspace_paths

# ── Checkpoint Nexus DB (flush WAL into main file before syncing) ────
# The host's live store by its real path (INV-18). Not named NEXUS_DB: that is nexus's own env var.
checkpoint_db="$(expand "$NEXUS_HOST_STORE")"
if [ -f "$checkpoint_db" ] && command -v sqlite3 &>/dev/null; then
    sqlite3 "$checkpoint_db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
    ok "Nexus DB: WAL checkpointed"
fi

# ── Repoint links left at a moved source (ADR-0006) ──────────────────
# Before the pulls, while the old targets still exist. A sync runs the code it started with,
# so a move reaches a machine on its second sync after the dotfiles push.
echo -e "\n${GREEN}==>${NC} Checking moved link sources"
retarget_moved_links

# ── Sync dotfiles repo itself ────────────────────────────────────────
echo -e "\n${GREEN}==>${NC} Syncing dotfiles"
sync_repo "$DOTFILES_DIR"

# ── Sync manifest repos ─────────────────────────────────────────────
echo -e "\n${GREEN}==>${NC} Syncing managed repos"
for entry in "${REPOS[@]}"; do
    target="$(expand "${entry##*|}")"
    sync_repo "$target"
done

# ── Per-agent skill links (agent-skills lives in dotfiles, ADR-0007) ──
if [ -n "${AGENT_SKILLS_DIR:-}" ]; then
    echo -e "\n${GREEN}==>${NC} Linking agent skills"
    regen_agent_skills_links
fi

# ── Verify symlinks (auto-create if missing) ────────────────────────
echo -e "\n${GREEN}==>${NC} Checking symlinks"
for entry in "${SYMLINKS[@]}"; do
    source_path="$(expand "${entry%%|*}")"
    target_path="$(expand "${entry##*|}")"

    if [ -L "$target_path" ] && [ "$(readlink "$target_path")" = "$source_path" ]; then
        ok "$(basename "$target_path"): linked correctly"
    elif [ -e "$target_path" ] || [ -L "$target_path" ]; then
        # Real file or wrong-target symlink - don't auto-overwrite (could lose local edits)
        warn "$(basename "$target_path"): exists but not the expected symlink - resolve manually (rm and re-run, or run setup.sh)"
    elif [ ! -e "$source_path" ]; then
        warn "$(basename "$target_path"): source missing at $source_path"
    else
        # Target absent, source present - safe to auto-create
        mkdir -p "$(dirname "$target_path")"
        ln -s "$source_path" "$target_path"
        ok "$(basename "$target_path"): created symlink -> $source_path"
    fi
done

# Regenerate the Codex single-file rule bundle from global-rules/* (and remove retired ones)
regen_combined_agent_rules
configure_agent_integrations || warn "agent integrations were not updated"

# Regenerate cross-agent COMMANDS (codex prompts) and mirror the Claude
# permission ALLOWLIST into codex/gemini. Both are shared python generators (one source
# of truth; both OSes invoke the same script - parity is "both sync scripts call them").
if command -v python3 >/dev/null 2>&1; then
    cmd_args=()
    for entry in "${COMMAND_SOURCES[@]}"; do
        cmd_args+=("${entry%%|*}:$(expand "${entry#*|}")")
    done
    python3 "$DOTFILES_DIR/scripts/gen-agent-commands.py" "${cmd_args[@]}" || warn "command generation reported an issue"
    # COMMAND_MIRROR_VERIFY: every source command produced a codex prompt.
    python3 "$DOTFILES_DIR/scripts/gen-agent-commands.py" --verify "${cmd_args[@]}" || warn "COMMAND_MIRROR_VERIFY: a source command is missing its generated codex output"
    python3 "$DOTFILES_DIR/scripts/gen-agent-allowlist.py" || warn "allowlist mirror reported an issue"
    # Machine-state verification (INV-6 BLOCKING + INV-8 advisory). check-skill-targets --machine
    # runs AFTER regen_agent_skills_links (508/552), so dangling/missing/colliding links mean the
    # tree is genuinely wrong, not mid-sync: flag now, fail the run at the end (not warn-and-forget).
    # Guarded: absent target dirs (fresh machine) are skipped inside the check, never a false-fail.
    python3 "$DOTFILES_DIR/scripts/ci/check-skill-targets.py" --machine || { err "check-skill-targets --machine: skill links incomplete/dangling/colliding (above) - run a full sync; if it persists, investigate"; SKILL_TARGET_FAIL=1; }
    python3 "$DOTFILES_DIR/scripts/ci/check-agent-integrations.py" --machine || warn "agent integration machine check reported an issue"
    python3 "$DOTFILES_DIR/scripts/ci/check-worktrees.py" || true
else
    warn "python3 not found - skipping cross-agent command + allowlist generation"
fi

# Wire PreToolUse guards into settings.json. Scripts ride the global-hooks symlink
# (handled above); registration is per-machine, so merge each specific command
# idempotently and let routine `sync` repair missing guard registrations.
settings="$HOME/.claude/settings.json"
ensure_claude_pretooluse_hook() {
    local hook_cmd="$1" label="$2" tmp
    if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
        if jq -e --arg cmd "$hook_cmd" 'any(.hooks.PreToolUse[]?.hooks[]?; .command == $cmd)' "$settings" >/dev/null 2>&1; then
            ok "$label already wired in settings.json"
            return
        fi
        tmp="$settings.tmp.$$"
        if jq --arg cmd "$hook_cmd" '
            .hooks = (.hooks // {})
          | .hooks.PreToolUse = (
              ((.hooks.PreToolUse // []) | if type == "array" then . else [] end) as $pre
              | $pre + [{matcher:"Bash", hooks:[{type:"command", command:$cmd}]}]
            )' "$settings" > "$tmp" && [ -s "$tmp" ]; then
            cp "$settings" "$settings.bak"
            mv "$tmp" "$settings"
            ok "wired $label into settings.json"
        else
            rm -f "$tmp"
            warn "$label: jq merge failed, settings.json left untouched"
        fi
    else
        warn "$label: no jq or no settings.json - wire manually"
    fi
}
ensure_claude_pretooluse_hook "$HOME/.claude/hooks/warn-stacked-git-push.sh" "stacked-push guard"
ensure_claude_hook PostToolUse "Edit|Write|MultiEdit" "$UI_NUDGE_HOOK_CMD" "UI-workflow nudge"
if ! ensure_agent_defaults; then
    err "sync: agent default convergence FAILED"
    exit 1
fi

# ── Nvim-adjacent configs (delegated) ────────────────────────────────
NVIM_SETUP="$(expand "~/.config/nvim/setup.sh")"
if [ -x "$NVIM_SETUP" ]; then
    echo -e "\n${GREEN}==>${NC} Nvim-adjacent configs"
    "$NVIM_SETUP"
fi

# ── Rebuild Nexus from the code root ─────────────────────────────────
CODE_ROOT="$(resolve_code_root)"
NEXUS_PATH="$CODE_ROOT/nexus"
is_mcp_host && ensure_host_store_link "$CODE_ROOT"
if needs_local_nexus && [ -f "$NEXUS_PATH/package.json" ]; then
    cd "$NEXUS_PATH"
    npm install --silent 2>/dev/null
    npm run build 2>/dev/null
    ok "Nexus: rebuilt"
    cd - >/dev/null
fi

# ── Refresh MCP runtime deps + global wiring ─────────────────────────
COURIER_PATH="$CODE_ROOT/courier"
DOCGEN_PATH="$DOTFILES_DIR/tools/docgen"
CALENDAR_PATH="$CODE_ROOT/calendar"
retire_project_mcp_files
NEXUS_SERVER="$NEXUS_PATH/dist/server.js"
COURIER_SRC="$COURIER_PATH/src"
DOCGEN_SRC="$DOCGEN_PATH/src"
CALENDAR_SRC="$CALENDAR_PATH/src"
DOCGEN_BROWSERS="$HOME/.cache/docgen-playwright"

if command -v uv >/dev/null 2>&1; then
    # courier and calendar run only on the host; a client reaches them over http.
    if is_mcp_host; then
        [ -d "$COURIER_PATH" ] && (cd "$COURIER_PATH" && uv sync --quiet 2>/dev/null) && ok "Courier: deps synced"
        [ -d "$CALENDAR_PATH" ] && (cd "$CALENDAR_PATH" && uv sync --quiet 2>/dev/null) && ok "Calendar: deps synced"
    fi
    if [ -d "$DOCGEN_PATH" ]; then
        (cd "$DOCGEN_PATH" && uv sync --quiet 2>/dev/null) && ok "Docgen: deps synced"
        PLAYWRIGHT_BROWSERS_PATH="$DOCGEN_BROWSERS" \
            uv run --project "$DOCGEN_PATH" --no-sync playwright install chromium >/dev/null 2>&1 \
            && ok "Docgen: Chromium installed"
    fi
else
    warn "uv not found - skipping courier/docgen/calendar dep sync"
fi

if mcp_wiring_ready; then
    # Hubs are wired per-ROLE through register_all_hub_mcp / register_hub_mcp (manifest.sh,
    # sourced at the top) - ONE copy shared with setup.sh; check-hub-wiring (INV-5) proves no
    # script wires a hub directly. CLIENT machines: token on disk before the http courier entry.
    is_mcp_host || provision_all_client_tokens
    register_all_hub_mcp claude
    register_all_hub_mcp codex
    register_all_hub_mcp gemini

    # POST-cutover client self-check (cross-check): `sync` re-wires the GLOBAL agent configs but does NOT
    # regenerate project `.mcp.json`, so a sync-only client could keep a stale STDIO nexus there (reading
    # its own frozen nexus.db = split-brain). Surface it on the routine command - NON-FATAL (a warn, sync
    # must still complete), and only POST-cutover on a CLIENT (pre-cutover stdio nexus is correct, and the
    # host legitimately keeps a role-gated stdio nexus). The fix is `setup.sh --full --client`, not `sync`.
    if [ "${NEXUS_REMOTED:-false}" = "true" ] && ! is_mcp_host \
            && [ -x "$DOTFILES_DIR/scripts/assert-no-client-stdio-nexus.sh" ]; then
        bash "$DOTFILES_DIR/scripts/assert-no-client-stdio-nexus.sh" \
            || warn "a stale stdio nexus survives on this client (see above) - re-run 'setup.sh --full --client', not just 'sync'"
    fi

    # Host-side INV-4 (HUB_BEARER_HOST_SCAN): a gemini http add can MATERIALIZE the bearer into
    # ~/.gemini/settings.json (WSL); the wiring re-locks it 0600, this flags any literal for ROTATION.
    # Advisory (configs not in git). (parity-checked: scripts/ci/check-parity.py)
    if command -v python3 >/dev/null 2>&1 && [ -f "$DOTFILES_DIR/scripts/ci/check-hub-wiring.py" ]; then
        python3 "$DOTFILES_DIR/scripts/ci/check-hub-wiring.py" --host \
            || warn "hub bearer host-scan flagged an exposure (see above) - rotate the token"
    fi

    # MCP HOST: refresh the HTTP service(s) clients connect to - one per hub in hubs.json
    # (courier today). Idempotent repair.
    if is_mcp_host && [ "${WORKSPACE_MOVE_FAIL:-0}" = 1 ]; then
        warn "Hub host bootstrap skipped: a workspace move was blocked this run (fix it first; see 'workspace:' above)"
    elif is_mcp_host; then
        echo -e "\n${GREEN}==>${NC} Hub host bootstrap ($MCP_HOST)"
        # sync.sh runs `set -uo pipefail` (NO -e), so honor the rc explicitly: bootstrap_all_hubs returns
        # non-zero on a nexus bootstrap failure (loopback/PROP-2 self-test). A bare `|| warn` is VISIBLE but
        # not load-bearing - a post-cutover routine host sync would still EXIT 0 while nexus is mis-served
        # (cross-check). So record the failure and make sync exit non-zero at the end (after its other work),
        # mirroring the SKILL_TARGET_FAIL discipline - the host re-bootstrap IS an operational gate.
        bootstrap_all_hubs "$DOTFILES_DIR/hubs.json" "$DOTFILES_DIR/scripts/hub-host-bootstrap.sh" \
            || { warn "hub host bootstrap reported a FAILURE (nexus is fatal; see above) - the tunnel may be mis-served"; HUB_BOOTSTRAP_FAIL=1; }
    fi

    check_calendar_health() {
        # A client reaches the host's calendar over http and keeps no calendar identity or token.
        is_mcp_host || return 0
        command -v uv >/dev/null 2>&1 || return
        [ -d "$CALENDAR_PATH" ] || return
        if PYTHONPATH="$CALENDAR_SRC" uv run --project "$CALENDAR_PATH" --no-sync python -m ea_calendar.cli status --check-events --quiet >/dev/null 2>&1; then
            ok "Calendar: healthy (identity and login)"
        else
            warn "Calendar: health check failed - if status reports the identity missing, run identity-set (four key=value lines on stdin), else login: cd $CALENDAR_PATH && PYTHONPATH=src uv run --no-sync python -m ea_calendar.cli status"
        fi
    }
    check_calendar_health

    trust_gemini_managed_repos() {
        command -v gemini >/dev/null 2>&1 || return
        command -v jq >/dev/null 2>&1 || { warn "Gemini trust: jq not found - skipping trustedFolders update"; return; }
        local trust_file="$HOME/.gemini/trustedFolders.json"
        local tmp target entry
        mkdir -p "$(dirname "$trust_file")"
        [ -f "$trust_file" ] || printf '{}\n' > "$trust_file"
        tmp="$(mktemp)"
        cp "$trust_file" "$tmp"
        for entry in "${REPOS[@]}"; do
            target="$(expand "${entry##*|}")"
            [ -d "$target" ] || continue
            jq --arg path "$target" '. + {($path): "TRUST_FOLDER"}' "$tmp" > "$tmp.next" && mv "$tmp.next" "$tmp"
        done
        for target in "$HOME/Documents" "$HOME/Downloads" "$HOME/.dotfiles" "$HOME/.codex" "$HOME/.claude" "$HOME/.gemini" "$HOME/.config/nvim"; do
            [ -d "$target" ] || continue
            jq --arg path "$target" '. + {($path): "TRUST_FOLDER"}' "$tmp" > "$tmp.next" && mv "$tmp.next" "$tmp"
        done
        mv "$tmp" "$trust_file"
        ok "Gemini: trusted managed repo + workspace folders"
    }
    trust_gemini_managed_repos
else
    if needs_local_nexus; then warn "MCP wiring skipped - Nexus server not built at $NEXUS_SERVER"
    else warn "MCP wiring skipped - docgen not found at $DOCGEN_PATH (is the code root cloned?)"; fi
fi
ensure_gemini_cross_check_setup

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
        pull_keeping_changes

        if $HAS_CLAUDE; then
            # Ask Claude for a commit message (or a review flag)
            PROMPT="You are a commit message generator. Given these changes in the '$name' repo:

$CHANGES

Respond with ONLY one of:
1. A single-line commit message (no quotes, no prefix) if the changes are safe to commit
2. REVIEW: <reason> if the changes need human review (e.g. secrets, large deletions, config that looks wrong)

Nothing else. No explanation."

            info "$name: asking Claude for commit message..."
            MSG=$(claude -p "$PROMPT" 2>/dev/null); MSG_RC=$?

            if ! usable_commit_message "$MSG" "$MSG_RC"; then
                warn "$name: no usable commit message from Claude (exit $MSG_RC; is it logged in?) - commit manually"
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

# INV-6: a machine-state skill-target violation (flagged above) fails the whole sync run -
# the link tree is not in the expected state. Sync still completed its other work first.
if [ "${SKILL_TARGET_FAIL:-0}" = 1 ]; then
    err "sync: skill-target machine check FAILED (see above) - run a full sync or investigate"
    exit 1
fi

# A host hub bootstrap failure (nexus is fatal) makes sync exit non-zero so the failure is not silent -
# the host re-bootstrap is an operational gate, not just an advisory warn (cross-check). Sync still
# completed its other work first.
if [ "${WORKSPACE_MOVE_FAIL:-0}" = 1 ]; then
    err "sync: a workspace move was blocked or a clone could not retire (see 'workspace:' above) - fix it and re-run"
    exit 1
fi

if [ "${HUB_BOOTSTRAP_FAIL:-0}" = 1 ]; then
    err "sync: host hub bootstrap FAILED (nexus mis-served over the tunnel - see above) - investigate before relying on it"
    exit 1
fi
