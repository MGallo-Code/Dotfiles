# 0003 - EA git hooks regenerate the Codex/Gemini rule files

- Status: accepted
- Date: 2026-09-10
- Surfaces: EA `.githooks/`, dotfiles `manifest.{sh,ps1}` and `scripts/regen-agent-rules.{sh,ps1}`,
  generated `~/.codex/AGENTS.md` + `~/.gemini/GEMINI.md`

## Context

Claude reads EA's `global-rules/` directory live through the `~/.claude/rules` symlink. Codex
and Gemini load one file each, which dotfiles generates by concatenating that directory, but
only during `setup` or `sync`. Rules merged into EA on 2026-08-24 did not reach Codex or Gemini
until a manual regen on 2026-09-10, so for 17 days the three agents ran on different rules.

Rule changes land through EA git operations: a commit, a pull on this machine, or auto-git's
fast-forward of a change made on another machine.

## Decision

EA's `post-commit`, `post-merge` and `post-checkout` hooks call
`~/.dotfiles/scripts/regen-agent-rules.{sh,ps1} --quiet`, which runs the same manifest function
setup and sync call. The hook prints nothing unless a file changed, exits 0 on any failure,
and exits silently when there is no dotfiles checkout.

EA now depends on dotfiles at a fixed path, a new direction (dotfiles already reads EA). It is
the smallest one: EA owns only the trigger. The generator stays in dotfiles, and there is no
second generator to drift from it.

## Alternatives

- **A dotfiles check that fails when the files are stale.** It detects drift, but sync
  already fixes it on the next run. The problem was the gap between syncs, which this
  leaves open.
- **Symlinks instead of generated files.** A file cannot symlink to a directory. Codex and
  Gemini each need one file.
- **An EA-side generator.** That makes two generators that can drift. Rejected.

## Consequences

- Hooks fire in every EA lane. A quiet no-op costs about 50ms on macOS. On Windows, each run
  starts PowerShell, roughly 0.5-1s, and a rebase pays it once per replayed commit.
- Because hooks now run the regen often and concurrently, the diff-guard had to be hardened
  (INV-15). Writes go through a staged file and a rename. The header carries a checksum of
  the body, so an untouched stale copy is replaced without a backup, and any edited copy gets
  its own backup whatever its mode. An empty source never replaces the files.
- `git reset --hard` fires no hook, so it waits for the next sync.
- Guarded by dotfiles `check-combined-rules.{sh,ps1}` and EA `check-agent-rules-hooks.sh`.
