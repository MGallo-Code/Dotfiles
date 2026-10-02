# Request Queue

Every message Michael types lands on this conversation's request queue automatically, as
`R1`, `R2`, ... (hooks capture it, including messages sent mid-turn; dotfiles ADR-0008). After a
compaction or resume the open items come back verbatim, so a summary can never lose one.

- Your part is closing items: `python3 ~/.claude/hooks/context-card.py queue done R3 R4` when a
  request is finished or answered, `queue drop R5 --note "superseded by R7"` when it no longer
  applies. Close plain acknowledgements ("yes", "go ahead") together with the item they answer.
- `queue list` shows what is open (`--all` adds closed items, `--project` shows other
  conversations' open items in this folder); `queue show R3` prints one in full.
- A request that arrived another way (a peer session relaying Michael, an email) goes on with
  `queue add "<text>"`.
- Before a final report, run `queue list`: report each open item as done, not done, or waiting on
  Michael, and close what is done.
- Never tell Michael "I'll add this to the queue": it is already there.
