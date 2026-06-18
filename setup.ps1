# Cross-platform dev environment setup (Windows)
# Usage: powershell -ExecutionPolicy Bypass -File setup.ps1 [-Mode full|dev|minimal]

param(
    [ValidateSet("full", "dev", "minimal")]
    [string]$Mode = "full"
)

$ErrorActionPreference = "Stop"
$DotfilesDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Ok   { param($msg) Write-Host "[ok] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[skip] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "[error] $msg" -ForegroundColor Red }
function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Green }

# Helper: find ssh.exe (OpenSSH or Git's bundled copy)
function Find-Ssh {
    $cmd = Get-Command ssh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if (Test-Path "C:\Windows\System32\OpenSSH\ssh.exe") { return "C:\Windows\System32\OpenSSH\ssh.exe" }
    if (Test-Path "C:\Program Files\Git\usr\bin\ssh.exe") { return "C:\Program Files\Git\usr\bin\ssh.exe" }
    return $null
}

. "$DotfilesDir\manifest.ps1"

# ── Execution Policy ─────────────────────────────────────────────────
Write-Step "Execution policy"

$currentPolicy = Get-ExecutionPolicy -Scope CurrentUser
if ($currentPolicy -eq "RemoteSigned" -or $currentPolicy -eq "Unrestricted") {
    Write-Ok "Execution policy: $currentPolicy"
}
else {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Write-Ok "Set execution policy to RemoteSigned"
}

# ── OpenSSH Default Shell ────────────────────────────────────────────
Write-Step "SSH server default shell"

