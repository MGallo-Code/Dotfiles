# Forge Automation Audit - 2026-06-25

## Summary

Forge is working as a method, but not yet as a system. The recent WSL/SBIC work shows
that the plan-hardening and build-verification loops catch real defects, sometimes many
rounds in. The failure is that Forge still lives mostly as prose plus manual handoffs, so
Michael has been acting as the scheduler, continuity store, and compliance gate.

The fix is not another reminder. Forge needs a cross-agent state machine and checker that
Claude, Codex, and Gemini can all see:

1. A shared `/forge` command/prompt entrypoint.
2. A mandatory tracker file with machine-readable status.
3. A clarify / assumption gate before planning and before implementation.
4. A handoff template that carries Forge state by default.
5. A checker that reports whether risky questions are answered, plan cross-check,
   build verification, visual proof, and PR permission are complete.
6. A one-screen resume capsule for compaction, `/clear`, and fresh-agent starts.
7. Claude hooks as a convenience layer, not the source of truth.

## Evidence Base

Local evidence inspected:

- `~/.claude/history.jsonl`
- `~/.claude/projects/**/*.jsonl`
- `~/.claude/plans/*.md`
- `~/Documents/Wiki/wiki/ai-coding-*.md`
- `~/Documents/Wiki/wiki/coding-mastermind-sync-system.md`
- `~/Documents/Wiki/wiki/cross-session-continuity-for-coding-agents.md`
- `~/Documents/EA/claude-config/global-skills/forge/SKILL.md`
- `~/Documents/EA/claude-config/global-commands/handoff.md`
- `~/.dotfiles/INVARIANTS.md`

Quantitative signals from `~/.claude/history.jsonl`:

- 30 handoff / fresh-agent prompts.
- 44 reminder / "do not" / "make sure" prompts.
- 41 context / compact / resume prompts.
- 48 Forge / cross-check prompts.
- 62 PR / commit / branch / merge guardrail prompts.

Transcript scale:

- 545 Claude project JSONL files under `~/.claude/projects`.
- 40 top-level sessions and 505 subagent logs.
- The largest SBIC sessions reached roughly 0.8M-1.0M cached input tokens, which matches
  the observed need for compaction and external trackers.

## What Is Going Well

- **Forge catches real defects.** The access-model backend plan converged from about 15
  significant findings in round 1 to 0 by round 9, with several late findings becoming
  explicit enforcers.
- **Trackers work when used.** Files like `~/.claude/plans/access-model-backend-tracker.md`
  and `~/.claude/plans/forms-phase1-access-spine-build-tracker.md` preserved state across
  compaction and fresh sessions.
- **Cross-vendor review is useful when actually run.** Codex repeatedly found real issues
  that panel-only rounds missed, including missed surfaces and over-claimed coverage.
- **Mechanical invariants pay off.** Repeated classes such as hub wiring, fresh-client
  setup aborts, and access-surface drift became dotfiles/SBIC invariant rows and gates.
- **Live verification beats plan reasoning.** The remote-hubs work caught a real
  `tailscale serve --set-path` behavior difference and a fresh-client `setup.sh --client`
  abort only when deployed/tested, despite prior plan review.

## What Is Not Going According To Plan

### 1. Forge Is Optional In Practice

The user repeatedly had to type `/forge`, paste the Forge process into prompts, ask whether
Forge was actually used, or restart the strict 3-round loop manually. Evidence includes:

- `history.jsonl` session `9f0968e7-b91d-4c8a-8a36-fd04f3c798c9`: user pasted the whole
  cross-check -> handoff -> fresh-agent -> verify workflow manually.
- `~/.claude/projects/-root-Documents-SBIC/d8289d25-41a4-4ee7-a48c-6d25a3ea1d58.jsonl`:
  assistant later had to explain that Forge phases 4-5 were not complete and that fusion
  was degraded.
- `~/.claude/projects/-root-Documents-SBIC/0a6e496e-4f14-44d2-9f52-ec28338e3f92.jsonl`:
  Michael asked whether the strict 3-round cross-check actually happened, then had to ask
  for it explicitly.

Root cause: Forge is a skill/procedure, not a required state transition.

### 2. Build Verification Is Easy To Skip

The original Forge handoffs hardened plans but did not always require the implementing
agent to run the build-verification loop. This was caught by Michael:

- Session `6bfe36e6-d78f-40df-87a3-0f9601add6ae`: assistant admitted the handoffs were
  "half right" because plan cross-check happened, but build cross-check had been left
  implicit.
- Session `8518499b-dfda-4749-af5e-4cde73572b38`: tracker notes that the original
  8-round convergence excluded Codex; after redoing Codex-inclusive rounds, many real
  defects were found.

Root cause: "build verified" is not a durable field with a checker. It is text in the
agent's final answer unless Michael challenges it.

