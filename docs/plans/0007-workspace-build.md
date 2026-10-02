# ADR-0007 build plan: ~/Workspace, docgen and agent-skills in dotfiles, GalloGrid mini-only

Decision: `docs/decisions/0007-workspace-layout.md`. Each phase is gated: its tests green locally and in CI before the next starts. Nothing moves on a machine until phase 1 is pushed and green.

## Phase 1 - dotfiles (one branch, one push)

1. **docgen in.** Copy `GalloGrid/docgen` tracked files at the current GalloGrid `main` to `tools/docgen/`. No history; the source commit goes in the commit message.
   - `.gitignore`: `tools/docgen/.venv/`, `tools/docgen/output/*` (keep `.gitkeep`).
   - Chromium leaves the repo: `DOCGEN_BROWSERS` = `~/.cache/docgen-playwright` (`$HOME\.cache\docgen-playwright` on Windows).
   - `DOCGEN_PATH` = `$DOTFILES_DIR/tools/docgen` in setup and sync, both platforms. It no longer comes from the code root.
   - CI: a `docgen` job (uv, `playwright install chromium`, pytest) on Linux. A Windows smoke run (import and `docgen-server --help`), since the PC wires docgen locally.
   - Gate: check-no-secrets over `tools/docgen`; a personal-data grep (emails, home paths) is zero hits.
2. **agent-skills in.** `git subtree add --prefix=agent-skills <fork> main`. This keeps history; the repo is already public. An `upstream` note in the README tells how to pull upstream by hand.
   - `AGENT_SKILLS_DIR` / `$AgentSkillsDir` = `$DOTFILES_DIR/agent-skills`.
   - sync stops pulling it as a separate repo. The dirty-repo commit path's agent-skills branch goes.
   - The `sysupdate` launcher drops its `--add-dir agent-skills`, since it is inside dotfiles now.
   - Check how its own `hooks/` and `CLAUDE.md` are used today. Nothing of it may register twice.
3. **Paths.** One root: `WORKSPACE_DIR="~/Workspace"` (`$WorkspaceDir`).
   - **REPOS** (and `EA_REPOS`): EA, Wiki, Notes under `~/Workspace`. GalloGrid moves to a new `HOST_REPOS` list, cloned and synced only when `is_mcp_host`. Windows has no host repos.
   - **Code root (INV-18 rewrite):** `resolve_code_root` = `~/Workspace/GalloGrid` on the host. A client has none and never needs one (`needs_local_nexus` is false after the cutover, and docgen is in dotfiles). The switch file `~/.config/dotfiles/code-root` is retired with a tombstone, and the EA fallback goes. `hubs.json` keeps `$CODE_ROOT`.
   - **Every live reference** in the tracked-file list from the 2026-10-01 grep:
     - manifest sh/ps1, setup sh/ps1, sync sh/ps1;
     - `shell/ea.zsh` and `shell/windows/ea.ps1`: `ea`, `wiki`, `sysupdate`, practice;
     - the Gemini and Codex trust lists;
     - check-workspace-access py/ps1 and workspace-access-diagnostics;
     - check-tcc-grants;
     - the global rules (`workspace-map.md`, `email-tools.md`), skills and agents that name paths;
     - README, CLAUDE.md and AGENTS.md.
4. **Migration** (new manifest functions `migrate_to_workspace` / `Move-ToWorkspace`), run by setup and sync before any repo sync or linking. For each managed repo (EA, Wiki, Notes; GalloGrid on the host; the old `~/Documents/agent-skills` clone):
   - **Act only when** the old path is a git repo whose origin matches the manifest remote AND the new path does not exist. Otherwise: no-op if already moved; warn and leave both if both exist. Never merge, never overwrite.
   - **Refuse, warn and skip:**
     - on macOS, any dataless (iCloud-only) file;
     - a process with its working directory inside (macOS/Linux `lsof -d cwd`; Windows: the move fails as a locked folder and is reported);
     - for agent-skills, a dirty tree or unpushed commits.
   - **Move:**
     - same-disk rename to `~/Workspace/X`;
     - `git worktree repair` from the new main checkout (this re-points the linked worktrees under `~/.claude-worktrees` and `~/.codex/worktrees`), then `git worktree prune` only for entries whose folder is already gone;
     - the old agent-skills clone is not moved but parked in a dated leftovers folder, after the clean check above.
   - **Re-point:**
     - Claude memory folders: every `~/.claude/projects/<key>` whose key starts with key(old path) is renamed to key(new path) plus the same suffix (key = path with each non-alphanumeric character turned into `-`). It is skipped if the target exists;
     - Codex `config.toml` project paths, as a text replace of the exact old path prefix;
     - links: `MOVED_LINK_SOURCES` gains `~/Documents/EA`, `Wiki`, `GalloGrid` -> `~/Workspace/...` and `~/Documents/agent-skills` -> `~/.dotfiles/agent-skills` (ADR-0006 machinery: live or dangling links, Windows junctions).
   - **Not touched:**
     - `~/.claude.json` project keys, which running Claude processes rewrite: each moved folder asks for trust once;
     - the Claude Desktop app config;
     - the old empty `~/Documents/X` folder, which is removed only if empty.
   - **Idempotent:** a second run is a no-op.
