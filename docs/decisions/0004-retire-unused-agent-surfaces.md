# 0004 - Retire unused agent surfaces: Forge, SBIC dev wiring, interactive Gemini, upstream skill sync

- Status: accepted (Michael, 2026-09-27)
- Evidence: `~/Documents/EA/docs/plans/agent-setup-trim.md` (usage scan of Claude, Codex and Gemini history on the Mac mini, where all recent non-SBIC work happens)

## Context

The usage audit found four surfaces that cost wiring, CI, and always-loaded context but no longer earn it:

- **Forge.** Last Claude use 2026-07-06, last Codex use 2026-08-24. `forge-guard.sh` ran on every Bash call in Claude and Codex (and in ea-hub's owner lane, which inherits user hooks) and never blocked or warned in the audited window.
- **SBIC dev wiring.** Michael: SBIC dev work is "irrelevant now". The SBIC repo and its docs stay as employment history.
- **Gemini as an interactive agent.** Zero interactive sessions on record; the only use is the headless cross-check (9 calls, last 2026-07-18). Michael: "retire gemini for now".
- **Upstream sync of the agent-skills fork.** The fork has diverged (the coding-mastermind kit exists only there) and Michael does not want upstream pulled automatically: "it's basically my system at this point".

## Decision

1. **Forge retired.** Removed: the skill, the `/forge` command, `forge-guard.sh`, `scripts/forge/check-state.py`, `check-forge-wiring.py` and its CI job, the `Agent-Forge` directory ensure, the PR-template section. Existing `~/Documents/Agent-Forge` content stays on disk. Hook registrations are removed on every machine by the Claude/Codex config convergers through a retired-hook tombstone list, so no machine is left calling a deleted script.
2. **SBIC dev wiring removed.** `dev-update`, the `sbic-*` Codex/Gemini skill copies and command mirrors, the Codex duplicate-skill suppression for SBIC, and the `sbic` launcher + SBIC trusted root. `~/Documents/SBIC`, its docs, and the workspace-map entry stay.
3. **Gemini retired as an interactive agent.** No more generated `~/.gemini/skills`, `~/.gemini/commands`, `~/.gemini/GEMINI.md`, or Gemini allowlist policy, and no `--gemini` launcher flag. The Gemini CLI stays installed for the headless cross-check. Its MCP hub wiring (INV-4/5/10) and completion-notify hook (INV-13) are untouched.
4. **agent-skills upstream sync retired.** `sync` treats the fork like any other origin repo. The INV-3 security gate (`gate_skill_diff`, `skills-scan.py`, `/skills-review`, the gate corpus CI) goes with it, because nothing untrusted is merged automatically any more. Upstream stays one link away: https://github.com/addyosmani/agent-skills (fetch and review by hand if ever wanted).

## Consequences

- INV-3 and INV-11 are retired. Their rows stay in `INVARIANTS.md`, marked retired, so the numbering is stable. INV-6, INV-7 and INV-15 narrow to Claude + Codex.
- Parity rows for the removed behaviors are removed from `check-parity.py`; everything left stays paired sh/ps1.
- Reversal is `git revert` of the retirement commits plus one `sync`.
