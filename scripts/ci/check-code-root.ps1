# check-code-root.ps1 - GalloGrid split, PowerShell half (bash half: check-code-root.sh).
#
# Hermetic: dot-sources the real manifest.ps1, then points $CodeRootNew/$CodeRootOld and
# $RetiredProjectMcpFiles at a throwaway tree ($HOME is read-only in PowerShell). Asserts that
# Resolve-CodeRoot picks GalloGrid only once it is a git checkout, else EA (warning when neither
# holds service code), and that Remove-RetiredProjectMcp removes EA's generated docgen-only
# .mcp.json and keeps any other. Runs under pwsh 7 and Windows PowerShell 5.1 in CI.
#   -RevertTest   makes Resolve-CodeRoot always answer EA; the fixtures must then FAIL.
param([switch]$RevertTest)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Fail = $false
$script:Log = [System.Collections.Generic.List[string]]::new()
function Write-Ok   { param($msg) $script:Log.Add("[ok] $msg") }
function Write-Warn { param($msg) $script:Log.Add("[!] $msg") }
function Write-Err  { param($msg) $script:Log.Add("[error] $msg") }
function Expect { param($name, [bool]$cond) if ($cond) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name"; $script:Fail = $true } }

function Invoke-Fixtures {
    $T = Join-Path ([System.IO.Path]::GetTempPath()) ("code-root-" + [guid]::NewGuid())
    try {
        . (Join-Path $Root 'manifest.ps1')
        # Override AFTER dot-sourcing, in this scope: the functions read them from their caller.
        $CodeRootNew = Join-Path $T 'GalloGrid'
        $CodeRootOld = Join-Path $T 'EA'
        $RetiredProjectMcpFiles = @(Join-Path $CodeRootOld '.mcp.json')
        if ($RevertTest) { function Resolve-CodeRoot { return $CodeRootOld } }

        New-Item -ItemType Directory -Path (Join-Path $CodeRootOld 'nexus') -Force | Out-Null
        Expect "no GalloGrid: EA" ((Resolve-CodeRoot) -eq $CodeRootOld)
        New-Item -ItemType Directory -Path (Join-Path $CodeRootNew 'nexus') -Force | Out-Null
        Expect "GalloGrid without .git: still EA" ((Resolve-CodeRoot) -eq $CodeRootOld)
        New-Item -ItemType Directory -Path (Join-Path $CodeRootNew '.git') -Force | Out-Null
        Expect "GalloGrid checkout: GalloGrid" ((Resolve-CodeRoot) -eq $CodeRootNew)
        Remove-Item -Path $CodeRootNew, (Join-Path $CodeRootOld 'nexus') -Recurse -Force
        $script:Log.Clear()
        $r = @(Resolve-CodeRoot)
        Expect "no code anywhere: one path back" (($r.Count -eq 1) -and ($r[0] -eq $CodeRootOld))
        Expect "no code anywhere: warned" ([bool]($script:Log | Where-Object { $_ -like '*no service code*' }))

        $mcp = Join-Path $CodeRootOld '.mcp.json'
        Set-Content -Path $mcp -Value '{"mcpServers":{"docgen":{"command":"uv","args":["run","--project","x","python","-m","docgen.server"]}}}'
        Remove-RetiredProjectMcp
        Expect "generated docgen-only .mcp.json removed" (-not (Test-Path $mcp))
        Set-Content -Path $mcp -Value '{"mcpServers":{"docgen":{"args":["docgen.server"]},"mine":{"command":"x"}}}'
        Remove-RetiredProjectMcp
        Expect "edited .mcp.json kept" (Test-Path $mcp)
    }
    finally {
        Remove-Item -Path $T -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "check-code-root (ps1): fixtures$(if ($RevertTest) { ' (revert test)' })"
Invoke-Fixtures
if ($RevertTest) {
    if ($script:Fail) { Write-Host "revert-test ok: an EA-only resolver fails the fixtures"; exit 0 }
    Write-Host "revert-test FAILED: an EA-only resolver still passes"; exit 1
}
if ($script:Fail) { Write-Host "check-code-root (ps1): FAILED"; exit 1 }
Write-Host "check-code-root (ps1) OK"
