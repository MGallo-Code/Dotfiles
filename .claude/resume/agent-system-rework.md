# agent-system-rework

## Goal
Keep Michael's agent setup lean, and his long sessions accurate without him managing context. Done so far: the unused-surface trim and self-refreshing sessions v1. Still to come: the orchestration (GAN) layer and the deferred model/CLI settings.

## Decisions (stated exactly)
- Commits: "git commits should be frequently used, just not pushes necessarily." Pushes, merges and deploys need his go.
- Context scope: "I wouldn't want to enable it in one session and have it start activating on another session I don't want it in." So a card is per session (`/wrap`), the threshold is per project (`/wrap project`), and nothing is user-level.
- Hub: "we don't need it on the hub for the most part." Don't touch the hub's CLI or user settings until he says so (deferred 2026-09-27).
- Models: "opus default, fable for orchestration prompts" (lean on the research). Not applied yet; it is tied to the CLI deferral.
- Orchestrator pilot: "A/B both" (Opus 5.5 high + Fable advisor vs Fable 5.1 high).
- No helper sessions: "don't like the idea of wasting process on a refresher."
- Keep ea-hub-specific things on the mini, outside dotfiles.

## Discoveries paid for
- In the 2.1.281 build, PreCompact stdout is appended to the compaction instructions, and SessionStart(compact) output reaches the model.
- A Desktop self-clear starts a new session (`startup`) with the same `CLAUDE_CODE_HOST_SESSION_ID`.
- The built-in `/autocompact` writes USER settings, so there is no per-session threshold.
- Desktop `start_session` / `hand_off_to_session` sit behind a server feature gate that is off for this account.
- PreToolUse hooks fire on Desktop tools and can block `clear_session`.
- Hooks in linked worktrees get an absolute `GIT_DIR`. Any git call from a hook-run test must drop `GIT_*`: on 2026-09-29 at 16:29 this corrupted the EA config, which has since been repaired.
- Michael's remotes use the `git@github:` alias.

## Done and verified
- Trim applied and pushed (dotfiles CI 36307705174 green); the EA trim commits are local. Detail: EA `docs/plans/agent-setup-trim.md`.
- Self-refreshing sessions v1 is built and registered on the mini: EA `7e65d1d5`..`683fd8b8` (local) and dotfiles `de99d1e` (local). Fixtures, revert tests and the live guard check are green. Detail:
  - EA `docs/plans/self-refreshing-sessions{,-build}.md`
  - ADRs: EA-0004, dotfiles-0005
  - Invariants: EA INV-11, dotfiles INV-16

## Next exact step
Everything is pushed (2026-09-30).
- EA `a2e2c820` (verify_tree GREEN, Learning notified): `/wrap [keep]`, `/autowrap on|off|status|limit`, and `/orchestrate new|on|off|end|status`. A pause holds Builders idle, and one window record per folder is shared by autowrap and orchestrations.
- Dotfiles is pushed.
Now: the context diet, read-only. Plan: EA `docs/plans/context-diet.md` (uncommitted in the main checkout, which is 46 behind; commit it after Michael pulls, or through a worktree).
- Michael decides the EA project skills one by one (keep, archive or delete) from the table in the plan.
- Then the connectors, EA's CLAUDE.md, the rules, and the kit, item by item.
- Principle (Michael): keep Claude and Codex the same, or as close as possible.

## Queued after that
1. Pushes done 2026-09-29: dotfiles and Wiki (dotfiles CI 36660742569 green, 15/15), and EA `2f00ac66`. EA: Michael said go, coordinated with the Learning session: merge `02853ed1` in `~/Documents/Worktrees/ea-push`, pushed only on verify_tree GREEN, then send Learning the sha. Plain push, never force. EA is about 32 ahead and 65 behind: merge first (the Learning session found a clean trial merge). Then get CI green for EA INV-11 and dotfiles INV-16; the PC picks everything up at its next sync.
2. Done (dotfiles `40e2255`, local): F8. Sync now sets `permissions.defaultMode=auto` (Michael: "Auto"). The `ea` launcher still starts in bypass per launch (INV-14).
3. Done 2026-09-30: CLI 2.1.285, and model defaults via dotfiles `8b3cbb3`.
4. Orchestration phase 2 is built (skill `orchestrate`). What remains is the A/B pilot on Michael's next orchestrated project, and the design detail below: Wiki "Orchestrated Build-Critique System (Lab Note)", steps 1-8. The pinned handoff is Wiki `raw/orchestrated-build-critique-handoff-2026-09-27.md`.
   - Challenger: a fresh subagent per revision.
   - Builder: one per slice, with a lessons file.
   - Orchestrator: rotated from `RESUME.md`.
   - Prose rules become hooks; model and effort are set per role; A/B pilot plus metrics.
5. Done 2026-09-30, `/magic-prompt` upgrade: fold in `/prompt-audit`'s doc-grounded routers, add a refresh mode, and own `model-profiles/compact`. Retire `/prompt-audit` unless Michael objects.
6. Done 2026-09-30 (card reload after compaction; no card-aware summary, because Codex ignores PreCompact). Codex: test compaction hooks (does SessionStart fire after a compaction?) and give cards a session identity.
7. Done 2026-09-30: the POC worktrees went to the Trash; the test sessions stay archived.
8. After major Desktop updates, recheck the guard's tool name, `mcp__ccd_session_mgmt__clear_session` (INV-11 limit).
