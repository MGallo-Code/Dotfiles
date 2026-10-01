# Claude Opus 5.5 - prompting profile

Last verified: 2026-09-30 against Anthropic's migration guide bundled with Claude Code 2.1.281 (`claude-api` skill, `shared/model-migration.md`, "Migrating to Claude Opus 5.5": effort, behavioral shifts). Model config: https://code.claude.com/docs/en/model-config (`opus` = `claude-opus-5-5`).
Compaction profile: `../compact/claude-opus-5-5.md`.

- **Shape:** explicit about scope, output shape, tools and review depth. For implementation, name the files or surfaces to inspect before editing.
- **Effort** (source): the API default is `medium` (earlier Opus models defaulted to `high`), and level names do not map 1:1 from Opus 5. Opus 5.5 at `medium` exceeds Opus 5 at `high` on coding and knowledge-work evaluations. Start at `medium` and test the neighboring levels; reserve `xhigh`/`max` for measured gains. Set effort explicitly. Thinking is always on; effort is the only thinking control.
- **Effort** (Michael's policy, not the source): `high` for the orchestration roles (Orchestrator arm A, Challenger), per the Wiki lab note.
- **Re-evaluate Opus 5-era prompts:** verbosity, over-verification and scope scaffolding tuned for Opus 5 may no longer be needed. Keep them only where a test shows they still help.
- **Reviews:** ask for all plausible findings first, then filter by evidence and severity.
- **Visual inputs:** it reads charts, diagrams and screenshots much more precisely; re-test any scaffolding built for earlier models.
- **Progress updates** arrive as thinking blocks (text between tool calls). If Michael should see progress, ask for it at a set cadence.
- **Brevity:** lower effort before adding prompts that ask for shorter output.
- **Visual style:** it responds well to naming specific patterns to avoid. Work iteratively: look at what the first result used, then extend the list (useful with the handoff's section-5 preferences).
- **Never** ask it to reproduce its reasoning; that can trigger a refusal (the `claude-api` skill's prompt-audit table). Ask for rationale and evidence.
