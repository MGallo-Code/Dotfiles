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
- EA project skills (plan records each): relink, note, inbox-zero archived (EA `dc5bfed1`, `ae87e70e`, plan `b7478f2e`; local, main is 3 ahead and 47 behind, so push via the ea-push worktree handshake on Michael's go). Hub inbox gaps sent to Learning. Learning retires practice, write-practice, check and addskill as the hub covers them and will message; then drop the dotfiles `practice` function. checkin and refresh: undecided.
- Decided: refresh and checkin kept (for now); the `--dev` gap is parked (Michael: probably no such machine).
- EA cleanup, plan EA `docs/plans/ea-cleanup.md`. Step 1 (quick wins) is done and pushed: EA `4ea6ee19`, verify_tree GREEN, local-green because CI is billing-blocked; Learning was asked to log it in coordination.md. Dotfiles is pushed (CI 36792552268 green). The EA main checkout is level with origin.
- Michael decided step 2 (2026-09-30): A "a yes" (claude-config to dotfiles); B "I like that split, let's do it" = code vs personal at ~/Documents/GalloGrid (sibling root), done in tandem with Learning ("communicate with it to ensure this all lands as intended").
- A, dotfiles ADR-0006 (reviewed; blockers fixed: no sync self-re-run, EA removal waits for the PC):
  - Step 1 done: dotfiles `aaeb9ff` (local). Copy of EA 3ef719ac, retarget function sh+ps1, Windows verify by target, prompt generator guard, secret patterns, trigger hooks, check-context-card/agent-rules-hooks/moved-links checks, INV-17.
  - Step 2 done: mini cut over (links, hooks, Codex config, prompts), machine checks OK, `claude -p` clean.
  - Step 3 done: pushed `ebb3fb3` (Michael: "Yes, go for it"), CI 36805410899 green, 17/17 incl. agent-config-windows. Step 5 sent: Learning drops the verify_tree blocks in its next push.
  - Step 4 done over SSH (mini key now trusted: PC user moses via C:\ProgramData\ssh\administrators_authorized_keys, WSL root@100.101.19.102, laptop michael@100.67.196.41). Ran the cutover steps by hand, not sync. Stashed: PC dotfiles font edits ("PC font edits set aside..."; restore with `git stash pop`) and WSL EA note (now in EA 1629746b). Left for a full sync: PC Wiki research pages (conflict in index.md/log.md with origin), PC nvim lazy-lock, the mini Wiki's uncommitted Aug 21 index section, dangling retired skill links.
  - Step 5 done: EA 57952754 pushed (Michael: "Go ahead and move a"), verify_tree GREEN on that commit. Main checkout rebased onto it, plus 2 local unpushed commits: cd24724d (Styling's ui-style round 4; Styling will message me to fold the settled rules into claude-config) and e8824b0a (split plan sign-off). PC/WSL EA pulled; leftover __pycache__ dirs removed; WSL stash dropped (note landed). ADR-0006 is DONE.
  - Not yet: the mini's ~/.ssh/config aliases (pc-pwsh, pc-wsl, laptop) are still unwritten.
- Queued (Michael): clean the bloated ~/Documents folder, after the GalloGrid split. A Wiki reconciliation (PC + mini uncommitted research) is also needed before full syncs on the PC.
- B, Michael said go ("split b"). Plan: EA docs/plans/gallogrid-split.md (my commits 42545470, a894bb3c, b20bde2a ride Learning's next push; Styling's 946ad6ad and 725a510e stay local until Michael approves them) + gallogrid-split-hub.md (pushed in 6830ecf9).
  - Review (proceed with fixes) folded in: no identifying data in GalloGrid, tip or history; B5 before B4; drain before freeze; per-machine CODE_ROOT; cleanup and grep gates; rollback.
  - Michael's history decision: "Keep history, scrubbed", i.e. a filter-repo rewrite. git-filter-repo is installed (brew). Learning builds the scrub lists (replacements.txt, paths.txt) in its scratchpad; I move them to ~/.config/gallogrid-scrub/ (700) and trial on a scratch clone. The gate must show zero hits before any freeze.
  - B0 (Learning): items 1 (promote root) and 4 (deny constant, GalloGrid denied whole) pushed in 6830ecf9. Tip scrub bb1a3627 is being expanded to "no identifying data at all". Remaining: 2 (pinned store), 3 (ea_root), 5-7, plus --dry-run, the media-ratings path setting, and a closing promote from EA (needs Michael for sudo).
  - B1 (me): dotfiles 26bca63 + 7338f0d pushed, CI 36809150628 green. resolve_code_root/Resolve-CodeRoot, NEXUS_HOST_STORE (renamed: never NEXUS_DB/NEXUS_LIVE_DB, never exported), $CODE_ROOT in hubs.json with the bootstrap refusing an unresolved token, EA's generated .mcp.json retired, Gemini roots, INV-18, check-code-root sh+ps1. The mini resolves to EA.
  - B0 item 2 revised (Learning): the per-checkout nexus.db link stays, because it is what keeps worktrees hermetic. At B3: hubs.json nexus run_cmd gets NEXUS_DB=..., courier gets COURIER_NEXUS_DB, music plists get EA_HUB_NEXUS_DB, and setup creates GalloGrid's nexus/nexus.db link on the host only. Deferred to B3 because a hubs.json change reloads the live services on the next sync.
  - History trial (scratch clone of EA 914341c5, filter-repo keep-list, then invert paths.txt, then replace-text + replace-message): 2188 commits, 224 MB. Gate (~/.config/gallogrid-scrub/gate.py, plus allowed-domains.txt and keep-paths.txt): zero SQLite, rule, health or message hits; 3 addresses left (keepthecall l****, neatfp j***, stephen h****), sent to Learning for the list and the tip edits.

- UI library, reshaped per Michael ("let's actually have ui be a workflow"; COMP-25 dropped). Dotfiles e281927 (local, unpushed):
  - one `ui` skill: SKILL.md is the workflow (read rules.md and the matching topic files, mock when there is a real choice, build, verify live, review, show, report), plus rules.md (the 25 core rules), core, components, touch, desktop, assistant, personal-tools, process and FORMAT;
  - one always-on `verification.md`: visible work runs the ui workflow; data processing gets its real output inspected;
  - ui-style.md and visual-verification.md are gone, and Design Taste moved into the workflow. Always-on rules are now about 16K;
  - INV-19 ui-nudge.py, PostToolUse Edit|Write|MultiEdit, once per session, fail-open, registered by ensure_claude_hook / Ensure-ClaudeHook (manifest), with check-ui-nudge sh+ps1 and revert tests. Registered on the mini.
  - Open: push on his go; GalloGrid 32 rules after the split; KeepTheCall 4 rules (where is that repo?); the overlap walk; Styling's 3 EA commits await his publish decision.
- B0 done on main (Learning, a9acd20f and later), apart from the closing promote: kickstart com.ea.calendar-http (Michael's go), then the promote with Michael at the screen.
- History re-trial 2026-10-01 on EA 09832b0c: 2208 commits, gate 0 hits over 23,156 objects and all messages (54 rules, 3 drop paths, allowed-domains reviewed). Ready for B2 after the drain (B) and the freeze.
- Calendar identity: (a) ran on the mini 2026-10-01 (Michael: "sure on new 2"); identity.toml present, `identity: present` sent to Learning, which pushes (b) and item 7. Before the B0-closing promote: `launchctl kickstart -k gui/501/com.ea.calendar-http` (needs Michael's go), else the promote preflight refuses.
- Laptop: Michael asked to pull laptop-only EA files (profile/health etc.). Blocked by macOS TCC; asked him to turn on Remote Login's "Allow full disk access for remote users".
- Left in place: worktrees `journal` and `music-playlist` (uncommitted changes) and `emailing` and `rating` (their chats are not archived).
- Running chats pick up new rules only via `/wrap` or a new chat (docs: rules load at start; skills, agents and hooks hot-reload; commands undocumented).
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
