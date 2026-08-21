# EA-specific shell commands (PowerShell)

# ── Agent runner ─────────────────────────────────────────────────────
# Named Michael Workspace launchers are the trust boundary. Direct internal-helper calls fail
# closed, and permission-policy overrides use the raw agent CLIs instead.
$script:MichaelWorkspaceDotfiles = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:MichaelWorkspaceDiagnostic = Join-Path $script:MichaelWorkspaceDotfiles "scripts/workspace-access-diagnostics.py"
$script:MichaelWorkspacePython = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $script:MichaelWorkspacePython) { $script:MichaelWorkspacePython = Get-Command python -ErrorAction SilentlyContinue }

function Test-WsTrustedRoot {
    param([string]$Dir)
    $trusted = @(
        (Join-Path $HOME ".dotfiles"),
        (Join-Path $HOME "Documents/EA"),
        (Join-Path $HOME "Documents/Wiki"),
        (Join-Path $HOME "Documents/SBIC")
    )
    return $trusted -contains $Dir
}

function Test-WsRootRedirected {
    param([string]$Dir)
    $paths = @($HOME, $Dir)
    if ($Dir.StartsWith((Join-Path $HOME "Documents"), [System.StringComparison]::OrdinalIgnoreCase)) {
        $paths = @($HOME, (Join-Path $HOME "Documents"), $Dir)
    }
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        }
    }
    return $false
}

function Test-WsSafeTrustedRoot {
    param([string]$Dir)
    return (Test-WsTrustedRoot $Dir) -and -not (Test-WsRootRedirected $Dir)
}

function Test-WsPolicyOverride {
    param([string]$Cli, [object[]]$Rest)
    foreach ($arg in $Rest) {
        $text = [string]$arg
        if ($Cli -eq "claude" -and ($text -eq "--permission-mode" -or $text.StartsWith("--permission-mode=") -or $text -eq "--dangerously-skip-permissions" -or $text -eq "--safe-mode")) {
            return $true
        }
        if ($Cli -eq "codex" -and ($text -in @("--sandbox", "-s", "--ask-for-approval", "-a", "--dangerously-bypass-approvals-and-sandbox") -or $text.StartsWith("--sandbox=") -or $text.StartsWith("--ask-for-approval=") -or $text.StartsWith("-s") -or $text.StartsWith("-a"))) {
            return $true
        }
    }
    return $false
}

function Test-WsScopeOverride {
    param([string]$Cli, [object[]]$Rest)
    foreach ($arg in $Rest) {
        $text = [string]$arg
        if ($Cli -eq "codex" -and (
            $text -in @("-C", "--cd", "--add-dir", "-c", "--config", "-p", "--profile", "--remote") -or
            $text.StartsWith("-C") -or $text.StartsWith("-c") -or $text.StartsWith("-p") -or
            $text.StartsWith("--cd=") -or $text.StartsWith("--add-dir=") -or
            $text.StartsWith("--config=") -or $text.StartsWith("--profile=") -or
            $text.StartsWith("--remote=")
        )) { return $true }
    }
    return $false
}

