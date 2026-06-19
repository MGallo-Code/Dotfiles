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

function Set-AgentDefaults { # AGENT_DEFAULTS_CONFIG
    $codexDir = Join-Path $HOME ".codex"
    $codexConfig = Join-Path $codexDir "config.toml"
    New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
    $content = ""
    if (Test-Path $codexConfig) {
        $content = Get-Content $codexConfig -Raw
    }

    function Set-CodexTomlKey {
        param([string]$Content, [string]$Key, [string]$Value)
        $line = "$Key = `"$Value`""
        $keyPattern = '(?m)^' + [regex]::Escape($Key) + '\s*=\s*"[^"]*"\r?\n?'
        $Content = [regex]::Replace($Content, $keyPattern, "")
        $tableMatch = [regex]::Match($Content, '(?m)^\s*\[')
        if ($tableMatch.Success) {
            $before = $Content.Substring(0, $tableMatch.Index).TrimEnd()
            $after = $Content.Substring($tableMatch.Index)
            if ($before) {
                return $before + "`n" + $line + "`n`n" + $after
            }
            return $line + "`n`n" + $after
        }
        if ($Content -and -not $Content.EndsWith("`n")) { $Content += "`n" }
        return $Content + $line + "`n"
    }

    function Set-CodexManagedBlock {
        param([string]$Content)
        $markerStart = "# dotfiles: Codex Michael workspace permission profile"
        $markerEnd = "# dotfiles: end Codex Michael workspace permission profile"
        $block = @"
$markerStart
[permissions.michael_workspace]
description = "Michael's local workspace, dotfiles, and agent config"

[permissions.michael_workspace.filesystem]
":minimal" = "read"

[permissions.michael_workspace.filesystem.":workspace_roots"]
"." = "write"

[permissions.michael_workspace.workspace_roots]
"~/Documents" = true
"~/Downloads" = true
"~/.dotfiles" = true
"~/.codex" = true
"~/.claude" = true
"~/.gemini" = true
"~/.config/nvim" = true

[permissions.michael_workspace.network]
enabled = true
allow_local_binding = true
$markerEnd
"@
        $pattern = '(?s)\r?\n?# dotfiles: Codex Michael workspace permission profile\r?\n.*?# dotfiles: end Codex Michael workspace permission profile\r?\n?'
        $Content = [regex]::Replace($Content, $pattern, "`n")
        if ($Content -and -not $Content.EndsWith("`n")) { $Content += "`n" }
        return $Content + "`n" + $block + "`n"
    }

    $content = Set-CodexTomlKey $content "model_reasoning_effort" "xhigh"
    $content = Set-CodexTomlKey $content "approval_policy" "on-request"
    $content = Set-CodexTomlKey $content "approvals_reviewer" "user"
    $content = Set-CodexTomlKey $content "default_permissions" "michael_workspace"
    $content = Set-CodexManagedBlock $content
    Set-Content -Path $codexConfig -Value $content -NoNewline
    Write-Ok "Codex: defaults set (xhigh reasoning + Michael workspace permissions)"

    # Stacked-push guard for Codex (PreToolUse), parity mirror of the bash block:
    # same script + protocol as the Claude PreToolUse guard, invoked via bash.
    # Registration is machine-local in config.toml; trust once via Codex /hooks.
    # Idempotent via a marker comment.
    $codexGuardMarker = "# dotfiles: flat-PR stacked-push guard"
    $codexGuard = "bash `"$HOME/.claude/hooks/warn-stacked-git-push.sh`""
    $codexExisting = if (Test-Path $codexConfig) { Get-Content $codexConfig -Raw } else { "" }
    if ($codexExisting -notlike "*$codexGuardMarker*") {
        $codexGuardBlock = @"

$codexGuardMarker
[[hooks.PreToolUse]]
matcher = "^Bash`$"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = '$codexGuard'
  timeout = 30
