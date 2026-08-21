# INV-14 PowerShell behavior gate. Runs only in a disposable Windows CI account.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Launcher = Join-Path $Root "shell/windows/ea.ps1"
$Diagnostic = Join-Path $Root "scripts/workspace-access-diagnostics.py"
$Python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $Python) { $Python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $Python) { throw "check-workspace-access: Python is required" }

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    throw "check-workspace-access: ea.ps1 parse failure: $($parseErrors[0].Message)"
}

& $Python.Source $Diagnostic --self-test
if ($LASTEXITCODE -ne 0) { throw "check-workspace-access: diagnostic self-test failed on Windows" }

$OriginalLocation = (Get-Location).Path
$Fixture = Join-Path ([IO.Path]::GetTempPath()) ("workspace-access-" + [guid]::NewGuid().ToString("N"))
$Start = Join-Path $Fixture "start"
$Untrusted = Join-Path $Fixture "untrusted"
$TrustedEa = Join-Path $HOME "Documents/EA"
$TrustedWiki = Join-Path $HOME "Documents/Wiki"
$EaBacking = Join-Path $Fixture "ea-backing"
$CreatedTrusted = [System.Collections.Generic.List[string]]::new()
$global:WorkspaceAccessTrace = [System.Collections.Generic.List[string]]::new()
$global:RemoveCallerPath = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "check-workspace-access: $Message" }
}

function global:claude {
    $global:WorkspaceAccessTrace.Add("cli=claude")
    $global:WorkspaceAccessTrace.Add("cwd=$((Get-Location).Path)")
    foreach ($arg in $args) { $global:WorkspaceAccessTrace.Add("arg=$arg") }
    if ($global:RemoveCallerPath) {
        Remove-Item -LiteralPath $global:RemoveCallerPath -Force
        $global:RemoveCallerPath = $null
    }
    $global:LASTEXITCODE = 23
}

function global:codex {
    $global:WorkspaceAccessTrace.Add("cli=codex")
    $global:WorkspaceAccessTrace.Add("cwd=$((Get-Location).Path)")
    foreach ($arg in $args) { $global:WorkspaceAccessTrace.Add("arg=$arg") }
    $global:LASTEXITCODE = 0
}

try {
    foreach ($path in @($TrustedEa, $TrustedWiki)) {
        if (Test-Path -LiteralPath $path) {
            throw "check-workspace-access: refusing to alter pre-existing fixture path $path"
        }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $CreatedTrusted.Add($path)
    }
    New-Item -ItemType Directory -Path $Start, $Untrusted -Force | Out-Null
    . $Launcher

    Set-Location -LiteralPath $Start
    ea --claude marker
    Assert-True ($LASTEXITCODE -eq 23) "Claude exit status was not preserved"
    Assert-True ((Get-Location).Path -eq $Start) "Claude launch did not restore caller cwd"
    foreach ($expected in @("cli=claude", "cwd=$TrustedEa", "arg=--permission-mode", "arg=bypassPermissions", "arg=marker")) {
        Assert-True ($global:WorkspaceAccessTrace.Contains($expected)) "Claude trace missing '$expected'"
    }

    $global:WorkspaceAccessTrace.Clear()
    wiki --codex marker
    Assert-True ($LASTEXITCODE -eq 0) "Codex exit status was not preserved"
    Assert-True ((Get-Location).Path -eq $Start) "Codex launch did not restore caller cwd"
    foreach ($expected in @("cli=codex", "cwd=$TrustedWiki", "arg=--sandbox", "arg=danger-full-access", "arg=--ask-for-approval", "arg=never", "arg=marker")) {
        Assert-True ($global:WorkspaceAccessTrace.Contains($expected)) "Codex trace missing '$expected'"
    }

    $global:WorkspaceAccessTrace.Clear()
    Invoke-WsLaunch $Untrusted --claude
    Assert-True ($LASTEXITCODE -eq 64) "unnamed root did not fail with status 64"
    Assert-True ($global:WorkspaceAccessTrace.Count -eq 0) "unnamed root invoked an agent"

    $global:WorkspaceAccessTrace.Clear()
    wiki --codex --cd $Untrusted
    Assert-True ($LASTEXITCODE -eq 64) "Codex cwd override did not fail with status 64"
    Assert-True ($global:WorkspaceAccessTrace.Count -eq 0) "Codex cwd override invoked an agent"

    Move-Item -LiteralPath $TrustedEa -Destination $EaBacking
    New-Item -ItemType Junction -Path $TrustedEa -Target $Untrusted | Out-Null
    $global:WorkspaceAccessTrace.Clear()
    ea --claude
    Assert-True ($LASTEXITCODE -eq 64) "redirected trusted root did not fail with status 64"
    Assert-True ($global:WorkspaceAccessTrace.Count -eq 0) "redirected trusted root invoked an agent"
    Remove-Item -LiteralPath $TrustedEa -Force
    Move-Item -LiteralPath $EaBacking -Destination $TrustedEa

    $TransientCaller = Join-Path $Fixture "transient-caller"
    New-Item -ItemType Directory -Path $TransientCaller | Out-Null
    Set-Location -LiteralPath $TransientCaller
    $global:RemoveCallerPath = $TransientCaller
    ea --claude
    Assert-True ($LASTEXITCODE -eq 74) "lost caller cwd did not fail with status 74"
    Assert-True ((Get-Location).Path -eq $HOME) "lost caller cwd did not recover to HOME"
    $LatestReport = Get-Content (Join-Path $HOME ".local/state/michael-workspace-access/latest.json") -Raw | ConvertFrom-Json
    Assert-True ($LatestReport.caller_cwd_restore_failed -eq $true) "lost caller cwd was not recorded"
    Assert-True ($LatestReport.primary_category -eq "inaccessible_cwd_or_file_provider") "lost caller cwd was misclassified"

    Remove-Item -LiteralPath $TrustedEa -Force
    [void]$CreatedTrusted.Remove($TrustedEa)
    ea --claude
    Assert-True ($LASTEXITCODE -eq 74) "missing trusted root did not fail with status 74"
    Assert-True ((Get-Location).Path -eq $HOME) "missing trusted root did not recover to HOME"

    Write-Host "check-workspace-access PowerShell OK"
} finally {
    Set-Location -LiteralPath $OriginalLocation
    foreach ($path in $CreatedTrusted) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    if (Test-Path -LiteralPath $EaBacking) { Remove-Item -LiteralPath $EaBacking -Recurse -Force }
    if (Test-Path -LiteralPath $Fixture) { Remove-Item -LiteralPath $Fixture -Recurse -Force }
    Remove-Item Function:\claude, Function:\codex -ErrorAction SilentlyContinue
}
