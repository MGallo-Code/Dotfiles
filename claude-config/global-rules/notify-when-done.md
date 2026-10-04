# Notify Me When Done

Completion email is available in Claude Code, Codex, and Gemini CLI. It is strictly
per-turn opt-in.

## Arm only on an explicit request

Arm only when Michael explicitly asks for an email or notification when the current
turn finishes, such as “email me when this is done” or “notify me when you finish.”

- Never infer consent from a long task, Michael stepping away, or similar context.
- Never arm for “tell me if you get blocked.” Only successful turn completion is wired.
- An ordinary turn must never use email.

Run this once during the requested turn, with a short status label:

    uv run --no-project "$HOME/.dotfiles/claude-config/global-hooks/agent-notify.py" \
      arm --label "short status"

Use `--to address@example.com` only if Michael explicitly names another recipient. If
the command fails, report that it was not armed. If it succeeds, tell him the completion
hook will email him.

## Boundaries

- Do not send the completion email yourself with courier, Gmail, or Himalaya. The hook
  owns the channel; a manual send would duplicate it.
- Claude uses `Stop`, Codex uses `agent-turn-complete`, and Gemini uses `AfterAgent`.
- One acknowledged email consumes the arm. A delivery failure retains that same explicit
  request for retry; it does not authorize email for unrelated turns.
- Prompt, response, working directory, and session identifiers are never included.
- A question card holds the turn open, so an armed email waits until he answers it (ADR-0011).

To cancel the current arm:

    uv run --no-project "$HOME/.dotfiles/claude-config/global-hooks/agent-notify.py" disarm

Operator details live in `~/.dotfiles/claude-config/global-hooks/README.md`.
