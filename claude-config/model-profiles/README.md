# Model profiles

One registry of per-model guidance, so prompting and compaction never drift apart.

- `prompting/<model>.md`: how to write prompts for that model. Used by `/magic-prompt` (compose, audit).
- `compact/<model>.md`: what that model's compaction summary keeps. Used by the resume-card hooks (`global-hooks/context-card.py`, EA ADR-0004).

Each profile names its sources and a "Last verified" date. `/magic-prompt refresh` re-checks every profile against the official docs and Claude Code's bundled migration guide, adds profiles for new models, and proposes a diff. A change to a prompting profile that affects what a model should keep across compaction is flagged for its `compact/` twin.

File names use the model id with any date suffix dropped (`claude-opus-5-5`); `codex-gpt` and `gemini` cover their families.
