#!/usr/bin/env bash
# Compatibility wrapper for settings created before the cross-agent notifier.
# New installations register agent-notify.py directly.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v uv >/dev/null 2>&1; then
  exec uv run --no-project "$SCRIPT_DIR/agent-notify.py" hook --agent claude
elif command -v python3 >/dev/null 2>&1; then
  exec python3 "$SCRIPT_DIR/agent-notify.py" hook --agent claude
fi
exit 0
