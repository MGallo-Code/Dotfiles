# 0001 - Adopt the coding-mastermind invariant registry

- Status: accepted
- Date: 2026-06-17
- Surfaces: whole repo (paired `*.sh`/`*.ps1` scripts, `skills-scan.py`)

## Context

This repo's whole purpose is one cross-platform setup, but parity between the bash and
powershell sides held only as convention - and had already drifted (the stacked-push
guard exists on mac, not Windows). It had no `.gitignore`, no git hooks, and no CI, so
nothing mechanically protected against a committed private key or a silent platform
divergence.

## Decision

Adopt the kit's Layer-2 artifacts: `INVARIANTS.md`, `DEFINITION_OF_DONE.md`, a PR
template, and `AGENTS.md`. Every cross-cutting invariant names a mechanical enforcer.

## Why a copy (not a symlink) for AGENTS.md

This repo is checked out on Windows, where git symlinks degrade to plain text files
unless `core.symlinks` is on with privileges. So `AGENTS.md` is a real copy of
`CLAUDE.md`, kept identical by a `cmp -s AGENTS.md CLAUDE.md` pre-commit check. (The EA
repo, macOS-only, uses a symlink instead - no guard needed there.)

## Why the parity gate keys on a curated registry (not a grep)

A literal token grep false-positives: `trust_gemini_managed_repos` exists on both sides
under different names, and `regen_combined_agent_rules` uses a different (not missing)
mechanism on Windows. The parity gate keys on a human-curated feature registry with an
explicit `PARITY_EXEMPT` list, so it stays precision-first.

## Consequences

- A `*.sh` behavior change must land on the `*.ps1` side too, or be marked exempt.
- CI rows stay `local-green (pending merge)` until GREEN on a pushed PR.