function Invoke-AgentRun {
    param([string]$Cli, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    $r = @($Rest)
    if ($env:MICHAEL_WORKSPACE_TRUSTED_LAUNCH -ne "1" -or
        -not $env:MICHAEL_WORKSPACE_TRUSTED_ROOT -or
        -not (Test-WsSafeTrustedRoot $env:MICHAEL_WORKSPACE_TRUSTED_ROOT) -or
        (Get-Location).Path -ne $env:MICHAEL_WORKSPACE_TRUSTED_ROOT) {
        Write-Warning "workspace launcher: refusing autonomous $Cli outside a named trusted root"
        $global:LASTEXITCODE = 64
        return
    }
    if (Test-WsPolicyOverride $Cli $r) {
        Write-Warning "workspace launcher: permission-policy overrides are not accepted; invoke $Cli directly"
        $global:LASTEXITCODE = 64
        return
    }
    if (Test-WsScopeOverride $Cli $r) {
        Write-Warning "workspace launcher: cwd, writable-root, profile, config, and remote overrides require raw $Cli"
        $global:LASTEXITCODE = 64
        return
    }
    switch ($Cli) {
        "claude" { & claude --permission-mode bypassPermissions @r }
        "codex"  { & codex --sandbox danger-full-access --ask-for-approval never @r }
        "gemini" { & gemini --yolo @r }
        default  { Write-Warning "workspace launcher: unsupported agent: $Cli"; $global:LASTEXITCODE = 64 }
    }
}

function Get-WsRequestedPolicy {
    param([string]$Cli)
    switch ($Cli) {
        "claude" { return "bypassPermissions" }
        "codex"  { return "sandbox=danger-full-access,approval=never" }
        "gemini" { return "yolo" }
        default  { return "unverified" }
    }
}

function Test-WsAccess {
    param([string]$Dir, [ValidateSet("enumerate", "full")][string]$Mode = "full")
    if (-not $script:MichaelWorkspacePython) { return $false }
    & $script:MichaelWorkspacePython.Source $script:MichaelWorkspaceDiagnostic probe --path $Dir --mode $Mode --timeout 3 *> $null
    return $LASTEXITCODE -eq 0
}

function Write-WsCapture {
    param(
        [string]$Dir,
        [string]$Phase,
        [string]$Cli,
        [string]$Policy,
        [Nullable[int]]$AgentStatus = $null,
        [string]$Symptom = "filesystem",
        [switch]$CallerCwdRestoreFailed,
        [switch]$Quiet
    )
    $captureArgs = @(
        $script:MichaelWorkspaceDiagnostic, "capture", "--path", $Dir, "--home", $HOME,
        "--phase", $Phase, "--agent", $Cli, "--requested-policy", $Policy,
        "--symptom", $Symptom, "--timeout", "3"
    )
    if ($null -ne $AgentStatus) { $captureArgs += @("--agent-status", [string]$AgentStatus) }
    if ($CallerCwdRestoreFailed) { $captureArgs += "--caller-cwd-restore-failed" }
    if (-not $script:MichaelWorkspacePython) { return $false }
    if ($Quiet) { & $script:MichaelWorkspacePython.Source @captureArgs *> $null } else { & $script:MichaelWorkspacePython.Source @captureArgs }
    return $LASTEXITCODE -eq 0
}

function Move-WsHomeAfterFailure {
    try {
        Set-Location -LiteralPath $HOME -ErrorAction Stop
        Write-Warning "workspace launcher: access failed; recovered the parent shell to HOME"
    } catch {
        Write-Warning "workspace launcher: access failed and HOME is inaccessible; open a fresh shell and run wsdoctor"
    }
}

# ── Workspace launchers ──────────────────────────────────────────────
# Set-Location into a workspace root and open an agent. An optional FIRST flag picks the CLI:
#   --claude (default) | --codex | --gemini ; remaining args pass through.
function Invoke-WsLaunch {
    param([string]$Dir, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    $r = @($Rest)   # force array: a remaining-args param is $null when empty
    $cli = "claude"
    if ($r.Count -ge 1) {
        switch ($r[0]) {
            "--claude" { $cli = "claude"; $r = @($r | Select-Object -Skip 1) }
            "--codex"  { $cli = "codex";  $r = @($r | Select-Object -Skip 1) }
            "--gemini" { $cli = "gemini"; $r = @($r | Select-Object -Skip 1) }
        }
    }
    if (-not (Test-WsSafeTrustedRoot $Dir)) {
        Write-Warning "workspace launcher: refusing unnamed or redirected root: $Dir"
        $global:LASTEXITCODE = 64
        return
    }
    if (-not (Test-WsAccess $Dir "full")) {
        Write-WsCapture $Dir "preflight" $cli (Get-WsRequestedPolicy $cli) | Out-Null
        Move-WsHomeAfterFailure
        $global:LASTEXITCODE = 74
        return
    }

    $previousLaunch = $env:MICHAEL_WORKSPACE_TRUSTED_LAUNCH
    $previousRoot = $env:MICHAEL_WORKSPACE_TRUSTED_ROOT
    $locationPushed = $false
    $callerRestoreFailed = $false
    # TRUSTED_WORKSPACE_SUBSHELL: Push/Pop confines the agent cwd and restores the caller.
    try {
        Push-Location -LiteralPath $Dir -ErrorAction Stop
        $locationPushed = $true
        $env:MICHAEL_WORKSPACE_TRUSTED_LAUNCH = "1"
        $env:MICHAEL_WORKSPACE_TRUSTED_ROOT = $Dir
        Invoke-AgentRun $cli @r
        $agentStatus = $LASTEXITCODE
    } catch {
        Write-Warning $_
        $agentStatus = 74
    } finally {
        $env:MICHAEL_WORKSPACE_TRUSTED_LAUNCH = $previousLaunch
        $env:MICHAEL_WORKSPACE_TRUSTED_ROOT = $previousRoot
        if ($locationPushed) {
            try { Pop-Location -ErrorAction Stop } catch {
                $callerRestoreFailed = $true
                Set-Location -LiteralPath $HOME -ErrorAction SilentlyContinue
            }
        }
    }

    $policy = Get-WsRequestedPolicy $cli
    $trustedCallerFailed = (Test-WsSafeTrustedRoot (Get-Location).Path) -and -not (Test-WsAccess (Get-Location).Path "enumerate")
    if ($callerRestoreFailed -or -not (Test-WsAccess $Dir "full") -or $trustedCallerFailed) {
        Write-WsCapture $Dir "exit" $cli $policy $agentStatus -CallerCwdRestoreFailed:$callerRestoreFailed | Out-Null
        Move-WsHomeAfterFailure
        $global:LASTEXITCODE = 74
        return
    }
    $global:LASTEXITCODE = $agentStatus
}

function ea   { Invoke-WsLaunch "$HOME\Documents\EA" @args }        # active personal ops + MCP tools
function wiki { Invoke-WsLaunch "$HOME\Documents\Wiki" @args }      # LLM-curated research
function sbic { Invoke-WsLaunch "$HOME\Documents\SBIC" @args }      # employer-only work (SBIC)

# Update the Michael Workspace SYSTEM: open an agent in the dotfiles control plane (manifest.sh
# = root/role map). Claude (default) gets the EA + agent-skills source roots added; Codex/Gemini
# already see the whole workspace via the michael_workspace profile. Same --claude/--codex/--gemini flag.
function sysupdate {
    $rest = $args
    if ($rest.Count -ge 1 -and $rest[0] -eq "--codex")  { Invoke-WsLaunch "$HOME\.dotfiles" --codex @($rest | Select-Object -Skip 1); return }
    if ($rest.Count -ge 1 -and $rest[0] -eq "--gemini") { Invoke-WsLaunch "$HOME\.dotfiles" --gemini @($rest | Select-Object -Skip 1); return }
    if ($rest.Count -ge 1 -and $rest[0] -eq "--claude") { $rest = @($rest | Select-Object -Skip 1) }
    Invoke-WsLaunch "$HOME\.dotfiles" --claude --add-dir "$HOME\Documents\EA" --add-dir "$HOME\Documents\agent-skills" @rest
}

function wsdoctor {
    param([ValidateSet("latest", "agent-read-only", "shell-message")][string]$Mode = "latest")
    if ($Mode -eq "latest") {
        if (-not $script:MichaelWorkspacePython) { Write-Warning "workspace diagnostics require Python"; return }
        & $script:MichaelWorkspacePython.Source $script:MichaelWorkspaceDiagnostic latest --home $HOME
        return
    }
    $symptom = if ($Mode -eq "agent-read-only") { "agent-read-only" } else { "shell-message" }
    Write-WsCapture (Get-Location).Path "manual" "shell" "unverified" -Symptom $symptom | Out-Null
}

# Tab-complete the agent flags for the workspace launchers.
$WsAgentCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)
    @('--claude', '--codex', '--gemini') |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterName', $_) }
}
Register-ArgumentCompleter -CommandName ea, wiki, sbic, sysupdate -ScriptBlock $WsAgentCompleter

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