$sshShellPath = "HKLM:\SOFTWARE\OpenSSH"
$currentShell = (Get-ItemProperty -Path $sshShellPath -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
$psPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

if ($currentShell -eq $psPath) {
    Write-Ok "SSH default shell is PowerShell"
}
else {
    try {
        New-ItemProperty -Path $sshShellPath -Name DefaultShell -Value $psPath -PropertyType String -Force | Out-Null
        Restart-Service sshd -ErrorAction SilentlyContinue
        Write-Ok "Set SSH default shell to PowerShell"
    }
    catch {
        Write-Warn "Could not set SSH default shell (needs admin). Run as Administrator or set manually."
    }
}

# ── Git Config ────────────────────────────────────────────────────────
Write-Step "Git config"

$currentName = git config --global user.name 2>$null
$currentEmail = git config --global user.email 2>$null

if ($currentName -and $currentEmail) {
    Write-Ok "Git user: $currentName <$currentEmail>"
}
else {
    if (-not $currentName) {
        $gitName = Read-Host "Enter your Git name (e.g. Michael Gallo)"
        git config --global user.name $gitName
    }
    if (-not $currentEmail) {
        $gitEmail = Read-Host "Enter your Git email"
        git config --global user.email $gitEmail
    }
    Write-Ok "Git config set"
}

# ── SSH Key ──────────────────────────────────────────────────────────
Write-Step "SSH key setup"

# Ensure OpenSSH client is available
$sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
if (-not $sshKeygen) {
    Write-Host "Installing OpenSSH Client..."
    try {
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
        # Refresh PATH so ssh/ssh-keygen are available this session
        $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        $env:Path = "$machinePath;$userPath"
        Write-Ok "OpenSSH Client installed"
    }
    catch {
        Write-Err "Failed to install OpenSSH Client. Run this script as Administrator."
        Write-Host "Or install manually: Settings > Apps > Optional Features > OpenSSH Client"
        exit 1
    }
}

$SshKey = "$HOME\.ssh\id_ed25519"
if (Test-Path $SshKey) {
    Write-Ok "SSH key already exists"
}
else {
    Write-Host "Generating SSH key..."
    New-Item -ItemType Directory -Path "$HOME\.ssh" -Force | Out-Null
    ssh-keygen -t ed25519 -C "$env:USERNAME@$env:COMPUTERNAME" -f $SshKey -N '""'

    # Copy to clipboard
    Get-Content "$SshKey.pub" | Set-Clipboard
    Write-Ok "Public key copied to clipboard"

    Start-Process "https://github.com/settings/ssh/new"
    Write-Host ""
    Write-Host "Paste your key on GitHub, then press Enter to continue..."
    Read-Host
}

# SSH config - create if missing, or ensure github alias exists
$SshConfig = "$HOME\.ssh\config"
if (-not (Test-Path $SshConfig)) {
    Copy-Item "$DotfilesDir\ssh\config.template" $SshConfig
    Write-Ok "SSH config created from template (edit IPs in $SshConfig)"
}
else {
    # Check if github alias already exists
    $configContent = Get-Content $SshConfig -Raw
    if ($configContent -match "(?m)^Host github\b") {
        Write-Ok "SSH config has github alias"
    }
    else {
        $githubBlock = @"

# Dotfiles setup
Host github
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
"@
        Add-Content -Path $SshConfig -Value $githubBlock
        Write-Ok "Added github alias to existing SSH config"
    }
}

# Test GitHub SSH access
Write-Step "Testing GitHub SSH access"
$sshExe = Find-Ssh
if (-not $sshExe) {
    Write-Warn "No ssh client found - skipping SSH test"
}
else {
    $sshTest = & $sshExe -T git@github 2>&1 | Out-String
    if ($sshTest -match "successfully authenticated") {
        Write-Ok "GitHub SSH access works"

        # Switch dotfiles remote from HTTPS to SSH if needed
        $currentRemote = git -C $DotfilesDir remote get-url origin 2>$null
        if ($currentRemote -and $currentRemote.StartsWith("https://")) {
            git -C $DotfilesDir remote set-url origin "git@github:MGallo-Code/Dotfiles.git"
            Write-Ok "Switched dotfiles remote to SSH"
        }
    }
    else {
        Write-Warn "GitHub SSH test inconclusive - clone steps may fail"
    }
}

# ── Winget Packages ──────────────────────────────────────────────────
if ($Mode -ne "minimal") {
    Write-Step "Package installation"

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Warn "winget not available. Install packages manually."
    }
    else {
        $answer = Read-Host "Install packages via winget? (y/n)"
        if ($answer -eq "y") {
            $packages = @(
                @{ Id = "Neovim.Neovim" }
                @{ Id = "OpenJS.NodeJS.LTS" }
                @{ Id = "GoLang.Go" }
                @{ Id = "Python.Python.3.12" }
            )
            foreach ($pkg in $packages) {
                Write-Host "Installing $($pkg.Id)..."
                winget install --id $pkg.Id --accept-package-agreements --accept-source-agreements 2>$null
            }

            # Refresh PATH after installs
            $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
            $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
            $env:Path = "$machinePath;$userPath"
            Write-Ok "Packages installed"
        }
        else {
            Write-Warn "Skipped package installation"
        }
    }
}

# ── Directories ──────────────────────────────────────────────────────
Write-Step "Creating directories"

foreach ($dir in $Directories) {
    if (Test-Path $dir) {
        Write-Ok "$dir already exists"
    }
    else {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Ok "Created $dir"
    }
}

# ── Clone Repos ──────────────────────────────────────────────────────
if ($Mode -ne "minimal") {
    Write-Step "Cloning repos"

    foreach ($repo in $Repos) {
        $remote = $repo.Remote
        $target = $repo.Target
        $name = Split-Path $target -Leaf

        # Skip EA-only repos if --dev
        if ($Mode -eq "dev" -and $EARepos -contains $name) {
            Write-Warn "Skipping $name (dev mode)"
            continue
        }

        if (Test-Path "$target\.git") {
            Write-Ok "$target already cloned"
        }
        elseif (Test-Path $target) {
            Write-Warn "$target exists but is not a git repo - skipping"
        }
        else {
            $parent = Split-Path $target -Parent
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            git clone $remote $target
            Write-Ok "Cloned to $target"
        }
    }
}

