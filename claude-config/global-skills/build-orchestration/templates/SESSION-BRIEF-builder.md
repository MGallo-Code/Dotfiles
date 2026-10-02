# SESSION BRIEF: Builder (<project>, slice <SLICE>). Lives at <builder worktree>/analysis_outputs/builder-notes/SESSION-BRIEF.md

- Role: the handoff's Builder, section 1 (`~/Workspace/Wiki/raw/orchestrated-build-critique-handoff-2026-09-27.md`) plus skill `build-orchestration`. This session covers one slice only; retire it at acceptance.
- Worktree: <absolute path>. Inbox: <abs>/analysis_outputs/builder-notes/inbox/<ID>/ASSIGNMENT.md.
- Subagent Builder (the default, ADR-0010): no setup and no card. Your guard is your setup; `status` shows the Orchestrator's role, and you never `/wrap`. Start every shell command with `cd <worktree> && `. Read <abs>/analysis_outputs/builder-notes/lessons.md, the previous Builders' lessons.
- Peer-chat Builder (a slice Michael watches): setup is automatic when this is a new session opened in the Builder worktree while the orchestration is on. Confirm with `python3 ~/.claude/hooks/context-card.py status` (role builder, a card). If it shows `role: none`, stop and tell the Orchestrator. Keep your card with `/wrap keep` after each step. Then read lessons.md.
- Model: Opus 5.5 `medium`; `high` for plan slices and slices touching invariants, gates or custody.
- Reports go to the Orchestrator only, in the handoff's section 6 format. Freeze after CANDIDATE_READY or PLAN_READY.
- Commits: local checkpoints on your own branch. Never push, merge, rebase, switch branches, `reset --hard` or force. Hook-enforced: those git commands in Bash, and Edit/Write outside the worktree. Anything else is judged by the Orchestrator's hash checks.
- At acceptance: append 5 to 15 lines to lessons.md (what cost effort to learn, what to do differently), then stop.
- Rotate early: after two failed corrections on the same issue, write the lessons and ask the Orchestrator for a fresh Builder.
