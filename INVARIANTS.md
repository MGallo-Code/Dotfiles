# INVARIANTS - Dotfiles

The per-repo registry of cross-cutting invariants: rules that must hold across many
surfaces, the single point that enforces each, and the gate that guards it. This repo's
defining property is cross-platform PARITY, so most invariants are about the `*.sh` and
`*.ps1` sides staying in lockstep.

## How to read a row

- **Invariant**: the end-state that must hold, stated as an outcome, NEVER as a banned
  verb.
- **Enforcement point**: the single chokepoint that, if used, makes the invariant hold.
- **Gate**: the mechanical check + its tier (pre-commit -> CI). POINT guards one named
  site; COVERAGE guarantees no site can silently omit it.
- **Status**: `required-gate` / `advisory-gate` / `point-only` / `local-green (pending
  merge)` (passes locally, not yet a CI gate - "prove it, don't promise it") /
  `advisor-only` / `to-build`.
- **Recur**: how many times this invariant has regressed (seed estimate).

## Index

| ID | Invariant (end-state) | Enforcement point | Gate (tier) | Status | Recur |
|----|-----------------------|-------------------|-------------|--------|-------|
| INV-1 | No live credential ever enters the tracked tree: private keys, real `~/.ssh/config` (with LAN/Tailscale IPs), `.env`, tokens. The committed SSH config is always the `*.template`, never the populated copy. | The git index at commit time + a content scanner over staged blobs; a committed `.gitignore`. | `scripts/ci/check-no-secrets.py` (pre-commit + CI) | CI-green | 0 |
| INV-2 | Every behavior the mac/linux `setup`/`sync`/`manifest` scripts perform is also performed by the Windows scripts (and vice-versa); a machine ends up configured the same way whichever OS ran setup, except genuinely OS-specific steps on the exempt list. | The paired `*.sh`/`*.ps1` files + a declared feature-token registry. | `scripts/ci/check-parity.py` (pre-commit + CI) | CI-green | 3 |
| INV-3 | RETIRED 2026-09-27 (ADR-0004): upstream agent-skills is no longer merged automatically, so there is no untrusted diff to gate. The fork syncs with origin like any repo; upstream stays one link away in `manifest.sh` (`AGENT_SKILLS_UPSTREAM`). | - | - | retired | 0 |
| INV-4 | No managed hub's bearer token is ever inlined into agent MCP wiring: the only token reference in a hub `mcp add` is an env var - `${<HUB>_BEARER}` (or the manifest's generic `${$token_env}` indirection) via claude/gemini `--header`/`-H`, or `--bearer-token-env-var <HUB>_BEARER` (codex); a literal token never reaches argv or a CLI's stored config. Distinct from INV-1 (the token lives OUTSIDE git, in `~/.config/<hub>/auth-token`, so the secret-scan never sees it). | The `Authorization: Bearer` references inside `register_hub_mcp`/`Register-HubMcp` (manifest), which only ever name an env var. | `scripts/ci/check-hub-wiring.py` COVERAGE (pre-commit + CI) | CI-green | 1 |
| INV-5 | Every managed hub is wired per-ROLE only through the shared functions: the host-vs-client decision AND every hub `mcp add` live once in `manifest.{sh,ps1}` (`register_hub_mcp`/`register_all_hub_mcp` and `Register-HubMcp`/`Register-AllHubMcp`); no `setup`/`sync` script wires a hub directly. | `register_hub_mcp`/`register_all_hub_mcp` (+ the `Register-*` ps1 mirror) in manifest; setup/sync only CALL them. | `scripts/ci/check-hub-wiring.py` COVERAGE (pre-commit + CI) | CI-green | 1 |
| INV-6 | Generated agent affordances derive only from ACTIVE roots AND match each target agent's native source exactly: an archived root (`ARCHIVED_REPOS` / `ARCHIVED_PROJECT_SKILLS`) never appears in an active list; after a regen every active source skill HAS its intended generated link/copy, no generated target dangles, and no two sources collide on a name. An archived project-skill source whose repo stays on disk (SBIC, ADR-0004) is pruned from every generated target; user-authored real skill dirs are never touched. | The manifest active/archived split + `CODEX_PROJECT_SKILLS` / `GEMINI_PROJECT_SKILLS` + `regen_agent_skills_links` (link/materialize + stale prune) + the post-regen `--machine` assertion. | `scripts/ci/check-skill-targets.py` (manifest mode: pre-commit + CI; `--machine` source-exact completeness/dangling/archived-leak/collision during `sync`, BLOCKING on both OSes) | local-green (pending merge) | 3 |
| INV-7 | Every shared Claude command source is usable in Claude and Codex: Claude sees the source directory at `~/.claude/commands`, Codex gets a generated prompt, and the generated dir carries an invocation index. Gemini's retired mirrors (ADR-0004) are removed, never regenerated. | `manifest.{sh,ps1}` wires `global-commands -> ~/.claude/commands`; `gen-agent-commands.py` emits the Codex mirror + `README.md` index and removes the retired Gemini TOMLs. | `gen-agent-commands.py --verify` run during `sync` on both OSes (a missing mirror fails the check); parity-gated by `COMMAND_MIRROR_VERIFY` and the `~/.claude/commands dir wired` parity row. | local-green (pending merge) | 2 |
| INV-8 | A temporary git worktree does not masquerade as a canonical workspace root: every linked worktree lives under `~/Documents/Worktrees/` or is explicitly allowlisted; none sits as a bare top-level sibling of the project roots in `~/Documents`. | The canonical home `~/Documents/Worktrees` + the `ALLOWLIST` in the checker; the linked-worktree test is a `.git` FILE vs DIR. | `scripts/ci/check-worktrees.py` (ADVISORY - warns, never fails; run by hand or during `sync`) | advisor-only | 1 |
| INV-9 | No bash `local`/`declare`/`typeset` statement references a variable assigned EARLIER in the SAME statement: under `set -u` the just-declared local is not yet visible while the rest of the statement's RHS is expanded, so the reference is UNBOUND and the script aborts. The dependent assignment is split onto its own `local` line. | One-assignment-per-dependent-`local` in every `*.sh`; the highest-stakes surface is `sync.sh` (runs under `set -uo pipefail`). | `scripts/ci/check-local-selfref.py` (static scan of tracked `*.sh`: pre-commit + CI) | CI-green | 1 |
| INV-10 | A fresh/headless CLIENT's `setup.sh`/`sync.sh` (incl. `--client`) wiring path runs to **exit 0** AND leaves a FUNCTIONAL client: no step aborts the whole run on an EXPECTED non-zero (a `mcp remove` of an unregistered server, a headless `pbcopy`/`open`, a failed-optional install), and the per-hub `${*_BEARER}` are exported for the shell the agent launches from while every role-aware hub is wired http+`${*_BEARER}` for EACH agent CLI (claude/codex/gemini) — never a literal token, never a leftover stdio entry on a client. | The guards in setup/sync + the shared manifest wiring fns: `\|\| true` on the mcp-remove loop, the `command -v`/`[ -t 0 ]` gates, `ensure_client_bearer_exports`, and `register_all_hub_mcp` http+`${*_BEARER}`. | `scripts/ci/check-fresh-client-setup.sh` (hermetic: throwaway `$HOME` + stub agent CLIs whose unregistered `mcp remove` returns rc1; runs the real shared wiring fns `setup.sh`/`sync.sh` call — `provision_all_client_tokens` + `register_all_hub_mcp` for claude/codex/gemini — under genuine errexit, pre- AND post-cutover, + a revert-test; CI. It exercises the wiring fns, not the whole setup.sh/sync.sh scripts.). ps1 is `PARITY_EXEMPT` (Linux-client gate). | local-green (pending CI) | 4 |
| INV-11 | RETIRED 2026-09-27 (ADR-0004): Forge was retired. What remains is its tombstone: no machine keeps a Claude or Codex registration of the deleted `forge-guard.sh`. | `RETIRED_HOOK_SCRIPTS` in `configure-claude-defaults.py` + `configure-codex-defaults.py`, run by all four setup/sync entrypoints. | `scripts/ci/check-workspace-access.py` retired-hook fixtures (pre-commit + CI) | retired | 2 |
| INV-12 | Auto-git only moves already-committed document history: it pulls clean-behind repos and pushes clean-ahead default-branch repos, while dirty/diverged/in-progress repos are skipped. It never stages, commits, stashes, calls Claude, uses autostash, aborts a rebase, or auto-resolves user work. Manual `sync` and auto-git are serialized by the same atomically published lock. | `auto-git.{sh,ps1}` per-repo policy + `scripts/git-sync-lock.{sh,ps1}` shared by manual sync and auto-git. | `scripts/ci/check-auto-git-safety.sh` on Ubuntu + `scripts/ci/check-auto-git-safety.ps1` on Windows (CI: forbidden-operation scan, Bash and PowerShell bare-repo fixtures for dirty/behind/ahead/diverged/in-progress/git-lock/status-fail/default-ref/remote-ref-race/lock/default-disabled trigger behavior, plus revert-test). | local-green (pending CI) | 1 |
| INV-13 | Completion email is strictly a per-session, per-turn opt-in across Claude, Codex, and Gemini: ordinary events never email or log payloads; only the native completion event may consume an arm; one acknowledged send disarms it; a failed send retains only the explicit request for retry; Notification/action-needed events never email; prompt, response, cwd, and session id never enter the email. Setup and routine sync converge the same behavior on macOS/Linux and Windows without overwriting unrelated hooks; because Codex exposes one notify command, an existing Codex Desktop callback is preserved as an argument-safe passthrough. | EA `agent-notify.py` state machine + dotfiles `configure-agent-integrations.py`, called through the shared manifest functions by all four setup/sync entrypoints. | `scripts/ci/check-agent-integrations.py` (hermetic migration/idempotence/fail-closed fixtures in pre-commit + CI; `--machine` live three-agent wiring + stubbed state transitions during sync) | local-green (pending merge) | 1 |
| INV-14 | A named Michael Workspace agent launcher never silently continues with the wrong access context: only the fixed trusted roots receive autonomous Claude/Codex modes; workspace cwd is child-scoped; missing, stale, denied, redirected, or read-only roots fail loudly; the parent recovers to HOME; and automatic reports distinguish child sandbox, TCC, cwd/File Provider, read-only mount, Unix permission, and Zsh history/prompt evidence without storing private content or raw paths. | `shell/ea.zsh` + `shell/windows/ea.ps1`, `configure-{claude,codex}-defaults.py`, and `workspace-access-diagnostics.py`; all four setup/sync entrypoints converge user defaults. | `scripts/ci/check-workspace-access.py` + `.ps1` (pre-commit + Linux/Windows CI: static wiring, config preservation/idempotence/fail-closed fixtures, real Zsh/PowerShell launcher behavior, diagnostic classifier/privacy probes, plus revert-test) | CI-green | 3 |
| INV-15 | Codex runs on the same global rules Claude reads: `~/.codex/AGENTS.md` is regenerated from every `global-rules/*.md` in EA's main working tree (the files `~/.claude/rules` points at) whenever EA commits, pulls or checks out, not only at the next sync; they stay read-only and are written by rename, never partially. An empty or unreadable source never replaces them. A differing copy whose body still matches the checksum in its generated header is stale and replaced; any other (hand-edited whatever its mode, or legacy) is saved under its own timestamped `.sync-backup-*` name, never over an earlier backup, and never replaced when that save fails. A retired target (`~/.gemini/GEMINI.md`, ADR-0004) is removed while it carries our header, saved first when hand-edited, and never touched otherwise. | `regen_combined_agent_rules` / `Regen-CombinedAgentRules` (manifest), called by setup/sync and by EA's `.githooks/post-commit`/`post-merge`/`post-checkout` through `scripts/regen-agent-rules.{sh,ps1}`. | `scripts/ci/check-combined-rules.sh` (pre-commit + CI) + `check-combined-rules.ps1` (Windows CI, pwsh + Windows PowerShell); EA `scripts/ci/check-agent-rules-hooks.sh` (EA CI: hooks tracked executable, calling the entrypoint); parity rows for the diff-guard, the entrypoint and the retired targets | local-green (pending CI) | 2 |
| INV-16 | Claude's resume-card hooks (EA `context-card.py`, EA ADR-0004 / EA INV-11) are registered on every managed machine exactly once per event (SessionStart `startup|resume|clear|compact`, PreCompact, PreToolUse `mcp__ccd_session_mgmt__clear_session` fail-closed, and PreToolUse `Edit|Write|NotebookEdit|Bash|PowerShell` role guard whose wrapper maps only its exit 3 to a block; on macOS/Linux also one Codex `[[hooks.SessionStart]]`, found by content because Codex drops our markers, skipped with a warning when the config holds an inline SessionStart array, and trusted once by Michael in Codex. Windows Codex stays unregistered until its hook shell is verified), all on one runner, in place, that runner being the unresolved `uv` path, which survives `brew upgrade` (never a `python3` from PATH, which the manifest's uv fallback makes a throwaway environment), with forward-slash double-quoted paths; the clear guard's command is wrapped so a missing runner/script or crash still exits 2 (fail closed); they are removed when the script is gone; unrelated hooks and event order are untouched, and a second run is byte-identical. | `_configure_claude_context` in `scripts/configure-agent-integrations.py`, the shared Bash/PowerShell chokepoint (INV-13), called by all four setup/sync entrypoints. | `scripts/ci/check-agent-integrations.py` (hermetic in-place/embedded/removal/malformed-event/idempotence/quoting/wrapper fixtures: pre-commit + CI; `--revert-test` in CI; `--machine` during sync: one hook per event, runner exists, and the live guard blocks a self-clear without `/wrap`) | CI-green (run 36773569647, 2026-09-30) | 0 |

