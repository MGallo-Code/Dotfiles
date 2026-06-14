# Dotfiles manifest - Windows (mirrors manifest.sh)

$Repos = @(
    @{ Remote = "git@github:MGallo-Code/EA.git";         Target = "$HOME\Documents\EA" }
    @{ Remote = "git@github:MGallo-Code/NVIM-Setup.git";  Target = "$env:LOCALAPPDATA\nvim" }
    @{ Remote = "git@github:MGallo-Code/Wiki.git";        Target = "$HOME\Documents\Wiki" }
    @{ Remote = "git@github:MGallo-Code/Notes.git";       Target = "$HOME\Documents\Notes" }
    @{ Remote = "git@github:MGallo-Code/IT-Worker.git";   Target = "$HOME\Documents\IT-Worker" }
)

$EARepos = @(
    "EA"
    "Wiki"
    "Notes"
    "IT-Worker"
)

$Symlinks = @(
    @{ Source = "$HOME\Documents\EA\claude-config\global-rules"; Target = "$HOME\.claude\rules" }
    # Smart-default agent-skills nudge: single source, three consumers (Claude loads
    # it via the global-rules dir symlink above; these wire it as Codex's and
    # Gemini's global instructions).
    @{ Source = "$HOME\Documents\EA\claude-config\global-rules\agent-skills.md"; Target = "$HOME\.codex\AGENTS.md" }
    @{ Source = "$HOME\Documents\EA\claude-config\global-rules\agent-skills.md"; Target = "$HOME\.gemini\GEMINI.md" }
)

# ── Forked agent-skills (addyosmani/agent-skills) ────────────────────
# Two remotes: origin = your fork (trusted, push), upstream = Addy (untrusted,
# gated pull). Synced by the dedicated, security-gated Sync-SkillsRepo in
# sync.ps1, NOT the generic Sync-Repo. Kept OUT of $Repos for that reason.
$AgentSkillsDir = "$HOME\Documents\agent-skills"
$AgentSkillsUpstream = "https://github.com/addyosmani/agent-skills.git"

# Each tool reads global skills from its own dir; sync symlinks every
# skills\<name> from the vendor repo into each (idempotent, never clobbers
# existing real skill dirs like calendar/contact/dev-update).
$AgentSkillsTargets = @(
    "$HOME\.claude\skills"
    "$HOME\.codex\skills"
    "$HOME\.gemini\skills"
)

$Directories = @(
    "$HOME\Documents\Learning"
    "$HOME\Documents\Jobs"
)
