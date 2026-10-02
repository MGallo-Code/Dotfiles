---
name: coding-mastermind-init
description: Scaffolds the coding-mastermind kit into a repo - a short layered CLAUDE.md, an INVARIANTS registry stub, a Definition-of-Done, and a PR template - so an agent reuses what exists and every cross-cutting invariant has a named enforcer. Use when onboarding a repo to the kit, when a repo keeps re-breaking the same invariant, or when asked to "harden this repo" or "set up coding-mastermind here."
---

# coding-mastermind-init

## Overview

Scaffolds the kit's per-repo Layer-2 artifacts into the current repo, then hands you
a short authoring checklist. The kit's spine is ENFORCERS vs ADVISORS: a prose rule
(advisor) is necessary but never sufficient, so every cross-cutting invariant must
name a mechanical gate (enforcer). This skill lays down the registry that tracks
those invariants and the templates that wire them into review and CI. It is
language-agnostic: the check PATTERN is the same everywhere, only the runner changes
(Node `.mjs`, `go test`/`go vet`, `cargo`, `ruff`/`pytest`).

It SCAFFOLDS, it does not overwrite. Where a file already exists it adds a pointer or
leaves it, so re-running is safe.

## When to Use

- Onboarding a new repo to the kit.
- A repo keeps re-breaking the same invariant per-surface (pattern #1) and needs a
  coverage gate + a registry to count recurrence.
- The user says "harden this repo," "set up coding-mastermind," or "add an invariants
  registry."

**When NOT to use:** a throwaway script, or a repo that already has the kit (just
edit `INVARIANTS.md` directly).

## Process

1. **Detect the toolchain** (picks the example runner): look for `package.json`
   (Node), `go.mod` (Go), `Cargo.toml` (Rust), `pyproject.toml`/`setup.py` (Python).
   Record which one; the example enforcer in the registry stub is written for it.
2. **Scaffold, never clobber.** For each target, create it only if absent:
   - `INVARIANTS.md` at the repo root - from `templates/INVARIANTS.md.template`. The
     surface-indexed registry: the spine of the kit.
   - `DEFINITION_OF_DONE.md` - from `templates/DEFINITION_OF_DONE.md`.
   - `.github/PULL_REQUEST_TEMPLATE.md` - from `templates/PULL_REQUEST_TEMPLATE.md`.
   - `CLAUDE.md` - if ABSENT, from `templates/CLAUDE.md.template` (short, layered,
     points at `INVARIANTS.md`). If PRESENT, do NOT rewrite it; add a one-line pointer
     to `INVARIANTS.md` near the top if missing.
   - `AGENTS.md` - the cross-tool constitution Codex/Cursor/Gemini read. If absent,
     create it as a byte-identical copy of `CLAUDE.md` so non-Claude agents get the
     SAME per-repo context, and offer a pre-commit `cmp -s AGENTS.md CLAUDE.md` copy to
     keep them identical. WITHOUT this the repo is Claude-only at Layer 2 (the portable
     layer is still CI + the synced global rules, but the per-repo constitution would
     not reach the other agents).
3. **Seed the first invariant.** Walk the user through one real invariant for this
   repo: its end-state (not a banned verb), the single enforcement point, and the
   gate. Add it as the first `INVARIANTS.md` row. If it has no gate yet, mark it
   `to-build` and note the runner-appropriate enforcer to write.
4. **Offer the enforcer + wiring** (do not force):
   - the check itself (`scripts/ci/<name>.mjs` for Node, `<name>_test.go` or a
     `go vet`-style check for Go, etc.) that asserts a REAL outcome and fails-closed;
   - a CI job that runs it (the portable, vendor-neutral enforcer);
   - for Claude Code only, a `Stop` hook that re-runs it in-loop (the kit's
     `hooks/hooks.json` is the template - CI stays the backstop for other agents).
5. **Report** what was created vs skipped (already-present), and the authoring TODO.

## Common Rationalizations (reject these)

- "The prose rule in CLAUDE.md is enough." No - patterns #1/#3/#6 all recurred WITH
  the prose rule present. An advisor with no named enforcer is a flagged smell.
- "I'll add the gate later." Later is when the invariant breaks again. The promotion
  trigger is the SECOND recurrence, not the third.
- "A passing check means it works." Only if its green asserts a real outcome. A check
  that passes with no tests collected, or with `--if-present` on a missing script, is
  rotten green - fail it closed.
- "One big CLAUDE.md is simpler." Bloated context files reduce agent success and raise
  cost. Keep Layer 2 short and point at the registries.

## Red Flags

- Overwriting an existing CLAUDE.md (clobbers the repo's real conventions).
- A flat prohibition ("never X") with no logged escape hatch - every guardrail is
  default-with-audited-override plus a named owner.
- Scaffolding `INVARIANTS.md` and walking away: an empty registry is an advisor with
  no teeth. Seed at least one real invariant + its enforcer.

## Verification

- `INVARIANTS.md`, `DEFINITION_OF_DONE.md`, `.github/PULL_REQUEST_TEMPLATE.md` exist;
  `CLAUDE.md` exists and points at `INVARIANTS.md`.
- At least one real invariant row is filled in (not the example placeholder).
- If an enforcer was written, it RUNS and its green means something: run it on the
  current tree (exit 0), then make it red (revert-test: it must FAIL if you break the
  invariant), then green again.
- Nothing pre-existing was overwritten (diff shows only new files + at most a one-line
  CLAUDE.md pointer).

## Related

- The generic concepts (enforcers-vs-advisors, the PRE-ACT/IN-LOOP/POST-MERGE ladder,
  POINT vs COVERAGE) live in the kit's `SPEC.md` and the system wiki.
- `coding-mastermind-help` - how to use the whole kit.
- `coding-mastermind-cross-check` - the rare-high-stakes cross-vendor adversarial pass.
- The SBIC instance is the worked example: `platform/INVARIANTS.md` +
  `platform/scripts/ci/check-cohort-floor-coverage.mjs`.
