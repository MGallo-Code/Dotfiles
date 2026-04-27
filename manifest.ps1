# Dotfiles manifest - Windows (mirrors manifest.sh)

$Repos = @(
    @{ Remote = "git@github:MGallo-Code/EA.git";         Target = "$HOME\Documents\EA" }
    @{ Remote = "git@github:MGallo-Code/NVIM-Setup.git";  Target = "$env:LOCALAPPDATA\nvim" }
    @{ Remote = "git@github:MGallo-Code/Wiki.git";        Target = "$HOME\Documents\Wiki" }
    @{ Remote = "git@github:MGallo-Code/IT-Worker.git";   Target = "$HOME\Documents\IT-Worker" }
)

$EARepos = @(
    "EA"
    "Wiki"
    "IT-Worker"
)

$Symlinks = @(
    @{ Source = "$HOME\Documents\EA\claude-config\global-rules"; Target = "$HOME\.claude\rules" }
    @{ Source = "$HOME\Documents\EA\claude-config\settings.json"; Target = "$HOME\.claude\settings.json" }
)

$Directories = @(
    "$HOME\Documents\Learning"
    "$HOME\Documents\Jobs"
)
