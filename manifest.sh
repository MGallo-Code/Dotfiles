#!/usr/bin/env bash
# Dotfiles manifest - single source of truth for repos, symlinks, and directories

# Repos to clone: "remote|target_path"
REPOS=(
  "git@github:MGallo-Code/EA.git|~/Documents/EA"
  "git@github:MGallo-Code/NVIM-Setup.git|~/.config/nvim"
  "git@github:MGallo-Code/Wiki.git|~/Documents/Wiki"
)

# EA-only repos (skipped with --dev)
EA_REPOS=(
  "git@github:MGallo-Code/EA.git|~/Documents/EA"
  "git@github:MGallo-Code/Wiki.git|~/Documents/Wiki"
)

# Symlinks to create: "source|target"
SYMLINKS=(
  "~/Documents/EA/claude-config/global-rules|~/.claude/rules"
)

# Directories to ensure exist
DIRECTORIES=(
  "~/Documents/Learning"
  "~/Documents/Jobs"
)

# Shell command files (relative to dotfiles repo root)
SHELL_CORE="shell/core.zsh"
SHELL_EA="shell/ea.zsh"
