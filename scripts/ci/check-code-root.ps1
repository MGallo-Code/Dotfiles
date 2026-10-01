# check-code-root.ps1 - GalloGrid split, PowerShell half (bash half: check-code-root.sh).
#
# Hermetic: dot-sources the real manifest.ps1, then points $CodeRootNew/$CodeRootOld and
# $RetiredProjectMcpFiles at a throwaway tree ($HOME is read-only in PowerShell). Asserts that
# Resolve-CodeRoot picks GalloGrid only when the machine's switch file says so, or when EA no
# longer holds the code (a clone alone never switches), warning when neither holds service code,
# and that Remove-RetiredProjectMcp removes EA's generated docgen-only .mcp.json and keeps any
# other. Runs under pwsh 7 and Windows PowerShell 5.1 in CI.
#   -RevertTest   makes Resolve-CodeRoot switch as soon as GalloGrid is cloned; the fixtures must then FAIL.
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
        $CodeRootSwitch = Join-Path $T 'config\dotfiles\code-root'
        if ($RevertTest) { function Resolve-CodeRoot { if (Test-Path (Join-Path $CodeRootNew '.git')) { return $CodeRootNew } return $CodeRootOld } }

        New-Item -ItemType Directory -Path (Join-Path $CodeRootOld 'nexus') -Force | Out-Null
        Expect "no GalloGrid: EA" ((Resolve-CodeRoot) -eq $CodeRootOld)
        New-Item -ItemType Directory -Path (Join-Path $CodeRootNew 'nexus'), (Join-Path $CodeRootNew '.git') -Force | Out-Null
        Expect "GalloGrid cloned, no switch: still EA" ((Resolve-CodeRoot) -eq $CodeRootOld)
        New-Item -ItemType Directory -Path (Split-Path $CodeRootSwitch -Parent) -Force | Out-Null
        Set-Content -Path $CodeRootSwitch -Value 'GalloGrid'
        Expect "switch says GalloGrid: GalloGrid" ((Resolve-CodeRoot) -eq $CodeRootNew)
        Remove-Item -Path $CodeRootSwitch -Force
        Remove-Item -Path (Join-Path $CodeRootOld 'nexus') -Recurse -Force
        Expect "EA without code, GalloGrid cloned: GalloGrid" ((Resolve-CodeRoot) -eq $CodeRootNew)
        Remove-Item -Path $CodeRootNew -Recurse -Force
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
    if ($script:Fail) { Write-Host "revert-test ok: a switch-on-clone resolver fails the fixtures"; exit 0 }
    Write-Host "revert-test FAILED: a switch-on-clone resolver still passes"; exit 1
}
if ($script:Fail) { Write-Host "check-code-root (ps1): FAILED"; exit 1 }
Write-Host "check-code-root (ps1) OK"
