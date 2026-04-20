# EA-specific shell commands (PowerShell)

function ea {
    Set-Location "$HOME\Documents\EA"
    & claude
}

function wiki {
    Set-Location "$HOME\Documents\Wiki"
    & claude
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
