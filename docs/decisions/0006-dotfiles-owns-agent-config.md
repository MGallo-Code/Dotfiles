# 0006 - Dotfiles owns the agent setup: `claude-config` moves from EA

- Status: proposed
- Date: 2026-09-30
- Decided by: Michael ("a yes", 2026-09-30, step 2A of EA `docs/plans/ea-cleanup.md`)
- Supersedes: ADR-0003, in part. The rule-regeneration trigger moves from EA's git hooks to dotfiles' own.
- Amends:
  - ADR-0005: the hook script now lives here.
  - EA ADR-0004: its surfaces move here; its design stands.
- Invariants: INV-15 and INV-16 change; new INV-17 takes over EA INV-11.

## Context

- **What `claude-config/` is:** the source for every machine's agent setup:
  - `global-rules/`, loaded by every Claude chat and generated into Codex's `AGENTS.md`;
  - `global-hooks/`: resume cards and the completion email;
  - `global-commands/`, `global-agents/` and `global-skills/`;
  - `model-profiles/`.
- **Where it lives today:** in EA, Michael's personal-ops repo. Dotfiles links it into `~/.claude` and `~/.codex`.
- **What that costs:**
  - **Slow pushes for small changes.** A one-line rule change is an EA push. That push runs EA's full gate (7,384 hub tests, about 6 minutes) and the push handshake with the hub sessions.
  - **Split work.** One agent-system feature lands in two repos with two invariant registries. Self-refreshing sessions were EA ADR-0004 / INV-11 plus dotfiles ADR-0005 / INV-16.
  - **No setup without EA.** A machine set up without EA (`setup --dev` or `--minimal`) gets no rules, commands, hooks or agents.
  - **Shared branch.** Agent-system work and hub work share one branch.

## Decision

1. **The move.** `claude-config/` moves to `~/.dotfiles/claude-config/`, with the same name and subfolders.
   - It is copied, not history-imported. EA keeps the full history. The copy is EA `origin/main` 6f06e117, whose last change to `claude-config/` was `3ef719ac`, byte-identical with the same file modes. The removal checks `git log 3ef719ac..HEAD -- claude-config` in EA is empty.
   - Because the layout is unchanged, EA's `check-context-card.py` moves unchanged: it resolves the script from its own repo root.
2. **The manifests** (`manifest.sh`, `manifest.ps1`) point every source at the new path:
   - the four `~/.claude` links (rules, hooks, agents, commands);
   - the combined-rules source;
   - the completion-email hook;
   - the global skills;
   - the Codex prompt source.
   The hook registrations in `~/.claude/settings.json` and `~/.codex/config.toml` follow on their own: the configurator finds hooks by script name and rewrites them in place (ADR-0005).
3. **Cutover on existing machines.** Sync today leaves a link that points at the wrong place, and only warns. The Windows half accepts any link at all. So:
   - **Retarget known moves.** A new manifest list, `MOVED_LINK_SOURCES` (old prefix to new prefix), and one manifest function per platform (registered for parity) let setup and sync replace a link whose target is under a moved prefix, whether the link is live or dangling.
     - The function covers the `~/.claude` links and the skill links. The Windows skill junctions are retargeted too; today they keep any existing link.
     - Only links are touched; a real file or folder is never removed.
     - On Windows the link alone is deleted, as the retired-surface cleanup already does. If a symlink needs elevation, the fallback is a junction.
     - Sync runs it before the repo pulls, while the old targets still exist.
   - **Windows verifies by target,** as `setup.ps1` already does, instead of accepting any link.
   - **Two phases, not one.** A sync runs the code it started with: PowerShell parses the whole script first, and bash keeps reading the old file. So a machine's first sync after the push still uses the old paths, and only the second runs the new code. EA therefore keeps its copy until the PC has synced twice and its links are confirmed in dotfiles. EA removal comes after that, behind a check that EA's copy is unchanged since the move.
   - **Generated files never empty out.** If a declared source folder is missing, the Codex prompt generator keeps its outputs and fails verification. Today it deletes every prompt.
