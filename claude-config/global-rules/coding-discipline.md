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
