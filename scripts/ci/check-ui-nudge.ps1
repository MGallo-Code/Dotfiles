# check-ui-nudge.ps1 - INV-19, PowerShell half (bash half: check-ui-nudge.sh).
#
# Hermetic: dot-sources the real manifest.ps1. $HOME is read-only in PowerShell, so the test runs
# Ensure-ClaudeHook's own body with $HOME swapped for a throwaway home's path.
# Asserts the UI-workflow nudge is registered once by exact command and unrelated hooks are kept.
#   -RevertTest   swaps in a do-nothing Ensure-ClaudeHook; the fixtures must then FAIL.
param([switch]$RevertTest)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Fail = $false
function Write-Ok   { param($msg) }
function Write-Warn { param($msg) }
function Write-Err  { param($msg) }
function Expect { param($name, [bool]$cond) if ($cond) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name"; $script:Fail = $true } }

function Invoke-Fixtures {
    $T = Join-Path ([System.IO.Path]::GetTempPath()) ("ui-nudge-" + [guid]::NewGuid())
    try {
        . (Join-Path $Root 'manifest.ps1')
        $fakeHome = Join-Path $T 'home'
        New-Item -ItemType Directory -Path (Join-Path $fakeHome '.claude') -Force | Out-Null
        $settings = Join-Path $fakeHome '.claude\settings.json'
        Set-Content -Path $settings -Value '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"}]}]}}'
        # Run the real function's body with $HOME pointing at the throwaway home.
        $body = (Get-Command Ensure-ClaudeHook).ScriptBlock.ToString() -replace '\$HOME', '$fakeHome'
        if ($RevertTest) { $body = 'param($HookEvent, $Matcher, $Command, $Label)' }
        $fn = [scriptblock]::Create($body)
        & $fn -HookEvent PostToolUse -Matcher "Edit|Write|MultiEdit" -Command $UiNudgeHookCmd -Label "UI-workflow nudge"
        & $fn -HookEvent PostToolUse -Matcher "Edit|Write|MultiEdit" -Command $UiNudgeHookCmd -Label "UI-workflow nudge"
        $cfg = Get-Content $settings -Raw | ConvertFrom-Json
        $mine = @($cfg.hooks.PostToolUse | ForEach-Object { @($_.hooks) } | Where-Object { $_.command -eq $UiNudgeHookCmd })
        Expect "registered exactly once" ($mine.Count -eq 1)
        Expect "unrelated hook kept" (@($cfg.hooks.PreToolUse)[0].hooks[0].command -eq 'guard.sh')
        Expect "matcher set" ((@($cfg.hooks.PostToolUse)[0].matcher) -eq 'Edit|Write|MultiEdit')
    }
    finally {
        Remove-Item -Path $T -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "check-ui-nudge (ps1): fixtures$(if ($RevertTest) { ' (revert test)' })"
Invoke-Fixtures
if ($RevertTest) {
    if ($script:Fail) { Write-Host "revert-test ok: a do-nothing helper fails the fixtures"; exit 0 }
    Write-Host "revert-test FAILED: a do-nothing helper still passes"; exit 1
}
if ($script:Fail) { Write-Host "check-ui-nudge (ps1): FAILED"; exit 1 }
Write-Host "check-ui-nudge (ps1) OK"
