#!/usr/bin/env python3
"""PostToolUse hook (INV-19): the first time a chat edits a UI file, remind it to follow the `ui`
workflow (rules, live verification, review, show Michael) before calling the work done.

Once per session, keyed by the hook's session_id, so it is a nudge rather than noise. Fails open:
bad input, a missing session id or any error prints nothing and exits 0, so it can never block an
edit. Python 3.9 standard library only (macOS's /usr/bin/python3). Registered by dotfiles setup
and sync through ensure_claude_hook / Ensure-ClaudeHook.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

UI_SUFFIXES = {".css", ".scss", ".sass", ".less", ".html", ".htm", ".jsx", ".tsx", ".vue", ".svelte", ".astro"}


def main() -> int:
    data = json.load(sys.stdin)
    tool_input = data.get("tool_input") or {}
    path = str(tool_input.get("file_path") or tool_input.get("notebook_path") or "")
    if Path(path).suffix.lower() not in UI_SUFFIXES:
        return 0
    session = "".join(c for c in str(data.get("session_id") or "") if c.isalnum() or c in "-_")
    if not session:
        return 0
    state = Path(os.environ.get("UI_NUDGE_STATE") or Path(tempfile.gettempdir()) / "ui-nudge")
    marker = state / session
    if marker.exists():
        return 0
    state.mkdir(parents=True, exist_ok=True)
    marker.touch()
    message = (f"This chat changed a UI file ({Path(path).name}). Follow the `ui` workflow before calling it "
               "done: its rules, live verification in a browser, the review, then show Michael.")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": message}}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
