---
description: Turn automatic refresh on or off for this project (Claude Code). The folder's chats compact at 350K, or your own limit, and this chat keeps a resume card, so each compaction keeps only what's new and reloads the card.
argument-hint: on | off | status | limit <tokens>
---

Arguments: `$ARGUMENTS`. The helper is `python3 ~/.claude/hooks/context-card.py` (on Windows, `python`).

- `on`:
  1. Run `status`. If it shows `session: none`, say that autowrap needs Claude Code and stop.
  2. If no card is bound, pick a short name for the work (lowercase words joined by dashes; if `cards here` lists one for this same work, use it), run `bind <name>`, and add `--bound` in step 3.
  3. Run `autowrap on` (with `--bound` if you just bound a card), then report its lines.
- `limit <tokens>` (for example `250k`): the same steps, with `autowrap limit <tokens>` in step 3. The limit must be between 150k and 1000k.
- `off`: run `autowrap off` and report its line.
  - It releases autowrap's hold on the folder; the previous limit returns once nothing else holds it (an orchestration may).
  - It unbinds only a card autowrap itself bound, never one bound with `/wrap`, never a file card, and never one in a chat with a role.
  - It does nothing if autowrap is not on.
- `status`: run `autowrap status` and report it.

Chats already running keep their current limit until they restart. For a refresh right now, use `/wrap`. In Codex this command does not apply: Codex has its own compaction settings.
