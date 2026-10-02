---
name: coding-mastermind-audit
description: The low-frequency BACKSTOP that keeps a repo's INVARIANTS registry honest - re-checks every enforcer still fires, finds NEW surfaces a covered invariant's gate does not yet see, refreshes recurrence counts, and surfaces a short ranked "what's overdue." Read-only detection that proposes, never edits. Use periodically or when asked to audit the invariants registry; it does NOT depend on the cross-vendor CLIs.
---

# coding-mastermind-audit

## Overview

The in-loop interception (the locator + compliance-guard) only fires on files an agent
actually touches, so it cannot see an UNTOUCHED surface that quietly drifted, or work
done by another agent/vendor. This backstop closes that gap on a slow cadence: it walks
`INVARIANTS.md`, confirms each enforcer still exists and passes, hunts for new surfaces
that match a covered invariant's glob but are not yet covered, and refreshes the
recurrence counts so the registry stays a true memory. It is the demoted form of the
old "cron digest" - low-frequency and ranked, because a reactive engineer ignores a
noisy digest. Precision-first: a short, trustworthy "what's overdue" beats a long one.

It is READ-ONLY detection. It proposes; the human (or the main loop, after a nod) edits.
It must NOT depend on the cross-vendor CLIs - headless auth is unreliable, so this can
run unattended.

## When to Use

- Periodically (the backstop cadence), or when asked to "audit the invariants" / "what's
  overdue in the registry."
- After a burst of work by multiple agents/vendors, to catch what the in-loop check
  could not see.

**When NOT to use:** as the PRIMARY hands-off lever - that is the in-loop interception.
This is the safety net under it.

## Process

1. **Load the registry.** Read `INVARIANTS.md`. For each row note its enforcement point,
   gate, status, surfaces glob, detection signals, and recurrence.
2. **Re-check each enforcer exists and passes.** Run the gate (the `scripts/...` check,
   the test suite for the pgTAP/point gates) and confirm a real green, not a vacuous one.
   Flag any gate whose script/file moved or no longer runs (a silently-disabled enforcer
   is worse than none).
3. **Hunt new uncovered surfaces.** For each invariant, glob its surface pattern and
   diff the live set against what the gate actually covers (e.g. the cohort-floor
   `SURFACES` list, the allowlist, the pgTAP-pinned functions). A surface that matches
   the glob but is in none of those is a coverage gap - the exact thing the in-loop
   check missed. Use the precise detection signals to keep false positives low.
4. **Refresh recurrence.** Skim git/PR history since the last audit for re-hardening of
   an invariant (the same fix landing again, possibly described differently - semantic
   recurrence). Update the count. Be conservative: a guessed recurrence that cries wolf
   gets the registry ignored.
5. **Rank and report.** Output a SHORT ranked "what's overdue": advisor-only/to-build
   rows whose recurrence crossed the promotion trigger (the 2nd recurrence), uncovered
   surfaces, and any disabled enforcer. Highest leverage first. Propose the concrete fix
   per item (write the coverage gate, add the surface to the list, promote to required).
6. **Propose registry edits** (recurrence bumps, status changes) for the human to apply.
   Never edit `INVARIANTS.md` yourself in this skill.

## Common Rationalizations (reject these)

- "The in-loop check already covers this." Only for touched files. Untouched drift and
  other-agent work are exactly this backstop's job.
- "List everything that could be better." No - rank and cut. A long digest is ignored;
  a short one gets acted on.
- "Bump recurrence whenever it looks like a repeat." Only on a real, confirmable repeat.
  False recurrence erodes trust in the count.

## Red Flags

- The skill editing `INVARIANTS.md` or any gate. It is read-only; it proposes.
- A report longer than a screen. Precision-first; rank and truncate (and say what was
  truncated).
- Depending on the cross-vendor CLIs. This must run unattended.

## Verification

- Every enforcer was actually run and its green confirmed real (or flagged).
- Each "overdue" item names a concrete next action and the registry row it came from.
- The report is short and ranked; nothing was auto-edited.

## Related

- `coding-mastermind-update` - updates the system/tooling baseline (this updates the
  per-repo registry).
- The in-loop interception it backstops: the codebase-locator + compliance-guard.
- `coding-mastermind-cross-check` - NOT used here (no headless CLI dependency).
