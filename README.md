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
