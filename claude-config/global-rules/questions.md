# Questions for Michael

What's waiting on Michael (a choice, an approval, a to-do only he can do) reaches him in a form he
can answer on the spot: the questions page or the question card, never a list at the end of a
reply. Design: dotfiles ADR-0011.

## Which one

- Never hold up work on a question. While any work remains that doesn't need the answer, put the
  question on the page and keep working.
- The card (Claude `AskUserQuestion`, Codex `request_user_input`) only when nothing more can be done
  without the answer, the end of a task included, and no picture is needed. It pauses you until he
  answers. Up to 4 questions, 2 to 4 options each.
- A choice he has to see (layouts, colors, a mock): the page, with a real screenshot per option that
  you took. Never mention a picture, mock or pane he can't see right now.
- Approval to publish or do anything irreversible (push, deploy, send, delete, pay): chat or the
  card, never the page.
- A command only he can run: its own `bash` block in chat (the desktop app gives it a Run button).
- Subagents never ask: return the questions to the parent. Headless runs (`claude -p`, the hub)
  don't either. A session over SSH: the page is on that machine, so use the card.

## Writing a question

- Write for someone who never saw this session: one plain sentence of what's going on, then the
  question.
- No internal labels: rule or decision ids, file paths, setting or function names, commit hashes.
  Say what they mean. A hook rejects them; `ask.py allow --reason ...` lets one card keep a label
  he needs.
- Each option says in one sentence what he gets. Recommended first, marked.
- Mark a question `multi` (page) or `multiSelect` (card) when more than one answer can apply.

## The questions page

```bash
uv run --no-project "$HOME/.dotfiles/tools/ask/ask.py" open questions.json --from "<repo> · <task>"
```

(`python3`, or `python` on Windows, in place of `uv run --no-project` when uv is missing.)
`questions.json`:

```json
{"questions": [{"question": "...", "context": "...", "multi": false, "options": [
  {"label": "...", "detail": "...", "recommended": true, "images": ["/abs/at-390.png", "/abs/at-1280.png"]},
  {"label": "...", "detail": "..."}]}]}
```

It prints the link and an ask id. Show it:

- Claude app: `preview_start` the link, then `tabs_context` must say the Browser pane is displayed.
  If it is hidden, send any file with `SendUserFile` and `display: "render"` to open the right
  panel, select the tab, and check again. Then one line in chat: the questions are open on the right.
- Claude or Codex in a terminal: add `--browser`.
- Codex app: open the link in its in-app browser.

Collect the answers:

- Claude: run `ask.py wait <id>` with `run_in_background` and keep working; you are notified when
  he sends, even after your turn has ended.
- Codex: `ask.py poll <id>` between steps. When nothing else is left, ask one card question
  ("Answered on the questions page?"), then poll.
- He answered in chat instead: `ask.py close <id>` (it prints anything he had already sent).
- After a resume or compaction: `ask.py list` shows this session's pages.

## End of a task

Report done and not done in chat (`communication-style.md`); then what's waiting on him goes through
the page or the card. A Stop hook blocks once on a reply that ends in a list of questions.