# ── MCP servers (nexus + courier + docgen + calendar) ─────────────
if ($Mode -eq "full") {
    Write-Step "Setting up MCP servers (nexus, courier, docgen, calendar)"
    $EaPath = "$HOME\Documents\EA"
    $ItwPath = "$HOME\Documents\IT-Worker"
    $NexusPath = "$EaPath\nexus"
    $CourierPath = "$EaPath\courier"
    $DocgenPath = "$EaPath\docgen"
    $CalendarPath = "$EaPath\calendar"
    $NexusServer = "$NexusPath\dist\server.js"
    $CourierSrc = "$CourierPath\src"
    $DocgenSrc = "$DocgenPath\src"
    $CalendarSrc = "$CalendarPath\src"
    $DocgenBrowsers = "$DocgenPath\.playwright-browsers"

    if (Test-Path "$NexusPath\package.json") {
        Push-Location $NexusPath
        npm install --silent 2>$null
        npm run build 2>$null
        Pop-Location
        Write-Ok "Nexus: installed and built"
    }
    else {
        Write-Warn "Nexus: package.json not found at $NexusPath"
    }

    $uvCmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($uvCmd) {
        if (Test-Path $CourierPath) {
            Push-Location $CourierPath
            uv sync --quiet 2>$null
            Pop-Location
            Write-Ok "Courier: deps synced"
        }
        if (Test-Path $CalendarPath) {
            Push-Location $CalendarPath
            uv sync --quiet 2>$null
            Pop-Location
            Write-Ok "Calendar: deps synced"
        }
        if (Test-Path $DocgenPath) {
            Push-Location $DocgenPath
            uv sync --quiet 2>$null
            Pop-Location
            Write-Ok "Docgen: deps synced"

            $oldBrowsers = $env:PLAYWRIGHT_BROWSERS_PATH
            $env:PLAYWRIGHT_BROWSERS_PATH = $DocgenBrowsers
            uv run --project $DocgenPath --no-sync playwright install chromium 2>$null | Out-Null
            $env:PLAYWRIGHT_BROWSERS_PATH = $oldBrowsers
            Write-Ok "Docgen: Chromium installed"
        }
    }
    else {
        Write-Warn "uv not found - skipping courier/docgen/calendar dep sync"
    }

    if (Test-Path $NexusServer) {
        # Generate private project .mcp.json for EA and IT-Worker with machine-specific paths.
        # Courier is intentionally global-only so email does not flow through shared repo config.
        $McpJson = @{
            mcpServers = @{
                nexus = @{
                    command = "node"
                    args = @($NexusServer)
                }
                docgen = @{
                    command = "uv"
                    args = @("run", "--project", $DocgenPath, "--no-sync", "python", "-m", "docgen.server")
                    env = @{
                        PYTHONPATH = $DocgenSrc
                        PLAYWRIGHT_BROWSERS_PATH = $DocgenBrowsers
                    }
                }
            }
        } | ConvertTo-Json -Depth 6
        Set-Content -Path "$EaPath\.mcp.json" -Value $McpJson
        Write-Ok "EA .mcp.json generated (nexus + docgen)"

        if (Test-Path $ItwPath) {
            Set-Content -Path "$ItwPath\.mcp.json" -Value $McpJson
            Write-Ok "IT-Worker .mcp.json generated (nexus + docgen)"
        }
    }

    function Register-GlobalMcp {
        param([string]$Cli)
        $cmd = Get-Command $Cli -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Write-Warn "$Cli not found - skipping its global MCP wiring"
            return
        }

        foreach ($name in @("nexus", "courier", "docgen", "calendar")) {
            switch ($Cli) {
                "claude" { & $cmd.Source mcp remove --scope=user $name 2>$null | Out-Null }
                "codex"  { & $cmd.Source mcp remove $name 2>$null | Out-Null }
                "gemini" { & $cmd.Source mcp remove --scope user $name 2>$null | Out-Null }
            }
        }

        switch ($Cli) {
            "claude" {
                & $cmd.Source mcp add --scope=user nexus -- node $NexusServer | Out-Null
                & $cmd.Source mcp add --scope=user courier --env "PYTHONPATH=$CourierSrc" -- uv run --project $CourierPath --no-sync python -m courier.server | Out-Null
                & $cmd.Source mcp add --scope=user docgen --env "PYTHONPATH=$DocgenSrc" --env "PLAYWRIGHT_BROWSERS_PATH=$DocgenBrowsers" -- uv run --project $DocgenPath --no-sync python -m docgen.server | Out-Null
                & $cmd.Source mcp add --scope=user calendar --env "PYTHONPATH=$CalendarSrc" -- uv run --project $CalendarPath --no-sync python -m ea_calendar.server | Out-Null
            }
            "codex" {
                & $cmd.Source mcp add nexus -- node $NexusServer | Out-Null
                & $cmd.Source mcp add courier --env "PYTHONPATH=$CourierSrc" -- uv run --project $CourierPath --no-sync python -m courier.server | Out-Null
                & $cmd.Source mcp add docgen --env "PYTHONPATH=$DocgenSrc" --env "PLAYWRIGHT_BROWSERS_PATH=$DocgenBrowsers" -- uv run --project $DocgenPath --no-sync python -m docgen.server | Out-Null
                & $cmd.Source mcp add calendar --env "PYTHONPATH=$CalendarSrc" -- uv run --project $CalendarPath --no-sync python -m ea_calendar.server | Out-Null
            }
            "gemini" {
                & $cmd.Source mcp add --scope user nexus node $NexusServer | Out-Null
                & $cmd.Source mcp add --scope user courier --env "PYTHONPATH=$CourierSrc" uv run --project $CourierPath --no-sync python -m courier.server | Out-Null
                & $cmd.Source mcp add --scope user docgen --env "PYTHONPATH=$DocgenSrc" --env "PLAYWRIGHT_BROWSERS_PATH=$DocgenBrowsers" uv run --project $DocgenPath --no-sync python -m docgen.server | Out-Null
                & $cmd.Source mcp add --scope user calendar --env "PYTHONPATH=$CalendarSrc" uv run --project $CalendarPath --no-sync python -m ea_calendar.server | Out-Null
            }
        }
        Write-Ok "$Cli`: global MCP wired (nexus + courier + docgen + calendar)"
    }

    if (Test-Path $NexusServer) {
        Register-GlobalMcp "claude"
        Register-GlobalMcp "codex"
        Register-GlobalMcp "gemini"
    }

    function Test-CalendarHealth {
        if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { return }
        if (-not (Test-Path $CalendarPath)) { return }
        & uv run --project $CalendarPath --no-sync calendar-auth status --check-events --quiet *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Calendar: authenticated as michaelgallo.va@gmail.com"
        }
        else {
            Write-Warn "Calendar: not authenticated or health check failed - run calendar-auth login"
        }
    }
    Test-CalendarHealth

    function Trust-GeminiManagedRepos {
        if (-not (Get-Command gemini -ErrorAction SilentlyContinue)) { return }
        $trustFile = "$HOME\.gemini\trustedFolders.json"
        $trustDir = Split-Path $trustFile -Parent
        New-Item -ItemType Directory -Path $trustDir -Force | Out-Null

        $trust = @{}
        if (Test-Path $trustFile) {
            $raw = Get-Content $trustFile -Raw
            if ($raw) {
                $obj = $raw | ConvertFrom-Json
                if ($obj) {
                    foreach ($prop in $obj.PSObject.Properties) {
                        $trust[$prop.Name] = $prop.Value
                    }
                }
            }
        }

        foreach ($repo in $Repos) {
            if (Test-Path $repo.Target) {
                $trust[$repo.Target] = "TRUST_FOLDER"
            }
        }

        $trust | ConvertTo-Json -Depth 4 | Set-Content -Path $trustFile
        Write-Ok "Gemini: trusted managed repo folders"
    }
    Trust-GeminiManagedRepos
}

