# Gemini - prompting profile

Last verified: NOT re-verified in this revision. Carried over from `/prompt-audit`; run `/magic-prompt refresh`. Interactive Gemini is retired (dotfiles ADR-0004); this profile serves cross-model checks (`coding-mastermind-cross-check`). Source: https://ai.google.dev/gemini-api/docs/

- **Shape:** clearly labeled sections, with the final task near the end, after the context.
- **Examples:** include them when the exact output format matters.
- **Thinking:** low for simple, latency-sensitive work; medium for balanced work; high for complex reasoning.
- **Tools:** keep the active tool set small, and say how to handle tool failures.
- **Long context:** put the query at the end and use structured delimiters.
