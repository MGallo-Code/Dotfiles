# coding-mastermind - SPEC

Kit version: v1.0 (generic phase). See `MANIFEST.md` for the tool-version baseline.

## Mission (one line)

A reusable, agent-agnostic kit that stops an AI agent from generating code or docs
that fight the existing codebase, its conventions, or future plans, turning 5-10
rework rounds into 1-2. It ships as the DEFAULT to Claude Code / Codex / Gemini /
any future agent through the dotfiles sync rail, with no special prompts.

## The problem it serves (the 7 recurring patterns)

Scored against Michael's own SBIC history. Full detail: the Wiki "AI Coding
Systems" section (`~/Documents/Wiki/index.md`).

1. Cross-cutting invariant enforced per-surface (k-anon floor re-added 5+ times).
2. Architecture bet adopted then unwound (WorkOS), no decision record.
3. Dual source-of-truth migration drift (mass renumber, dup migration prefix).
4. Domain-ungrounded fabrication (off-form fields on SBA Form 1031).
5. Build-before-spec churn (one component revised ~14 times).
6. Stale cross-references plus duplication; guardrails written only AFTER the bug.
7. Rigid rule fought the task ("never renumber" blocked a needed renumber).
   Lesson #1: every guardrail must be overridable-with-justification or it
   becomes the next bug.

## The spine: ENFORCERS vs ADVISORS

- ADVISOR: names an invariant and points at it (CLAUDE.md, ADRs, the locator, the
  critic). Necessary, never sufficient. Patterns #1/#3/#6 all recurred WITH the
  prose rule already present.
- ENFORCER: mechanically guarantees the invariant (a CI check, a Stop-hook re-run
  of that check, a fail-closed chokepoint, a `chmod 0444`).
- The rule: every advisor must name its backing enforcer. An advisor with no named
  enforcer is a flagged smell.

Two axes used when placing every check (canonical home: the wiki
`ai-coding-technique-catalog.md`, do not restate):
- WHEN it bites: PRE-ACT (PreToolUse) -> IN-LOOP (Stop/SubagentStop) -> POST-MERGE
  (CI). Earlier is stronger; CI is the portable backstop.
- POINT vs COVERAGE: a point enforcer guards one named site; a coverage enforcer
  guarantees no site can silently omit the invariant. Only the coverage tier
  closes pattern #1. A coverage check must DECLARE its full surface set (every dir /
  glob the invariant can be violated in) and that set must be audited for completeness:
  a coverage check with an incomplete surface set is secretly a point check (e.g. a
  banned-import scan over `app/lib` but not `components/` or a root `proxy.ts` lets the
  violation through green). Share ONE canonical surface list across sibling checks so
  they cannot drift apart.

A green check is not proof ("rotten green"): every gate must assert a real outcome,
fail-closed on "no tests collected," and keep its own grader un-editable in the
same turn.

## Three-layer context model

- Layer 1 - global rules (`~/Documents/EA/claude-config/global-rules/`), synced to
  all agents. Change rarely.
- Layer 2 - per-repo CLAUDE.md/AGENTS.md, SHORT, pointing at the per-repo
  INVARIANTS registry + domain-grounding + decision log. Change per project.
- Layer 3 - task/session context. Change per session.

Keep CLAUDE.md short: hand-written-minimal files are safe; LLM-bloated files reduce
success and raise cost (ETH/Gloaguen, arXiv:2602.11988).

## What is IN scope (the deliverables, by canonical home)

- agent-skills (rail-distributed): `coding-mastermind-init` (scaffolds a layered
  CLAUDE.md + INVARIANTS stub + DoD/PR template), `coding-mastermind-cross-check`
  (Delta B), `coding-mastermind-audit` (Delta A.3 backstop),
  `coding-mastermind-invariant` (mints new registry rows + their enforcers),
  `coding-mastermind-research-refresh`, `coding-mastermind-update`,
  `coding-mastermind-help` (Delta C). Plus `MANIFEST.md` and the Stop-tier hook
  framework (`hooks/hooks.json`).
- per-repo INVARIANTS registry (Delta A.1): surface-indexed, with recurrence_count
  / detection_signals / enforcer_status. SBIC instance = `platform/INVARIANTS.md`,
  k-anon coverage check is its first entry.
- in-loop interception (Delta A.2): the locator emits applicable invariants +
  recurrence for touched files; drafts the enforcer in-PR when an invariant recurs
  or a new unguarded surface appears. Precision-first.
- global rules: extend `git.md` with the 4 shared-repo PR standards (item 10b).
- wiki: the system concepts + the interaction matrix (items 17-18).
- the rail: cross-agent portability fix (diff-guard + `chmod 0444`).
- decision-log (ADR) enforcers - both back the one advisor "a reverted/superseded bet
  cannot silently return": a reverted dependency is blocked in CODE by a banned-import
  grep gate (`check-banned-imports.mjs`); a superseded design still framed as live in
  DOCS is flagged by a superseded-term grep gate (`check-superseded-terms.mjs`, the docs
  analog - advisory, fail-soft, allowlisted). The link-lint guards stale PATHS; this
  guards stale CLAIMS (present-tense prose about a removed system), which a path check
  structurally cannot see.

## Acceptance criteria

- Each of the 7 patterns has a named ENFORCER, or a stated reason it is
  advisor-only.
- The registry exists with the 3 new fields; k-anon is its first entry.
- In-loop interception surfaces applicable invariants + recurrence on touched files
  (precision-first).
- `coding-mastermind-init` scaffolds cleanly, proven on Charon (Go) with one real
  invariant + one go-runner check.
- The cross-vendor cross-check works (adversarial, sandboxed, proposes-not-applies,
  NOT majority-vote).
- The backstop audit + the 2 maintenance commands + the usage command each RAN once
  and produced a correct artifact.
- `MANIFEST.md` stamps the build date + tool-version baseline; the portability fix
  is applied; the kit distributes to all agents.
- Nothing committed/pushed/PR'd without explicit per-action permission.

## Non-goals (the cure must not add entropy)

- No sprawling multi-agent contraption. Convergent: few agents, two passes, in-repo
  and version-controlled over new SaaS/MCP, short context files. Divergent fan-out
  only for read-only diagnosis.
- No flat prohibitions. Every guardrail is a default-with-audited-override + a
  named owner.
- No duplicated facts. One canonical home each; the rest link.
