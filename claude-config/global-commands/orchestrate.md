---
description: Run an orchestration from this chat. `new` interviews Michael to shape the brief and a kickoff prompt for this chat's model, then sets everything up for a clean start. `off` and `on` pause and resume it; `end` finishes it; `status` reports.
argument-hint: new | on | off | end | status
---

Arguments: `$ARGUMENTS`. The helper is `python3 ~/.claude/hooks/context-card.py orchestration ...` (on Windows, `python`).

- `status`: run `orchestration status` and report it in a line or two, including whether it is paused or stale.
- `off`: run `orchestration off`. The orchestration pauses. This chat works as a normal agent (its guard is lifted). Running Builders are held idle: their edits and shell calls are blocked until `on`. No new Builders activate, and nothing is deleted. While paused, `/wrap` still saves only RESUME.md, so commit or note other work first.
- `on`: run `orchestration on`. The orchestration resumes: the guard is back and Builders activate again.
- `end`: run `orchestration end`, then report what was removed and restored. The Builder worktree and its branch stay, since they hold the work.
- `new`: phase 1, below.

## Phase 1: shape the orchestration (in this chat)

1. Run `orchestration status`. If an orchestration is already set up in this session, say so and stop.
2. Interview Michael with the `interview-me` skill, or `idea-refine` if he brings a raw idea. Settle what the brief needs, per the pinned handoff (the `build-orchestration` skill names it):
   - the goal and scope items;
   - what must survive unchanged;
   - the acceptance journeys, lettered;
   - boundaries;
   - the report formats.
   Section 5 (his UI preferences) goes into the brief verbatim.
3. Write the kickoff prompt: the first thing the fresh Orchestrator reads. It covers its role, the brief's path, the `build-orchestration` skill, and the first slice to aim for.
   - Write it for the model this chat runs on now, following `~/.dotfiles/claude-config/model-profiles/prompting/<that model's id>.md` and the `/magic-prompt` compose rules.
   - If no profile exists for the model, say so and use the closest.
4. Show Michael the brief and the kickoff prompt, and revise until he gives an explicit yes. Nothing is written to the repo before that.

## Transition (after his yes)

5. Pick a short name for the orchestration (lowercase words joined by dashes). Write `tasks/<name>/brief.md` and `tasks/<name>/KICKOFF.md` in this repository.
6. Run `orchestration new <name>`. It:
   - creates the Builder worktree and the Challenger folder under `~/Documents/Worktrees/`;
   - writes `tasks/<name>/RESUME.md`, pointing at the kickoff;
   - makes RESUME.md this chat's card;
   - sets the orchestrator role and autowrap (the 350K limit) for both checkouts.
7. Tell Michael, in one line: ready. Type `/wrap` for a clean start, then say "go". If he skips `/wrap`, phase 2 continues here, and the first automatic compaction drops the interview.

## Phase 2 (in the cleared chat)

Only RESUME.md is loaded. Its next action is to read `KICKOFF.md` and `brief.md`, then follow the `build-orchestration` skill: ledger skeleton, briefs, baseline manifests, and the first assignment. Tell Michael to open each Builder as a new session in the Builder worktree; it sets itself up. Challengers are fresh `challenger` subagents per revision.
