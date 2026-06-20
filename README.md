# Dotfiles

Cross-platform dev environment setup. One repo, one command.

## Quick Start

```bash
# macOS
git clone https://github.com/MGallo-Code/Dotfiles.git ~/.dotfiles
cd ~/.dotfiles && bash setup.sh
```

```powershell
# Windows (coming soon)
git clone https://github.com/MGallo-Code/Dotfiles.git $HOME\.dotfiles
cd $HOME\.dotfiles; .\setup.ps1
```

## Setup Modes

- `setup.sh --full` (default) - Everything: dev tools, EA, NVIM, Wiki, shell commands
- `setup.sh --dev` - Dev tools + NVIM only, no EA/Wiki
- `setup.sh --minimal` - Just SSH key + git config

## Sync

Pull updates across all managed repos, push local commits, and hand dirty repos to Claude for committing:

```bash
sync
```

## Gemini Cross-Check

Configure Gemini CLI for cross-agent refutation checks:

```bash
# macOS
bash scripts/setup-gemini-cross-check.sh
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts/setup-gemini-cross-check.ps1
```

The scripts pin `gemini-3.1-flash-lite` and store the API key in machine-local secret storage. See `docs/gemini-cross-check-setup.md`.

## What It Manages

Every root has one role (see the taxonomy at the top of `manifest.sh`):

| Root | Location | Role |
|------|----------|------|
| EA | ~/Documents/EA | active-repo (synced; `--full`) |
| Wiki | ~/Documents/Wiki | active-repo (synced; `--full`) |
| Notes | ~/Documents/Notes | active-repo (synced; `--full`) |
| NVIM-Setup | ~/.config/nvim (Mac) / %LOCALAPPDATA%\nvim (Win) | active-repo (synced; `--dev` + `--full`) |
| agent-skills | ~/Documents/agent-skills | external-managed (forked addyosmani upstream; security-gated sync) |
| IT-Worker | ~/Documents/IT-Worker | archive-repo (NOT synced; legacy reference, active ops moved to EA/business/michaelgit) |

**Generated for codex + gemini on every sync** (never hand-edit; the targets are read-only):
- Combined agent rules from `EA/claude-config/global-rules/*.md` -> `~/.codex/AGENTS.md`, `~/.gemini/GEMINI.md`
- Global + per-repo project skills, namespaced (`ea-*`, `wiki-*`, `sbic-*`) into `~/.codex/skills`, `~/.gemini/skills`
- Claude slash-commands -> codex prompts (`~/.codex/prompts/*.md`) + gemini commands (`~/.gemini/commands/*.toml`). Invoke with `/<name>` (e.g. `/handoff`); each dir gets a generated `README.md` index listing commands + how to invoke them.
- Tool allowlist mirrored into codex/gemini

**Also:** Claude Code rules + hooks symlinks (`~/.claude/rules`, `~/.claude/hooks`), per-role courier MCP wiring, shell commands, SSH config, Homebrew packages.

**MCP servers** (EA, configured in `EA/.mcp.json`): nexus, courier, docgen, calendar.

## Updating This System

"This system" = the whole Michael Workspace (dotfiles + the EA sources it distributes + the
agent-skills kit). When you change the **plumbing** (manifest, sync/setup, the CI checks, or
the rules/commands/skills sources), start the agent in the **control plane** - this repo:

```bash
sysupdate     # = cd ~/.dotfiles && claude --add-dir ~/Documents/EA --add-dir ~/Documents/agent-skills
```

- `manifest.sh` is the single, always-current **map** of every managed root and its role -
  read it to see the whole system from one file (no separate map to drift).
- `INVARIANTS.md` + the pre-commit hook + CI are the rules and their mechanical enforcers.
- Claude Code scopes to its launch dir, so `sysupdate` adds the EA + agent-skills source roots.
  Codex and Gemini already see the whole workspace (the `michael_workspace` permission profile
  + Gemini `includeDirectories`), so for those use `sysupdate --codex` / `sysupdate --gemini`.
- The workspace launchers (`ea`, `wiki`, `sbic`, `sysupdate`) open Codex/Gemini with
  auto-approve and **no sandbox** (`codex --dangerously-bypass-approvals-and-sandbox`,
  `gemini --yolo`), so an agent never stops to ask before editing files or running commands.
  Claude keeps its own permission model. Use them only in trusted local roots.

For everyday **ops** (email, calendar, nexus, notes) start in `~/Documents/EA` instead, where
the MCP servers and the Nexus DB live.
