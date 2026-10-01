---
description: Save where the work stands to this session's resume card and commit it, then clear the session (`/wrap keep` saves without clearing).
argument-hint: [keep]
---

Resume cards keep long work accurate across compactions and clears; only the session that binds a card is affected. The helper does the mechanical parts: `python3 ~/.claude/hooks/context-card.py <command>` (on Windows, `python` instead of `python3`).

Arguments: `$ARGUMENTS`: empty (save, then clear) or `keep` (save only). For anything else (such as the old `off` or `project on`), point to `/autowrap` and stop. Automatic refresh is `/autowrap`.

Checkpoint:

1. Run `context-card.py status`. If it shows `session: none`, say that resume cards need Claude Code and stop.
2. If no card is bound: pick a short name for the work (lowercase words joined by dashes, such as `email-triage`). If `cards here` lists a card for this same work, use that name. Run `context-card.py bind <name>`.
3. If this session changed files for a step it finished, commit them first as their own commit: stage only those files by path, a one-line message, no trailer lines. Leave anyone else's changes alone. Never push.
4. If `status` shows `kind file` (an Orchestrator's RESUME.md or another file its own process maintains), do not rewrite it. Refresh it the way its process says: for RESUME.md, that is a ledger write, which rewrites it. At the `/orchestrate` transition there is no ledger yet, and RESUME.md is already current. Then skip to step 5.
   Otherwise, rewrite the card file (the path from `status` or `bind`), under 60 lines, with these sections:
   - Goal
   - Decisions (stated exactly; keep Michael's own words)
   - Discoveries paid for (what took effort to learn)
   - Done and verified (from `git log` and the evidence you saw, with commit hashes, not from memory)
   - Next exact step
   - Queued after that
5. Run `context-card.py commit "checkpoint: <one-line summary>"`. It commits only the card. For someone else's repo the card is kept outside the repo and nothing is committed.
6. `keep`: say in one line what the card says is next, and stop.
7. Empty argument: say in one line what is next, then clear the session.
   - Claude Desktop: call the `clear_session` tool with `session_id: "self"`. A hook allows it only because Michael typed /wrap. If it blocks, report its message and stop.
   - Claude Code in a terminal: ask Michael to type `/clear`. The card comes back on its own.
   - Codex: ask Michael to type `/new`, then in the new thread say "continue <card name>", which rebinds it. In Codex, only the reload after compaction is automatic.
