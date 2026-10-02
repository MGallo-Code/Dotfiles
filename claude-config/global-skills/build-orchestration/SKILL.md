---
name: build-orchestration
description: Run Michael's Orchestrator/Builder/Challenger build system on a project. Covers setting up worktrees and briefs, the Orchestrator's continuity through a resume card, a fresh Challenger subagent per candidate, a Builder per slice, role guards, per-role models and the pilot metrics. Use when Michael asks to orchestrate a build, start or continue an orchestration, or run the build/critique system.
---

# Orchestrate

The protocol of record is Michael's handoff, pinned verbatim: `~/Workspace/Wiki/raw/orchestrated-build-critique-handoff-2026-09-27.md`. Its sha256 is in the Wiki lab note "Orchestrated Build-Critique System". Read it all before starting; its bootstrap checklist (section 9) is the setup.
This skill adds only the phase-2 changes agreed on 2026-09-27 to 2026-09-30 (the lab note's decisions log, EA ADR-0004). Where the two differ, the handoff wins, except for the overrides listed at the end.

## What changed from the handoff

1. **The Challenger is a fresh subagent per candidate revision,** not a long-lived peer session.
   - The Orchestrator spawns the `challenger` agent (`~/.dotfiles/claude-config/global-agents/challenger.md`: Opus 5.5 `high`, Playwright inline and isolated, no CLAUDE.md).
   - Its inbox lives outside the canonical checkout: `~/.worktrees/<project>-challenger/analysis_outputs/reviewer-evidence/inbox/<ID>/`, a plain folder.
   - It is given only the pass-1 materials. Its agent-scoped guard keeps it out of the canonical checkout (Read, Glob and Grep), so it cannot see builder deliverables, earlier reviews or the ledger.
   - After `PASS1_COMPLETE`, the Orchestrator sends the builder materials to the same instance with SendMessage for pass 2.
   - Record the instance's agent id in RESUME.md while it is live. If the Orchestrator is refreshed between `PASS1_COMPLETE` and pass 2 and the id is lost, spawn a fresh instance with the pass-1 report plus the builder materials.
   - Revisions r2 and r3 get a new instance. Never fork a Challenger: a fork inherits the parent's context.
   - Hook-enforced: Write only under `analysis_outputs/reviewer-evidence/` (never `execution-copy/`); read-only git; no `gh`; no messaging tools. Its shell is not policed; custody re-hashes stay the final judge.
2. **The Builder is one session per slice,** from plan through the last revision, then retired.
   - At acceptance it appends 5 to 15 lines to `analysis_outputs/builder-notes/lessons.md`, and the next slice's Builder reads that file first.
   - Rotate early after two failed corrections on the same issue.
   - A Builder session opened in the Builder worktree sets itself up (item 3); no command needed.
   - Hook-enforced:
     - Edit and Write only inside that worktree.
     - In Bash: git push, merge, rebase, switch, pull, cherry-pick, a branch-changing checkout, `reset --hard`, `branch -D/-f` and `update-ref` are blocked, as are `gh pr merge` and `gh pr create`.
     - Commits stay allowed and local.
     - The handoff's "never switches branches" holds.
3. **`/orchestrate new`, run in the chat that will become the Orchestrator, from the canonical checkout.** Phase 1 interviews Michael (`interview-me` / `idea-refine`) and writes the brief plus a kickoff prompt for the model the chat is running on. On his yes, the transition runs `orchestration new <name>`, and he types `/wrap` for a clean phase 2. It sets up context management for the whole orchestration:
   - **The Orchestrator** (this session):
     - its card becomes `tasks/<name>/RESUME.md` (created from the template if missing), so every compaction and clear reloads it, and the summary keeps only what happened since RESUME.md was last written;
     - it gets the orchestrator role: product files are hook-blocked, and it may write `tasks/<name>/`, any `analysis_outputs/`, and anything outside a git work tree;
     - its checkout gets the 350K compaction window.
   - **The Builder:** each *new* Claude session opened in the Builder worktree becomes a Builder at start, while the orchestration is live. It gets:
     - the builder role (the git guard, and edits confined to the worktree);
     - its own fresh card, kept outside the repo and updated with `/wrap keep` after each step, so its compactions keep only what's new;
     - the 350K window.

     Sessions that were already open, already bound to a card, or headless are never touched.
     A new slice means a new Builder session, which starts with a fresh card. Lessons carry across slices through `lessons.md`, as before.
     The Builder confirms its setup with `python3 ~/.claude/hooks/context-card.py status`; if it shows `role: none`, it stops and tells the Orchestrator.
   - **The Challenger:** nothing to set up. It is a fresh subagent per revision.
   - `/orchestrate off` pauses: the Orchestrator chat acts as a normal agent (guard lifted), running Builders are held idle (edits and shell blocked), and none activate; `/orchestrate on` resumes. `/orchestrate end` finishes: it returns the Orchestrator and every activated Builder to normal and restores the folders' previous compaction limit. Builders can run none of these. `/orchestrate status` reports.
   - If the Orchestrator session is gone, the orchestration goes stale on its own: nobody new activates, and existing Builder roles go inert. Clean it up with `/orchestrate end` from the canonical checkout. Activations also expire after 30 days.
   - One Orchestrator per Builder worktree: a second `new` against a live one is refused. `--allow <path>` adds writable roots.
   - **Custody:** `new` writes `.claude/settings.local.json` in both checkouts (git-excluded). Run it before the section 9 baseline snapshot, or list that file as an audit exclusion. Everything else lives outside the repos, in `~/.claude/resume-state/`.
   - **Rotation:** `/wrap` at a milestone freeze, or automatic compaction (autowrap, set up by `new`). For the Orchestrator, `/wrap` refreshes RESUME.md through a ledger write; it never rewrites it into the card template.
   - The one-orchestrator lock (handoff section 10) records `CLAUDE_CODE_HOST_SESSION_ID`, which survives clears, so a refresh never trips the lock. Its Bash is not policed; custody is.
4. **Model and effort per role, and the A/B pilot:**
   - Builder: Opus 5.5 `medium`, or `high` for plan slices and slices that touch invariants, gates or custody.
   - Challenger: pinned in its agent file.
   - Orchestrator, one arm per milestone:
     - arm A is Opus 5.5 `high`, consulting Fable 5.1 through `/advisor` at plan dispositions and milestone freezes;
     - arm B is Fable 5.1 `high`.

     Record the arm in the ledger.
   - At milestone freezes, add a cross-vendor check (`coding-mastermind-cross-check`), since Opus reviewing Opus shares blind spots.
5. **Every assignment carries "Discoveries paid for"**, drawn from `lessons.md` and earlier dispositions.
6. **Metrics** (`templates/ledger-additions.json`), per slice:
   - review rounds, and P1/P2/P3 findings from pass 1 vs pass 2;
   - findings rejected as invalid;
   - usage per role, custody incidents and taste rejections;
   - the Orchestrator arm.

   Compare each milestone with M1 (2 to 4 rounds per slice). Remove a ceremony only when the metrics hold without it, one at a time.

## Starting an orchestration

1. The brief and kickoff come from `/orchestrate new` phase 1. Then run the rest of the handoff's section 9 checklist: baseline manifests (after `new`, with `.claude/settings.local.json` expected), and the ledger skeleton with the additions.
2. Write the briefs from `templates/`. The Orchestrator's goes in its checkout. The Builder's goes at `<builder worktree>/analysis_outputs/builder-notes/SESSION-BRIEF.md`, which the Orchestrator may write and which stays out of git. Challenger instructions go in each spawn prompt (`templates/challenger-spawn.md`).
3. In a chat in the canonical checkout, Michael runs `/orchestrate new`. The transition creates the Builder worktree (`~/.worktrees/<repo>-<name>-builder`, branch `orchestration/<name>/builder`) and the Challenger folder (`<repo>-<name>-challenger/`). After `/wrap`, the fresh Orchestrator reads KICKOFF.md and continues here. Open each Builder as a new session in the Builder worktree, with its one-liner; it sets itself up. The Orchestrator arm is whatever model the chat runs on; record it in the ledger.
4. The first assignment is the smallest slice Michael can see.

## Overrides of the handoff (Michael)

- 2026-09-27: git commits are local checkpoints and should be frequent. Pushes, PRs, merges and deploys still need his explicit go, relayed by the Orchestrator.
