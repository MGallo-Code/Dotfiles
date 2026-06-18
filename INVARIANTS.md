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
| INV-1 | No live credential ever enters the tracked tree: private keys, real `~/.ssh/config` (with LAN/Tailscale IPs), `.env`, tokens. The committed SSH config is always the `*.template`, never the populated copy. | The git index at commit time + a content scanner over staged blobs; a committed `.gitignore`. | `scripts/ci/check-no-secrets.py` (pre-commit + CI) | local-green (pending merge) | 0 |
| INV-2 | Every behavior the mac/linux `setup`/`sync`/`manifest` scripts perform is also performed by the Windows scripts (and vice-versa); a machine ends up configured the same way whichever OS ran setup, except genuinely OS-specific steps on the exempt list. | The paired `*.sh`/`*.ps1` files + a declared feature-token registry. | `scripts/ci/check-parity.py` (pre-commit + CI) | local-green (pending merge) | 3 |
| INV-3 | The agent-skills sync security gate stays load-bearing and identical across platforms: an untrusted upstream diff auto-merges only when text-only + in-scope + clean (no net/exec/secret/prompt-injection/hidden-unicode) AND the LLM advisory clears it; any deterministic failure forces human review regardless of the LLM verdict (fails closed); bash and powershell enforce the SAME policy. | `gate_skill_diff()` (sync.sh) + `Test-SkillDiffGate` (sync.ps1), both delegating to `skills-scan.py`. | a malicious-corpus regression test across sh + ps1 + py (to build) | advisor-only | 0 |

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
