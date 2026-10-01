# check-moved-links.ps1 - ADR-0006 cutover, PowerShell half (bash half: check-moved-links.sh).
#
# Hermetic: dot-sources the real manifest.ps1, then points $Symlinks, the skill target dirs and
# $MovedLinkSources at a throwaway tree ($HOME is read-only in PowerShell). Asserts that
# Update-MovedLinks repoints symlinks AND junctions under an old prefix, live or dangling, keeps
# the old target itself, leaves unrelated links, real dirs and links with no new counterpart
# alone, and that the sync verify helpers (Get-LinkItem / Get-LinkTargetPath) read the result.
# Runs under pwsh 7 and Windows PowerShell 5.1 in CI.
#   -RevertTest   empties $MovedLinkSources; the fixtures must then FAIL.
# Exit 0 = all assertions hold, 1 = a regression.
param([switch]$RevertTest)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Fail = $false
$script:Log = [System.Collections.Generic.List[string]]::new()
function Write-Ok   { param($msg) $script:Log.Add("[ok] $msg") }
function Write-Warn { param($msg) $script:Log.Add("[!] $msg") }
function Write-Err  { param($msg) $script:Log.Add("[error] $msg") }
function Expect { param($name, [bool]$cond) if ($cond) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name"; $script:Fail = $true } }
function Target-Of { param($path) $item = Get-LinkItem $path; if ($item) { return (Get-LinkTargetPath $item) } return $null }

function Invoke-Fixtures {
    $T = Join-Path ([System.IO.Path]::GetTempPath()) ("moved-links-" + [guid]::NewGuid())
    try {
        . (Join-Path $Root 'manifest.ps1')
        $old = Join-Path $T 'old\claude-config'
        $new = Join-Path $T 'new\claude-config'
        $claude = Join-Path $T 'claude'
        $skillsA = Join-Path $T 'claude\skills'
        $skillsB = Join-Path $T 'codex\skills'
        foreach ($d in @('global-rules', 'global-hooks', 'global-commands', 'global-agents', 'global-skills\calendar')) {
            New-Item -ItemType Directory -Path (Join-Path $old $d), (Join-Path $new $d) -Force | Out-Null
        }
        New-Item -ItemType Directory -Path (Join-Path $old 'global-skills\ghost'), $skillsA, $skillsB, (Join-Path $T 'elsewhere'), (Join-Path $claude 'realdir') -Force | Out-Null
        Set-Content -Path (Join-Path $claude 'realdir\keep.md') -Value 'keep'

        # Override AFTER dot-sourcing, in this scope: Update-MovedLinks reads them from its caller.
        $Symlinks = @(
            @{ Source = (Join-Path $new 'global-rules');    Target = (Join-Path $claude 'rules') }
            @{ Source = (Join-Path $new 'global-hooks');    Target = (Join-Path $claude 'hooks') }
            @{ Source = (Join-Path $new 'global-commands'); Target = (Join-Path $claude 'commands') }
            @{ Source = (Join-Path $new 'global-agents');   Target = (Join-Path $claude 'agents') }
            @{ Source = (Join-Path $new 'global-agents');   Target = (Join-Path $claude 'realdir') }
        )
        $AgentSkillsTargets = @($skillsA, $skillsB)
        $ProjectSkillsTargets = @($skillsB)
        $MovedLinkSources = if ($RevertTest) { @() } else { @(@{ Old = $old; New = $new }) }

        New-Item -ItemType SymbolicLink -Path (Join-Path $claude 'rules') -Target (Join-Path $old 'global-rules') | Out-Null   # live symlink
        New-Item -ItemType Junction -Path (Join-Path $claude 'hooks') -Target (Join-Path $old 'global-hooks') | Out-Null       # live junction
        New-Item -ItemType SymbolicLink -Path (Join-Path $claude 'commands') -Target (Join-Path $old 'global-commands') | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $claude 'agents') -Target (Join-Path $old 'global-agents') | Out-Null
        Remove-Item -Path (Join-Path $old 'global-commands'), (Join-Path $old 'global-agents') -Recurse -Force             # both now dangling
        New-Item -ItemType Junction -Path (Join-Path $skillsA 'calendar') -Target (Join-Path $old 'global-skills\calendar') | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $skillsB 'ghost') -Target (Join-Path $old 'global-skills\ghost') | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $skillsA 'other') -Target (Join-Path $T 'elsewhere') | Out-Null

        Update-MovedLinks
        Update-MovedLinks   # idempotent

        Expect "live symlink repointed" ((Target-Of (Join-Path $claude 'rules')) -ieq (Join-Path $new 'global-rules'))
        Expect "live junction repointed" ((Target-Of (Join-Path $claude 'hooks')) -ieq (Join-Path $new 'global-hooks'))
        Expect "dangling symlink repointed" ((Target-Of (Join-Path $claude 'commands')) -ieq (Join-Path $new 'global-commands'))
        Expect "dangling junction repointed" ((Target-Of (Join-Path $claude 'agents')) -ieq (Join-Path $new 'global-agents'))
        Expect "skill junction repointed" ((Target-Of (Join-Path $skillsA 'calendar')) -ieq (Join-Path $new 'global-skills\calendar'))
        Expect "repointed link resolves" (Test-Path (Join-Path $claude 'commands'))
        Expect "link with no new counterpart left as is" ((Target-Of (Join-Path $skillsB 'ghost')) -ieq (Join-Path $old 'global-skills\ghost'))
        Expect "missing counterpart warned" ([bool]($script:Log | Where-Object { $_ -like '*ghost*missing*' }))
        Expect "unrelated link untouched" ((Target-Of (Join-Path $skillsA 'other')) -ieq (Join-Path $T 'elsewhere'))
        Expect "real dir untouched" ((Test-Path (Join-Path $claude 'realdir\keep.md')) -and -not (Get-LinkItem (Join-Path $claude 'realdir')))
        Expect "old target itself kept" (Test-Path (Join-Path $old 'global-rules'))
        Expect "no errors" (-not [bool]($script:Log | Where-Object { $_ -like '[error]*' }))
    }
    finally {
        Remove-Item -Path $T -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "check-moved-links (ps1): fixtures$(if ($RevertTest) { ' (revert test)' })"
Invoke-Fixtures
if ($RevertTest) {
    if ($script:Fail) { Write-Host "revert-test ok: an empty `$MovedLinkSources fails the fixtures"; exit 0 }
    Write-Host "revert-test FAILED: with `$MovedLinkSources empty the fixtures still pass"; exit 1
}
if ($script:Fail) { Write-Host "check-moved-links (ps1): FAILED"; exit 1 }
Write-Host "check-moved-links (ps1) OK"
