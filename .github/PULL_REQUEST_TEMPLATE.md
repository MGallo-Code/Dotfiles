<!-- coding-mastermind PR template. Keep it short; the goal is a real self-check, not theater. -->

## What and why

<one or two lines: the outcome this PR delivers, and the issue/spec it serves>

## Invariants touched

<which `INVARIANTS.md` rows the changed surfaces are subject to; for each, how this PR
keeps it. For a `*.sh` change: did the `*.ps1` side get the same behavior (INV-2)?
"none" is valid if the surfaces match no registry row.>

## Definition of Done

- [ ] Does what the issue/spec said; scope did not silently grow.
- [ ] Cross-platform parity held: `*.sh` and `*.ps1` changed together (or `PARITY_EXEMPT`).
- [ ] Idempotent: a second `setup`/`sync` run is a no-op.
- [ ] Required CI checks are GREEN on this PR (not "will be green").
- [ ] The relevant gate's green asserts a real outcome and FAILS on revert.
- [ ] No secrets in the diff (INV-1); committed SSH config is the `*.template`.

## Blast radius

<the files this PR was expected to touch; flag anything outside that set>