<!-- Add a row when a rule recurs across surfaces. The SECOND recurrence is the trigger
     to promote it from prose to a gate, not the third. -->

## Detail

### INV-1 - no live secrets in the tracked tree
- **Surfaces**: whole repo; highest-risk `ssh/` (`setup.sh` generates `~/.ssh/id_ed25519`
  and copies the template to a real `~/.ssh/config` the user edits with private IPs).
- **Current state (verified 2026-06-17)**: HOLDS but UNGUARDED - the repo has NO
  `.gitignore` at all and no git hooks. `git ls-files` shows only `ssh/config.template`.
- **Detection signals**: a staged blob with a PEM/OpenSSH private-key header, a `.env`
  value, or high-entropy token; a staged path matching `id_ed25519`/`id_rsa`/`*.pem`/
  `*.key`; an `ssh/config` that is not the `.template`.
- **Reuse**: the secret regex already lives in `skills-scan.py:32` - the scanner reuses
  it rather than reinventing.
- **Escape hatch**: an allowlist of reviewed false-positive substrings.

### INV-2 - cross-platform parity
- **Surfaces**: `setup.sh`<->`setup.ps1`, `sync.sh`<->`sync.ps1`, `manifest.sh`<->
  `manifest.ps1`.
- **Recurrence history (verified 2026-06-17, recur=1, under adjudication)**: a literal
  token grep flagged three candidates; on inspection they are NOT all equal:
  - **stacked-push guard**: was GENUINELY absent on Windows (`setup.sh`/`sync.sh` wire
    `warn-stacked-git-push.sh` into `settings.json`; no `.ps1` equivalent). PORTED:
    `manifest.ps1` now symlinks `global-hooks -> ~/.claude/hooks` (the prerequisite, also
    previously missing) and `setup.ps1` wires the PreToolUse registration. NOTE: whether
    Claude Code on Windows executes a bash hook is a downstream Claude Code behavior to
    confirm; the wiring parity is enforced.
  - **trust_gemini_managed_repos**: a FALSE positive - the behavior exists on the `.ps1`
    side under different naming (`setup.ps1` / `sync.ps1` write `~/.gemini/
    trustedFolders.json`). Parity holds; the gate must key on behavior, not the literal
    function name.
  - **combined agent-rules**: the `.sh` side regenerates a single read-only combined file
    from ALL `global-rules/*.md`; the `.ps1` side previously symlinked ONLY
    `agent-skills.md`, so Windows Codex/Gemini got a SUBSET of the rules. PORTED:
    `setup.ps1` `Regen-CombinedAgentRules` now generates the full combined file (read-only)
    to `~/.codex/AGENTS.md` + `~/.gemini/GEMINI.md`, matching macOS.
