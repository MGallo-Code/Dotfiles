# Workspace Map

Michael's setup is one ecosystem ("Michael Workspace") spread across a few roots. Before
guessing or searching for where something lives, consult the authoritative pointers here.

## Authoritative maps (read these; don't reconstruct them from memory)

- **Roots + their roles:** `~/.dotfiles/manifest.sh` — the role taxonomy at the top is the
  single, always-current list of every managed root and its role (active-repo, archive-repo,
  external-managed, generated-target, artifact-dir).
- **Ops / personal / SBIC orientation:** `~/Documents/EA/CLAUDE.md` — the executive-assistant
  hub; it points to `profile/`, SBIC (`~/Documents/SBIC/`), business, Nexus, and the Wiki. Start
  there for assistant/ops work.

## Roots at a glance (authoritative list: `manifest.sh`)

- `~/.dotfiles` — transport/control plane, and the agent setup itself: `claude-config/` holds the
  global rules (this file is one of them), commands, hooks, agents and skills. Change the SYSTEM
  here (`sysupdate` launches an agent scoped to it).
- `~/Documents/EA` — active personal ops (profile, business, meetings, context, personal docs).
- `~/Documents/GalloGrid` — the code (private repo): the EA hub (`ea-hub/`) and its servers, nexus, courier, calendar, docgen and the agent. Split out of EA 2026-10-01.
- `~/Documents/Wiki` — LLM-curated research (`Wiki/index.md`).
- `~/Documents/Notes` — Michael's first-person notes (read-only to the LLM by default).
- `~/Documents/SBIC` — employer-only work; its own `CLAUDE.md`, `docs/` is the canonical wiki + evidence.
- `~/Documents/Customer-Work` — bulky michaelgit client artifacts.
- `~/Documents/agent-skills` — the forked coding-skills kit.

If a root you need isn't listed, or a pointer looks stale, read `~/.dotfiles/manifest.sh` (the
source of truth) and flag the gap so this map gets fixed.
