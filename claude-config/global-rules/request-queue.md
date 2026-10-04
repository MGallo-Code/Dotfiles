# Checklist

Every conversation keeps a checklist of what Michael asked for (dotfiles ADR-0008), managed with
`python3 ~/.claude/hooks/context-card.py queue`. It exists the whole time, not only at compaction.

- When Michael asks for something, add it as one short task: `queue add "<what, in a few words>"`.
  Close it when it is done (`queue done R3 [--note ...]`) or no longer applies (`queue drop R5
  --note why`); `queue title R3 "<better title>"` renames one. Questions, answers and
  acknowledgements are not tasks.
- Hooks also capture every message he types into an inbox. After turning the requests in it into
  tasks, run `queue reviewed`. If three or more pile up unreviewed, the Stop hook asks once.
- `queue list` shows the open tasks (`--all` adds closed ones, `--project` other conversations'
  in this folder); `queue inbox` shows unreviewed messages. After a compaction or resume both come
  back on their own.
- Before a final report, run `queue list` and report each open task as done, not done, or
  waiting on Michael; what a waiting task needs from him goes through the questions page or card
  (`questions.md`).
- Never tell Michael "I'll add this to the queue": just add it.