4. **The trigger and the checks move too:**
   - `refresh-agent-rules` and the `post-commit`, `post-merge` and `post-checkout` hooks come to dotfiles, so a rule edit here regenerates Codex's `AGENTS.md`.
   - `check-context-card.py` (with its revert test) and `check-agent-rules-hooks.sh` move to dotfiles CI and pre-commit.
   - EA's copies, its CI steps and its hooks are removed. The hub's `verify_tree.sh:131-144` drops its two calls; the hub session owns that edit.
5. **The invariants follow the files:**
   - New INV-17 takes over EA INV-11's text and enforcer.
   - INV-15 and INV-16 drop "EA". EA INV-11 becomes a one-line pointer.
   - Files inside `claude-config` that name their own path are updated: `notify-when-done`, `workspace-map`, `magic-prompt`, `orchestrate`, `build-orchestration` and the hooks README.

## Alternatives rejected

- **Leave it in EA and fix only `--dev`** (clone just `claude-config` with a sparse checkout). This closes the gap but keeps the slow gate, the split ownership and the shared branch.
- **Import the history** (fast-export or subtree). `git subtree` is not installed, and EA keeps the history anyway. The move commit points to it.
- **A sync that re-runs itself after pulling new dotfiles commits.** Rejected in review: the first sync after a push still runs the old code. A re-run also deadlocks on sync's own lock (`git-sync-lock.sh`): it exits 0 after the dotfiles step and silently skips everything else.

## Consequences

- A rule, command or hook change becomes a dotfiles commit: seconds of checks, no hub gate, and nothing shared with the hub's work.
- Codex may ask once per machine to trust the SessionStart hook again, because its command path changes.
- During the move window, the Codex `AGENTS.md` regeneration runs from either repo's hooks; both call the same dotfiles entrypoint.
- Between the dotfiles push and the EA removal, two copies exist. Only the dotfiles copy is live on a cut-over machine. Nobody edits EA's copy (the hub session is told), and the removal checks that EA's copy is unchanged since the move.
- The moved files get EA's stronger secret scan: dotfiles' `check-no-secrets` gains EA's API-key and bearer patterns.
- Open: whether WSL on the PC runs its own dotfiles. If it does, it is a third machine to sync twice.
- Wiki pages and old plans that name `EA/claude-config` are history and are left as they are.

## Rollout (each step verified before the next)

1. **Dotfiles: add.**
   - Copy `claude-config/` in, keeping file modes.
   - Point the manifests at it, and add the retarget list and functions.
   - Windows verifies links by target; the prompt generator no longer empties out.
   - Move the trigger hooks and the two checks.
   - Port EA's secret patterns.
   - Fix the hermetic checks built on the EA path, and add a Windows retarget test (symlink and junction, live and dangling) with a revert test.
   - Update the docs: README, INVARIANTS, comments.
   - Hermetic checks green locally. Commit.
2. **The mini: cut over** without running `sync`, which would push. Run the retarget, link, rules, skills, prompts and configurator steps by hand. Verify:
   - every link and registration points into dotfiles;
   - Codex's `AGENTS.md` matches the new sources;
   - a `claude -p` smoke run shows no hook errors.
3. **Dotfiles: push** (Michael's go). CI green, including the Windows jobs.
4. **The PC and WSL: `sync` twice each.** Then `(Get-Item ~\.claude\rules).Target` on the PC, and `readlink ~/.claude/rules` in WSL, show the dotfiles path. WSL (`/root`) has its own dotfiles and EA clone, so it is a third machine.
5. **EA: remove, in one push with the hub session.** EA's `ci.yml` steps, the hub's `verify_tree.sh` blocks and its `test_manifest_consistency` step map are locked to each other, so removing any one alone turns the gate RED.
   - Confirm EA's copy is unchanged since the move.
   - Mine: remove `claude-config/` (and its ignored `__pycache__`), the trigger hooks, the two checks and their `ci.yml` steps. Point CLAUDE.md, INV-11, the INV-15 trigger and ADR-0004 at dotfiles.
   - The hub session, on top: both `verify_tree.sh` blocks (found by content) and both `CI_STEP_TO_LOCAL_LABEL` entries.
   - One `verify_tree` GREEN, then one push (Michael's go).

Review: a fresh-context adversarial review on 2026-09-30 found two blockers, both fixed above. One was the self-re-run; the other was the removal order. Its should-fix items are folded into steps 1, 2, 4 and 5. Step 5 was merged with the hub's edit after the hub session found the CI-to-gate lock.