# ── Symlinks ─────────────────────────────────────────────────────────
if ($Mode -eq "full") {
    Write-Step "Creating symlinks"

    # Check developer mode
    $devMode = $false
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
        $devModeValue = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
        $devMode = $devModeValue -eq 1
    }
    catch {}

    if (-not $devMode) {
        Write-Warn "Developer mode not enabled. Symlinks may fail."
        Write-Host "  Enable: Settings > Privacy & Security > For Developers > Developer Mode"
        Write-Host "  Or run this script as Administrator."
        Write-Host ""
    }

    foreach ($link in $Symlinks) {
        $source = $link.Source
        $target = $link.Target

        if ((Test-Path $target) -and ((Get-Item $target).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $existing = (Get-Item $target).Target
            if ($existing -eq $source) {
                Write-Ok "$target already linked correctly"
                continue
            }
        }

        if (Test-Path $target) {
            Write-Warn "$target exists but is not the expected symlink - skipping"
            continue
        }

        $parent = Split-Path $target -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path $target -Target $source | Out-Null
            Write-Ok "Linked $target -> $source"
        }
        catch {
            Write-Err "Failed to create symlink. Enable Developer Mode or run as Admin."
        }
    }
}

# ── PowerShell Profile ───────────────────────────────────────────────
if ($Mode -ne "minimal") {
    Write-Step "Shell commands"

    # Ensure profile directory exists
    $profileDir = Split-Path $PROFILE -Parent
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

    # Build source lines
    $coreLine = ". `"$DotfilesDir\shell\windows\core.ps1`""
    $eaLine = ". `"$DotfilesDir\shell\windows\ea.ps1`""

    # Check if profile already sources our files
    $profileContent = ""
    if (Test-Path $PROFILE) {
        $profileContent = Get-Content $PROFILE -Raw
    }

    $needsUpdate = $false

    if ($profileContent -notmatch "dotfiles.*core\.ps1") {
        Add-Content -Path $PROFILE -Value "`n# Dotfiles custom commands"
        Add-Content -Path $PROFILE -Value $coreLine
        $needsUpdate = $true
        Write-Ok "Added core commands to PowerShell profile"
    }
    else {
        Write-Ok "Core commands already in profile"
    }

    if ($Mode -eq "full") {
        if ($profileContent -notmatch "dotfiles.*ea\.ps1") {
            Add-Content -Path $PROFILE -Value $eaLine
            $needsUpdate = $true
            Write-Ok "Added EA commands to PowerShell profile"
        }
        else {
            Write-Ok "EA commands already in profile"
        }
    }

    if (-not $needsUpdate) {
        Write-Ok "PowerShell profile already configured"
    }
}

