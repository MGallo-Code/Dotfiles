# EA-specific shell commands (PowerShell)

function ea {
    Set-Location "$HOME\Documents\EA"
    & claude
}

function wiki {
    Set-Location "$HOME\Documents\Wiki"
    & claude
}

function it {
    Set-Location "$HOME\Documents\IT-Worker"
    & claude
}

# Update the Michael Workspace SYSTEM: launch Claude in the dotfiles control plane (manifest.sh
# is the map of every managed root + its role) with the source roots it distributes (EA =
# rules/commands/skills/MCP) and the skills kit added. Codex/Gemini already see the whole
# workspace via the michael_workspace profile, so for those just `cd ~/.dotfiles; codex`.
function sysupdate {
    Set-Location "$HOME\.dotfiles"
    & claude --add-dir "$HOME\Documents\EA" --add-dir "$HOME\Documents\agent-skills" @args
}

function practice {
    $WorkspaceDir = "$HOME\Documents\EA\exercises\workspace"
    $VenvDir = "$HOME\Documents\EA\exercises\.venv"

    New-Item -ItemType Directory -Path $WorkspaceDir -Force | Out-Null

    if (-not (Test-Path "$VenvDir\Scripts\Activate.ps1")) {
        Write-Host "Setting up practice environment..."
        & python3 -m venv $VenvDir
        & "$VenvDir\Scripts\pip.exe" install pytest
        Write-Host "Done!"
    }

    & "$VenvDir\Scripts\Activate.ps1"
    Set-Location $WorkspaceDir
    & nvim .
}
