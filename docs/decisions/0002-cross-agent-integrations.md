# 0002 - Converge native completion hooks and skill discovery

- Status: accepted
- Date: 2026-08-17
- Surfaces: EA global hooks/rules, dotfiles setup/sync, Claude/Codex/Gemini user config,
  generated global skill targets

## Context

Completion email existed only as a macOS Claude `Stop` + `Notification` hook. Its
fire-and-forget sender deleted an arm before delivery was acknowledged, action-needed
mail no longer matched the requested policy, and Codex/Gemini had no equivalent. Codex
also discovered the same SBIC triggers from repo `.codex`, converted `.agents`, and a
global symlink to `.claude`; three catalog entries spent the skill-description budget and
could select the Claude workflow in a Codex turn.

The shared SBIC repo must not receive personal notification or dotfiles configuration.
EA is the canonical source for personal agent behavior; dotfiles is its transport and
machine-config control plane.

## Decision

Use one EA `agent-notify.py` implementation and each CLI's native completion event:

- Claude `Stop`
- Codex `agent-turn-complete` through top-level `notify`
- Gemini `AfterAgent`; a narrow `AfterTool(run_shell_command)` hook attaches the explicit
  arm marker to Gemini's real session because its shell tool lacks the session id

Email is explicit per-turn opt-in only. The arm atomically becomes pending work and is
removed only after acknowledged delivery. No hook includes prompt, response, cwd, tool
content, or raw session id in email or logs. Local Himalaya is preferred; Courier HTTP is
the dependency-free cross-platform fallback.

One dotfiles Python configurator preflight-validates all three user configs before writing
and atomically replaces each resulting file. Bash and PowerShell setup and sync call that
same path. It preserves unrelated hooks, removes only managed legacy entries, and refuses
to replace an unknown Codex notifier.

Project skill propagation is target-specific. Codex receives SBIC's native `.codex`
skills as distinct materialized global copies; Gemini receives `.claude`. Codex user
config disables the exact repo-local `.codex` and `.agents` `SKILL.md` paths so one native
global entry remains. The shared SBIC tree is read-only to this mechanism.

## Consequences

- Ordinary turns cannot email. Claude action-needed notifications no longer email.
- Delivery is at-least-once. An ambiguous network timeout can theoretically duplicate a
  message; deleting before acknowledgement would instead lose the requested notice.
- Setup and routine sync converge the same behavior on macOS/Linux and Windows.
- Adding an agent requires a native completion event, a stable session-binding mechanism,
  one configurator mapping, and parity/gate coverage.
- `check-agent-integrations.py` and `check-skill-targets.py --machine` mechanically verify
  config preservation, idempotence, native-source topology, duplicate suppression, and
  state transitions without sending email.
