#!/usr/bin/env bash
# client-bearer-env.sh - make each hub's ${<HUB>_BEARER} visible to agents that no interactive shell
# launched (hub CLIENTS only; the MCP host's hubs are stdio and need no bearer).
#
# shell/ea.zsh and the ~/.bashrc block export the bearers for INTERACTIVE shells only. An agent the
# Claude desktop app starts never runs one: on macOS the app is launched by launchd, and on WSL/Linux
# the app's SSH remote server starts under a non-interactive `zsh -c`. Those agents send
# `Authorization: Bearer ` (empty) and every hub answers 401. Two fixes, both reading the mode-600
# token file at use time so no token value is ever written anywhere else (INV-1/INV-4):
#   - ~/.zshenv managed block: every zsh, interactive or not (ssh commands, the desktop remote server).
#   - macOS: a LaunchAgent that `launchctl setenv`s the bearers at login, for GUI-launched apps
#     (an app started before it ran must be relaunched to pick them up).
# This is the macOS/Linux analog of Initialize-HubClientToken's User-env set on Windows.
# Idempotent: the zshenv block is replaced, not appended; the LaunchAgent is rewritten and reloaded.
set -euo pipefail

HUBS="courier calendar nexus"

zshenv="${ZDOTDIR:-$HOME}/.zshenv"
begin="# >>> dotfiles hub bearer env >>>"
end="# <<< dotfiles hub bearer env <<<"
tmp="$(mktemp)"
if [ -f "$zshenv" ]; then
    awk -v b="$begin" -v e="$end" '$0==b{s=1;next} $0==e{s=0;next} s!=1{print}' "$zshenv" > "$tmp"
fi
{
    printf '%s\n' "$begin"
    for h in $HUBS; do
        H="$(printf '%s' "$h" | tr '[:lower:]' '[:upper:]')"
        printf '[ -r "$HOME/.config/%s/auth-token" ] && export %s_BEARER="$(cat "$HOME/.config/%s/auth-token")"\n' "$h" "$H" "$h"
    done
    printf '%s\n' "$end"
} >> "$tmp"
mv "$tmp" "$zshenv"
chmod 600 "$zshenv"
echo "client-bearer-env: hub bearer exports in $zshenv"

[ "$(uname -s)" = "Darwin" ] || exit 0

label="com.ea.hub-bearer-env"
plist="$HOME/Library/LaunchAgents/$label.plist"
mkdir -p "$(dirname "$plist")"
cmd='for h in '"$HUBS"'; do f="$HOME/.config/$h/auth-token"; H=$(printf %s "$h" | tr a-z A-Z); if [ -r "$f" ]; then launchctl setenv "${H}_BEARER" "$(cat "$f")"; fi; done'
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>-c</string><string>$cmd</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
uid="$(id -u)"
launchctl bootout "gui/$uid/$label" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
sleep 1
# `launchctl getenv` reads the CALLER's domain (an SSH session's differs from the GUI one), so check gui/.
domain_env="$(launchctl print "gui/$uid" 2>/dev/null || true)"   # not piped: grep -q + pipefail = SIGPIPE false negative
if [[ "$domain_env" == *"NEXUS_BEARER => "* ]] || [ ! -r "$HOME/.config/nexus/auth-token" ]; then
    echo "client-bearer-env: $label loaded (relaunch apps opened before now to pick up the bearers)"
else
    echo "client-bearer-env: WARNING $label did not set the bearers; run: launchctl kickstart -k gui/$uid/$label" >&2
fi
