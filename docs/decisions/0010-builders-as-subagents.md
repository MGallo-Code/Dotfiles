# 0010 - Builders run as subagents of the Orchestrator

Status: accepted 2026-10-02 (Michael: "3a, but lets make sure it works first"; after the tests
below, "it sounds like this is a go otherwise, yes?").

## Context

The build system (skill `build-orchestration`, the Wiki lab note "Orchestrated Build-Critique
System") made the Challenger a fresh subagent and kept the Builder a peer chat per slice "for one
pilot milestone", because it was undocumented whether a subagent survives the Orchestrator's
rotation. A peer chat costs Michael a manual step per slice and a second window to coordinate.

## Evidence (2026-10-02, Claude Code 2.1.285, headless runs on a small model, throwaway folders)

1. A subagent compacts on its own when its context fills (forced with
   `CLAUDE_CODE_AUTO_COMPACT_WINDOW`), and keeps its task: it reported its codeword and finished.
2. The parent compacting while a background subagent works does not disturb it; the compacted
   parent still receives the full result.
3. A finished subagent can be messaged again (`SendMessage` resumes it from its transcript) after
   the parent compacts, but not from a fresh parent session ("No transcript found").
4. Clearing the parent mid-work starts a new session; the subagent keeps working and its
   completion still reaches the new session. Only further messaging to it is lost.
5. Hooks in a user-level agent definition fire for that agent with `agent_type` and `agent_id` and
   can block a tool call (a write outside the allowed folder and `git push` were refused). The same
   hooks in a PROJECT-level agent definition did not fire.
6. During a subagent's compaction, `PreCompact`, `PostCompact` and `SessionStart(compact)` carry
   the parent's session id and transcript, with no agent field and the same environment.

## Decision

- **The Orchestrator spawns a Builder subagent per slice** (`builder`, or `builder-high` for plan
  slices and slices touching invariants, gates or custody), in the background, and records its
  agent id in the ledger so RESUME.md carries it across compactions. Revisions within the slice go
  to the same Builder with `SendMessage`. The Builder works in the Builder worktree by absolute path.
- **Its guardrails travel with the agent, and with the session.** `context-card.py builder-guard`
  runs before every edit and shell call twice: from the global `role-guard` hook, which routes a
  Builder's calls there (they carry the Orchestrator's session, finding 6, and would otherwise be
  judged by the Orchestrator's role), and from the agent's own fail-closed hook (both definitions
  live in dotfiles' user-level agents, finding 5). Its rules: edits only inside the Builder worktree
  of the orchestration this session runs, never its `.claude/` or `.git/`; every shell command
  starts with `cd <worktree> &&` (a subagent's shell starts in the Orchestrator's checkout on every
  call); the Builder git rules (no push, merge, rebase, branch moves); no `context-card.py` helper
  but `status` (they would act on the Orchestrator's records). No live orchestration for the
  session, or a paused one: refused. A `tools:` allowlist leaves out Agent and messaging.
- **No clear mid-slice.** A `SubagentStart` hook records each Builder as open; the Orchestrator
  retires it at acceptance (`context-card.py builders retire <id>`), and the clear guard refuses
  `/wrap` while one is open (finding 4: a clear would only cut off messaging, so the rule is about
  revisions, not lost work). Open, not running: between two reports the Builder is idle, and a clear
  then would still lose it. `builders forget` drops the records of Builders that are gone; a record
  older than 7 days is ignored.
- **Compaction while a Builder is open asks for the full context.** The pre-compaction hook cannot
  tell whose compaction it is (finding 6), so it drops its "summarize only what is new" narrowing.
- **Card and checklist text is role-aware.** Because of finding 6, everything the card and
  checklist hooks print says it belongs to the conversation's main agent, and that a subagent
  compacting inside it ignores it and keeps its own task's context.
- **Fallback:** a lost Builder (finding 3) is replaced by a new one that continues from the
  worktree, the ledger and the lessons file, the same as a new peer chat did.
- The peer-chat Builder path stays available, unchanged, for a slice Michael wants to watch.

## Not done

- Per-slice effort is two agents (`builder`, `builder-high`) with one body; the Agent tool takes a
  model, not an effort.
- A live check that agent-scoped hooks keep firing after a Claude Code update is a follow-up; the
  fixtures run the guard directly (the same limit the Challenger's guard has today).

Enforcers: INV-16 (registration of the subagent hooks) and INV-17 (`builder-guard`, the live-Builder
clear refusal, the role-aware text), `scripts/ci/check-context-card.py`.