# ── Claude Code ──────────────────────────────────────────────────────
Write-Step "Claude Code"

$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    Write-Ok "Claude Code is installed"
    Write-Host "    Run 'claude' to authenticate if needed"
}
else {
    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if ($npmCmd) {
        Write-Host "Installing Claude Code..."
        npm install -g @anthropic-ai/claude-code
        Write-Ok "Claude Code installed. Run 'claude' to authenticate."
    }
    else {
        Write-Warn "Claude Code not found. Install Node.js first, then: npm install -g @anthropic-ai/claude-code"
    }
}

# ── Practice Environment ─────────────────────────────────────────────
if ($Mode -eq "full") {
    Write-Step "Practice environment"

    $exerciseDir = "$HOME\Documents\EA\exercises"
    $venvDir = "$exerciseDir\.venv"
    $workspaceDir = "$exerciseDir\workspace"

    if (Test-Path $exerciseDir) {
        New-Item -ItemType Directory -Path $workspaceDir -Force | Out-Null

        $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue }

        if ($pythonCmd) {
            if (-not (Test-Path "$venvDir\Scripts\Activate.ps1")) {
                Write-Host "Setting up practice venv..."
                & $pythonCmd.Source -m venv $venvDir
                & "$venvDir\Scripts\pip.exe" install pytest
                Write-Ok "Practice environment ready"
            }
            else {
                Write-Ok "Practice venv already exists"
            }
        }
        else {
            Write-Warn "Python not found - install via winget, then run setup again for practice env"
        }
    }
    else {
        Write-Warn "EA not cloned yet - practice environment skipped"
    }
}

# ── Summary ──────────────────────────────────────────────────────────
Write-Step "Setup complete!"
Write-Host ""
Write-Host "What's next:"
Write-Host "  - Edit SSH config IPs: $HOME\.ssh\config"
Write-Host "  - Authenticate Claude Code: claude"
Write-Host "  - Restart PowerShell to load new commands"
Write-Host ""
