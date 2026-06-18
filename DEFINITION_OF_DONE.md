# Definition of Done - Dotfiles

A change is done when each item holds, or a reason it does not is stated. "It ran on my
machine" is not done; "the gate is green AND the green asserts a real outcome" is.

## Correctness

- [ ] The change does what the spec/issue said; scope did not silently grow.
- [ ] Cross-platform PARITY (INV-2): a behavior added to the `*.sh` side is added to the
      `*.ps1` side too (or marked `PARITY_EXEMPT` with a reason), and vice-versa.
- [ ] Idempotent: running `setup`/`sync` a second time is a no-op, not a double-apply.
- [ ] No flat prohibition; every guardrail is default-with-audited-override.

## The gate is real (no rotten green)

- [ ] The relevant checks were RUN and are green.
- [ ] Green means something: the check asserts a real outcome and FAILS if you revert the
      implementation (the revert-test). A missing input FAILS, it does not pass vacuously.
- [ ] The check's own config/allowlist was not edited in the same change it guards.
- [ ] An INVARIANTS row's Status matches reality: a built-but-uncommitted check is
      `local-green (pending merge)`, not `required-gate`; CI-green is claimed only when
      green on the PR.

## Hygiene

- [ ] No secrets/keys/tokens in the diff (INV-1). The committed SSH config is the
      `*.template`, never the populated copy.
- [ ] The agent-skills sync gate (INV-3) still fails closed and is identical across
      bash/powershell.
- [ ] Docs/cross-references the change touches still resolve.
