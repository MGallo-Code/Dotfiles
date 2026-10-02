# check-code-root.ps1 - GalloGrid split, PowerShell half (bash half: check-code-root.sh).
#
# Hermetic: dot-sources the real manifest.ps1, then points $WorkspaceDir/$LegacyRepoHome and
# $RetiredProjectMcpFiles at a throwaway tree ($HOME is read-only in PowerShell). Asserts that
# Resolve-CodeRoot is wherever GalloGrid is (ADR-0007: ~\Workspace, or the old home while a move is
# pending), and that Remove-RetiredProjectMcp removes EA's generated docgen-only .mcp.json and keeps
# any other. Runs under pwsh 7 and Windows PowerShell 5.1 in CI.
#   -RevertTest   makes Resolve-CodeRoot ignore a pending old home; the fixtures must then FAIL.
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
        $WorkspaceDir = Join-Path $T 'Workspace'
        $LegacyRepoHome = Join-Path $T 'Documents'
        $RetiredProjectMcpFiles = @(Join-Path $WorkspaceDir 'EA\.mcp.json')
        if ($RevertTest) { function Resolve-CodeRoot { return (Join-Path $WorkspaceDir 'GalloGrid') } }

        $new = Join-Path $WorkspaceDir 'GalloGrid'; $pending = Join-Path $LegacyRepoHome 'GalloGrid'
        Expect "no GalloGrid anywhere (a client): the Workspace path" ((Resolve-CodeRoot) -eq $new)
        New-Item -ItemType Directory -Path (Join-Path $pending '.git') -Force | Out-Null
        Expect "move pending: the old home" ((Resolve-CodeRoot) -eq $pending)
        New-Item -ItemType Directory -Path (Join-Path $new '.git') -Force | Out-Null
        Expect "a stray clone at the new home switches nothing" ((Resolve-CodeRoot) -eq $pending)
        Remove-Item -Recurse -Force $pending
        Expect "moved: the Workspace home" ((Resolve-CodeRoot) -eq $new)

        $mcp = Join-Path $WorkspaceDir 'EA\.mcp.json'
        New-Item -ItemType Directory -Path (Split-Path $mcp -Parent) -Force | Out-Null
        Set-Content -Path $mcp -Value '{"mcpServers":{"docgen":{"command":"uv","args":["run","--project","x","python","-m","docgen.server"]}}}'
        Remove-RetiredProjectMcp
        Expect "generated docgen-only .mcp.json removed" (-not (Test-Path $mcp))
        Set-Content -Path $mcp -Value '{"mcpServers":{"docgen":{"args":["docgen.server"]},"mine":{"command":"x"}}}'
        Remove-RetiredProjectMcp
        Expect "edited .mcp.json kept" (Test-Path $mcp)

        # Clients never build or run the central services (2026-10-01): Windows builds nexus only
        # before the cutover, syncs no courier/calendar deps, and wires with docgen alone.
        $NexusRemoted = $true
        Expect "a remoted client does not build nexus" (-not (Test-NeedsLocalNexus))
        $NexusRemoted = $false
        Expect "a pre-cutover client builds nexus" (Test-NeedsLocalNexus)
        $NexusRemoted = $true
        $NexusServer = Join-Path $T 'none\server.js'
        $DocgenPath = Join-Path $T 'docgen'
        New-Item -ItemType Directory -Path $DocgenPath -Force | Out-Null
        Expect "a client wires with docgen and no nexus build" (Test-McpWiringReady)
        Remove-Item -Path $DocgenPath -Recurse -Force
        Expect "a client without docgen skips the wiring" (-not (Test-McpWiringReady))
        foreach ($f in @('sync.ps1', 'setup.ps1')) {
            $lines = Get-Content (Join-Path $Root $f)
            $i = ($lines | Select-String -SimpleMatch 'npm run build' | Select-Object -First 1).LineNumber - 1
            $before = $lines[[Math]::Max(0, $i - 14)..$i] | Where-Object { $_ -notmatch '^\s*#' }
            Expect "$f builds nexus only under Test-NeedsLocalNexus" ([bool]($before | Where-Object { $_ -match 'Test-NeedsLocalNexus' }))
            Expect "$f syncs no calendar deps" (-not ($lines | Where-Object { $_ -match 'Push-Location \$CalendarPath' }))
            Expect "$f gates the wiring on Test-McpWiringReady" ([bool]($lines | Where-Object { $_ -match '^\s*if \(Test-McpWiringReady\)' }))
        }
    }
    finally {
        Remove-Item -Path $T -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "check-code-root (ps1): fixtures$(if ($RevertTest) { ' (revert test)' })"
Invoke-Fixtures
if ($RevertTest) {
    if ($script:Fail) { Write-Host "revert-test ok: a resolver blind to the pending old home fails the fixtures"; exit 0 }
    Write-Host "revert-test FAILED: a resolver blind to the pending old home still passes"; exit 1
}
if ($script:Fail) { Write-Host "check-code-root (ps1): FAILED"; exit 1 }
Write-Host "check-code-root (ps1) OK"
