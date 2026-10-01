# check-sync-commit.ps1 - INV-20, PowerShell half (bash half: check-sync-commit.sh).
#
# Hermetic: throwaway repos and a bare origin driven through the real manifest.ps1. Asserts that
# Invoke-PullKeepingChanges pops only a stash it made (an older stash survives an untracked-only
# pull; a tracked edit comes back), that Test-UsableCommitMessage accepts only a clean exit with one
# non-empty line, and that sync.ps1 uses both with no bare stash pop. Runs under pwsh 7 and
# Windows PowerShell 5.1 in CI.
#   -RevertTest   swaps in the old bare stash/pop and empty-only check; the fixtures must then FAIL.
param([switch]$RevertTest)
# Continue, not Stop: Windows PowerShell 5.1 turns redirected native stderr into errors.
$ErrorActionPreference = 'Continue'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Fail = $false
function Write-Ok   { param($msg) }
function Write-Warn { param($msg) }
function Write-Err  { param($msg) }
function Expect { param($name, [bool]$cond) if ($cond) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name"; $script:Fail = $true } }

function Invoke-Fixtures {
    $T = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-commit-" + [guid]::NewGuid())
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@example.com'
    $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@example.com'
    Push-Location ([System.IO.Path]::GetTempPath())
    try {
        . (Join-Path $Root 'manifest.ps1')
        if ($RevertTest) {
            function Invoke-PullKeepingChanges { git stash -q 2>$null; git pull -q --ff-only 2>$null; git stash pop -q 2>$null }
            function Test-UsableCommitMessage { param($Message, [int]$ExitCode) return [bool]$Message }
        }
        $origin = Join-Path $T 'origin.git'; $work = Join-Path $T 'work'; $other = Join-Path $T 'other'
        New-Item -ItemType Directory -Path $T -Force | Out-Null
        git -c init.defaultBranch=main init -q --bare $origin 2>$null
        git clone -q $origin $work 2>$null
        git clone -q $origin $other 2>$null
        function Push-Upstream { param($Name)
            Push-Location $other
            git pull -q origin main 2>$null
            Set-Content -Path $Name -Value $Name
            git add $Name 2>$null; git commit -qm $Name 2>$null; git push -q origin HEAD:main 2>$null
            Pop-Location
        }
        Set-Location $work
        Set-Content -Path f -Value base
        git add f 2>$null; git commit -qm one 2>$null; git push -q origin HEAD:main 2>$null
        git branch -q --set-upstream-to=origin/main 2>$null

        Set-Content -Path f -Value set-aside
        git stash push -q -m older 2>$null
        $older = git rev-parse refs/stash
        Set-Content -Path untracked.txt -Value new
        Push-Upstream g1
        Invoke-PullKeepingChanges
        Expect "an older stash survives an untracked-only pull" ((git rev-parse -q --verify refs/stash) -eq $older)
        Expect "the older stash is not applied" ((Get-Content f) -eq 'base')
        Expect "the pull fast-forwarded" (Test-Path g1)
        Expect "untracked changes are kept" (Test-Path untracked.txt)

        Set-Content -Path f -Value local
        Push-Upstream g2
        Invoke-PullKeepingChanges
        Expect "a tracked edit comes back after the pull" ((Get-Content f) -eq 'local')
        Expect "the pull fast-forwarded past a tracked edit" (Test-Path g2)
        Expect "only the older stash remains" (@(git stash list).Count -eq 1)

        Expect "a logged-out claude is not a message" (-not (Test-UsableCommitMessage 'Not logged in · Please run /login' 1))
        Expect "a clean one-line reply is a message" (Test-UsableCommitMessage 'Not logged in · Please run /login' 0)
        Expect "an empty reply is not a message" (-not (Test-UsableCommitMessage $null 0))
        Expect "a blank reply is not a message" (-not (Test-UsableCommitMessage '   ' 0))
        Expect "a multi-line reply is not a message" (-not (Test-UsableCommitMessage @('line one', 'line two') 0))

        $sync = Get-Content (Join-Path $Root 'sync.ps1')
        Expect "sync pulls through Invoke-PullKeepingChanges" ([bool]($sync | Where-Object { $_ -match '^\s*Invoke-PullKeepingChanges\s*$' }))
        Expect "sync checks the message and its exit code" ([bool]($sync | Where-Object { $_ -match 'Test-UsableCommitMessage \$msg \$msgExit' }))
        Expect "sync has no bare stash pop" (-not ($sync | Where-Object { $_ -match 'git stash pop' }))
    }
    finally {
        Pop-Location
        Remove-Item -Path $T -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "check-sync-commit (ps1): fixtures$(if ($RevertTest) { ' (revert test)' })"
Invoke-Fixtures
if ($RevertTest) {
    if ($script:Fail) { Write-Host "revert-test ok: the old stash/pop and message check fail the fixtures"; exit 0 }
    Write-Host "revert-test FAILED: the old stash/pop and message check still pass"; exit 1
}
if ($script:Fail) { Write-Host "check-sync-commit (ps1): FAILED"; exit 1 }
Write-Host "check-sync-commit (ps1) OK"
