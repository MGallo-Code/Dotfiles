# Workspace Map

Michael's setup is one ecosystem ("Michael Workspace") spread across a few roots. Before
guessing or searching for where something lives, consult the authoritative pointers here.

## Authoritative maps (read these; don't reconstruct them from memory)

- **Roots + their roles:** `~/.dotfiles/manifest.sh` — the role taxonomy at the top is the
  single, always-current list of every managed root and its role (active-repo, archive-repo,
  external-managed, generated-target, artifact-dir).
- **Ops / personal orientation:** `~/Workspace/EA/CLAUDE.md` — the executive-assistant hub; it
  points to `profile/`, business, Nexus, and the Wiki. Start there for assistant/ops work.

## Roots at a glance (authoritative list: `manifest.sh`; layout: dotfiles ADR-0007)

- `~/.dotfiles` — transport/control plane, and the agent setup itself: `claude-config/` holds the
  global rules (this file is one of them), commands, hooks, agents and skills; `agent-skills/` is
  the forked coding-skills kit; `tools/docgen/` is the DOCX/PDF tool every machine runs. Change
  the SYSTEM here (`sysupdate` launches an agent scoped to it).
- `~/Workspace/EA` — active personal ops (profile, business, meetings, context, personal docs).
- `~/Workspace/Wiki` — LLM-curated research (`Wiki/index.md`).
- `~/Workspace/Notes` — Michael's first-person notes (read-only to the LLM by default).
- `~/Workspace/GalloGrid` — on the Mac mini only: the hub code (private repo), the EA hub
  (`ea-hub/`) and its servers, nexus, courier, calendar and the agent. Other machines reach those
  servers over Tailscale.
- `~/Projects` — Michael's own software projects (not synced by dotfiles); old ones in
  `~/Projects/Archive`. KeepTheCall's code is `~/Projects/keepthecall`; on the mini its live
  deploy is `~/Apps/keepthecall`.
- `~/Documents` — personal files only. `~/Documents/Customer-Work` holds bulky michaelgit client
  artifacts.
- SBIC (former employer) is archived at `/Volumes/Media/Archive/SBIC-2026-10-01.zip` on the mini;
  no machine keeps a working copy.

If a root you need isn't listed, or a pointer looks stale, read `~/.dotfiles/manifest.sh` (the
source of truth) and flag the gap so this map gets fixed.
