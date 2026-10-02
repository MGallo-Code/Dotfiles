# 0008 - Every request Michael types lands on a persistent queue, automatically

Status: accepted 2026-10-02 (Michael: "ensure the claude always puts my requests on a persistent
work queue that can't be lost due to compacts/loss in long context ... I'd like that to be
automatic, part of the system already ... (claude and codex), pull them everywhere").

## Problem

Long sessions run for days through compaction. A compaction summary paraphrases, merges or drops
requests, most often the ones Michael sends mid-turn while the agent is busy. Today a request
survives only if the agent chose to write it down (a resume card, a todo list), so Michael ends up
saying "persist this on a work queue" by hand. Resume cards only cover sessions bound with `/wrap`.

## Decision

A per-conversation request queue, captured by hooks (not by the agent remembering), in
`context-card.py` beside the resume-card hooks it builds on.

- **Capture (mechanical).** Hooks sweep the agent's own transcript for what Michael typed, at
  the end of every turn (`Stop`), before every compaction (`PreCompact`) and at session start:
  - Claude: `user` entries and mid-turn `queued_command` attachments whose origin is `human`,
    deduplicated by their transcript ids (Claude Code re-writes a queued message later with the
    same id).
  - Codex: `user_message` events (deduplicated by `client_id`), only in rollouts Michael types into
    (`session_meta.source` `cli` or `vscode`); `codex exec` runs and Codex subagents are skipped.
  - Never captured: peers and subagent hand-backs, task notifications, meta entries, compaction
    summaries, tool results, bare slash commands (`/clear`), headless runs, and a `claude -p`
    nested in a session (it inherits the session's environment, so the hook reads the nearest
    `claude` ancestor's arguments; `sync` also runs its commit-message prompt headless).
- **Store.** `~/.claude/resume-state/queue/<session>.jsonl`, append-only (items and status
  events), machine-local, mode 0600. `<session>` is the resume-card session id: the Desktop session
  id (survives clears and compactions), else the CLI process, else the Codex thread. The sweep
  keeps a byte offset per transcript beside the file, so each run reads only new lines and skips
  lines without the marker before parsing; a conversation's first sweep reaches back 15 minutes.
- **Show.** `PreCompact` tells the summary the open ids are restored; after a compaction, resume
  or clear, `SessionStart` prints every open item verbatim (Claude and Codex), so a summary losing
  one costs nothing. Mid-session the agent reads the queue with `queue list`.
- **Close.** The agent closes items: `context-card.py queue done R3 R4 [--note ...]`,
  `queue drop R5 --note "superseded by R7"`, `queue add "<text>"` (a request given another way),
  `queue list [--all]`. A new global rule (`request-queue.md`, bundled into Codex's AGENTS.md)
  says to close an item when it is finished or answered, and to check `queue list` before a final
  report. An item nobody closes stays open and keeps showing: the failure mode is noise, never loss.
- **Retention.** A queue file untouched for 90 days is pruned, open items or not.

## Why not

- **The resume card as the queue:** only bound sessions have one, it is git-tracked, and writing
  to it depends on the agent.
- **Classifying requests vs. replies in the hook:** "1. Go for it 2. Fold it in" is a decision, not
  noise. Everything is kept; the agent closes acknowledgements in one call.
- **A `UserPromptSubmit` hook:** in Claude Code 2.1.285, configuring one makes a message typed
  mid-turn wait for the turn to end instead of reaching the agent mid-turn, and it would capture
  each such message twice (once at Enter, once in the transcript). The design review caught this.

## Limits

- Codex: POSIX machines only (INV-16: Windows Codex hooks are unverified). Codex asks Michael once
  per machine to trust each new hook; an untrusted hook never runs.
- A CLI conversation is keyed by its process, so `claude --resume` in a new terminal starts a new
  queue (`queue list --project` still shows the old one). Desktop conversations keep theirs.
- The queue is per conversation. A new conversation starts empty; `queue list --project` shows
  open items other conversations left in the same folder.

Enforcers: INV-23. `check-context-card.py` (behaviour, with revert plants that drop typed or
mid-turn messages, capture peers, `codex exec` or a nested `claude -p`, or skip the restore) and
`check-agent-integrations.py` (registration, INV-16).