5. **Gates (new invariants, both platforms):**
   - **INV-21, migration:** `check-workspace-migration` sh+ps1, hermetic, using real repos plus a linked worktree, memory folders and a Codex config. It checks:
     - the repo moves;
     - the worktree still works;
     - the memory keys are renamed;
     - Codex is re-pointed;
     - a second run is a no-op;
     - an existing target is never overwritten;
     - a cwd-busy repo is skipped.
     A revert test plants an unconditional move.
   - **INV-22, no stale pointers:** `check-no-stale-paths` fails on `Documents/(EA|Wiki|Notes|GalloGrid|agent-skills)` in tracked live files. History is allowlisted: `docs/decisions/`, `docs/plans/` older than 0007, and dated handoffs.
   - **INV-18:** rewritten fixtures (host has a code root, a client has none, the switch file is ignored).
   - Parity rows for every new function. CI jobs on Linux, macOS and Windows (pwsh and Windows PowerShell).
6. **Doubt pass on the diff** (fresh-context reviewer), then push; CI green.

## Phase 2 - content repos (same day, after phase 1 is green)

- **EA:** live pointers to `~/Documents/...` become `~/Workspace/...`:
  - `CLAUDE.md`, skills, `.claude/settings.json` hooks, `context/`, `profile/index.md`;
  - the KeepTheCall pointers (done in `8e63f30c`).
  - History docs stay. EA's own stale-path check if EA has a gate surface; otherwise dotfiles' check covers the rules it ships.
- **Wiki:** `index.md` and live pages (17 files). Lab notes keep the dated paths they describe.
- Push each with its own gate (EA `scripts/verify.sh`).

## Phase 3 - clients: PC, WSL, laptop (over SSH)

- Per machine:
  - pre-check no session is open in the repos;
  - `git -C ~/.dotfiles pull`, then one `sync`;
  - verify: `/mcp` shows docgen from `~/.dotfiles/tools/docgen`, links and the machine checks pass.
- **PC:** the WSL-hosted docgen entry in the PC's Claude config (B5 repointed it to `/root/Documents/GalloGrid/docgen`) moves to `/root/.dotfiles/tools/docgen`.
- **Clients drop their GalloGrid clone** (to the leftovers folder) and the switch file.
- **Laptop:** moving out of iCloud deletes iCloud's copies. Everything moved is on GitHub; the dataless check guards the rest.

## Phase 4 - the mini, with Learning (window like B3; Michael present for the promote)

1. **Learning, before the window:**
   - GalloGrid drops `docgen/` and its CI job;
   - GalloGrid's live path references (about 350 lines, mostly docs) become `~/Workspace/GalloGrid`;
   - the hub's `ea_root` setting and any EA paths the services read become `~/Workspace/EA`;
   - Learning's sessions pause.
2. **The window:**
   - **Dotfiles sync on the mini:** the migration moves EA, Wiki, Notes and GalloGrid and repairs their worktrees. It re-points MCP, re-bootstraps courier, calendar and nexus-http from the new code root, and wires docgen from dotfiles.
   - **Learning's installers** re-run from `~/Workspace/GalloGrid`: agent-http, media-intake, media-pull, playback-poll, music poller and drip.
   - **Checks:** `hub status`, launchd integrity, each installer's `--check-installed`.
   - **Promote (Michael):** `cd ~/Workspace/GalloGrid/ea-hub && ./scripts/promote_production.py`.
   - **After:**
     - the `hub` function in `~/.zshrc`;
     - the Desktop preview server;
     - the hub chats reopen in `~/Workspace/GalloGrid/ea-hub`.
3. **Rollback until the promote:** rename back, then sync from the previous dotfiles commit and re-run the installers.

## Phase 5 - cleanup