"@
        Add-Content -Path $codexConfig -Value $codexGuardBlock
        Write-Ok "Codex: wired stacked-push guard (run /hooks once to trust it)"
    } else {
        Write-Ok "Codex stacked-push guard already wired"
    }

    $geminiDir = Join-Path $HOME ".gemini"
    $geminiSettings = Join-Path $geminiDir "settings.json"
    New-Item -ItemType Directory -Path $geminiDir -Force | Out-Null
    $settings = [ordered]@{}
    if (Test-Path $geminiSettings) {
        $raw = Get-Content $geminiSettings -Raw
        if ($raw) {
            $obj = $raw | ConvertFrom-Json
            if ($obj) {
                foreach ($prop in $obj.PSObject.Properties) {
                    $settings[$prop.Name] = $prop.Value
                }
            }
        }
    }
    if (-not $settings.Contains("general") -or $null -eq $settings["general"]) {
        $settings["general"] = [ordered]@{}
    }
    $general = $settings["general"]
    if (-not ($general -is [System.Collections.IDictionary])) {
        $newGeneral = [ordered]@{}
        foreach ($prop in $general.PSObject.Properties) {
            $newGeneral[$prop.Name] = $prop.Value
        }
        $general = $newGeneral
        $settings["general"] = $general
    }
    $general["defaultApprovalMode"] = "auto_edit"
    $geminiWorkspaceRoots = @(
        "$HOME\Documents",
        "$HOME\Downloads",
        "$HOME\.dotfiles",
        "$HOME\.codex",
        "$HOME\.claude",
        "$HOME\.gemini",
        "$HOME\.config\nvim"
    )
    if (-not $settings.Contains("context") -or $null -eq $settings["context"]) {
        $settings["context"] = [ordered]@{}
    }
    $context = $settings["context"]
    if (-not ($context -is [System.Collections.IDictionary])) {
        $newContext = [ordered]@{}
        foreach ($prop in $context.PSObject.Properties) {
            $newContext[$prop.Name] = $prop.Value
        }
        $context = $newContext
        $settings["context"] = $context
    }
    $includeDirs = @()
    if ($context.Contains("includeDirectories") -and $null -ne $context["includeDirectories"]) {
        $includeDirs = @($context["includeDirectories"])
    }
    foreach ($root in $geminiWorkspaceRoots) {
        if ($includeDirs -notcontains $root) { $includeDirs += $root }
    }
    $context["includeDirectories"] = $includeDirs
    if (-not $settings.Contains("tools") -or $null -eq $settings["tools"]) {
        $settings["tools"] = [ordered]@{}
    }
    $tools = $settings["tools"]
    if (-not ($tools -is [System.Collections.IDictionary])) {
        $newTools = [ordered]@{}
        foreach ($prop in $tools.PSObject.Properties) {
            $newTools[$prop.Name] = $prop.Value
        }
        $tools = $newTools
        $settings["tools"] = $tools
    }
    $sandboxAllowedPaths = @()
    if ($tools.Contains("sandboxAllowedPaths") -and $null -ne $tools["sandboxAllowedPaths"]) {
        $sandboxAllowedPaths = @($tools["sandboxAllowedPaths"])
    }
    foreach ($root in $geminiWorkspaceRoots) {
        if ($sandboxAllowedPaths -notcontains $root) { $sandboxAllowedPaths += $root }
    }
    $tools["sandboxAllowedPaths"] = $sandboxAllowedPaths
    $tools["sandboxNetworkAccess"] = $true
    if (-not $settings.Contains("security") -or $null -eq $settings["security"]) {
        $settings["security"] = [ordered]@{}
    }
    $security = $settings["security"]
    if (-not ($security -is [System.Collections.IDictionary])) {
        $newSecurity = [ordered]@{}
        foreach ($prop in $security.PSObject.Properties) {
            $newSecurity[$prop.Name] = $prop.Value
        }
        $security = $newSecurity
        $settings["security"] = $security
    }
    if (-not $security.Contains("auth") -or $null -eq $security["auth"]) {
        $security["auth"] = [ordered]@{}
    }
    $auth = $security["auth"]
    if (-not ($auth -is [System.Collections.IDictionary])) {
        $newAuth = [ordered]@{}
        foreach ($prop in $auth.PSObject.Properties) {
            $newAuth[$prop.Name] = $prop.Value
        }
        $auth = $newAuth
        $security["auth"] = $auth
    }
    $auth["selectedType"] = "gemini-api-key"
    if (-not $settings.Contains("model") -or $null -eq $settings["model"]) {
        $settings["model"] = [ordered]@{}
    }
    $model = $settings["model"]
    if (-not ($model -is [System.Collections.IDictionary])) {
        $newModel = [ordered]@{}
        foreach ($prop in $model.PSObject.Properties) {
            $newModel[$prop.Name] = $prop.Value
        }
        $model = $newModel
        $settings["model"] = $model
    }
    $model["name"] = "gemini-3.1-flash-lite"
    $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $geminiSettings
    Write-Ok "Gemini: defaults set (auto_edit + workspace roots + gemini-3.1-flash-lite API-key auth)"
}

