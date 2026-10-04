# ADR-0011 build plan: questions that don't hold up work

Idea and tested assumptions: `docs/ideas/questions-page.md`. Each slice: its checks green
locally (pre-commit) before the next; committed per slice. Nothing is pushed without Michael.

**Order (after review):** ADR-0011 first; then the tool with `check-ask.py`; then the hooks
with their registration checks and INV-26; then the Codex flag; the rules last, because
`~/.claude/rules` is this working tree and a rule edit is live in every session at once.

## Contract (what must hold when done)

1. Anything waiting on Michael (a choice, an approval, a non-command to-do) reaches him as the
   questions page or the native card, never as a prose list at the end of a reply. Commands he
   must run stay in chat as `bash` blocks (desktop Run button).
2. Never hold up work on a question: the page while any work remains that doesn't need the
   answer; the card only when nothing more can be done without it and no pictures are needed.
   Visual choices always go on the page, with a real picture per option.
3. Questions stand alone (one plain context sentence, each option says what he gets,
   recommended first, no internal labels) and support multi-select.
4. Works on Claude app + terminal and Codex app + terminal; mac and Windows (INV-2 parity).
5. Several sessions asking at once never cross answers; nothing is reachable off-machine.
6. (Moved out of the build: a "waiting on you" email when a card opens conflicts with INV-13,
   which forbids action-needed email. Michael decides; see Review.)
7. Every rule above has a mechanical enforcer or a documented gap.

## Slice 1 - the `ask` tool (`tools/ask/`)

Stdlib Python 3.9+ (macOS `/usr/bin/python3`, Windows `python`), run as
`uv run --no-project ~/.dotfiles/tools/ask/ask.py ...` like the other agent tools.

- `ask.py open <questions.json> [--from LABEL] [--browser]`: validate + lint (shared
  `asklint.py`), copy to `~/.cache/ask/<id>/` (0700), spawn a detached server
  (`start_new_session` / `DETACHED_PROCESS`), wait until it listens, print the link, the id and
  the next command. `--browser` opens the default browser (terminals).
- Server: `127.0.0.1`, port 0 (OS-picked), a 128-bit token as the path prefix. `GET /<t>/` page,
  `GET /<t>/img/<n>` only images listed in the questions, `POST /<t>/answers` validated against
  the questions, written atomically to `answers.json`, then the server exits ~2 s later. Any other
  path 404. Idle expiry 24 h (writes `expired`). Records `server.json` (port, pid, session id from
  `CLAUDE_CODE_SESSION_ID` / `CODEX_THREAD_ID`, created).
- `ask.py wait <id> [--timeout S]` blocks until answers (exit 0, prints them), expiry (exit 4) or
  timeout (exit 3). `ask.py poll <id>` non-blocking (0 answered, 3 waiting, 4 expired).
  `ask.py close <id>` stops the server (he answered in chat). Answers print as numbered
  question/answer lines plus the path of `answers.json`.
- Questions JSON: `{"from": str, "questions": [{"question", "context", "multi": bool,
  "options": [{"label", "detail", "image"?, "recommended"?}]}]}`; 1-10 questions, 2-6 options,
  `context`/`label`/`detail` required, images must exist (png/jpg/gif/webp).
- Page (`tools/ask/page.html`, from the approved mock): one question per screen, single or multi
  pick, Other, review screen, Send; keys A-F pick or toggle, Enter next, Left back; header names
  the asking session; light/dark. If Send fails, the page shows the answers as text to paste.
- Lint (`asklint.py`, shared with the hook): rejects internal labels (rule/ADR/invariant ids like
  `INV-14`, `ADR-0008`, `PROC-01`; file paths; snake_case identifiers; commit hashes).

## Slice 2 - the rule

