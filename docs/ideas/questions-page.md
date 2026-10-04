# Questions that don't hold up work

Status: idea, refined 2026-10-04. Next: test the assumptions below, then a plan and ADR-0011.

## Problem

How might we get every item waiting on Michael in front of him as something he can answer
on the spot (plain words, real visuals, one or several picks) without stopping the agent's
work?

What goes wrong today, across Claude (app and terminal) and Codex (app and terminal):

- Turns end in an unformatted list of questions to answer by hand.
- Questions assume knowledge only the working agent has (internal IDs, slice names).
- Agents refer to screenshots he can't see, or ask him to pick between styles he can't compare.

The current rule causes part of it: `communication-style.md` tells agents to end with a
"needs his decision" section in prose.

## Recommended direction

- **The page is the default.** The agent writes its open questions to a file, a dotfiles `ask`
  tool turns them into a page on the right, and the agent keeps working. Send hands the
  answers back. Mock: one question per screen, pictures per option, single or multiple picks,
  Other, a review screen before Send, keyboard picks.
- **The card only when blocked.** The native card (Claude AskUserQuestion, Codex
  `request_user_input`) pauses the agent, so it is used only when the agent can't do anything
  more without the answer, end of task included, and the question needs no pictures.
- **Wording.** Every question carries one plain sentence of context, each option says what
  he gets, recommended first, no internal labels.
- **Visible or not mentioned.** An agent never refers to a picture or pane it hasn't
  confirmed is on screen. (Found while mocking: the desktop browser pane can be open but
  hidden, and agents can't un-hide it; a file sent with display "render" does open the
  right-side preview.)
- **Several sessions at once.** Each ask gets an OS-picked port and a secret link, the page
  names the session asking, and answers return only to that session.
- **Commands stay in chat** as Run-button blocks.
- Hooks hold the wording and routing, so it does not rest on memory.

## Key assumptions to validate (tested 2026-10-04; spike in the session scratchpad)

- [x] **Claude return path: browser pane, not file preview.** A per-ask server that serves its
      own page to the desktop browser pane got the page load and the answers POST back
      (same origin, no CORS), then exited. A page sent as a rendered file preview never
      reached the server, not even a preflight, so the file preview is display-only. The
      browser pane stays hidden while the right-side panel is closed; `tabs_context` reports
      hidden/displayed, and a rendered file send opens the panel.
- [x] **Codex can't be woken after its turn ends.** Design: Codex polls the answers file
      between steps and, with nothing left to do, blocks on `ask wait` (the card's role).
      Not exercised live in the Codex app.
- [x] **Codex card outside Plan mode works, but the flag is "under development".** With
      `features.default_mode_request_user_input=true`, `codex exec` called
      `request_user_input` in default mode (exec itself rejects it: "not supported in exec
      mode"). Every start prints an unstable-feature warning unless suppressed.
- [x] **Sessions never cross answers.** Two servers at once got distinct OS-picked ports; a
      POST with the other session's token got 404; each answers file held only its own.
- [x] **A card blocks the done email.** This session's Stop hooks never ran during four card
      waits (queue sweep untouched 03:35 to 04:16 UTC), so an armed "email me when done"
      would wait on the answer. Fix: a PreToolUse hook on AskUserQuestion sends it.

Also learned: the AskUserQuestion option `preview` renders markdown or an HTML fragment (no
script or style), per the Agent SDK docs; images are not documented.

## MVP scope

In:
- A new global rule (Claude, and Codex via the generated AGENTS.md) replacing the
  "needs his decision" lines in `communication-style.md`.
- The `ask` tool: stdlib Python (mac and Windows), single or multi pick, local screenshots,
  Other, review screen; exits when answered or after an idle timeout.
- Hooks: reject card questions with internal labels; catch a turn ending in a bare question
  list; send the done email when a card opens.
- Codex card flag in `configure-codex-defaults.py`, both platforms (INV-2).
- ADR-0011, an INVARIANTS row, a CI check for the hooks.

## Not doing (and why)

- Inline chat widget: works only in the Claude app, one of four places he reads.
- One inbox across sessions: most plumbing, and answers arrive late.
- "Ask less" (agents decide reversible things): not chosen.
- Gemini: retired as an interactive agent (ADR-0004).

## Open questions

- On terminals, the page opens as a default-browser tab (assumed).
