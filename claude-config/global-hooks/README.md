# global-hooks

Claude Code hook scripts, symlinked to `~/.claude/hooks/` by the dotfiles installer
(`manifest.sh` SYMLINKS array plus `setup.sh`). The payload lives here in EA (synced);
the per-machine registration lives in `~/.claude/settings.json` (not synced).

## agent-notify.py - explicit cross-agent completion email

The assistant convention lives in `global-rules/notify-when-done.md`. The implementation
is completion-only and silent unless the exact Claude, Codex, or Gemini session was armed.
`notify-claude.sh` remains only as a compatibility wrapper during migration.

### Native events

- Claude Code: `Stop`. The old `Notification` registration is removed.
- Codex: top-level `notify`, receiving `agent-turn-complete` JSON as its final argument.
- Gemini CLI: `AfterTool(run_shell_command)` binds the successful arm marker to Gemini's
  real session id; `AfterAgent` consumes it at completion.

Dotfiles `configure-agent-integrations.py` owns all registrations. Both setup and routine
sync call the same configurator on Bash and PowerShell, preserving unrelated hooks and
failing closed if an existing config is malformed. Because Codex exposes one `notify`
command, an existing Codex Desktop callback is encoded as an argument-safe passthrough;
it still receives Codex's untouched event payload before the opt-in email path runs.

### State and delivery

- Private state: `~/.config/agent-notify/` (directory 0700, files 0600 on POSIX).
- Session ids are SHA-256 keys, never stored raw or included in email.
- An arm atomically becomes pending work. A successful send removes it. Failure retains
  it for a later completion of that same explicitly armed session.
- Delivery is at-least-once. A network timeout after server acceptance can theoretically
  duplicate a message; deleting before acknowledgement would instead lose the requested
  notice.
- Local Himalaya is attempted first. Any absence or real send failure falls back to the
  authenticated Courier Streamable HTTP endpoint with a standard-library MCP handshake.
- Email contains only agent name and the caller-provided short label. Hook prompt,
  response, cwd, tool content, and session id are ignored.
- Unarmed events do not read mail config, log payloads, or contact the email transport.
  A preserved Codex Desktop callback still runs exactly as it did before migration.

### Troubleshooting

- Status log: `~/.config/agent-notify/notify.log`. It contains fixed result codes only,
  never addresses, labels, paths, or hook payloads.
- Live wiring and a stubbed state-machine exercise, with no email sent:

      python3 ~/.dotfiles/scripts/ci/check-agent-integrations.py --machine

- Re-run `sync` to repair missing registrations and regenerate the machine-local transport
  config. The notifier never stores a bearer token itself; it reads the existing mode-600
  Courier token only after an armed local send fails.

## context-card.py - resume cards and the clear guard

Design: EA `docs/decisions/0004-self-refreshing-sessions.md`; invariant: dotfiles INV-17 (was EA INV-11; moved by dotfiles ADR-0006); command `/wrap`.

- `session-start`: in a session bound to a card, prints the full card after a compaction or clear (or after a guarded `/wrap` clear, which the Desktop reports as `startup`), otherwise a one-line pointer; lists a repo's cards for unbound sessions; silent in headless lanes (`CLAUDE_CODE_ENTRYPOINT=sdk*`).
- `pre-compact`: bound sessions only. Prints the card contract (path, last update, commits since) and the working model's profile from `../model-profiles/compact/`; its stdout is appended to the compaction instructions.
- `clear-guard`: PreToolUse on the Desktop `clear_session` tool. A session clears itself only when the turn began with a bare typed `/wrap` and the card checkpoint landed after it; everything else, including errors, exits 2.
- `role-guard`: PreToolUse on Edit/Write/NotebookEdit/Bash/PowerShell. Silent unless the session set an orchestration role (skill `build-orchestration`). Blocks with exit 3; the registered wrapper maps 3 to 2 and lets everything else through, so a missing or unreadable script never blocks a session.
- `challenger-guard`: registered in the `challenger` agent's own frontmatter (runs only for that subagent): pass-1 isolation from the canonical checkout, evidence-only writes, read-only git.
- `orchestration new <name> [--builder-worktree <path>] [--allow <path>]... | on | off | end [<name>] | status` (the `/orchestrate` command): `new` sets up the Orchestrator's card (RESUME.md), role and autowrap; `off`/`on` pause and resume; `end` tears down. Its activation lives in `~/.claude/resume-state/orchestrations/`. Each brand-new session in the Builder worktree becomes a Builder with its own card while the Orchestrator's role is live.
- Recovery: if a role session is ever stuck (a guard error blocks its tools), delete `~/.claude/resume-state/role/<session-id>.json` from another terminal.
- Helpers: `status`, `bind <name>`, `bind --file <path>` (the Orchestrator's RESUME.md), `unbind`, `commit <message>` (commits only the card), `autowrap on|off|status|limit <tokens>` (the `/autowrap` command: 350K or a custom 150k-1000k window for chats started in the project, keyed by its repo root. One record per folder tracks who holds the window (autowrap, or an orchestration), and the previous limit returns when the last holder leaves), `role orchestrator --orch-dir <path> | builder | off`.
- Codex: `session-start --agent codex` reloads the card after Codex compacts (identity: stdin `session_id` in hooks, `CODEX_THREAD_ID` in the model's shell). Codex ignores PreCompact output, so no card-aware summary there.
- State: `~/.claude/resume-state/` (bindings keyed by the Desktop session id or `pid-$CLAUDE_PID`, clear markers, local cards for other people's repos, `log.txt`).
- `request-capture` (Stop; also run inside `pre-compact` and `session-start`): sweeps what Michael typed, prompts and mid-turn messages, from the transcript onto the conversation's request queue in `~/.claude/resume-state/queue/` (dotfiles ADR-0008, INV-23). `session-start` then prints every open item verbatim. Agents close items with `context-card.py queue done|drop <ids>`; `queue list|show|add|reopen` too. Codex: `request-capture --agent codex` on Stop, interactive rollouts only.
- Registration: dotfiles `configure-agent-integrations.py` (SessionStart `startup|resume|clear|compact`, PreCompact, PreToolUse `mcp__ccd_session_mgmt__clear_session`, Stop `request-capture`). Test: `python3 scripts/ci/check-context-card.py` (+ `--revert-test`).