- New `claude-config/global-rules/questions.md` (bundled into Codex's AGENTS.md by regen):
  routing (contract 1-2), how to open and collect on each surface, writing (contract 3),
  "never mention a picture or pane he can't see now".
  - Claude app: `preview_start` the link; `tabs_context` must say displayed; if hidden, send any
    file with display "render" to open the right panel, then re-check; else say so in chat.
  - Claude: `ask.py wait <id>` with `run_in_background` (re-invoked when he sends).
  - Codex: `ask.py poll <id>` between steps; when nothing is left, `ask.py wait <id>`.
    Codex app: open the link in its in-app browser; Codex terminal: `--browser`.
- `communication-style.md`: the three "Reports and Decisions" lines about decisions and review
  pages point at `questions.md`; the report keeps done / not done.
- `ui` skill: step 2 and PROC-01's example show options on the questions page; step 6's report
  routes "needs his decision" through the page or card.

## Slice 3 - Claude hooks

- `claude-config/global-hooks/ask-guard.py` (stdlib, fail-open: bad input or any error exits 0):
  - `PreToolUse` `AskUserQuestion`: lint every question/option text with `asklint`; also deny
    when a question refers to pictures (screenshot, mock, picture, image, "on the right") since
    the card can't show them. Deny = `permissionDecision: deny` + a reason telling Claude what to
    rewrite or to use the page.
  - `Stop`: if the final assistant text of the turn ends in 2+ question lines, or a heading like
    "Needs your decision" / "Questions for you" followed by a list, block once
    (`decision: block`, skipped when `stop_hook_active`).
  - Registered with `ensure_claude_hook` (manifest.sh) / `Ensure-ClaudeHook` (manifest.ps1) from
    setup and sync, both events, like INV-19's ui-nudge.
- `agent-notify.py`: a Claude `PreToolUse` on `AskUserQuestion` is a "waiting" event: it claims
  the arm and sends "Claude is waiting on you - <label>". Registered by
  `configure-agent-integrations.py` `_configure_claude` (PreToolUse, matcher `AskUserQuestion`).
  Known overlap: a Stop the ask-guard blocks still counts as completion for agent-notify (all
  Stop hooks run together); the email then goes out as the agent turns to the page, accepted.

## Slice 4 - Codex

- `configure-codex-defaults.py`: converge `[features] default_mode_request_user_input = true`
  (into an existing `[features]` table, else a new one) and top-level
  `suppress_unstable_features_warning = true`. Same script on both platforms (setup/sync).
- `scripts/codex-pin-preflight.sh`: fail a pin bump when `codex features list` no longer has the
  flag.
- Gap (documented, not built): Codex hooks for card lint and the waiting email; Codex notify only
  emits `agent-turn-complete`, and PreToolUse coverage of `request_user_input` is unverified.

## Slice 5 - gates and records

- `scripts/ci/check-ask.py` (hermetic, throwaway HOME/cache): validation and lint cases; two
  concurrent asks get distinct ports, a cross-token POST is 404, each answers file holds only its
  own; only listed images are served; `wait`/`poll` exit codes; ask-guard deny/allow/Stop cases
  and fail-open; Codex defaults render the feature keys idempotently and keep `js_repl`.
  `--revert-test` proves each check fails against a broken copy. Wired into `.githooks/pre-commit`
  and `ci.yml` (Linux + Windows for the server and spawn).
- Registration checks: extend `check-ui-nudge` style tests (sh + ps1) for the two ask-guard
  registrations; extend `check-agent-integrations.py` for the agent-notify PreToolUse entry;
  parity tokens for the new setup/sync calls.
- INVARIANTS row INV-26, status `local-green (pending merge)` until CI is green.
- ADR-0011 in `docs/decisions/`; idea doc status; global-hooks README; notify-when-done.md note.

## Verification (real output)

- Use the page for this build's own closing questions to Michael (Claude app, browser pane).
- Codex: `codex exec` opens an ask, polls, and reads an answer posted by curl.
- Windows: CI job runs `check-ask.py` on `windows-latest`.

## Review 2026-10-04 (fresh Claude reviewer + Codex gpt-5.6-terra; Gemini unauthenticated)

Changed (valid, actionable):
- Hooks stay silent in headless lanes (the hub's `claude -p`), like INV-17's context-card.
- Approvals for publication or anything irreversible (push, deploy, send, delete) stay in chat
  or the card, never the page: a page answer arrives as tool output, and any same-user process
  holding the token could post one. Threat model in ADR-0011.
- Waiting email dropped (INV-13); Michael's decision.
- Registration order: ask-guard registered before `configure_agent_integrations` in setup and
  sync, so the agent-notify Stop entry stays last and a second run is byte-identical.
- Codex flag through `codex features enable` (the CLI owns its TOML), not the string-only
  defaults converger; no `suppress_unstable_features_warning` (it would hide every unstable
  feature's warning).
- Codex gets the ask-guard Stop check too (`last_assistant_message`); needs Michael's one-time
  hook review in Codex, like the existing Codex hooks.
- Server: 127.0.0.1 bind and Host-header check under test; `close` over HTTP (no pid kill);
  random id, exclusive dir; first answer wins (409 after); images copied at open, regular files
  only; JSON in the page escapes `<`, `>`, `&`; text rendered with textContent; session id
  stored hashed; dirs older than 7 days pruned; `wait` ends when the server is gone; detached
  with no inherited pipes (Windows: breakaway from the job when allowed).
- Lint false positives cut: picture words only in picture phrases ("the mock", "screenshot",
  "right pane"), URLs and framework names (`Next.js`) ignored; Windows paths caught.
- Stop check: headings only count when they are headings, not list items; skips sidechain
  entries; a missing final message never blocks.
- Up to 3 images per option (PROC-01's 390 and 1280 px pair); questions may be skipped.
- Rules that conflict updated with the new one: agent-skills.md (clarifying questions use the
  card), request-queue.md (status in the report, open items through page or card).
- Subagents never open pages; they return questions to the parent.
- SSH or remote sessions: the page is on the agent's machine, so they use the card.
- `check-ask.py --machine` proves the registered hook runs; a 3.9 grammar check.

Accepted trade-offs: same-user processes can reach a page whose token they read (the user
account is the trust boundary); the Stop check is a backstop, not a parser; Codex app and its
browser are not exercised (no way to drive the app here); Windows ACLs come from the profile.
