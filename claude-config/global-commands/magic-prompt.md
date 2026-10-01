---
description: Write a strong prompt for the active model, audit Michael's prompting setup, or refresh the per-model guidance as models change.
argument-hint: [rough task] | audit [claude|codex|all] | refresh
---

# Magic Prompt

Per-model guidance lives in one registry: `~/.dotfiles/claude-config/model-profiles/` (`prompting/` for how to write prompts, `compact/` for what a model keeps across compaction; see its README). This command reads it, audits against it, and keeps it current.

Arguments: `$ARGUMENTS`. The first word picks the mode: `audit`, `refresh`, or anything else (compose). If there are no arguments, ask for the task or prompt to improve.

## Compose (default)

Turn Michael's rough request into a prompt for the model that will run it.

1. Identify the active runtime (Claude Fable, Claude Opus, Codex/GPT, Gemini or unknown), the invocation surface, and the tool access that matters. If the prompt is for a different model, Michael will say so.
2. Read that model's `prompting/<model>.md`. If none exists, say so, use the closest profile, and suggest `refresh`.
3. Write the prompt:
   - Preserve his real intent; don't make it larger or more formal than needed.
   - Lead with the outcome, then context, constraints, success criteria, evidence requirements and stop rules.
   - Ask at most 3 sharp questions first, and only if the task is ambiguous.
   - Risky work gets explicit pause points: destructive actions, pushes, secrets, irreversible external changes, and user-only decisions.
   - Long work names where durable state lives: a plan, tracker or resume card.
   - Visible UI work requires live visual verification.
   - Never ask for hidden reasoning; ask for concise rationale, evidence and trade-offs.

Output: detected runtime (with confidence), the best goal in one sentence, questions if needed, and the paste-ready prompt. Add variants for other models only if asked.

## Audit (`audit [claude|codex|all]`)

Audit Michael's prompts, rules, commands, skills, hooks and settings against the registry and current docs. The active model is the auditor, not the target. The default target is `all`.

- **Evidence, local:**
  - `~/.dotfiles/{manifest.sh,INVARIANTS.md,DEFINITION_OF_DONE.md}`
  - `~/.dotfiles/claude-config/{global-rules,global-commands,global-skills,global-agents,global-hooks,model-profiles}`
  - `~/.claude/settings.json`, `~/.codex/config.toml`
  - recent session files, for patterns only: short identifiers and counts, never private content
- **Evidence, docs:** the sources named in each profile. Check any fact that can drift before relying on it.
- **Look for:**
  - progress claims without current-session evidence;
  - verifier loops without a stopping rule;
  - plans or trackers Michael has to ask about;
  - model or effort mismatched to the work;
  - duplicated or stale rules;
  - config that appends instead of converging;
  - always-on rules that should be commands or skills;
  - repeated failures that never became a rule, check or memory;
  - generated files edited by hand.
- **Output:**
  - TLDR (3 bullets);
  - auditor context;
  - evidence map (paths and links);
  - ranked findings: issue, evidence, impact, fix;
  - changes per model and shared;
  - a patch plan;
  - what needs Michael's approval.
- **Applying approved fixes:** read `~/.dotfiles/INVARIANTS.md` first. Edit sources only: `~/.dotfiles/claude-config`, never the generated `~/.codex/prompts` or `~/.codex/AGENTS.md`. Regenerate as dotfiles `sync` does. Commit locally; never push without his go.

## Refresh (`refresh`)

Keep the registry current as models change.

1. List the models in use: Claude Code's aliases (`opus`, `sonnet`, `fable`; see https://code.claude.com/docs/en/model-config), the models pinned in settings, agents and the EA hub, and Codex's configured model.
2. For each `prompting/` profile, and for any model in use that has none, check its named sources:
   - Anthropic's prompting pages and the migration guide bundled with the current Claude Code (the `claude-api` skill, `shared/model-migration.md`);
   - OpenAI's Codex and prompt-guidance docs;
   - Google's Gemini docs.
3. Propose a diff per profile: what changed, the source for each line, and a new "Last verified" date. New models get a new profile.
4. Flag any change that affects what a model should keep across compaction for its `compact/` twin. Anthropic publishes compaction prompts for some models.
5. Apply only after Michael says so, commit locally, and report which profiles are still unverified.
