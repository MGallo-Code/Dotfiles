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

| Repo | Location |
|------|----------|
| EA | ~/Documents/EA |
| Wiki | ~/Documents/Wiki |
| NVIM-Setup | ~/.config/nvim (Mac) / ~/AppData/Local/nvim (Win) |

Plus: shell commands, SSH config, Claude Code rules symlink, Homebrew packages.
