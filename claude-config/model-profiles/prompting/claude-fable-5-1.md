# Claude Fable 5.1 - prompting profile

Last verified: 2026-09-30 against Anthropic's migration guide bundled with Claude Code 2.1.281 (`claude-api` skill, `shared/model-migration.md`, "Migrating to Claude Fable 5.1 from Claude Fable 5", "Behavioral shifts (prompt-tunable)"). Web page: https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5
Compaction profile: `../compact/claude-fable-5-1.md`.

- **Shape:** compact and outcome-first: the goal, then context, constraints, success criteria and stop rules. Ceremony only where it helps.
- **Effort:** start at `high` (the default) and move up only where you have measured a quality gain. At `xhigh`/`max`, long deliverables are drafted in thinking and written out again, which means a longer wait and roughly double the output tokens. Leave `max_tokens` room for both.
- **Long autonomous runs:** it can stop at *describing* the next step ("Next, I'll ...") or ask permission for a step the request already covers. Say it is operating autonomously and should carry on until the work is done or genuinely blocked.
- **Scope:** "the user's request, or the plan they approved, sets the scope; don't quietly narrow, widen, or swap it." In coding, pre-existing bugs or unrequested improvements go in the summary as follow-ups, not into the change.
- **Progress updates:** it writes fewer of them in long tool chains. Ask for a line before starting and brief updates while working. If the harness hides tool output, tell it, or it may run commands just to "show" output.
- **Prose and formatting:** denser prose and less formatting than earlier models. Ask for lists only where content is multifaceted, and for plain, direct statement ("remove mannered prose").
- **Edits:** it prefers whole-file rewrites; ask it to minimize the tokens spent editing files.
- **Tools:** it parallelizes calls the request names explicitly, but batches implied tool calls less than Fable 5. Ask it to list what it needs first and request every independent item in one response. At `low` effort it answers from memory more; for fast-moving names (models, tools), tell it to verify first.
- **Evidence:** progress claims should cite current-session tool output. Use bounded stop rules (destructive actions, scope ambiguity, user-only decisions, pushes, secrets), not "ask before everything".
- **Never** ask it to reproduce its reasoning; that can trigger a refusal on Fable 5.1 (the `claude-api` skill's prompt-audit table). Ask for rationale, evidence and trade-offs instead.