### 3. Handoffs Are Still Paste-Based

The process routinely required Michael to open a fresh agent, paste a file path, and remind
it of Forge context. This becomes worse after `/compact`, because the next model is operating
from a lossy summary and may confidently invent state that was only present in the prior context:

- Session `8518499b-dfda-4749-af5e-4cde73572b38`: Michael asked how to continue in a
  fresh context; the answer was to `/compact` or `/clear` and paste a kickoff prompt.
- Session `70ddf556-5e5b-448e-94bd-fc536e2c2f5b`: Michael asked for a handoff file with
  everything needed so he could `/clear` and paste the filename.

Root cause: the continuation primitive is human-mediated. There is no `forge resume`
equivalent that loads state and tells the agent the next required transition. A transcript
summary is not a reliable workflow database.

### 4. PR / Commit Guardrails Are Too Weak

The strongest concrete miss was PR #276:

- Session `0a6e496e-4f14-44d2-9f52-ec28338e3f92`: the assistant opened a PR despite the
  standing hold to keep the PR closed until backend, seed, GUI, and visual verification
  were all ready. Michael caught it: "you pr'd? You're specifically not supposed to do
  that until EVERYTHING is settled."

There was also a dotfiles sync incident where auto-commits used `root <root@...>` as the
author identity, which later required cleanup.

Root cause: current hooks warn about stacked pushes, but do not know about Forge state,
repo-level PR holds, or explicit PR permission.

### 5. Cross-Agent Distribution Is Incomplete

Dotfiles already mirrors global commands to Codex and Gemini:

- `~/.codex/prompts/handoff.md`
- `~/.gemini/commands/handoff.toml`

But live Claude command wiring is missing:

- `~/Documents/EA/claude-config/global-commands` has `handoff.md`, `skills-review.md`,
  and `sync-review.md`.
- `~/.claude/commands` is not currently wired from that directory.
- There is no shared `/forge` command prompt in `global-commands`, only a Forge skill in
  `global-skills`.

Root cause: Forge exists as a skill for all agents, but not as a generated command entrypoint
with a standard tracker/checker contract.

### 6. Risky Assumptions Are Too Easy

Michael's additional requirement is explicit: agents should question him on risky unknowns
instead of making "reasonable" assumptions that later turn out wrong. This is the sibling
failure to skipped cross-checking. Both are cases where a workflow step lives as personality
guidance instead of as a tracked gate.

Examples of decisions that must block until clarified:

- auth and data visibility,
- schema and migrations,
- PR timing and release bundling,
- irreversible operations,
- UX scope that affects business workflows,
- business rules and compliance posture.

Root cause: "ask when unsure" is prose. Forge needs a decision ledger that can block
planning or implementation while high-risk questions remain unresolved.

### 7. Context Compaction Loses Workflow State

Michael specifically called this out during this audit: every compaction burns useful context,
but not compacting makes agents hallucinate or degrade. The failure is not that context windows
are finite; it is that important workflow state lives inside the context window.

State that must survive compaction:

- current phase,
- approved decisions,
- unresolved questions,
- clean-round counts,
- reviewer outputs and evidence paths,
- what was actually verified,
- PR/commit permission,
- next exact action.

Root cause: the session transcript is being used as both conversation and job-state store. Long
jobs need a compact external resume capsule, not a longer prompt.

### 8. Live Config / Destructive Verification Is Risky

The remote-hubs work produced a recurring lesson: agent config and MCP wiring should not be
verified by mutating the live config being protected. Some failures only showed up under real
execution, but the safe proof path is a throwaway `$HOME`, temp config dir, stub CLI, or container.

Root cause: "test the real thing" and "do not damage live config" need a standard isolated
rehearsal pattern. That belongs in Forge for `high_risk` and `destructive` work.

### 9. Reviewer Context Can Be Too Broad

Gemini context drift was another faced issue: setup had been narrowed to source/control-plane
roots, while sync still appended broad roots like `~/Documents`, `~/Downloads`, and agent-state
directories. That makes cross-check reviewers slower and more likely to inspect caches, downloads,
or stale generated content.

Root cause: cross-agent reviewer quality depends on deterministic workspace scope. Sync and setup
must set the same narrow Gemini roots instead of appending broad directories.

### 10. Generated Agent Config Can Materialize Secrets

During this implementation pass, live Gemini settings contained literal hub bearer values for
some generated MCP entries, while the tracked source intended env-var references. This is already
the class covered by dotfiles INV-4, but the source behavior needed to do more than re-lock the
file: it should scrub known hub headers back to env references after Gemini rewrites settings.

Root cause: some agent CLIs do not preserve indirection exactly as authored. Generated config
needs both source-level env refs and a generated-config scan/scrub.

## Target Architecture

### Cross-Agent First