- **Gate design**: `check-parity.py` keys on a human-curated feature registry (each
  feature names its `.sh` marker AND its `.ps1` marker, OR a `PARITY_EXEMPT` entry with a
  one-line reason). A naive grep would false-positive on the two above - precision first.
- **Escape hatch**: `PARITY_EXEMPT` with a one-line reason per genuinely OS-specific step
  (e.g. Windows OpenSSH `DefaultShell` registry, macOS `pbcopy`/`open`).

### INV-3 - retired (agent-skills upstream gate)
- Retired 2026-09-27 by ADR-0004. The fork is Michael's system now; nothing untrusted is merged
  automatically, so `gate_skill_diff`/`Test-SkillDiffGate`, `skills-scan.py`, the LLM advisory,
  `check-skill-gate-corpus.sh` and `/skills-review` were removed. Pulling upstream is a manual,
  reviewed act: `git -C ~/Documents/agent-skills fetch https://github.com/addyosmani/agent-skills.git`.

### INV-4 - no hub bearer is ever inlined into agent wiring
- **Generalized (remote-hubs Phase A)**: was courier-only; now covers EVERY managed hub (the gate
  reads the http-hub set from `hubs.json` and unions the managed stdio servers). courier is the
  only token-bearing hub today; calendar/nexus join when they are remoted (Phase C/D).
