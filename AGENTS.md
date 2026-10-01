# CLAUDE.md - Dotfiles

Cross-platform dev environment setup (macOS/Linux + Windows). One repo, one command.
Always-loaded context; keep it SHORT. Point at the registries, do not inline them.

`AGENTS.md` is a byte-identical copy of this file (the cross-tool standard Codex/Gemini
read). A pre-commit `cmp -s AGENTS.md CLAUDE.md` keeps them identical - a copy, not a
symlink, because this repo targets Windows where git symlinks degrade to text files.

## Invariants (read before writing)

Cross-cutting invariants and their enforcers live in [`INVARIANTS.md`](./INVARIANTS.md).
Before changing a script, check which invariants its surface is subject to.
Definition-of-Done: [`DEFINITION_OF_DONE.md`](./DEFINITION_OF_DONE.md).

## Repo at a glance

- Stack: Bash (`setup.sh`/`sync.sh`/`manifest.sh`), PowerShell (`setup.ps1`/`sync.ps1`/
  `manifest.ps1`), and Python (config convergers and CI checks under `scripts/`).
- Run: `bash setup.sh [--full|--dev|--minimal]` (mac/linux) or `.\setup.ps1` (Windows);
  `sync` pulls/pushes managed repos (including the agent-skills fork) and regenerates agent wiring.
- Where it lives: paired `*.sh`/`*.ps1` scripts at the root; `shell/` (commands),
  `ssh/` (config template), `packages/` (Homebrew), and `claude-config/` (the global agent
  rules, hooks, commands, agents and skills; moved from EA by ADR-0006). Manages EA, Wiki,
  NVIM-Setup, the agent wiring, and SSH config.

## Conventions that matter

- Cross-platform PARITY (INV-2): every behavior the `*.sh` scripts perform on a managed
  machine the `*.ps1` scripts also perform, except genuinely OS-specific steps marked in
  the parity gate's exempt list. The mac and windows sides must not silently drift.
- No live secrets in the tree (INV-1): the committed SSH config is always the
  `*.template`; private keys / `.env` / tokens never become tracked content.
- Retired surfaces stay retired (ADR-0004: Forge, SBIC dev wiring, interactive Gemini,
  upstream skill sync): their tombstone lists in the manifests clean every machine on sync.
- Idempotency: `setup`/`sync` are safe to re-run; a second run is a no-op, not a double.

## Decisions

Architecture bets get a one-page record in `docs/decisions/` before they land.
