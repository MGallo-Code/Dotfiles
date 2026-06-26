#!/usr/bin/env bash
set -euo pipefail
# GIT_AUTOSYNC_BOOTSTRAP

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERVAL=1800
ENABLE=0
DISABLE=0

usage() {
    echo "usage: git-autosync-bootstrap.sh [--enable|--disable] [--interval seconds]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --enable) ENABLE=1 ;;
        --disable) DISABLE=1 ;;
        --interval) shift; INTERVAL="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
    shift
done

case "$INTERVAL" in
    ''|*[!0-9]*) echo "interval must be seconds" >&2; exit 2 ;;
esac

OS_OVERRIDE="${GIT_AUTOSYNC_BOOTSTRAP_TEST_OS:-}"
OS_NAME="${OS_OVERRIDE:-$(uname -s)}"
HOME_DIR="${GIT_AUTOSYNC_TEST_HOME:-$HOME}"
AUTO_GIT="$DOTFILES_DIR/auto-git.sh"
CRON_BEGIN="# dotfiles git-autosync begin"
CRON_END="# dotfiles git-autosync end"

write_macos() {
    local plist_dir="$HOME_DIR/Library/LaunchAgents"
    local log_dir="$HOME_DIR/Library/Logs"
    local plist="$plist_dir/com.ea.git-autosync.plist"
    mkdir -p "$plist_dir" "$log_dir"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.ea.git-autosync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$AUTO_GIT</string>
    </array>
    <key>StartInterval</key><integer>$INTERVAL</integer>
    <key>RunAtLoad</key><true/>
    <key>Disabled</key><true/>
    <key>StandardOutPath</key><string>$log_dir/git-autosync.log</string>
    <key>StandardErrorPath</key><string>$log_dir/git-autosync.log</string>
</dict>
</plist>
EOF
    echo "[ok] wrote dormant launchd plist: $plist"
    if [ "$DISABLE" = 1 ] && [ -z "${GIT_AUTOSYNC_BOOTSTRAP_TEST_OS:-}" ]; then
        launchctl bootout "gui/$(id -u)/com.ea.git-autosync" 2>/dev/null || true
        echo "[ok] git autosync disabled"
    fi
    if [ "$ENABLE" = 1 ]; then
        perl -0pi -e 's/<key>Disabled<\/key><true\/>/<key>Disabled<\/key><false\/>/' "$plist"
        if [ -z "${GIT_AUTOSYNC_BOOTSTRAP_TEST_OS:-}" ]; then
            launchctl bootout "gui/$(id -u)/com.ea.git-autosync" 2>/dev/null || true
            launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
            launchctl kickstart -k "gui/$(id -u)/com.ea.git-autosync" 2>/dev/null || true
        fi
        echo "[ok] git autosync enabled"
    fi
}

systemd_user_available() {
    [ -n "${GIT_AUTOSYNC_TEST_NO_SYSTEMD:-}" ] && return 1
    command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1
}

cron_minutes() {
    local minutes
    minutes=$((INTERVAL / 60))
    [ "$minutes" -gt 0 ] || minutes=1
    printf '%s\n' "$minutes"
}

write_cron_snippet() {
    local path="$1"
    local state_dir="$2"
    local minutes
    minutes="$(cron_minutes)"
    cat > "$path" <<EOF
$CRON_BEGIN
*/$minutes * * * * /bin/bash "$AUTO_GIT" >> "$state_dir/git-autosync.log" 2>&1
$CRON_END
EOF
}

remove_cron_block() {
    command -v crontab >/dev/null 2>&1 || return 0
    (crontab -l 2>/dev/null || true) \
        | awk -v begin="$CRON_BEGIN" -v end="$CRON_END" '
            $0 == begin { skip = 1; next }
            $0 == end { skip = 0; next }
            !skip { print }
        ' \
        | crontab -
}

install_cron_block() {
    local cron_snippet="$1"
    if command -v crontab >/dev/null 2>&1; then
        { (crontab -l 2>/dev/null || true) \
            | awk -v begin="$CRON_BEGIN" -v end="$CRON_END" '
                $0 == begin { skip = 1; next }
                $0 == end { skip = 0; next }
                !skip { print }
            '; cat "$cron_snippet"; } \
            | crontab -
        echo "[ok] git autosync enabled via user cron"
    else
        echo "[error] neither systemd user nor crontab is available; see $cron_snippet" >&2
        exit 1
    fi
}

write_linux() {
    local state_dir="${XDG_STATE_HOME:-$HOME_DIR/.local/state}/dotfiles"
    local unit_dir="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/systemd/user"
    local service="$unit_dir/git-autosync.service"
    local timer="$unit_dir/git-autosync.timer"
    mkdir -p "$state_dir" "$unit_dir"
    cat > "$service" <<EOF
[Unit]
Description=Dotfiles document auto-git sync

[Service]
Type=oneshot
ExecStart=/bin/bash $AUTO_GIT
StandardOutput=append:$state_dir/git-autosync.log
StandardError=append:$state_dir/git-autosync.log
EOF
    cat > "$timer" <<EOF
[Unit]
Description=Run dotfiles document auto-git sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}s
Unit=git-autosync.service

[Install]
WantedBy=timers.target
EOF
    echo "[ok] wrote dormant systemd user timer: $timer"
    if [ "$DISABLE" = 1 ]; then
        if systemd_user_available; then
            systemctl --user disable --now git-autosync.timer >/dev/null 2>&1 || true
        fi
        remove_cron_block
        echo "[ok] git autosync disabled"
    fi
    if [ "$ENABLE" = 1 ]; then
        if systemd_user_available; then
            systemctl --user daemon-reload
            systemctl --user enable --now git-autosync.timer
            echo "[ok] git autosync enabled via systemd user timer"
        else
            local cron_snippet="$state_dir/git-autosync.cron"
            write_cron_snippet "$cron_snippet" "$state_dir"
            install_cron_block "$cron_snippet"
        fi
    else
        write_cron_snippet "$state_dir/git-autosync.cron" "$state_dir"
        echo "[ok] wrote dormant cron snippet: $state_dir/git-autosync.cron"
    fi
}

case "$OS_NAME" in
    Darwin|darwin) write_macos ;;
    Linux|linux) write_linux ;;
    *) echo "unsupported OS for git autosync bootstrap: $OS_NAME" >&2; exit 1 ;;
esac
