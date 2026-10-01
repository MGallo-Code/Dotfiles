# Codex (GPT family) - prompting profile

Last verified: NOT re-verified in this revision. Carried over from `/prompt-audit`'s routers (EA history before 2026-09-30); run `/magic-prompt refresh`. Sources: https://developers.openai.com/codex/ and https://developers.openai.com/api/docs/guides/prompt-guidance

- **Shape:** role, goal, context, constraints, success criteria, output, stop rules.
- **Durable repo rules** belong in `AGENTS.md`; use prompts for task workflows. `~/.codex/AGENTS.md` is generated from EA `global-rules` (dotfiles INV-15).
- **Long work:** use goal mode or a tracked file so state survives context transitions.
- **Subagents:** request them explicitly, and only when independent read-only scans or adversarial checks are useful.
- **Effort:** use a smaller model or lower effort for cheap read-heavy scans, and reserve high or `xhigh` for hard synthesis. Re-evaluate low or medium results before escalating.
- **Environment:** state the sandbox and tool assumptions when they matter.
