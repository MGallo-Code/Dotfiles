# 0005 - Register EA's resume-card hooks through the agent-integrations configurator

- Status: accepted
- Date: 2026-09-29
- Design of record: EA `docs/decisions/0004-self-refreshing-sessions.md` (resume cards, card-aware compaction, the `/wrap`-only clear guard; EA INV-11)
- Invariant: INV-16

## Decision

Dotfiles registers the three resume-card hooks (SessionStart, PreCompact, and a PreToolUse clear guard) in `~/.claude/settings.json` through `scripts/configure-agent-integrations.py`, the configurator that already registers the completion-email hooks (INV-13).

- It needs no new manifest wiring: all four setup/sync entrypoints on macOS and Windows already call it, so parity (INV-2) holds by construction. The script is found beside `--hook` in EA `global-hooks`, and its registration is removed when the script is absent.
- Registration is in place and byte-idempotent, and the guard's command is wrapped to fail closed.
- The runner path is no longer resolved to the Homebrew Cellar, so `brew upgrade uv` no longer breaks the hooks. This also fixes the completion-email hook.

## Alternatives rejected

- **A new `configure-context-hooks.py`:** it would need four new entrypoint calls and parity rows for no benefit.
- **`configure-claude-defaults.py`:** it also forces `permissions.defaultMode`, which is open item F8. Running it to activate hooks would switch Michael's permission mode from `auto`.
- **Per-project `.claude/settings.json` hooks:** they only reach repos that carry the file, and would need committing into other people's repos.
