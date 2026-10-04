# 0011 - Questions for Michael go through the questions page or the card

Status: accepted 2026-10-04 (Michael: "I _do_ want them to ... show me what's waiting on me, but
not how it's been doing it"; "Try to never hold up work on questions, but yes, B, unless a
question we can't continue without"). Idea, tested assumptions and review:
`docs/ideas/questions-page.md`, `docs/plans/0011-questions-page-build.md`.

## Problem

Agents end replies with what's waiting on Michael as an unformatted list, worded for someone
who watched the session (rule ids, file paths), sometimes pointing at screenshots he can't see
or asking him to pick between styles he can't compare. The old rule caused part of it: end
with "needs his decision" in prose.

## Decision

- **Two surfaces.** The *questions page* (`tools/ask/ask.py`): a per-ask local page, one
  question per screen, real pictures per option, one or several picks, Other, review, Send;
  the agent keeps working and collects the answers later. The *card* (Claude AskUserQuestion,
  Codex `request_user_input`): native, but it pauses the agent.
- **Routing.** Never hold up work on a question: the page while any work remains that doesn't
  need the answer, and for any question that needs pictures. The card only when nothing more
  can be done without the answer and no picture is needed. Commands he must run stay in chat as
  `bash` blocks (the desktop Run button). Approvals for publication or anything irreversible
  stay in chat or the card.
- **Wording.** Each question stands alone: one plain context sentence, each option says what he
  gets, recommended first, no agent-internal labels. `tools/ask/asklint.py` checks it for both
  surfaces; a label he truly needs passes with an audited override.
- **Enforcement.** `ask-guard.py`: PreToolUse on Claude's card (deny on internal labels or a
  promised picture) and Stop on Claude and Codex (block once when a reply ends in a question
  list). `ask.py open` applies the same wording check to the page.
- **Codex** gets its card outside Plan mode through `codex features enable
  default_mode_request_user_input` (an under-development flag; Codex is pinned, and the pin
  preflight checks the flag still exists). Michael chose to hide Codex's start-up warning about
  under-development settings (`suppress_unstable_features_warning`, converged as a boolean).

## Threat model of the page

The server binds 127.0.0.1 on an OS-picked port, with a 128-bit token as the path prefix and a
Host-header check (DNS rebinding). Other machines and web pages can't reach it. A process
running as Michael that reads the token (it is in the transcript and in `~/.cache/ask`) could
post answers; the user account is the trust boundary, as for every other agent file. That is
why approvals never go through the page.

## Consequences

- The Claude desktop browser pane can be open but hidden; the agent checks it is displayed
  before pointing at it. A page sent as a rendered file can't reach the server (tested), so
  only the browser pane (or a default-browser tab) is used.
- Codex can't be woken by the page after its turn ends; it polls between steps, and at the end
  asks one card question to wait on the page.
- Not built: a "waiting on you" email when a card opens. INV-13 forbids action-needed email, so
  for now a card holds an armed done email until he answers (the question to change that was
  worded badly and left open, 2026-10-04).
