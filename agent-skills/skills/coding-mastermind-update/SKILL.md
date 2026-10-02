---
name: coding-mastermind-update
description: The single owner of agent-platform drift. Upgrades the installed coding-agent CLIs (Claude Code, Codex, Gemini, and any others) each via its REAL install channel, then re-stamps the kit's MANIFEST baseline and re-verifies the capability facts the kit depends on - proposing the MANIFEST diff, never auto-applying it. Use when the user says "update/upgrade my agents/tools", on a new Claude Code/Codex/Gemini release, on a periodic tooling refresh, or to re-verify the baseline without upgrading (check-only).
---

# coding-mastermind-update

## Overview

Agent platforms drift: a CLI ships a new version, a hook event is renamed, a sandbox
flag changes default, a primitive the kit relies on is removed (output-styles were
removed in Claude Code v2.1.91). When that happens silently, the kit's assumptions rot -
the system-level version of pattern #2/#6. This is the named owner of that drift. It does
two jobs in one pass: (1) UPGRADE the agent binaries to latest, each through the channel
it was actually installed with; (2) RE-STAMP the `MANIFEST.md` baseline and RE-VERIFY the
capability facts the kit's design rests on. The upgrade is the explicit action; the
MANIFEST edit is PROPOSED, never auto-applied (a human owns the change to the system).

(This folds in the old `update-coding-agents` actor: one command now upgrades and records,
because they were always run back to back.)

## When to Use

- "Update / upgrade my agents", "update claude / codex / gemini", "update my coding tools".
- A new Claude Code / Codex / Gemini release, or you suspect the baseline is stale.
- A periodic tooling refresh.
- **Check-only:** to re-stamp + re-verify the baseline WITHOUT upgrading (versions moved
  out of band, or you just want to confirm the capability facts still hold). Skip step 3.

**When NOT to use:** routine per-repo feature work (this updates the SYSTEM, not a
feature); mid-critical-session if you depend on the current Claude Code build (an upgrade
takes effect on the NEXT launch, so finish first); when a tool is deliberately pinned
(bump the pin, do not float to latest).

## Process