- **Surfaces**: `manifest.{sh,ps1}` (where `register_hub_mcp`/`Register-HubMcp` build the
  `Authorization: Bearer` header from an env-var reference), and `setup`/`sync` `{.sh,.ps1}`
  (which must never grow a literal-token wiring of their own).
- **Why it is not covered by INV-1**: the token legitimately lives OUTSIDE git in
  `~/.config/<hub>/auth-token`, so the secret-scan over the tracked tree never sees the
  risk. The risk here is a SCRIPT that bakes a literal token into argv (visible in the
  process table) or into a CLI's stored config - "not in git" is not "not leaked locally"
  (ADR-0002 cross-check review, finding #1).
- **Detection signal**: any `Authorization: Bearer <X>` line in the script set where `<X>`
  (after stripping a leading sh `\` or ps1 backtick escape) is NOT an env-var reference -
  `${<HUB>_BEARER}` or the manifest's generic `${$token_env}` indirection. A literal token is
  not `${...}`-shaped, so it is flagged. (PowerShell has no bash `${$var}` indirection, so the
  ps1 builds the header by single-quote concatenation; that one audited line carries
  `# hub-wiring-allow`.)
- **Gate design**: `check-hub-wiring.py` is a COVERAGE scan over the whole script set,
  so a literal token introduced on ANY surface is caught, not just the one known site.
- **Generated-config exposure (host-side complement)**: gemini may MATERIALIZE the
  `${<HUB>_BEARER}` reference into `~/.gemini/settings.json` at add-time on **WSL/Linux** (the
  real token value is in the env there, so it can land at-rest in plaintext; on macOS this box
  stores the ref - the behavior is platform-dependent). claude/codex store the reference. Two
  defenses: (1) `register_hub_mcp`/`Register-HubMcp` scrub known hub headers back to env refs
  and re-lock that file 0600 (sh `gemini_scrub_settings_bearer_refs` + `chmod 600`; ps1
  `Set-GeminiBearerRefs` + `icacls`) right after the gemini add; (2) `check-hub-wiring.py --host`
  (run during `sync` on both OSes) scans the generated configs (`~/.gemini/settings.json`,
  `~/.claude.json`, `~/.codex/config.toml`) for any literal bearer that still slipped through.
  Host-side only: those configs are machine-local, never in git, so this is NOT a CI gate (the
  CI scan covers the tracked script set; this covers the generated configs).
- **Recurrence (recur=1)**: caught in review before it ever shipped; promoted to a gate
  because it is security-critical and cross-cutting (2 OSes x 3 CLIs).
- **Escape hatch**: append `# hub-wiring-allow` to an audited line.
- **Sibling**: EA INV-7 enforces the SERVER side (loopback-only bind + mandatory-auth +
  fail-closed self-test); this is the CLIENT-wiring side.

### INV-5 - every hub is wired per-role only through the shared functions
- **Generalized (remote-hubs Phase A)**: the duplicated `register_global_mcp` (byte-identical in
  setup.sh + sync.sh, and `Register-GlobalMcp` in the ps1) was folded into the shared
  `register_hub_mcp`/`register_all_hub_mcp` in `manifest.{sh,ps1}`, so the per-role guard now
  covers all four managed hubs (nexus/courier/docgen/calendar), not just courier.
- **Surfaces**: `setup.{sh,ps1}`, `sync.{sh,ps1}` (must only CALL the shared fn);
  `manifest.{sh,ps1}` (the ONE allowed home for a hub `mcp add`).
- **Recurrence (recur=1)**: the blocking regression the ADR-0002 review caught - `sync`
  owned a SEPARATE copy of the MCP wiring that hardcoded courier as local stdio, which on a
  CLIENT silently clobbered the correct http-over-Tailscale entry with a broken stdio one
  pointing at a non-existent path. CI was green (parity only checked `setup`), so only the
  review caught it. The root fix hoisted the role logic into `manifest`; this gate stops the
  duplicate from coming back - for any hub now, not just courier.
- **Detection signal**: a line containing both `mcp add` and a managed hub name (the
  `hubs.json` http set ∪ the stdio servers nexus/docgen/calendar) in any setup/sync script
  (the remove-loop uses `mcp remove`, the shared call is `register_all_hub_mcp`, so a match
  means someone bypassed the function).
- **Gate design**: COVERAGE over the setup/sync set - a new script cannot silently add a
  direct hub wiring.
- **Escape hatch**: append `# hub-wiring-allow` to an audited line.

### INV-6 - generated affordances derive only from active roots
- **Surfaces**: `manifest.{sh,ps1}` (the active vs `ARCHIVED_*` lists), `sync.{sh,ps1}`
  (`clean_stale_skill_symlinks`/`Clean-StaleSkillSymlinks` called at the end of every
  `regen_agent_skills_links`/`Update-AgentSkillsLinks`), and the generated skill dirs
  `~/.codex/skills` + `~/.gemini/skills`.
- **Recurrence (recur=2)**: (1) IT-Worker was archived 2026-06-18 (skills moved to
  `.claude/skills.archived-2026-06-18`) but stayed in `REPOS`/`EA_REPOS`/`PROJECT_SKILLS`,
  so sync kept regenerating 16 dangling `it-worker-*` links in codex + gemini. Root fix:
  move it to `ARCHIVED_REPOS`/`ARCHIVED_PROJECT_SKILLS` (Phase 1) and prune dangling links
  on regen (Phase 2). (2) 2026-06-18: 9 EA project skills authored in
  `~/Documents/EA/.claude/skills` were never linked into `~/.codex/skills` because no `sync`
  ran after authoring them, so codex silently exposed 9 fewer skills than gemini. The
  dangling-only `--machine` check was BLIND to it (the links were ABSENT, not broken). Root
  fix: a COMPLETENESS assertion (every source skill HAS its link in each target) + a
  COLLISION assertion, both BLOCKING, run post-regen.
- **Gate design**: `check-skill-targets.py` has two scopes. MANIFEST mode (pre-commit + CI,
  repo-deterministic) fails if an archived target/label leaks into an active list - the
  guard against the root cause. `--machine` mode (run during `sync`, where the generated
  dirs exist) makes THREE assertions and is BLOCKING (sync exits non-zero on both OSes): no
  DANGLING link (residue), COMPLETENESS (every active source skill has its link in each
  intended target - catches the added-but-unlinked drift the dangling scan missed), and no
  name COLLISION (two sources shadowing one name). It mirrors `regen_agent_skills_links`
  exactly (vendor+global -> all 3 agents un-namespaced; project skills -> codex/gemini
  namespaced, NEVER claude, which reads repo `.claude/skills` natively) and runs AFTER regen,
  so a violation is a real fault, not a mid-sync race. Guarded: an absent target dir (fresh
  machine) is skipped, never a false-fail. CI cannot run `--machine` (dirs absent on the
  runner), so it never false-fails CI; the dev machine + sync own that scope.
- **Why pruning is safe**: it only removes a path that is BOTH a symlink AND unresolved
  (`-L` + `! -e`). A real directory (a materialized gemini project skill carrying
  `.dotfiles-skill-source`, or a user-authored skill) fails `-L` and is never touched.
- **Escape hatch**: none needed - a dangling generated link is always dead; a real dir is
  never a candidate.

### INV-7 - shared slash commands are available in all agents
- **Surfaces**: `~/Documents/EA/claude-config/global-commands/*.md`, repo/project command
  sources in `COMMAND_SOURCES` / `$CommandSources`, `~/.claude/commands`,
  `~/.codex/prompts`, and `~/.gemini/commands`.
- **Recurrence (recur=2)**: (1) cross-agent command mirrors existed for Codex/Gemini, but
  generated dirs lacked an invocation index, so commands were technically present but hard to
  discover. Root fix: `gen-agent-commands.py` writes a `README.md` index. (2) Forge existed as a
  global skill but not as a shared command, and `~/.claude/commands` was not wired from the
  command source dir. Root fix: add `global-commands -> ~/.claude/commands`, add `/forge` as a
  source command, and keep Codex/Gemini mirrors generated from the same source.
- **Gate design**: `gen-agent-commands.py --verify` checks every source command has the Codex
  and Gemini generated output after sync. `check-parity.py` now also checks that the Claude
  source command directory is wired on both OSes, so Claude does not lag behind its generated
  peers.
- **Escape hatch**: none. If a command should not be global, keep it out of
  `global-commands` or namespace it through project command sources.

### INV-11 - retired (Forge)
- Retired 2026-09-27 by ADR-0004: Forge went unused (last Claude use 2026-07-06, last Codex
  use 2026-08-24) and `forge-guard.sh` never blocked or warned. The skill, command, hook,
  `check-state.py`, `check-forge-wiring.py`, the PR-template section and the `Agent-Forge`
  directory ensure are gone; existing `~/Documents/Agent-Forge` content stays on disk.
- **What still holds**: every machine that syncs drops a leftover registration of the deleted
  hook (Claude `settings.json` and Codex `config.toml`, with Codex's positional trust keys
  renumbered), so no agent is left calling a missing script. Enforced by the retired-hook
  fixtures in `check-workspace-access.py`.

### INV-12 - auto-git never creates commits or touches dirty work
- **Surfaces**: `auto-git.sh`, `auto-git.ps1`, `scripts/git-sync-lock.sh`,
  `scripts/git-sync-lock.ps1`, `sync.sh`, `sync.ps1`, and the per-OS trigger bootstraps.
- **What is guarded**: auto-git only runs on clean repos, fetches the configured upstream, moves
  clean-behind repos with a pinned `merge --ff-only <fetched-upstream-rev>` only when that fetched
  OID is still the remote ref, pushes the classified local commit only when the branch is still the
  remote default branch and the remote ref still equals the fetched OID, and uses an
  expected-old-OID push lease. It skips dirty, ignored-collision, diverged, detached,
  missing-upstream, unreadable, or in-progress-operation repos. It never stages, commits, stashes,
  resets, cleans, checks out/restores paths, calls Claude, uses autostash, or aborts a rebase. The
  manual sync and timer path take one shared lock.
- **Gate design**: `check-auto-git-safety.sh` and `check-auto-git-safety.ps1` scan the real
  auto-git entrypoints for forbidden operative commands and run throwaway local bare-repo fixtures
  for dirty skip, hidden untracked skip, ignored file/directory/parent collision skip, behind
  fast-forward, ahead push, branch/default-ref/remote-ref race skips, non-origin upstream,
  divergence skip, in-progress marker skip, lock contention, partial-owner lock behavior, disabled
  trigger artifacts, reversible cron fallback, and "no unexpected commit" behavior. Their
  revert-tests prove planted forbidden operations and enabled-by-default triggers are caught,
  including PowerShell-specific invocation forms.
- **Escape hatch**: none for auto-git. A dirty repo belongs to the human/manual path, not the timer.

### INV-15 - combined agent rules stay current and never lose a differing copy
- **Surfaces**: `manifest.{sh,ps1}` (the regen + diff-guard), `scripts/regen-agent-rules.{sh,ps1}`
  (standalone entrypoints), EA `.githooks/post-commit` + `post-merge` + `post-checkout` (the
  between-sync trigger, all via `.githooks/refresh-agent-rules`), and the generated
  `~/.codex/AGENTS.md` + `~/.gemini/GEMINI.md`. Decision record: `docs/decisions/0003`.
- **Recurrence (recur=2, both found 2026-09-10)**: (1) STALENESS - regen ran only in setup/sync, so
  the 2026-08-24 rules merge (the commit-authority and clarify-the-plan rules) never reached Codex or
  Gemini for 17 days. (2) SILENT BACKUP FAILURE - `cp -p` copied the 0444 mode onto the single
  `.sync-backup` slot, so every later backup failed under `2>/dev/null || true` while the warning
  still claimed "backed up": both backups were frozen at 2026-07-14.
- **Stale vs edited is decided by content, not mode**: the generated header carries a checksum of
  the body (`body-cksum:` from `cksum` in bash, `body-sha256:` in ps1). A target whose body still
  matches is untouched generated output, merely stale: EA history rebuilds it, so it gets no backup,
  which keeps frequent hook regens from cycling backups. Anything else gets
  `<target>.sync-backup-<timestamp>-<pid>`, unique per run, so no later hand-edit, stale regen or
  concurrent run can overwrite it. Mode could not decide this: `sed -i`, `perl -pi` and an editor's
  forced write all keep 0444 (a first-draft mode-bit rule would have destroyed those edits
  silently). A header without a checksum (files from before this change) counts as edited, so the
  first regen after it lands takes one backup of each target. The legacy `.sync-backup` files are
  left alone.
- **Gate design**: `check-combined-rules.sh` drives the real entrypoint in a throwaway `$HOME`:
  fresh generate, quiet idempotence, stale copy (written by rename, no backup, no warning), two
  hand-edits then a stale regen (both backups survive), an edit that kept 0444, a legacy header,
  empty source and unreadable rule file (target untouched), and a target that cannot be backed up
  but could be written (untouched: only the fail-closed branch saves it). Mutations caught: dropping
  that `continue`, an in-place write, mode bits instead of content, and removing either source guard.
  The ps1 half repoints `$GlobalRulesDir`/`$CombinedRulesTargets` after dot-sourcing (`$HOME` is
  read-only in PowerShell), adds a case-only change (`-ceq`, matching `cmp`), and uses an `icacls`
  read-data deny for the unreadable cases. EA's `check-agent-rules-hooks.sh` guards the trigger: each hook
  tracked 100755 and handing off to the entrypoint, verified against a stub.
- **Hook triggers (verified on git 2.50)**: `post-commit` fires on commit, amend, and each replayed
  commit of a rebase; `post-merge` on `pull --ff-only`, auto-git's `merge --ff-only`, and a
  `pull --rebase` with no local commits; `post-checkout` on switch, a fetch-then-rebase that
  fast-forwards, and `checkout -- <file>`. `git reset --hard` fires no hook and waits for the next
  sync.
- **Known limits**: Windows PowerShell 5.1 has no one-step replace, so its `Move-Item` deletes then
  moves (pwsh 7 uses `File.Move(..., overwrite)`). On Windows each hook starts PowerShell (roughly 0.5-1s per commit, and per
  replayed commit in a rebase); only the bash hook path is exercised in CI, the Windows chain
  (git-bash, `cygpath`, `pwsh -File`) is not. A hook fired from a worktree regenerates from the
  main working tree, uncommitted edits included, which is what Claude already reads live.
- **Escape hatch**: none for the diff-guard. The hooks fail open (no dotfiles checkout or a regen
  error never blocks git; a missing entrypoint prints one line); the next sync regenerates.

### INV-16 - resume-card hooks are registered once, in place, and fail closed

EA owns the hook (`claude-config/global-hooks/context-card.py`) and its behaviour (EA INV-11,
ADR-0004: resume cards, card-aware compaction, the `/wrap`-only clear guard). Dotfiles owns
only the machine-local registration, through the same configurator as the completion email
(INV-13), so macOS and Windows cannot diverge and no manifest change was needed: the script
is found beside `--hook` in EA `global-hooks`.

- **Why the runner is not resolved:** `shutil.which("uv")` resolved to the Cellar path
  (`/opt/homebrew/Cellar/uv/<version>/bin/uv`), which a `brew upgrade uv` deletes; every
  registered hook would then fail until the next sync. The unresolved `/opt/homebrew/bin/uv`
  survives upgrades. This also changed the completion-email Stop hook's runner path.
- **Why the guard is wrapped:** Claude Code treats a hook that cannot run as a non-blocking
  error, so an unwrapped guard would fail open. The wrapper turns any exit other than 0 into 2.
- **Event order:** removing and re-adding the managed Stop hook used to move `Stop` to the end,
  so a second run rewrote `settings.json` once other events followed it. `_keep_order` fixes it.
- **Limit:** the guard matches the Desktop tool name; an app rename unguards it silently
  (EA INV-11). Re-run the live guard test after major Desktop updates.

### INV-9 - no `local` references a same-statement variable (set -u footgun)
- **Surfaces**: every tracked `*.sh`; highest-risk is `sync.sh` (runs under `set -uo pipefail`
  and does the skill-link generation).
- **Recurrence (recur=1)**: 2026-06-18, `sync.sh` `materialize_gemini_project_skill` declared
  `local src="$1" dst="$2" namespaced="$3" marker="$dst/.dotfiles-skill-source"`. On this
  machine's bash the RHS of `marker` is expanded BEFORE the same-statement `dst` local is
  visible, so under `set -u` `$dst` is UNBOUND - the function aborted at its first line, which
  aborted `regen_agent_skills_links` and EVERYTHING after it in `sync` (exit 1), and silently
  stopped gemini project skills from refreshing. `bash -n` (syntax only) and an isolation
  harness (no `set -u`) both missed it; only running the real `sync` surfaced it. Root fix:
  split `marker` onto its own `local` line.
- **Gate design**: `check-local-selfref.py` statically scans every tracked `*.sh`. For each
  `local`/`declare`/`typeset` statement it collects the assignment targets in order and flags
  any later value that references an earlier same-statement target. It is quote-aware (a value
  may contain spaces or `=`), splits on top-level `;`, and does NOT flag an OUTER-scope
  self-reference like `local PATH="$PATH:/x"` (a name counts as assigned only AFTER its own
  value is checked). Needs no machine state, so unlike the `--machine` skill check it is a real
  green-in-CI + pre-commit enforcer.
- **Escape hatch**: none needed - the dependent assignment always belongs on its own `local`
  line; there is no legitimate same-statement back-reference under `set -u`.

### INV-10 - a fresh/headless client setup is abort-free + leaves a functional client
- **Surfaces**: `setup.sh`/`sync.sh` (the `--client` path) + the shared `manifest.sh` wiring fns
  (`register_all_hub_mcp`, `provision_all_client_tokens`, `ensure_client_bearer_exports`). Only the
  bash side (Linux/WSL clients); Windows is `PARITY_EXEMPT` (a clean-Windows run is not cheaply CI-able).
- **Recurrence (recur=4)**: this class bit SILENTLY 4-5x across remote-hubs A-C, each a `set -e` abort
  or a non-functional client, none with a mechanical enforcer: (1) the `mcp remove` loop aborting a
  fresh client before any hub was wired (rc1 on an unregistered server - commit 0dbbaf1-era); (2) a
  headless `pbcopy`/`open` aborting under `set -e`; (3) an OpenSSH/npm optional install aborting the
  run; (4) the per-hub `${*_BEARER}` sitting on disk but never exported for a bash-launched (WSL)
  client, so every hub stayed 401 (commit 9eae2fc). Each passed `bash -n` + looked fine in review; only
  a real fresh-client run surfaced them.
- **Gate design**: `check-fresh-client-setup.sh` is HERMETIC - a throwaway `$HOME` + a stub-CLI dir on
  `PATH` whose `claude`/`codex`/`gemini` model the REAL exit codes (an unregistered `mcp remove`
  returns rc1, the actual abort trigger; `mcp add` records its argv). It runs the real manifest wiring
  fns exactly as setup/sync do (under `set -euo pipefail`, non-TTY stdin) and asserts: exit 0; the
  `~/.bashrc` bearer-export block with every `${*_BEARER}`; courier/calendar wired http with the
  `${*_BEARER}` REF (never a literal token); and nexus stdio (pre-cutover) / http (post-cutover, the
  `NEXUS_REMOTED` flip). A `--revert-test` mode proves the guard is load-bearing: the UNGUARDED remove
  loop aborts under `set -e`, the guarded `register_all_hub_mcp` does not.
- **Escape hatch**: none (true invariant). A genuinely OS-specific abort site is `command -v`/`[ -t 0 ]`
  guarded at the source, not exempted from the gate.

### INV-13 - completion email is explicit, session-scoped, and payload-private
- **Surfaces**: EA's global `agent-notify.py` implementation; Claude `Stop`, Codex
  `agent-turn-complete`, and Gemini `AfterTool(run_shell_command)` + `AfterAgent`; all four
  dotfiles setup/sync entrypoints; Codex's live duplicate-skill suppression.
- **Delivery semantics**: an arm atomically becomes durable pending work. A confirmed local
  Himalaya or Courier result deletes it. Failure retains it for the same explicitly armed
  session's next completion. This is intentionally at-least-once: an ambiguous network timeout
  can theoretically duplicate a mail, while deleting before acknowledgement would silently lose
  the notification Michael explicitly requested.
- **Privacy boundary**: the email path uses hook payloads only to select agent, event, and a
  hashed session key. Prompt, response, cwd, raw session id, and tool content never enter email
  or logs. An unarmed completion does not read mail config, write a log, or contact the email
  transport. If Codex Desktop already owned the single native notify slot, the configurator
  preserves it as an argument-safe passthrough that receives the unchanged payload it received
  before migration.
- **Gate design**: `check-agent-integrations.py` runs a hermetic migration fixture that proves
  unrelated hooks survive, legacy Notification email is removed, malformed input writes nothing,
  duplicate skill paths are exact `SKILL.md` entries, and a second run is byte-identical. Its
  `--machine` mode checks live three-agent configs and executes arm, consume-on-success,
  retain-on-failure, retry, Gemini arm handoff, and unarmed no-op with a stub sender.
- **Escape hatch**: a pre-existing non-dotfiles Codex `notify` program is left untouched and the
  configurator fails closed. A human must decide how to compose the two programs.

### INV-14 - trusted workspace launches are cwd-safe, explicit, and diagnosable
- **Surfaces**: the Zsh and PowerShell `ea`/`wiki`/`sysupdate` launchers; Claude and Codex
  user defaults converged by all four setup/sync entrypoints; macOS responsible-process TCC for
  Terminal, Ghostty, Claude CLI/Desktop, and Codex CLI/Desktop; Zsh prompt and history behavior.
- **Recurrence (recur=3)**: historical Claude `Operation not permitted` denials preceded its
  refreshed Full Disk Access grant; a Codex task persisted with an inherited read-only sandbox
  despite autonomous user config; and the ordinary interactive shell has separately lost cwd/file
  access after child agents exited until the terminal process was restarted.
- **Privacy boundary**: reports contain only known bundle identifiers, permission values, coarse
  process labels, errno names, mount flags, fixed root labels, and a truncated path hash. Raw paths,
  unified-log lines, environment values, history, commands, prompts, responses, and transcripts are
  never stored. On POSIX the state directory is mode 0700 and reports are mode 0600; Windows inherits
  the user-profile ACL. `latest.json` is published atomically, and retention is bounded.
- **Gate design**: `check-workspace-access.py` and its PowerShell companion launch the real Zsh and
  PowerShell functions with stub agent CLIs and assert child cwd, parent restoration, exact
  permission flags, exit-code preservation, fail-loud missing/untrusted/redirected roots and scope
  overrides, and HOME recovery when a launch or caller root disappears. They also exercise the real
  settings writers and diagnostic self-test, check cross-platform/config/docs/hook/CI wiring, and
  prove a weakened Codex launch is rejected in `--revert-test` mode.
- **Escape hatch**: use a raw agent CLI when intentionally selecting a non-autonomous policy or an
  unnamed root. Desktop host envelopes remain outside a child CLI's authority; diagnose and
  escalate them without editing opaque task history or signed application bundles.
