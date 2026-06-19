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
| INV-3 | The agent-skills sync security gate stays load-bearing and identical across platforms: an untrusted upstream diff auto-merges only when text-only + in-scope + clean (no net/exec/secret/prompt-injection/hidden-unicode) AND the LLM advisory clears it; any deterministic failure forces human review regardless of the LLM verdict (fails closed); bash and powershell enforce the SAME policy. | `gate_skill_diff()` (sync.sh) + `Test-SkillDiffGate` (sync.ps1), both delegating to `skills-scan.py`. | a malicious-corpus regression test across sh + ps1 + py (to build) | advisor-only | 0 |
| INV-4 | The courier bearer token is never inlined into agent MCP wiring: the only token reference in a courier `mcp add` is the `${COURIER_BEARER}` env var (claude/gemini `--header`/`-H`) or `--bearer-token-env-var COURIER_BEARER` (codex); a literal token never reaches argv or a CLI's stored config. Distinct from INV-1 (the token lives OUTSIDE git, in `~/.config/courier/auth-token`, so the secret-scan never sees it). | The single `Authorization: Bearer` reference inside `register_courier_mcp`/`Register-CourierMcp` (manifest), which only ever names the env var. | `scripts/ci/check-courier-wiring.py` COVERAGE (pre-commit + CI) | CI-green | 1 |
| INV-5 | Courier is wired per-ROLE only through the shared function: the host-vs-client decision AND every courier `mcp add` live once in `manifest.{sh,ps1}` (`register_courier_mcp`/`Register-CourierMcp`); no `setup`/`sync` script wires courier directly. | `register_courier_mcp`/`Register-CourierMcp` in manifest; setup/sync only CALL it. | `scripts/ci/check-courier-wiring.py` COVERAGE (pre-commit + CI) | CI-green | 1 |
| INV-6 | Generated agent affordances derive only from ACTIVE roots AND match their sources exactly: an archived root (`ARCHIVED_REPOS` / `ARCHIVED_PROJECT_SKILLS`) never appears in an active list; after a regen every active source skill HAS its generated link in each intended target (no missing link), no generated link dangles, and no two sources collide on a name in one target. User-authored real skill dirs are never touched. | The manifest active/archived split + `regen_agent_skills_links` (link + `clean_stale_skill_symlinks` prune on every regen) + the post-regen `--machine` assertion. | `scripts/ci/check-skill-targets.py` (manifest mode: pre-commit + CI; `--machine` completeness/dangling/collision during `sync`, BLOCKING on both OSes) | local-green (pending merge) | 2 |
| INV-7 | Every Claude command source has a generated Codex prompt AND Gemini command, and each generated dir carries an invocation index, so the same commands are usable (and discoverable) in all three agents. | `gen-agent-commands.py` (one shared generator, called by both sync scripts) emits the mirror + a `README.md` index. | `gen-agent-commands.py --verify` run during `sync` on both OSes (a missing mirror fails the check); parity-gated by the `COMMAND_MIRROR_VERIFY` marker. | local-green (pending merge) | 1 |
| INV-8 | A temporary git worktree does not masquerade as a canonical workspace root: every linked worktree lives under `~/Documents/Worktrees/` or is explicitly allowlisted; none sits as a bare top-level sibling of the project roots in `~/Documents`. | The canonical home `~/Documents/Worktrees` + the `ALLOWLIST` in the checker; the linked-worktree test is a `.git` FILE vs DIR. | `scripts/ci/check-worktrees.py` (ADVISORY - warns, never fails; run by hand or during `sync`) | advisor-only | 1 |
| INV-9 | No bash `local`/`declare`/`typeset` statement references a variable assigned EARLIER in the SAME statement: under `set -u` the just-declared local is not yet visible while the rest of the statement's RHS is expanded, so the reference is UNBOUND and the script aborts. The dependent assignment is split onto its own `local` line. | One-assignment-per-dependent-`local` in every `*.sh`; the highest-stakes surface is `sync.sh` (runs under `set -uo pipefail`). | `scripts/ci/check-local-selfref.py` (static scan of tracked `*.sh`: pre-commit + CI) | local-green (pending merge) | 1 |

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

