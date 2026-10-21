# Coding discipline (default for build work, every repo, every agent)

The standing default for non-trivial code or doc changes. No special prompt required.

- PLAN before you implement, then stress-test the plan: a fresh-context adversarial pass
  (`doubt-driven-development`) by default; escalate to `coding-mastermind-cross-check` (Codex +
  Gemini refute the plan) only for high-stakes, large, or irreversible changes.
- Before changing code, read the repo's `INVARIANTS.md` if present. It lists the
  cross-cutting rules your change is subject to and the CI check guarding each. Honor them.
- Every cross-cutting rule names a mechanical enforcer (a CI check, a hook, a `chmod 0444`),
  never just prose. A rule with no backing enforcer is a smell: flag it, don't rely on memory.
- Reach for the `coding-mastermind-*` skills: `-init` (harden a repo), `-help` (how the kit
  works), `-cross-check` (rare high-stakes diffs), `-audit` (check the invariants registry).
- "Prove it, don't promise it": a gate counts only when GREEN in CI, not when you feel sure.
  See `git.md`.
- Re-check in proportion: while iterating, run the checks the change can affect; run the full
  suite once before calling it done (or let CI). A deterministic check on unchanged inputs
  proves nothing new. If the suite is slow, say how long it takes and what dominates. In an
  orchestrated build, the assignment's check list wins over this line.

## Smallest complete change

- Before writing new code, stop at the first option that fully works: does it need to exist at all
  (skip features and options nobody asked for, and name them in one line) -> something already in this
  codebase -> the standard library or platform -> an installed dependency -> the minimum new code.
- Small solution, complete change: before editing, list every place it must reach (callers, tests,
  fixtures, config, the INVARIANTS rows) and finish all of them.
- A deliberate shortcut with a known limit gets a comment: `shortcut: <the limit>, <when to upgrade>`.
- Never cut to shrink a diff: validation at trust boundaries, data-loss handling, security,
  accessibility, or defensive code that guards a known failure (prove it unneeded before deleting).
