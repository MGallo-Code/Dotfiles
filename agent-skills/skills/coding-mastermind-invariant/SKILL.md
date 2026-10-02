---
name: coding-mastermind-invariant
description: Mints NEW invariants for a repo's INVARIANTS.md registry, then drafts and revert-tests the enforcer that guards each. Two modes - discover (mine git + GitHub history for recurring problems that have no registry row yet, ranked by recurrence) and add (scaffold one named invariant directly). Proposes the row AND the backing CI check/hook; never auto-edits or auto-commits. Use when asked to "add an invariant", "what invariant should we add", "turn this recurring bug into a gate", or "mine our history for things worth enforcing". Distinct from coding-mastermind-audit (which maintains EXISTING rows) and coding-mastermind-init (which scaffolds a whole repo).
---

# coding-mastermind-invariant

## Overview

`coding-mastermind-init` scaffolds a whole repo's registry; `coding-mastermind-audit`
keeps the EXISTING rows honest. This skill is the missing middle: it MINTS new rows. An
invariant earns its place only when a rule has broken repeatedly across many surfaces, so
this finds that evidence (or takes a rule you already know you want), phrases it as an
end-state, and - the part that makes it real, not prose - drafts and revert-tests the
mechanical enforcer that guards it. Every advisor must name a backing enforcer; this skill
ships both. It PROPOSES; the human (or the main loop after a nod) edits and commits.

## When to Use

- **discover** (default): "what invariant should we add", "mine our history for recurring
  issues worth enforcing", after a burst of work, or periodically alongside the audit.
- **add `<description>`:** you already know the rule ("rate every confidential read",
  "no raw `process.env` outside config") and want it scaffolded + enforced.
- `--deep`: also mine past Claude transcripts (token-heavy; off by default).

**When NOT to use:** to maintain existing rows (that is `coding-mastermind-audit`); to
stand up a registry from scratch (that is `coding-mastermind-init`); for a one-off bug (a
single occurrence is a fix, not an invariant).

## The bar (a candidate must clear ALL of these)

1. **Recurrence ≥ 2** across DIFFERENT surfaces (a guard re-added per-file, the same class
   of bug in two PRs). One occurrence is a fix, not an invariant.
2. **A precise detection signal.** Precision-first: a noisy signal that cries wolf gets the
   whole registry ignored, so it is worth zero. Favor a few reliable catches over recall.
3. **Mechanizable + cross-cutting.** It must hold across MANY surfaces (so it drifts when
   one silently omits it) AND be checkable by a script/test/hook. A single-site rule or a
   judgment call ("which rate-limit layer") is NOT an invariant - leave it advisor-only.

## Mode: discover

1. **Load the registry first.** Read `INVARIANTS.md` so you never re-propose a covered
   rule; note each row's surfaces + pattern.
2. **Mine evidence (default = git + GitHub, cheap).**
   - git: reverts (`git log -i --grep=revert`), re-hardening / "again" / "regression" /
     "re-add" commits (the SAME fix landing twice = the strongest signal), and high-churn
     files (`git log --name-only --since=...` frequency) where a guard keeps getting touched.
   - GitHub: closed-as-duplicate issues, recurring labels, the same review comment across
     PRs, and incident / post-mortem notes (`gh issue list --state all`, `gh pr list`).
   - `--deep` only: grep `~/.claude/projects/*/*.jsonl` for signal markers (an error class,
     "this keeps happening", "again", repeated debugging of one file) and deep-read ONLY the
     top few high-signal sessions. Token-heavy - opt-in, signal-grep before any deep read.
3. **Cluster signals into candidate rules and classify each against the pattern catalog**
   (below) so the proposal is concrete, not abstract.
4. **Apply the bar.** Drop one-offs, noisy-signal rules, and judgment-calls. Keep what
   clears all three tests.
5. **For each survivor, run the scaffolding** (next section): row + enforcer + revert-test.
6. **Rank and present SHORT.** Highest-recurrence / highest-leverage first; say what you cut.
7. **Surface non-invariant byproducts.** If the sweep turned up a concrete live bug or a
   worthwhile one-off cleanup that does NOT clear the bar, report it SEPARATELY as a
   non-invariant finding (a fix / PR, not a registry row) - never discard it. A run that
   mints zero invariants but finds two real bugs still paid for itself.

## Mode: add `<description>`

