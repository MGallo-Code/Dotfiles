#!/usr/bin/env bash
# Regenerate the Codex/Gemini combined rule files (~/.codex/AGENTS.md, ~/.gemini/GEMINI.md)
# from EA's global-rules/*.md, outside a full setup/sync. Called by EA's post-commit,
# post-merge and post-checkout hooks so a rule change reaches every agent without waiting
# for the next sync.
# Same function setup.sh/sync.sh call; this only supplies the helpers they define.
#   --quiet   print nothing when the targets are already current
# Windows twin: regen-agent-rules.ps1.
set -uo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok()     { echo "[ok] $1"; }
warn()   { echo "[!] $1"; }
expand() { echo "${1/#\~/$HOME}"; }

[ "${1:-}" = "--quiet" ] && COMBINED_RULES_QUIET=1

source "$DOTFILES_DIR/manifest.sh"
regen_combined_agent_rules
