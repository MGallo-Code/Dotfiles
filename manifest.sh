#!/usr/bin/env bash
# Dotfiles manifest - single source of truth for repos, symlinks, and directories

# Repos to clone: "remote|target_path"
REPOS=(
  "git@github:MGallo-Code/EA.git|~/Documents/EA"
  "git@github:MGallo-Code/NVIM-Setup.git|~/.config/nvim"
  "git@github:MGallo-Code/Wiki.git|~/Documents/Wiki"
  "git@github:MGallo-Code/Notes.git|~/Documents/Notes"
  "git@github:MGallo-Code/IT-Worker.git|~/Documents/IT-Worker"
)

# EA-only repos (skipped with --dev)
EA_REPOS=(
  "git@github:MGallo-Code/EA.git|~/Documents/EA"
  "git@github:MGallo-Code/Wiki.git|~/Documents/Wiki"
  "git@github:MGallo-Code/Notes.git|~/Documents/Notes"
  "git@github:MGallo-Code/IT-Worker.git|~/Documents/IT-Worker"
)

# Symlinks to create: "source|target"
SYMLINKS=(
  "~/Documents/EA/claude-config/global-rules|~/.claude/rules"
  # Smart-default agent-skills nudge: single source, three consumers.
  # (Claude already loads it via the global-rules dir symlink above; these wire
  #  the same one file as Codex's and Gemini's global instructions.)
  "~/Documents/EA/claude-config/global-rules/agent-skills.md|~/.codex/AGENTS.md"
  "~/Documents/EA/claude-config/global-rules/agent-skills.md|~/.gemini/GEMINI.md"
)

# ── Forked agent-skills (addyosmani/agent-skills) ────────────────────
# Two remotes: origin = your fork (MGallo-Code/agent-skills, trusted, push),
# upstream = Addy (untrusted source of truth, gated pull). Synced by the
# dedicated, security-gated sync_skills_repo() in sync.sh, NOT the generic
# sync_repo (which would blind ff-pull origin and skip the gate). Kept OUT of
# REPOS for that reason.
AGENT_SKILLS_DIR="~/Documents/agent-skills"
AGENT_SKILLS_UPSTREAM="https://github.com/addyosmani/agent-skills.git"

# Each tool reads global skills from its own dir; sync symlinks every
# skills/<name> from the vendor repo into each (idempotent, never clobbers
# existing real skill dirs like calendar/contact/dev-update).
AGENT_SKILLS_TARGETS=(
  "~/.claude/skills"
  "~/.codex/skills"
  "~/.gemini/skills"
)

# Directories to ensure exist
DIRECTORIES=(
  "~/Documents/Learning"
  "~/Documents/Jobs"
)

# Shell command files (relative to dotfiles repo root)
SHELL_CORE="shell/core.zsh"
SHELL_EA="shell/ea.zsh"