1. **Phrase the rule as an END-STATE, never a banned verb** (pattern #7): "k-anon floor
   holds," not "never inline `<5`." A flat "never do X" becomes the next bug.
2. **Confirm it is a true invariant** (cross-cutting + mechanizable). If it is single-site
   or a judgment call, say so and stop - propose it as an advisor-only note, not a gate.
3. **Run the scaffolding.**

## Scaffolding (shared by both modes - the "init for one invariant")

a. **Draft the row:** next-free `ID`; end-state phrasing; enforcement point (the single
   chokepoint that makes it hold); gate + tier (pre-commit -> local -> CI; POINT guards one
   site, COVERAGE guarantees no site can silently skip it - only COVERAGE closes pattern #1);
   status; recurrence; precise detection signals; escape hatch (default-with-audited-override
   + a named owner, never a flat ban).
b. **Draft the enforcer** with the cheapest reliable mechanism: a `node scripts/ci/check-*.mjs`
   (plain ESM, runs locally AND in CI - the portable default), a pgTAP test (DB/point), a
   PreToolUse/Stop hook (Claude in-loop), or `chmod 0444` (cheapest of all). It must assert a
   REAL outcome, FAIL-CLOSED, and print a self-correcting `Fix:` message. Prefer COVERAGE over
   POINT for a pattern-#1 rule.
c. **Wire it:** add the CI job / hook entry / allowlist escape-hatch file.
d. **Revert-test:** prove green -> RED on a planted violation -> green. An enforcer that does
   not fail on a real violation is theater.
e. **Status honestly:** `to-build` or `local-green (pending merge)` - NEVER `required-gate`
   until it is green on a real PR ("prove it, don't promise it").
f. **Present** row + enforcer + revert-test evidence. Propose; do not auto-edit `INVARIANTS.md`
   or commit.

## Pattern catalog (real recurrences - classify each candidate)

| # | Recurring failure | Enforcer shape |
|---|---|---|
| 1 | a guard re-added per-surface (k-anon floor) | COVERAGE gate over the surface glob |
| 2 | a reverted bet re-imported (a removed dep/design) | banned-import check + an ADR |
| 3 | two things that must stay identical drift (dual-schema, ledger parity) | parity check |
| 4 | fabricated data not in an authoritative source (form fields) | adversarial grep vs the raw source |
| 6 | a privileged call site not logged / allowlisted | audit/allowlist COVERAGE gate |
| 7 | a flat "never X" that becomes the next bug | re-phrase as an end-state + audited escape hatch |
| + | secret-leak, rotten-green (vacuous pass), hallucinated-dep, composition (one-layer-per-route) | scanner / fail-closed test / dep check / advisor-only |

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "It happened once, enforce it." | The bar is ≥2 recurrences across surfaces. One is a fix. |
| "Phrase it 'never do X'." | Banned verbs become the next bug (#7). End-state + escape hatch. |
| "Ship the row, write the check later." | An advisor with no enforcer is the exact rot the kit prevents. Draft + revert-test the enforcer WITH the row. |
| "A POINT check is fine." | Only if a new surface cannot silently skip it. If it can, you need COVERAGE. |
| "Mark it required-gate." | Not until it is green on a real PR. Until then `local-green (pending merge)`. |
| "Deep-read every transcript." | Default is git+GH. Transcripts are `--deep`, signal-grepped before any deep read. |

## Red Flags

- Auto-editing `INVARIANTS.md` or committing (this skill proposes).
- A proposed invariant with no drafted enforcer, or an enforcer not revert-tested.
- A flat prohibition / banned-verb phrasing with no escape hatch.
- A low-precision detection signal (it will be ignored - worth zero).
- Re-proposing a rule an existing row already covers (registry not read).
- A long, unranked candidate list (precision-first: rank and cut).

## Verification

- [ ] Read the existing `INVARIANTS.md`; no proposal duplicates a covered rule.
- [ ] Each proposal cleared the bar (≥2 confirmable recurrences across surfaces, or an explicitly named rule) with a precise signal.
- [ ] Each is an end-state with a default-with-audited-override escape hatch (no banned verb).
- [ ] Each ships a drafted enforcer, revert-tested green -> RED -> green, fail-closed, status `to-build` / `local-green (pending merge)`.
- [ ] Output ranked and short; nothing auto-edited or committed.

## Related

- `coding-mastermind-audit` - maintains EXISTING rows (recurrence, uncovered surfaces); this MINTS new ones.
- `coding-mastermind-init` - scaffolds a whole repo's registry; this adds one invariant to an existing one.
- The enforcer-vs-advisor doctrine + the full pattern catalog: the kit `SPEC.md`.