- Archive `MGallo-Code/agent-skills` on GitHub (Michael's go).
- Retire the code-root switch-file tombstone after every machine has synced once.
- Card and workspace-map updated; the leftovers folders listed for Michael.

## Review findings folded in (fresh-context review, 2026-10-01)

1. **Host opt-in (blocker).**
   - The mini is the dev box, so a test run or habitual `sync` must never move it early. On the MCP host the move runs only when `~/.config/dotfiles/workspace-move` says `now`, written at the start of its window.
   - Until then everything there falls back to the real old path:
     - REPOS entries and project-skill sources are re-pointed for the run;
     - `resolve_code_root` returns `~/Documents/GalloGrid`;
     - `MOVED_LINK_SOURCES` retargets only to a target that exists;
     - the launchers use the old folder while the new one does not exist.
   - No placeholder links, so the launchers' redirect rule stays intact.
   - The move is all or nothing: every repo is preflighted, and if one is blocked none moves.
2. **Laptop gitignored data (blocker).** Before its move, copy each repo's ignored files (`git ls-files -oi --exclude-standard`, minus venvs and `node_modules`) to `/Volumes/Media/Archive`. Leaving iCloud deletes iCloud's copy.
3. **No second copies.**
   - The migration runs before setup clones. Setup refuses to clone into `~/Workspace/X` while the old home still holds that repo.
   - Remotes compare as owner/repo.
   - A missing cwd probe fails closed (`lsof` or `/proc`).
   - Any skip makes sync and setup exit non-zero.
4. **Git config.** Values under the old prefix (EA's absolute `core.hooksPath`) are rewritten in `.git/config` and each `config.worktree`. INV-21 asserts a hook still fires.
5. **Hub sandbox profile.** Added to Learning's pre-window list, with its re-rooted denies, its test, and a hub-write smoke test before the promote. It must not grant write to GalloGrid.
6. **EA's GalloGrid-path edits land in phase 4**, not phase 2.
7. **Stale-path check.**
   - It matches both slashes (it already does).
   - Exemptions are per line (`stale-path-ok`) plus history files.
   - The launchers' `"$HOME/Documents/"*` redirect test is rewritten for `~/Workspace`.
   - A fixture launches `ea` in `~/Workspace/EA`.
8. **Rollback.** The migration journals every step: repo moves, git-config rewrites, memory-key renames, Codex rewrites, parked clones. `scripts/workspace-rollback.{sh,ps1}` replays the journal in reverse, with `git worktree repair`. INV-21 tests the round trip.
9. **Parked clones.** The same clean check (tree, unpushed on every branch, stash) covers agent-skills and a client's GalloGrid. The agent-skills unsync and the park step ship in one push.
10. **Venvs.**
    - After a move, a `.venv` that embeds the old path is removed; they rebuild: `practice` when missing, `uv sync` in sync, Learning's installers.
    - Learning is told its installers must rebuild theirs.
11. **Minor.**
    - **Memory keys:** renamed only for the exact repo key and for keys of subfolders that exist (no prefix sweep, so a sibling like iCloud's `EA 2` is safe).
    - **Process:** sync and setup `cd ~` first, and the cwd probe ignores the sync process and its parents.
    - **Windows:** moves use `[IO.Directory]::Move`.

## Second review (the diff, 2026-10-01) and Learning's window review, folded in

- **Arming.**
  - Every machine moves only when armed: `~/.config/dotfiles/workspace-move` says `now`. That is written over SSH per client, and on the mini at its window.
  - A pushed dotfiles moves nothing anywhere until then.
  - Until a machine is armed, nothing moves or retires there; the code root, lists and launchers use the real old home.
- **The old home wins.** While `~/Documents/<name>/.git` exists, the old home is used even if something exists at the new one. A stray clone or empty folder never switches the code root; the run flags it.
- **Hub bootstrap.** A blocked move skips the host's hub bootstrap for that run.
- **Busy check.** It exempts nothing: a shell or agent sitting in a repo, including the one that started sync, blocks the move.
- **iCloud check.** It is macOS `/usr/bin/find`, fail-closed, and runs on retired clones too.
- **agent-skills.** It parks only if its HEAD and origin/main are ancestors of the imported 0b1fea2.
- **Windows.** The library runs in Continue mode, since `setup.ps1` uses Stop. Python is checked before anything moves, post-move steps can't abort the run, and a leftover `*.ws-probe` stops it.
- **ACL.** `~/Workspace` gets `group:everyone deny delete` on macOS (Learning's point 2).
- **Phase 3 additions.**
  - Repoint the PC's WSL-hosted docgen entry (`~\.claude.json`, `/root/Documents/GalloGrid/docgen`) to `/root/.dotfiles/tools/docgen` before arming WSL.
  - The laptop's ignored files are already copied to `/Volumes/Media/Archive/laptop-ignored-before-move-2026-10-01`.
- **Phase 4 additions (Learning).**
  - Learning's `workspace-move` branch merges after the move succeeds, not before.
  - Step 0 boots out the web daemon, agent-http and the music/media jobs.
  - The installed-profile smoke needs Michael's sudo at step 5.
  - Rollback after the promote means re-promoting the previous commit (GalloGrid's window runbook).
  - Re-scope or retire `check-tcc-grants.sh`, which has no ~/Documents target after the move.
- **Open (Michael): the TCC trade-off.** `~/Documents` is TCC-guarded; `~/Workspace` is not. On the mini and the laptop, an unsandboxed process without a Documents grant could read EA's `profile/health` and write GalloGrid.