function Ensure-GeminiCrossCheckSetup { # GEMINI_CROSS_CHECK_SETUP
    if (-not (Get-Command gemini -ErrorAction SilentlyContinue)) {
        Write-Warn "Gemini cross-check: gemini CLI not found - install Gemini, then rerun setup"
        return
    }
    $script = Join-Path $DotfilesDir "scripts\setup-gemini-cross-check.ps1"
    if (-not (Test-Path $script)) {
        Write-Warn "Gemini cross-check: setup script missing at $script"
        return
    }

    $secret = Join-Path $HOME ".config\ea\gemini-api-key.dpapi"
    $shim = Join-Path $HOME ".local\bin\gemini.cmd"
    $ready = $env:GEMINI_API_KEY -or ((Test-Path $secret) -and (Test-Path $shim))
    if ($ready) {
        Write-Ok "Gemini cross-check setup present"
        return
    }

    Write-Warn "Gemini cross-check setup incomplete - launching installer"
    try {
        & powershell -ExecutionPolicy Bypass -File $script
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Gemini cross-check setup incomplete; rerun: powershell -ExecutionPolicy Bypass -File $script"
        }
    }
    catch {
        Write-Warn "Gemini cross-check setup incomplete; rerun: powershell -ExecutionPolicy Bypass -File $script"
    }
}

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
        # Courier runs ONLY on the mail host (macOS, login keychain). Windows is always a
        # client that reaches it over http, so syncing courier's Python deps here is wasted
        # work (and a misleading "deps synced") - skip it. (ADR-0002 review.)
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

    # Courier is per-ROLE (ADR-0002). Initialize-CourierClientToken + Register-CourierMcp
    # are defined in manifest.ps1 (dot-sourced at the top) so setup AND sync share ONE copy.
    # Windows is always a courier CLIENT (no macOS login keychain) -> the http path.
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
                Register-CourierMcp $Cli $cmd.Source
                & $cmd.Source mcp add --scope=user docgen --env "PYTHONPATH=$DocgenSrc" --env "PLAYWRIGHT_BROWSERS_PATH=$DocgenBrowsers" -- uv run --project $DocgenPath --no-sync python -m docgen.server | Out-Null
                & $cmd.Source mcp add --scope=user calendar --env "PYTHONPATH=$CalendarSrc" -- uv run --project $CalendarPath --no-sync python -m ea_calendar.server | Out-Null
            }
            "codex" {
                & $cmd.Source mcp add nexus -- node $NexusServer | Out-Null
                Register-CourierMcp $Cli $cmd.Source
                & $cmd.Source mcp add docgen --env "PYTHONPATH=$DocgenSrc" --env "PLAYWRIGHT_BROWSERS_PATH=$DocgenBrowsers" -- uv run --project $DocgenPath --no-sync python -m docgen.server | Out-Null
                & $cmd.Source mcp add calendar --env "PYTHONPATH=$CalendarSrc" -- uv run --project $CalendarPath --no-sync python -m ea_calendar.server | Out-Null
            }
            "gemini" {
                & $cmd.Source mcp add --scope user nexus node $NexusServer | Out-Null
                Register-CourierMcp $Cli $cmd.Source
                & $cmd.Source mcp add --scope user docgen --env "PYTHONPATH=$DocgenSrc" --env "PLAYWRIGHT_BROWSERS_PATH=$DocgenBrowsers" uv run --project $DocgenPath --no-sync python -m docgen.server | Out-Null
                & $cmd.Source mcp add --scope user calendar --env "PYTHONPATH=$CalendarSrc" uv run --project $CalendarPath --no-sync python -m ea_calendar.server | Out-Null
            }
        }
        Write-Ok "$Cli`: global MCP wired (nexus + courier + docgen + calendar)"
    }

    if (Test-Path $NexusServer) {
        Initialize-CourierClientToken   # Windows is always a courier CLIENT (ADR-0002)
        Register-GlobalMcp "claude"
        Register-GlobalMcp "codex"
        Register-GlobalMcp "gemini"
    }

    function Test-CalendarHealth {
        if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { return }
        if (-not (Test-Path $CalendarPath)) { return }
        $oldPyPath = $env:PYTHONPATH
        $env:PYTHONPATH = $CalendarSrc
        & uv run --project $CalendarPath --no-sync python -m ea_calendar.cli status --check-events --quiet *> $null
        $healthExit = $LASTEXITCODE
        $env:PYTHONPATH = $oldPyPath
        if ($healthExit -eq 0) {
            Write-Ok "Calendar: authenticated as michaelgallo.va@gmail.com"
        }
        else {
            Write-Warn "Calendar: not authenticated or health check failed - run: python -m ea_calendar.cli login"
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
                $trust[(Resolve-Path $repo.Target).Path] = "TRUST_FOLDER"
            }
        }
        foreach ($root in @("$HOME\Documents", "$HOME\Downloads", "$HOME\.dotfiles", "$HOME\.codex", "$HOME\.claude", "$HOME\.gemini", "$HOME\.config\nvim")) {
            if (Test-Path $root) {
                $trust[(Resolve-Path $root).Path] = "TRUST_FOLDER"
            }
        }

        $trust | ConvertTo-Json -Depth 4 | Set-Content -Path $trustFile
        Write-Ok "Gemini: trusted managed repo + workspace folders"
    }
    Trust-GeminiManagedRepos
    Set-AgentDefaults
    Ensure-GeminiCrossCheckSetup

    # Wire repo-local git hooks (coding-mastermind pre-commit gate) for managed repos
    # that ship a tracked .githooks dir. core.hooksPath is per-clone LOCAL config, so it
    # does NOT travel with the repo and must be set here. Idempotent. Mirror of
    # wire_repo_hooks in setup.sh (parity-checked: scripts/ci/check-parity.py).
    function Wire-RepoHooks {
        $targets = @($DotfilesDir)
        foreach ($repo in $Repos) { $targets += $repo.Target }
        foreach ($path in $targets) {
            if (-not (Test-Path (Join-Path $path ".githooks"))) { continue }
            $current = (& git -C $path config --get core.hooksPath 2>$null)
            if ($current -eq ".githooks") {
                Write-Ok "git hooks already wired in $path"
            }
            else {
                & git -C $path config core.hooksPath .githooks
                Write-Ok "Wired core.hooksPath in $path"
            }
        }
    }
    Wire-RepoHooks
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

    # Generate Codex + Gemini combined rule bundles from ALL global-rules/*.md.
    # Mirror of regen_combined_agent_rules in manifest.sh (parity-checked). Replaces a
    # prior symlink with a generated file; backs up a hand-edited copy; marks the result
    # read-only so an agent's Edit fails fast (edit the SOURCE rules, not the copy).
    function Regen-CombinedAgentRules {
        if (-not (Test-Path $GlobalRulesDir)) {
            Write-Warn "combined-rules: no global-rules dir at $GlobalRulesDir"; return
        }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("<!-- AUTO-GENERATED by dotfiles from $GlobalRulesDir. Edit the source rule files, not this copy. -->`n`n")
        foreach ($f in (Get-ChildItem -Path $GlobalRulesDir -Filter *.md | Sort-Object Name)) {
            [void]$sb.Append((Get-Content -Raw -Path $f.FullName))
            [void]$sb.Append("`n`n")
        }
        $content = $sb.ToString()
        foreach ($tgt in $CombinedRulesTargets) {
            New-Item -ItemType Directory -Path (Split-Path $tgt -Parent) -Force | Out-Null
            if ((Test-Path $tgt) -and ((Get-Item $tgt).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                Remove-Item $tgt -Force
            }
            if ((Test-Path $tgt) -and ((Get-Content -Raw -Path $tgt) -ne $content)) {
                Copy-Item $tgt "$tgt.sync-backup" -Force
                Write-Warn "combined-rules: $tgt differed from source; backed up to $tgt.sync-backup"
            }
            if (Test-Path $tgt) { Set-ItemProperty -Path $tgt -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
            [System.IO.File]::WriteAllText($tgt, $content, (New-Object System.Text.UTF8Encoding $false))
            Set-ItemProperty -Path $tgt -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
            Write-Ok "combined-rules: generated $tgt (read-only; edit the global-rules source)"
        }
    }
    Regen-CombinedAgentRules

    # Wire the stacked-push guard into the per-machine Claude settings.json (PreToolUse).
    # The SCRIPT rides the global-hooks symlink wired above; the REGISTRATION is machine-
    # local. Mirror of setup.sh (parity-checked). The guard script is bash; on Windows it
    # runs via git-bash, so the command invokes bash explicitly.
    $settingsPath = "$HOME\.claude\settings.json"
    $guardCmd = "bash `"$HOME/.claude/hooks/warn-stacked-git-push.sh`""
    if (Test-Path $settingsPath) {
        $cfg = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($cfg.hooks -and $cfg.hooks.PreToolUse) {
            Write-Ok "stacked-push guard already wired in settings.json"
        }
        else {
            Copy-Item $settingsPath "$settingsPath.bak" -Force
            if (-not $cfg.hooks) {
                Add-Member -InputObject $cfg -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $preEntry = @([pscustomobject]@{ matcher = "Bash"; hooks = @([pscustomobject]@{ type = "command"; command = $guardCmd }) })
            Add-Member -InputObject $cfg.hooks -NotePropertyName PreToolUse -NotePropertyValue $preEntry -Force
            $cfg | ConvertTo-Json -Depth 12 | Set-Content -Path $settingsPath
            Write-Ok "Wired stacked-push guard into settings.json"
        }
    }
    else {
        Write-Warn "stacked-push guard: no settings.json - wire manually"
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
