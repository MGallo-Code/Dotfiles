# Compaction profiles

What `global-hooks/context-card.py` hands the summarizer when a session bound to a resume card compacts, one file per working model (`<model-id>.md`, date suffix dropped), with `default.md` for anything else. The hook prepends the card contract (card path, last-update time, commits since).

- `claude-fable-5-1.md`: Anthropic's six-point summarization prompt from the Fable 5.1 migration guide (the model "responds well to being told explicitly what to retain"; the closing no-tools sentence is load-bearing), scoped to the span since the card's update.
- `claude-opus-5-5.md` / `default.md`: no model-specific compaction guidance exists for Opus 5.5 (its guide defers to Fable 5.1), so four labeled sections with a line cap.

The prompting side lives in `../prompting/`; `/magic-prompt refresh` keeps both current and flags compaction-relevant changes here. Evidence: `docs/plans/self-refreshing-sessions.md` (test 4).