1. **Inventory + detect channel** for each agent. Record the current version and HOW it is
   installed - the upgrade command depends on it, and npm-installing a Homebrew tool (or
   vice versa) leaves two copies on `PATH` and the wrong one wins:
   - **npm global:** `npm ls -g --depth=0 <pkg>` resolves -> `npm install -g <pkg>@latest`.
   - **Homebrew cask:** `which <bin>` resolves into `…/Caskroom/<name>/…` ->
     `brew upgrade --cask <name>` (a cask is NOT a formula: `brew upgrade <name>` misses it).
   - **Homebrew formula:** resolves into `…/Cellar/<name>/…` -> `brew upgrade <name>`.
   - **Native self-updater** (Claude Code's native install exposes `claude update`) -> use it.
2. **Show the plan BEFORE installing.** Print `current -> latest` per tool
   (`npm view <pkg> version`; `brew outdated --cask`). Do not upgrade silently: a bump is
   exactly when a capability fact moves under you (step 5).
3. **Upgrade each via its detected channel** (skip a tool already at latest; report it as a
   no-op, not a failure). Known agents (verified 2026-06-17; re-detect, do not trust blindly):
   | Agent | Channel | Upgrade command |
   |-------|---------|-----------------|
   | Claude Code (`@anthropic-ai/claude-code`) | npm global | `npm install -g @anthropic-ai/claude-code@latest` |
   | Gemini CLI (`@google/gemini-cli`) | npm global | `npm install -g @google/gemini-cli@latest` |
   | Codex (`@openai/codex`) | npm global, **PINNED** | `npm install -g @openai/codex@<MANIFEST pin>` (NOT `@latest`) |
   All three are npm now: Codex moved off the macOS-only Homebrew cask 2026-06-21 so one
   channel manages it on macOS AND WSL. Codex is PINNED to the MANIFEST version, not floated -
   its `config.toml` MCP-server schema is version-volatile (a newer Codex writes a `transport`
   field an older one rejects, which deadlocked sync's `codex mcp` re-wiring on WSL). To bump
   Codex, change the MANIFEST pin deliberately, then install that exact version. After any
   Codex install, confirm `which -a codex` resolves to the npm bin (no leftover cask).
   **Check-only mode: skip this step.**
4. **Verify after.** Re-run each `--version`; emit a `before -> after` table.
5. **Re-stamp the MANIFEST + re-verify the load-bearing facts.** Open
   `coding-mastermind/MANIFEST.md`. Update the version table and the re-stamp date. Then
   RE-VERIFY each fact the kit's design rests on (a bump can flip one silently):
   - **codex exec sandbox default is VERSION-VOLATILE** - confirm empirically via the
     `codex exec` session header (it was `workspace-write` on 0.139.0, `read-only` on
     0.140.0). The cross-check skill passes `-s read-only` regardless, so the fix on a flip
     is the MANIFEST/skill NOTE, not the command.
   - `gemini --approval-mode plan` still means read-only (`gemini --help` documents it).
   - PreToolUse exit-2 reliable for Bash only; Stop/SubagentStop `additionalContext` + the
     8-block cap; `.claude/skills` auto-load; no removed primitive the kit uses.
   Read the changelogs between baseline and now, not just the version strings. Output a
   proposed changes list (each tied to a kit file + edit) + the re-stamped MANIFEST. Present
   for approval; do NOT auto-apply the MANIFEST edit. (The binary upgrade in step 3 already
   happened; only the kit-file edits are propose-only.)

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "Just `npm install -g` everything." | Right channel still matters: cross-installing (npm a brew tool, or vice-versa) leaves two copies on PATH and the wrong one shadows. All three agents are npm now, but Codex was a Homebrew cask until 2026-06-21 - after migrating, confirm `which -a codex` resolves to the npm bin, not a leftover cask. |
| "Float Codex to `@latest` like the others." | Codex is PINNED on purpose: its `config.toml` MCP schema is version-volatile and floating reintroduced the drift that broke WSL. Bump the MANIFEST pin deliberately, then install that version. |
| "Upgrade silently, latest is latest." | Show `current -> latest` first; a bump is exactly when a sandbox flag / approval mode / hook event changes (step 5). |
| "Just bump the version numbers in the MANIFEST." | A version bump without diffing behavior misses the deprecation that breaks the kit. Diff the capability, not the string. |
| "Apply the MANIFEST edits since I'm here." | Propose. The human owns the change to the system, exactly as with any architecture decision. |
| "The fact is probably still true." | Re-verify the load-bearing ones; a silently-flipped capability is how the kit rots. |

## Red Flags

- A leftover Homebrew cask `codex` shadowing the npm copy on PATH after the 2026-06-21 migration (`which -a codex` must resolve to the npm bin; run `brew uninstall --cask codex` if a cask lingers).
- Floating Codex to `@latest` instead of the MANIFEST pin (its config schema is version-volatile).
- npm/brew cross-contamination (two copies on PATH).
- An upgrade run that does not record the `before -> after` delta.
- A capability change (sandbox default, approval mode, hook rename) noticed but not folded
  into the MANIFEST.
- Auto-applying edits to kit files or the MANIFEST (the binary upgrade is the only auto action).

## Verification

- [ ] Each agent reports a version >= its pre-run version (or "already latest"); none half-upgraded.
- [ ] Every tool upgraded via its DETECTED channel (no npm/brew cross-contamination).
- [ ] MANIFEST re-stamped to the new versions + date.
- [ ] Each load-bearing capability fact re-checked and marked still-true or changed (with the codex sandbox default re-confirmed empirically).
- [ ] The MANIFEST diff was PROPOSED, not auto-applied.

## Related

- The baseline it diffs and re-stamps: `coding-mastermind/MANIFEST.md`.
- The Wiki's `refresh` skill refreshes the KNOWLEDGE (wiki pages); this refreshes the TOOLING baseline.
- `coding-mastermind-cross-check` - depends on the codex/gemini sandbox + approval-mode facts this skill re-verifies.
