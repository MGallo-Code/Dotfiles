# check-ask.ps1 - INV-26 (ADR-0011), PowerShell half of the registration (check-ask.py covers the
# rest, on every OS).
#
# Hermetic: dot-sources the real manifest.ps1. $HOME is read-only in PowerShell, so Ensure-ClaudeHook
# is rebuilt from its own body with $HOME swapped for a throwaway home's path, then the real
# Register-AskGuard runs twice. Asserts ask-guard is registered once on the question card and once
# on Stop, unrelated hooks kept, and that setup and sync turn on Codex's question card.
#   -RevertTest   swaps in a do-nothing Register-AskGuard; the fixtures must then FAIL.
param([switch]$RevertTest)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Fail = $false
function Write-Ok   { param($msg) }
function Write-Warn { param($msg) }
function Write-Err  { param($msg) }
function Expect { param($name, [bool]$cond) if ($cond) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name"; $script:Fail = $true } }

function Invoke-Fixtures {
    $T = Join-Path ([System.IO.Path]::GetTempPath()) ("check-ask-" + [guid]::NewGuid())
    try {
        . (Join-Path $Root 'manifest.ps1')
        $fakeHome = Join-Path $T 'home'
        New-Item -ItemType Directory -Path (Join-Path $fakeHome '.claude') -Force | Out-Null
        $settings = Join-Path $fakeHome '.claude\settings.json'
        Set-Content -Path $settings -Value '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"}]}]}}'
        $body = (Get-Command Ensure-ClaudeHook).ScriptBlock.ToString() -replace '\$HOME', '$fakeHome'
        Set-Item -Path function:Ensure-ClaudeHook -Value ([scriptblock]::Create($body))
        if ($RevertTest) { Set-Item -Path function:Register-AskGuard -Value { } }
        Register-AskGuard
        Register-AskGuard
        $cfg = Get-Content $settings -Raw | ConvertFrom-Json
        $card = @($cfg.hooks.PreToolUse | Where-Object { @($_.hooks | Where-Object { $_.command -eq $AskGuardHookCmd }).Count -gt 0 })
        $stop = @($cfg.hooks.Stop | Where-Object { @($_.hooks | Where-Object { $_.command -eq $AskGuardHookCmd }).Count -gt 0 })
        Expect "question card: registered exactly once" ($card.Count -eq 1)
        Expect "question card: matcher AskUserQuestion" ($card.Count -eq 1 -and $card[0].matcher -eq 'AskUserQuestion')
        Expect "Stop: registered exactly once" ($stop.Count -eq 1)
        Expect "unrelated hook kept" (@($cfg.hooks.PreToolUse)[0].hooks[0].command -eq 'guard.sh')
        # Codex writes an "under development" warning to stderr on every run; under Windows PowerShell
        # with $ErrorActionPreference Stop that must not abort setup. A stand-in native codex does it.
        $bin = Join-Path $T 'bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            Set-Content -Path (Join-Path $bin 'codex.cmd') -Value "@echo Under-development features enabled 1>&2`r`n@exit /b 0"
        } else {
            Set-Content -Path (Join-Path $bin 'codex') -Value "#!/bin/sh`necho 'Under-development features enabled' >&2`nexit 0"
            chmod +x (Join-Path $bin 'codex')
        }
        $oldPath = $env:PATH
        $env:PATH = $bin + [System.IO.Path]::PathSeparator + $env:PATH
        $ErrorActionPreference = 'Stop'
        $threw = $false
        try { Enable-CodexQuestionCard } catch { $threw = $true }
        finally { $env:PATH = $oldPath }
        Expect "Codex's stderr warning does not abort setup" (-not $threw)
        foreach ($f in 'setup.ps1', 'sync.ps1') {
            $text = Get-Content (Join-Path $Root $f) -Raw
            Expect "$f turns on the Codex card, then registers ask-guard, before the agent integrations" ($text -match 'Enable-CodexQuestionCard\s*\r?\n\s*Register-AskGuard\s*\r?\n\s*Set-AgentIntegrations')
        }
    }
    finally {
        Remove-Item -Path $T -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "check-ask (ps1): fixtures$(if ($RevertTest) { ' (revert test)' })"
Invoke-Fixtures
if ($RevertTest) {
    if ($script:Fail) { Write-Host "revert-test ok: a do-nothing Register-AskGuard fails the fixtures"; exit 0 }
    Write-Host "revert-test FAILED: a do-nothing Register-AskGuard still passes"; exit 1
}
if ($script:Fail) { Write-Host "check-ask (ps1): FAILED"; exit 1 }
Write-Host "check-ask (ps1) OK"