The authoritative layer must work for Claude, Codex, and Gemini:

- Source prompts and templates live in `~/Documents/EA/claude-config`.
- Dotfiles generates/mirrors them to Claude, Codex, and Gemini.
- Forge state lives in files, not in one agent's context window.
- A shell/Python checker validates state from the filesystem, so any agent can run it.

Claude hooks are useful but secondary. They can block or ask at action time in Claude Code,
but they cannot be the only enforcement mechanism because Codex and Gemini need the same
workflow.

### Clarify / Assumption Gate

Forge should start with a blocking clarification pass, and repeat it before implementation.
The question format should be constrained:

- Ask 1-3 sharp questions at a time.
- Include a recommended default and the tradeoff.
- Do not ask open-ended "what do you want?" when the system can frame the choice.
- Do not proceed on a high-risk assumption unless the tracker records Michael's approval.

Example:

```text
Should LPs see raw uploaded forms or only derived performance for v1?
Recommended: derived performance only. It preserves LP value while avoiding raw-file
visibility until the disclosure model is proven.
```

This makes the effective Forge sequence:

```text
clarify risky unknowns -> plan -> cross-check plan -> handoff -> implement -> verify build
```

### Required Forge State

Create one task directory per Forge effort, for example:

```text
~/Documents/Agent-Forge/<slug>/
  tracker.json
  tracker.md
  plan.md
  handoff.md
  resume.md
  crosschecks/
    plan-r01-codex.txt
    plan-r01-gemini.txt
    build-r01-codex.txt
```

Use `~/Documents/Agent-Forge` instead of `~/.agent-forge` because Codex-style sandboxed
agents already have `~/Documents` in their writable roots. A neutral hidden home that is
outside the sandbox turns the tracker into another manual failure point.

Minimum `tracker.json` fields:

- `task_slug`
- `repo`
- `risk_class`: `small`, `non_trivial`, `high_risk`, `destructive`
- `phase`: `clarify`, `ground`, `plan`, `plan_crosscheck`, `handoff`, `implement`,
  `build_verify`, `visual_verify`, `ready_for_pr`
- `open_questions`
- `approved_decisions`
- `assumptions_made`
- `assumption_risk`: `low`, `medium`, `high`
- `plan_clean_streak`
- `build_clean_streak`
- `reviewers_required`
- `reviewers_completed`
- `degraded_reviewers`
- `open_findings_count`
- `gates_run`
- `visual_required`
- `visual_verified`
- `pr_allowed`
- `explicit_human_override`
- `last_evidence`
- `next_action`

The markdown tracker remains human-readable, but the JSON state is what hooks/checkers read.
`resume.md` is the compact handoff after `/compact` or `/clear`: current phase, blockers,
approved decisions, last evidence path, and next exact action.

High-risk assumptions block implementation. Low-risk assumptions are allowed only when they
are reversible and logged.

### Risk Router

The default classifier:

- `small`: one-file or trivial edits -> normal checks only.
- `non_trivial`: multi-file feature, new component/service, migration, design choice ->
  Forge tracker required.
- `high_risk`: auth, RLS, PII, data deletion, billing, production config, SOC 2 controls,
  cross-machine setup, or invariant-touching diff -> Forge + cross-vendor critic required.
- `destructive`: production data, credential rotation, deletes, rewrites, force push ->
  Forge + explicit human approval + isolated rehearsal.

This turns "Michael remembered to ask for Forge" into "the system routed the task."

## Recommended Implementation Plan

### Phase 1 - Make Forge Visible And Durable

Goal: any agent can start or resume Forge from a shared command and tracker.

Changes:

- Add `~/Documents/EA/claude-config/global-commands/forge.md`.
- Wire `global-commands -> ~/.claude/commands` safely in `manifest.{sh,ps1}` and setup/sync,
  while preserving existing real command directories if present.
- Update command generation so `/forge` mirrors to:
  - `~/.codex/prompts/forge.md`
  - `~/.gemini/commands/forge.toml`
- Make Forge tracker creation mandatory in
  `~/Documents/EA/claude-config/global-skills/forge/SKILL.md`.
- Add `global-skills/forge/templates/tracker.json` and `tracker.md`.
- Add/update `resume.md` during long Forge runs so compaction does not require transcript memory.
- Update `/handoff` to include a conditional `## Forge State` block whenever a tracker exists.
  That block must include:
  - decisions Michael explicitly made,
  - unapproved assumptions,
  - open questions,
  - "do not build past this" blockers.

Acceptance:

- A fresh Claude, Codex, or Gemini session can be pointed at a Forge tracker and know the
  current phase, next action, what is verified, which decisions are approved, and what
  remains unverified or unresolved.

### Phase 2 - Add A Forge Checker

Goal: "done" becomes checkable.

Changes:

- Add `scripts/forge/check-state.py`.
- It reads `tracker.json` and reports:
  - open high-risk questions,
  - high-risk assumptions without approval,
  - implementation started before required decisions were recorded,
  - missing plan cross-check,
  - missing build verification,
  - degraded/missing reviewers,
  - dirty/unresolved findings,
  - visual verification required but absent,
  - PR not allowed.
- Add a `forge status` command/prompt section that every agent can run before final answer.
- Exit codes:
  - `0`: `READY`,
  - `1`: `INCOMPLETE`,
  - `2`: `BLOCKED`,
  - `3`: `INVALID`.

Acceptance:

- A tracker with missing Codex/Gemini evidence cannot report as clean unless
  `explicit_human_override` is set with a reason.
- A tracker with `build_clean_streak < required` reports `not ready`.
- A tracker with `open_questions` or unapproved high-risk assumptions reports `blocked`.

### Phase 3 - Add Action-Time Guards

Goal: prevent the PR #276 class.

Changes:

- Add Claude/Codex `PreToolUse(Bash)` hook `forge-guard.sh` for:
  - `gh pr create`
  - `gh pr merge`
  - `git push`
  - `git commit`
- If `FORGE_TRACKER` is set, check that tracker.
- Otherwise find the newest `~/Documents/Agent-Forge/*/tracker.json` whose `repo` matches
  the current git root.
- If the checker does not return `READY`, return `permissionDecision: ask` with the missing
  checklist.
- Add PR template fields:
  - `Forge: N/A | tracker path | verified`
  - `Plan cross-check:`
  - `Build verification:`
  - `Visual verification:`
  - `Explicit PR approval:`

Acceptance:

- Claude Code pauses before PR creation when a tracker is incomplete.
- Codex gets the same PreToolUse guard registration in `~/.codex/config.toml` after trust.
- Gemini still sees the same PR requirements through generated rules/templates and can run the
  checker, but no equivalent hook surface is configured here.

### Phase 4 - Enforce Plumbing In Dotfiles

Goal: prevent the Forge tooling itself from drifting.

Changes:

- Add dotfiles invariant row, likely `INV-11`: Forge wiring and state checker stay
  distributed to Claude, Codex, and Gemini, or extend INV-7 for command wiring.
- Add `scripts/ci/check-forge-wiring.py`.
- Gate:
  - `global-commands/forge.md` exists.
  - generated Claude/Codex/Gemini command targets are configured.
  - Forge skill references mandatory tracker fields.
  - handoff template includes Forge State block.
  - hook registration includes `forge-guard.sh` where supported.
  - `--machine` verifies the generated command files and live Claude/Codex hook registration.
  - PR template exposes Forge status, tracker, plan/build/visual verification, and explicit PR approval.

Acceptance:

- CI fails if a future sync drops Forge from one agent but not the others.

### Phase 5 - Measure Whether It Worked

Goal: know if the automation reduces Michael's manual workload.

Track per Forge effort:

- manual Forge rescue prompts,
- number of compaction/handoff prompts,
- missing reviewer/degraded reviewer events,
- plan findings by round,
- build findings by round,
- PR guard attempts,
- escaped defects after "done."

Promotion rule:

- On the second recurrence of a manual reminder, either add it to the tracker/checker or
  explicitly mark it as a human judgment that should not be automated.

## What Not To Do

- Do not make Claude hooks the source of truth. They are Claude-only.
- Do not force Forge on one-line edits. That will make agents route around it.
- Do not let a critic verdict become the gate. The gate is tracker state plus actual command
  outputs, with degraded reviewers recorded.
- Do not store Forge state only in `~/.claude/projects/*/memory`; that is machine-local and
  does not solve Mac/WSL/Codex/Gemini continuity.
- Do not treat "3 arms in one round" as "3 consecutive clean rounds." The tracker should make
  that distinction impossible to blur.
- Do not let "reasonable assumption" carry auth, visibility, schema, migration, PR timing,
  irreversible, UX-scope, or business-rule decisions. Those are tracked questions.

## Immediate Next Step

Implement Phase 1 as a small dotfiles/EA change:

1. Add the shared `/forge` command source.
2. Wire Claude commands safely.
3. Make the Forge tracker mandatory with clarify/decision fields.
4. Add the Forge State block to `/handoff`, including decisions and unresolved assumptions.
5. Normalize Gemini workspace roots in setup/sync so cross-check reviewers stay focused.
6. Run dotfiles gates:
   - `scripts/ci/check-parity.py`
   - `scripts/ci/check-skill-targets.py`
   - `scripts/ci/check-hub-wiring.py`
   - `scripts/ci/check-local-selfref.py`
   - command generation verification.

That is the smallest change that reduces Michael's manual burden without pretending hooks can
solve cross-agent continuity.
