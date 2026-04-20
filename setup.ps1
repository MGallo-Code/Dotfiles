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