### INV-3 - the agent-skills sync gate stays load-bearing
- **Surfaces**: `sync.sh` `gate_skill_diff()`, `sync.ps1` `Test-SkillDiffGate`,
  `skills-scan.py`.
- **What is unguarded**: regression (nothing re-tests that a known-bad diff is still
  rejected) and divergence (the two reimplementations can drift; `sync.ps1` already adds
  a "python not found -> fail closed" branch the bash side lacks - itself a parity gap).
- **Gate design**: a fixed corpus of crafted diffs (a curl payload, an added `100755`
  mode bit, a binary blob, a >400-insertion diff, a bidi-unicode line, an out-of-scope
  path, plus a known-good markdown-only diff) fed through BOTH `gate_skill_diff` and
  `Test-SkillDiffGate`; assert identical verdicts and that every malicious sample is
  flagged. Fail closed if either passes a malicious sample or the two disagree.
- **Escape hatch**: none (true invariant) - this gate protects auto-merge of untrusted
  upstream code.

### INV-4 - the courier bearer is never inlined into agent wiring
- **Surfaces**: `manifest.{sh,ps1}` (where `register_courier_mcp`/`Register-CourierMcp`
  reference `${COURIER_BEARER}`), and `setup`/`sync` `{.sh,.ps1}` (which must never grow a
  literal-token wiring of their own).
- **Why it is not covered by INV-1**: the token legitimately lives OUTSIDE git in
  `~/.config/courier/auth-token`, so the secret-scan over the tracked tree never sees the
  risk. The risk here is a SCRIPT that bakes a literal token into argv (visible in the
  process table) or into a CLI's stored config - "not in git" is not "not leaked locally"
  (ADR-0002 cross-check review, finding #1).
- **Detection signal**: any `Authorization: Bearer <X>` line in the script set where `<X>`
  (after stripping a leading sh `\` or ps1 backtick escape) is not exactly `${COURIER_BEARER}`.
  Precise: the only `Bearer` lines in these files ARE the courier wiring.
- **Gate design**: `check-courier-wiring.py` is a COVERAGE scan over the whole script set,
  so a literal token introduced on ANY surface is caught, not just the one known site.
- **Recurrence (recur=1)**: caught in review before it ever shipped; promoted to a gate
  because it is security-critical and cross-cutting (2 OSes x 3 CLIs).
- **Escape hatch**: append `# courier-wiring-allow` to an audited line.
- **Sibling**: EA INV-7 enforces the SERVER side (loopback-only bind + mandatory-auth +
  fail-closed self-test); this is the CLIENT-wiring side.

### INV-5 - courier is wired per-role only through the shared function
- **Surfaces**: `setup.{sh,ps1}`, `sync.{sh,ps1}` (must only CALL the shared fn);
  `manifest.{sh,ps1}` (the ONE allowed home for a courier `mcp add`).
- **Recurrence (recur=1)**: the blocking regression the ADR-0002 review caught - `sync`
  owned a SEPARATE copy of the MCP wiring that hardcoded courier as local stdio, which on a
  CLIENT silently clobbered the correct http-over-Tailscale entry with a broken stdio one
  pointing at a non-existent path. CI was green (parity only checked `setup`), so only the
  review caught it. The root fix hoisted the role logic into `manifest`; this gate stops the
  duplicate from coming back.
- **Detection signal**: a line containing both `mcp add` and `courier` in any setup/sync
  script (the remove-loop uses `mcp remove`, the shared call is `register_courier_mcp`, so a
  match means someone bypassed the function).
- **Gate design**: COVERAGE over the setup/sync set - a new script cannot silently add a
  direct courier wiring.
- **Escape hatch**: append `# courier-wiring-allow` to an audited line.

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
