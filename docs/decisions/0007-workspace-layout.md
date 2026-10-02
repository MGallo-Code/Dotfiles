# 0007 - Repos leave ~/Documents; dotfiles carries every machine's tools; GalloGrid is mini-only

- Status: accepted 2026-10-01 (Michael: "1. Yes."). Build plan: `docs/plans/0007-workspace-build.md`. Nothing has moved yet except Michael's own projects (below).
- Decided by: Michael, 2026-10-01: "Let's move them out of documents everywhere"; "~/Projects" for his projects; "Sure" to `~/Workspace` with GalloGrid on the mini only; docgen and agent-skills into dotfiles (his suggestion, pending his yes on this record).
- Amends: ADR-0006 (dotfiles also holds agent-skills and docgen); INV-18 (the code root).

## Context

- **iCloud on the laptop.** Its `~/Documents` is in iCloud Drive. iCloud makes " 2" conflict copies inside git repos and `.git`. On 2026-10-01 sync committed three of them to EA (`c22d3ffb`, removed in `a5ba9958`).
- **macOS guards `~/Documents`.** Services under launchd and SSH sessions need Documents access. That cost a permission prompt per hub binary at B3, and blocked SSH on the laptop until Full Disk Access was turned on.
- **GalloGrid on clients.** The PC, the laptop and WSL clone it only because docgen's code lives in it. Nothing else on a client uses GalloGrid.
- **agent-skills.** It is a separate repo that only dotfiles uses. Dotfiles links it into the agents, and automatic upstream merges were retired in ADR-0004.

## Decision

1. **The same layout on every machine:**

   | Folder | What | Synced by dotfiles |
   |---|---|---|
   | `~/.dotfiles` | setup, agent config (`claude-config`), `agent-skills/`, `tools/docgen/` | itself |
   | `~/Workspace/EA`, `Wiki`, `Notes` | content repos | yes, every machine |
   | `~/Workspace/GalloGrid` | hub and server code | the mini only |
   | `~/Projects` (+ `Archive/`) | Michael's own projects | no |
   | `~/Apps` (mini) | deployed services (KeepTheCall) | no |
   | `~/Documents` | personal files only | no |

2. **docgen moves into dotfiles** at `tools/docgen/`, copied without history, as `claude-config` was in ADR-0006.
   - Dotfiles is public. docgen's 19 tracked files are generic, but its 5 history commits carry shared EA/GalloGrid messages, so its history stays in GalloGrid.
   - Every machine, the mini included, wires docgen from there.
   - Its Chromium goes to a cache folder outside the repo.
   - Dotfiles CI gains a docgen test job.
   - GalloGrid drops `docgen/`. That is Learning's change; only GalloGrid's docs and CI name it, and nothing imports it.
3. **agent-skills folds into dotfiles** at `agent-skills/` via `git subtree`.
   - The history is kept, and upstream changes can still be pulled by hand.
   - The GitHub repo `MGallo-Code/agent-skills` is archived.
4. **GalloGrid becomes host-only** in the repo list.
   - The code-root switch file and `resolve_code_root` reduce to: GalloGrid on the mini, and no code root on a client.
   - INV-18 is rewritten to match.
5. **Migration, by sync, once per machine:**
   - Each managed repo is renamed from `~/Documents/X` to `~/Workspace/X` (same disk, so instant).
   - Then `git worktree repair`.
   - Claude memory folders move to the new path keys.
   - Links, MCP wiring and agent trust entries are re-pointed.
   - No symlink is left at the old path: on the laptop it would sit in iCloud.
   - Tests on both platforms; CI green before any machine moves.
6. **Order:**
   1. dotfiles: folding in docgen and agent-skills, the path change, the migration, and its tests;
   2. the clients (PC, WSL, laptop);
   3. path references in EA (`CLAUDE.md`, skills), the Wiki and the global rules (`workspace-map.md`);
   4. the mini last, in a window like B3, with Learning:
      - GalloGrid's own path references (about 350 lines);
      - re-render the LaunchAgents;
      - re-bootstrap courier, calendar and nexus-http;
      - Learning's installers;
      - a promote (Michael's password).

      `/opt/ea-hub` is untouched until the promote.

## Done already (outside sync)

- Michael's own projects moved to `~/Projects` on the PC and the laptop, with old repos under `~/Projects/Archive`.
- A safety copy of the laptop's set is at `/Volumes/Media/Archive/laptop-projects-before-move-2026-10-01`. iCloud had been their only off-laptop copy.
- WizBots on the PC stays where it is until Michael says otherwise; he is working in it.

## Consequences

- Chats whose folder moved must be reopened in the new path.
- Codex and Claude ask to trust each moved folder once.
- The `ea` launcher starts in `~/Workspace/EA`. Starting at `~/Workspace` itself would not load EA's `CLAUDE.md`, skills or settings.
- Off the mini, nothing under launchd or SSH needs Documents access any more.
- Rollback: the moves are renames. Rename back, then re-run sync from the previous dotfiles commit.

- **No stale pointers.** A check fails when a live file (not history: decision logs, old plans, handoffs) still names `~/Documents/EA`, `Wiki`, `Notes`, `GalloGrid` or `agent-skills`.
- **GalloGrid's services.** The hub web app runs from a deployed copy (`/opt/ea-hub`). courier, calendar and nexus run straight from the checkout, which is why the move needs their re-bootstrap. Giving them deployed copies is a follow-up for Learning.

## Open

- KeepTheCall: the repo becomes `~/Projects/keepthecall` (today `recoup-calls`), and its business papers go to `EA/business/keepthecall/`, kept out of git.
- The stale Jul 1 checkout around the releases in `~/Apps/keepthecall`: trim it later, separately, since the service is live.
