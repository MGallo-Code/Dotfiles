---
name: coding-mastermind-help
description: Explains how to use the coding-mastermind kit in under a screen - what is automatic and global vs per-repo, how to harden a new repo, when to reach for the cross-vendor cross-check, and where the canonical homes are. Derives from the kit's real structure so it does not go stale. Use when asked "how do I use coding-mastermind / the kit" or "what does coding-mastermind give me."
---

# coding-mastermind-help

## Overview

A task-oriented answer to "how do I use this kit," derived from the kit's real
structure (list the installed `coding-mastermind-*` skills, read the MANIFEST) rather
than a hand-maintained copy that drifts. Keep the answer to under a screen.

## When to Use

- Someone asks how to use the kit, what is automatic, or how to harden a repo.
- You need a quick orientation before reaching for a specific kit command.

**When NOT to use:** to actually run a command (invoke that command's skill directly).

## Process

1. **List what is installed** (so the answer is current, not from memory):
   ```bash
   ls ~/Documents/agent-skills/skills | grep '^coding-mastermind'
   sed -n '1,20p' ~/Documents/agent-skills/coding-mastermind/MANIFEST.md
   ```
2. **Answer these, briefly:**

   **What is AUTOMATIC + global (the advisors).** The synced rules and skills every
   agent reads, distributed by the dotfiles rail to Claude Code, Codex, and Gemini. No
   prompt needed. These NAME invariants; they do not enforce them.

   **What is PER-REPO (the enforcers).** The mechanical checks: a repo's `INVARIANTS.md`
   registry, its `scripts/...` checks + CI gates, and (Claude Code only) a `Stop` hook
   that re-runs them in-loop. The invariant LIVES in CI (vendor-neutral); each agent
   gets the best in-loop enforcement its own harness supports.

   **How to harden a new repo.** Run `coding-mastermind-init` (scaffolds a short layered
   CLAUDE.md + an `INVARIANTS.md` stub + a DoD + a PR template), then author that repo's
   first real invariant and its enforcer. The init skill walks you through it.

   **The hands-off loop.** The locator reports which `INVARIANTS.md` rows the touched
   files are subject to; `compliance-guard` proposes drafting the enforcer in-PR when an
   invariant recurs or a new surface appears (the promotion trigger is the SECOND
   recurrence). `coding-mastermind-invariant` mints a NEW row plus its enforcer when a
   recurring problem has no row yet (or scaffolds one you name); `coding-mastermind-audit`
   is the low-frequency backstop that catches what the in-loop check missed.

   **The cross-vendor cross-check (`coding-mastermind-cross-check`).** For RARE
   high-stakes or large-diff decisions only: it asks Codex + Gemini to REFUTE a claim
   (read-only/sandboxed) and synthesizes a proposal that preserves the disagreement. Not
   a majority vote. Skip it on Q&A and small edits.

   **Maintenance.** `coding-mastermind-update` upgrades the agent CLIs (each via its real
   install channel) and then re-stamps the MANIFEST baseline + re-verifies the capability
   facts; the Wiki's own `refresh` skill keeps the knowledge wiki current. The MANIFEST
   and wiki edits propose, never auto-apply (the CLI upgrade is the one explicit action).

   **Canonical homes.** Concepts/why = the system wiki. Cross-repo rules =
   `global-rules/`. Skills + MANIFEST = `agent-skills/`. Per-repo invariants = that
   repo's `INVARIANTS.md`. Decisions = that repo's `docs/decisions/`.

## Red Flags

- Reciting a stale, hand-maintained command list. List the installed skills live.
- Telling someone to run the cross-check for routine work (it is rare-high-stakes only).

## Verification

- The answer fit in about a screen, named the actually-installed commands, and pointed
  at the canonical homes.

## Related

- Every `coding-mastermind-*` skill (init, invariant, cross-check, audit, update).
- The kit's `SPEC.md`, `PLAN.md`, `MANIFEST.md`.
