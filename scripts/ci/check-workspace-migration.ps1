# check-workspace-migration.ps1 - INV-21, PowerShell half (bash half: check-workspace-migration.sh).
#
# Hermetic: real git repos in a throwaway home, driven through the real manifest.ps1 with $WsHome and the
# $Workspace* settings pointed at it ($HOME is read-only in PowerShell). Asserts the move keeps every repo
# whole (ignored data, worktrees inside and outside, an absolute hooksPath that still fires), re-points Codex
# paths in Codex's own Windows form and Claude memory keys (never a sibling's), drops a venv naming the old
# path, parks retired clones, changes nothing on a second run, rolls back, and refuses a second copy, a repo
# held open (all or nothing) and a dirty clone. Runs under pwsh 7 and Windows PowerShell 5.1 in CI.
#   -RevertTest   plants a preflight that never sees a held-open repo; the fixtures must then FAIL.
param([switch]$RevertTest)
$ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 turns redirected native stderr into errors

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Fail = $false
function Write-Ok   { param($msg) }
function Write-Warn { param($msg) }
function Write-Err  { param($msg) }
function Expect { param($name, [bool]$cond) if ($cond) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name"; $script:Fail = $true } }

function Invoke-Fixtures {
    $T = Join-Path ([System.IO.Path]::GetTempPath()) ("ws-migrate-" + [guid]::NewGuid().ToString("N"))
    $env:GIT_CONFIG_NOSYSTEM = '1'; $env:GIT_SSH_COMMAND = 'false'
    $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@example.com'
    $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@example.com'
    Push-Location ([System.IO.Path]::GetTempPath())
    try {
        . (Join-Path $Root 'manifest.ps1')
        if ($RevertTest) { function Test-WsMovable { param([string]$Dir) return $true } }
        $H = Join-Path $T 'home'
        $WsHome = $H
        $WorkspaceDir = Join-Path $H 'Workspace'
        $LegacyRepoHome = Join-Path $H 'Documents'
        $RetiredCloneDir = Join-Path $H '.local\share\dotfiles\retired-clones'
        $WorkspaceJournal = Join-Path $H '.local\share\dotfiles\workspace-migration.journal'
        $RetiredCodeRootSwitch = Join-Path $H '.config\dotfiles\code-root'
        $WorkspaceMoveGate = Join-Path $H '.config\dotfiles\workspace-move'
        $D = $LegacyRepoHome; $W = $WorkspaceDir; $M = Join-Path $H '.claude\projects'
        function Key { param([string]$Path) return (Invoke-WsPaths key $Path | Select-Object -First 1) }

        function New-Repo { param([string]$Name, [string]$Remote)
            $bare = Join-Path $T "origin\$Name.git"
            git -c init.defaultBranch=main init -q --bare $bare 2>$null
            git clone -q $bare (Join-Path $D $Name) 2>$null
            Push-Location (Join-Path $D $Name)
            Set-Content -Path f -Value x; git add f 2>$null; git commit -qm one 2>$null; git push -q origin HEAD:main 2>$null
            git branch -q --set-upstream-to=origin/main 2>$null
            git remote set-url origin $Remote
            Pop-Location
        }
        function New-Fixture {
            if (Test-Path $T) { Remove-Item -Recurse -Force $T }
            New-Item -ItemType Directory -Path $D, $M, (Join-Path $H '.codex'), (Split-Path $RetiredCodeRootSwitch -Parent) -Force | Out-Null
            New-Repo 'EA' 'git@github:MGallo-Code/EA.git'
            New-Repo 'Wiki' 'git@github:MGallo-Code/Wiki.git'
            New-Repo 'Notes' 'https://github.com/mgallo-code/notes'
            New-Repo 'GalloGrid' 'git@github.com:MGallo-Code/GalloGrid.git'
            New-Repo 'agent-skills' 'git@github:MGallo-Code/agent-skills.git'
            $script:AsSha = (git -C (Join-Path $D 'agent-skills') rev-parse HEAD)
            $ea = Join-Path $D 'EA'
            Set-Content -Path (Join-Path $ea '.gitignore') -Value "secret/`n.venv/`n.worktrees/`n.githooks/"
            git -C $ea add .gitignore 2>$null; git -C $ea commit -qm ig 2>$null; git -C $ea push -q origin HEAD:main 2>$null
            git -C $ea update-ref refs/remotes/origin/main HEAD
            New-Item -ItemType Directory -Path (Join-Path $ea 'secret'), (Join-Path $ea 'sub'), (Join-Path $ea '.githooks'), (Join-Path $ea 'exercises\.venv\Scripts') -Force | Out-Null
            Set-Content -Path (Join-Path $ea 'secret\health.txt') -Value s
            $hookMark = (Join-Path $H 'hook-fired') -replace '\\', '/'
            [IO.File]::WriteAllText((Join-Path $ea '.githooks\post-commit'), "#!/bin/sh`ntouch '$hookMark'`n")
            git -C $ea config core.hooksPath ((Join-Path $ea '.githooks') -replace '\\', '/')
            Set-Content -Path (Join-Path $ea 'exercises\.venv\Scripts\activate') -Value "set VIRTUAL_ENV=$ea\exercises\.venv"
            git -C $ea worktree add -q (Join-Path $H '.claude-worktrees\w\EA') -b wt-out 2>$null
            git -C $ea worktree add -q (Join-Path $ea '.worktrees\in') -b wt-in 2>$null
            New-Item -ItemType Directory -Path (Join-Path $M (Key $ea)), (Join-Path $M (Key "$ea\sub")), (Join-Path $M (Key "$ea 2")) -Force | Out-Null
            $low = $ea.ToLower()
            Set-Content -Path (Join-Path $H '.codex\config.toml') -Value "[projects.'$low']`n[projects.'$low\sub']`n[projects.'$low-backing']"
            Set-Content -Path $RetiredCodeRootSwitch -Value GalloGrid
            Set-Content -Path $WorkspaceMoveGate -Value now   # armed; the unarmed case removes it
        }

        Write-Host "-- unarmed: nothing moves or retires"
        New-Fixture; Remove-Item -LiteralPath $WorkspaceMoveGate
        Expect "an unarmed client succeeds" (Move-ToWorkspace)
        Expect "and moves, parks and creates nothing" ((Test-Path (Join-Path $D 'EA\.git')) -and (Test-Path (Join-Path $D 'agent-skills\.git')) -and (Test-Path (Join-Path $D 'GalloGrid\.git')) -and -not (Test-Path $W))
        Expect "and keeps the switch file" (Test-Path $RetiredCodeRootSwitch)

        Write-Host "-- Windows client: everything moves, retires and is re-pointed (under setup.ps1's Stop mode)"
        New-Fixture
        $WorkspaceRetiredClones = @(@{ Name = "agent-skills"; Remote = "git@github:MGallo-Code/agent-skills.git"; Imported = $script:AsSha })
        $ErrorActionPreference = 'Stop'
        try { $moved = Move-ToWorkspace } catch { $moved = $false; Write-Host "  (threw: $($_.Exception.Message))" }
        $ErrorActionPreference = 'Continue'
        Expect "migration succeeds, and nothing throws under Stop" ($moved)
        Expect "EA moved to Workspace" ((Test-Path (Join-Path $W 'EA\.git')) -and -not (Test-Path (Join-Path $D 'EA')))
        Expect "Wiki and Notes moved (remote forms compared as owner/repo)" ((Test-Path (Join-Path $W 'Wiki\.git')) -and (Test-Path (Join-Path $W 'Notes\.git')))
        Expect "ignored data moved with the repo" ((Get-Content (Join-Path $W 'EA\secret\health.txt')) -eq 's')
        Expect "a worktree outside the repo still works" ((git -C (Join-Path $H '.claude-worktrees\w\EA') rev-parse --abbrev-ref HEAD 2>$null) -eq 'wt-out')
        Expect "a worktree inside the repo still works" ((git -C (Join-Path $W 'EA\.worktrees\in') rev-parse --abbrev-ref HEAD 2>$null) -eq 'wt-in')
        Expect "hooksPath points at the new home" ((git -C (Join-Path $W 'EA') config core.hooksPath) -ieq ((Join-Path $W 'EA\.githooks') -replace '\\', '/'))
        Push-Location (Join-Path $W 'EA'); Add-Content f y; git commit -qam two 2>$null; Pop-Location
        Expect "the git hook still fires" (Test-Path (Join-Path $H 'hook-fired'))
        Expect "a venv naming the old path is removed" (-not (Test-Path (Join-Path $W 'EA\exercises\.venv')))
        Expect "Claude memory follows EA and its subfolder" ((Test-Path (Join-Path $M (Key (Join-Path $W 'EA')))) -and (Test-Path (Join-Path $M (Key (Join-Path $W 'EA\sub')))))
        Expect "a sibling's memory is left alone" (Test-Path (Join-Path $M (Key ((Join-Path $D 'EA') + ' 2'))))
        $codex = Get-Content -Raw (Join-Path $H '.codex\config.toml')
        Expect "Codex paths re-pointed in Codex's own form" ($codex.Contains("'$((Join-Path $W 'EA').ToLower())'") -and $codex.Contains("'$((Join-Path $W 'EA').ToLower())\sub'"))
        Expect "a sibling path in Codex is left alone" ($codex.Contains("'$((Join-Path $D 'EA').ToLower())-backing'"))
        Expect "GalloGrid is parked (Windows is never the host)" ((-not (Test-Path (Join-Path $D 'GalloGrid'))) -and @(Get-ChildItem $RetiredCloneDir -Filter 'GalloGrid-*').Count -eq 1)
        Expect "the agent-skills clone is parked" ((-not (Test-Path (Join-Path $D 'agent-skills'))) -and @(Get-ChildItem $RetiredCloneDir -Filter 'agent-skills-*').Count -eq 1)
        Expect "the code-root switch file is retired" (-not (Test-Path $RetiredCodeRootSwitch))
        $lines = @(Get-Content $WorkspaceJournal).Count
        Expect "a second run succeeds" (Move-ToWorkspace)
        Expect "a second run changes nothing" (@(Get-Content $WorkspaceJournal).Count -eq $lines)

        Write-Host "-- rollback: the journal replays in reverse"
        Undo-WorkspaceMigration | Out-Null
        Expect "EA is back" ((Test-Path (Join-Path $D 'EA\.git')) -and -not (Test-Path (Join-Path $W 'EA')))
        Expect "its outside worktree works again" ((git -C (Join-Path $H '.claude-worktrees\w\EA') rev-parse --abbrev-ref HEAD 2>$null) -eq 'wt-out')
        Expect "Claude memory is back" (Test-Path (Join-Path $M (Key (Join-Path $D 'EA'))))
        Expect "Codex paths are back" ((Get-Content -Raw (Join-Path $H '.codex\config.toml')).Contains("'$((Join-Path $D 'EA').ToLower())'"))
        Expect "parked clones are back" ((Test-Path (Join-Path $D 'agent-skills\.git')) -and (Test-Path (Join-Path $D 'GalloGrid\.git')))
        Expect "the switch file is back" ((Get-Content $RetiredCodeRootSwitch).Trim() -eq 'GalloGrid')

        Write-Host "-- never a second copy, never a held-open repo, never a dirty retire"
        New-Fixture; New-Item -ItemType Directory -Path (Join-Path $W 'Wiki\.git') -Force | Out-Null
        Expect "both homes present: the run fails" (-not (Move-ToWorkspace))
        Expect "and the old Wiki stays" (Test-Path (Join-Path $D 'Wiki\.git'))
        New-Fixture
        $held = [IO.File]::Open((Join-Path $D 'Notes\f'), 'Open', 'Read', 'None')
        try { $ok = Move-ToWorkspace } finally { $held.Close() }
        Expect "a held-open repo fails the run" (-not $ok)
        Expect "and nothing moves (all or nothing)" ((Test-Path (Join-Path $D 'Notes\.git')) -and (Test-Path (Join-Path $D 'EA\.git')) -and -not (Test-Path (Join-Path $W 'EA')))
        New-Fixture; Set-Content -Path (Join-Path $D 'agent-skills\new.txt') -Value dirty
        Expect "a dirty clone fails the run" (-not (Move-ToWorkspace))
        Expect "and is kept in place" (Test-Path (Join-Path $D 'agent-skills\new.txt'))
        New-Fixture; $WorkspaceRetiredClones = @(@{ Name = "agent-skills"; Remote = "git@github:MGallo-Code/agent-skills.git"; Imported = $script:AsSha })
        $as = Join-Path $D 'agent-skills'
        Set-Content -Path (Join-Path $as 'g') -Value z; git -C $as add g 2>$null; git -C $as commit -qm two 2>$null; git -C $as update-ref refs/remotes/origin/main HEAD
        Expect "an agent-skills clone newer than the import fails the run" (-not (Move-ToWorkspace))
        Expect "and is kept in place" (Test-Path (Join-Path $as '.git'))
        New-Fixture; New-Item -ItemType Directory -Path (Join-Path $W 'EA') -Force | Out-Null
        Expect "a stray folder at the new home switches nothing" ((Get-WorkspaceHome 'EA') -eq (Join-Path $D 'EA'))
        New-Fixture; New-Item -ItemType Directory -Path (Join-Path $D 'EA.ws-probe') -Force | Out-Null
        Expect "a leftover rename probe stops the run" (-not (Move-ToWorkspace))
        Expect "and nothing moves" ((Test-Path (Join-Path $D 'EA\.git')) -and -not (Test-Path (Join-Path $W 'EA')))

        Write-Host "-- sync and setup call it first, and fail on a skip"
        $sync = Get-Content (Join-Path $Root 'sync.ps1'); $setup = Get-Content (Join-Path $Root 'setup.ps1')
        Expect "sync migrates" ([bool]($sync | Where-Object { $_ -match '^\$WorkspaceMoveFail = -not \(Move-ToWorkspace\)' }))
        $m = ($setup | Select-String -SimpleMatch '$WorkspaceMoveFail = -not (Move-ToWorkspace)' | Select-Object -First 1).LineNumber
        $c = ($setup | Select-String -SimpleMatch 'Write-Step "Cloning repos"' | Select-Object -First 1).LineNumber
        Expect "setup migrates before cloning" ($m -and $c -and ($m -lt $c))
    }
    finally {
        Pop-Location
        Remove-Item -Path $T -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "check-workspace-migration (ps1): fixtures$(if ($RevertTest) { ' (revert test)' })"
try { Invoke-Fixtures } catch { Write-Host "  FAIL  a fixture threw: $($_.Exception.Message)"; $script:Fail = $true }
if ($RevertTest) {
    if ($script:Fail) { Write-Host "revert-test ok: a blind preflight fails the fixtures"; exit 0 }
    Write-Host "revert-test FAILED: a blind preflight still passes"; exit 1
}
if ($script:Fail) { Write-Host "check-workspace-migration (ps1): FAILED"; exit 1 }
Write-Host "check-workspace-migration (ps1) OK"
