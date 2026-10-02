# workspace-migration.ps1 - ADR-0007: the synced repos leave ~\Documents for ~\Workspace (INV-21).
# Windows twin of workspace-migration.sh. Dot-sourced by manifest.ps1; uses its $Workspace* settings,
# Write-Ok and Write-Warn. Path rewriting is shared with the bash side: ws_paths.py.
#
# Move-ToWorkspace            move each repo once (all or nothing), repair worktrees, rewrite git config,
#                             Codex paths and Claude memory keys, drop venvs that name the old path, park
#                             retired clones; journal every step; $false on any skip
# Set-PendingWorkspacePaths   point this run's lists at the old home while a move is pending
# Get-WorkspaceHome NAME      where repo NAME lives on this machine right now
# Undo-WorkspaceMigration     replay the journal in reverse (scripts\workspace-rollback.ps1)
#
# Windows is never the MCP host: a "host" repo (GalloGrid) is parked, never moved, and nothing defers.

$WsPathsPy = Join-Path $PSScriptRoot "ws_paths.py"
# The home the migration works in; $HOME is read-only in PowerShell, so tests point this elsewhere.
$WsHome = $HOME

function Get-WsPython {
    foreach ($name in @("python3", "python", "py")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        $out = & $cmd.Source -c "print(1)" 2>$null
        if ($LASTEXITCODE -eq 0 -and "$out".Trim() -eq "1") { return $cmd.Source }
    }
    return $null
}

function Invoke-WsPaths {
    $py = Get-WsPython
    if (-not $py) { throw "workspace: no working Python for ws_paths.py" }
    $out = & $py $WsPathsPy @args 2>$null
    if ($LASTEXITCODE -ne 0) { throw "workspace: ws_paths.py $($args[0]) failed" }
    return @($out | Where-Object { "$_" -ne "" })
}

# Every machine moves only when armed: its gate file says "now" (mirror of workspace_move_deferred).
function Test-WorkspaceMoveDeferred {
    if (-not (Test-Path -LiteralPath $WorkspaceMoveGate)) { return $true }
    return ((Get-Content -Raw -LiteralPath $WorkspaceMoveGate).Trim() -ne "now")
}

function Get-WorkspaceHome {
    param([string]$Name)
    $new = Join-Path $WorkspaceDir $Name
    $old = Join-Path $LegacyRepoHome $Name
    # The old home wins while it still holds the repo (mirror of workspace_home): a stray clone or an
    # empty folder at the new home never switches anything.
    if (Test-Path -LiteralPath (Join-Path $old ".git")) { return $old }
    return $new
}

# Point this run's repo lists at the old home for every move still pending (a blocked move, so setup
# never clones a second copy next to it). Edits the list entries in place.
function Set-PendingWorkspacePaths {
    foreach ($m in $WorkspaceMoves) {
        $old = Join-Path $LegacyRepoHome $m.Name
        if ((Get-WorkspaceHome $m.Name) -ne $old) { continue }
        $new = Join-Path $WorkspaceDir $m.Name
        foreach ($r in @($Repos + $HostRepos)) {
            if ($r.Target -ieq $new -or $r.Target.StartsWith($new + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $r.Target = $old + $r.Target.Substring($new.Length)
            }
        }
        foreach ($ps in $CodexProjectSkills) {
            if ($ps.Dir.StartsWith($new + '\', [StringComparison]::OrdinalIgnoreCase)) { $ps.Dir = $old + $ps.Dir.Substring($new.Length) }
        }
    }
}

function Add-WsJournal {
    param([string]$Line)
    $dir = Split-Path $WorkspaceJournal -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $WorkspaceJournal -Value $Line -Encoding UTF8
}

function Get-WsOwnerRepo {
    param([string]$Url)
    $u = ($Url.Trim() -replace '/+$', '') -replace '\.git$', ''
    if ($u -match '([^/:]+)/([^/:]+)$') { return ("$($Matches[1])/$($Matches[2])").ToLower() }
    return $u.ToLower()
}

function Test-WsSameRemote {
    param([string]$Dir, [string]$Remote)
    $url = git -C $Dir remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $url) { return $false }
    return ((Get-WsOwnerRepo "$url") -eq (Get-WsOwnerRepo $Remote))
}

# A rename and back: fails while any process has the folder (or a file in it) open, which is exactly
# when a real move would fail halfway.
function Test-WsMovable {
    param([string]$Dir)
    $probe = "$Dir.ws-probe"
    try { [IO.Directory]::Move($Dir, $probe) } catch { return $false }
    try { [IO.Directory]::Move($probe, $Dir); return $true }
    catch {
        Write-Warn "workspace: $Dir is parked at $probe and could not be renamed back ($($_.Exception.Message)) - rename it back by hand before anything else"
        return $false
    }
}

function Update-WsPathsInFile {
    param([string]$File, [string]$Old, [string]$New)
    if (-not (Test-Path -LiteralPath $File)) { return }
    $n = (Invoke-WsPaths rewrite $File $Old $New | Select-Object -First 1)
    if ([int]$n -gt 0) { Add-WsJournal "rewrite|$File|$Old|$New"; Write-Ok "workspace: $n path(s) in $File point at $New" }
}

function Move-WsOne {
    param([string]$Old, [string]$New)
    $ErrorActionPreference = 'Continue'   # setup.ps1 runs with Stop; nothing after the move may abort it
    $oldFwd = $Old -replace '\\', '/'
    $inside = @()
    foreach ($line in @(git -C $Old worktree list --porcelain 2>$null)) {
        if ($line -like "worktree $oldFwd/*") { $inside += ($New + ($line.Substring(9 + $oldFwd.Length) -replace '/', '\')) }
    }
    $parent = Split-Path $New -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    try { [IO.Directory]::Move($Old, $New) } catch { Write-Warn "workspace: could not move $Old ($($_.Exception.Message))"; return $false }
    Add-WsJournal "repo|$Old|$New"; Write-Ok "workspace: moved $Old -> $New"
    $ok = $true
    try {
        git -C $New worktree repair @inside 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "workspace: git worktree repair reported a problem in $New (run it there by hand)" }
    } catch { Write-Warn "workspace: git worktree repair failed in $New ($($_.Exception.Message))"; $ok = $false }
    $configs = @(Join-Path $New ".git\config") + @(Get-ChildItem (Join-Path $New ".git\worktrees") -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName "config.worktree" })
    foreach ($f in @($configs) + @(Join-Path $WsHome ".codex\config.toml")) {
        try { Update-WsPathsInFile $f $Old $New } catch { Write-Warn "workspace: could not re-point paths in $f ($($_.Exception.Message))"; $ok = $false }
    }
    try {
        foreach ($line in (Invoke-WsPaths memory (Join-Path $WsHome ".claude\projects") $Old $New)) {
            if ($line -like "memory|*") { Add-WsJournal $line; Write-Ok "workspace: Claude memory $(Split-Path $line -Leaf)" }
            elseif ($line -like "warn|*") { Write-Warn "workspace: $($line.Substring(5))" }
        }
    } catch { Write-Warn "workspace: could not move Claude memory for $Old ($($_.Exception.Message))"; $ok = $false }
    try {
        foreach ($v in (Invoke-WsPaths venvs $New $Old)) {
            Remove-Item -LiteralPath $v -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok "workspace: removed $v (it named the old path; it rebuilds on next use)"
        }
    } catch { Write-Warn "workspace: could not check venvs in $New ($($_.Exception.Message))" }
    return $ok
}

# Park a clone that retires instead of moving, only when nothing in it is uncommitted, unpushed or
# stashed and (with $Imported, the commit dotfiles imported) nothing in it or on its origin is newer.
function Invoke-WsRetireClone {
    param([string]$Remote, [string]$Old, [string]$Imported = "")
    $ErrorActionPreference = 'Continue'
    if (-not (Test-Path -LiteralPath (Join-Path $Old ".git"))) { return $true }
    if (-not (Test-WsSameRemote $Old $Remote)) { Write-Warn "workspace: $Old is not a clone of $Remote - left as is"; return $false }
    git -C $Old fetch -q 2>$null | Out-Null
    if ($Imported) {
        foreach ($ref in @("HEAD", "refs/remotes/origin/main")) {
            git -C $Old rev-parse -q --verify $ref 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { continue }
            git -C $Old merge-base --is-ancestor $ref $Imported 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "workspace: $Old has commits after the dotfiles import ($Imported) on $ref - kept; fold them in (git subtree pull), then re-run sync"
                return $false
            }
        }
    }
    $dirty = @(git -C $Old status --porcelain 2>$null).Count -gt 0
    $unpushed = @(git -C $Old log --branches --not --remotes --oneline 2>$null).Count -gt 0
    $stashed = @(git -C $Old stash list 2>$null).Count -gt 0
    if ($dirty -or $unpushed -or $stashed) {
        Write-Warn "workspace: $Old has uncommitted, unpushed or stashed work - kept; push or clear it, then re-run sync"
        return $false
    }
    $dest = Join-Path $RetiredCloneDir ("{0}-{1}" -f (Split-Path $Old -Leaf), (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $RetiredCloneDir -Force | Out-Null
    try { [IO.Directory]::Move($Old, $dest) } catch { Write-Warn "workspace: $Old is in use - kept; close it, then re-run sync"; return $false }
    Add-WsJournal "park|$Old|$dest"; Write-Ok "workspace: retired $Old -> $dest (its ignored files came along; check them before deleting it)"
    return $true
}

function Move-ToWorkspace {
    $ErrorActionPreference = 'Continue'   # setup.ps1 runs with Stop; a move must never abort halfway
    $blocked = $false
    $pending = New-Object System.Collections.Generic.List[object]
    $retire = New-Object System.Collections.Generic.List[object]
    Push-Location $WsHome   # never hold a repo open ourselves
    try {
        foreach ($m in $WorkspaceMoves) {
            $old = Join-Path $LegacyRepoHome $m.Name
            $new = Join-Path $WorkspaceDir $m.Name
            if ($m.Scope -eq "host") {
                if (Test-Path -LiteralPath (Join-Path $old ".git")) { $retire.Add(@($m.Remote, $old, "")) }
                continue
            }
            if (-not (Test-Path -LiteralPath (Join-Path $old ".git"))) { continue }
            if (Test-Path -LiteralPath $new) {
                Write-Warn "workspace: both $old and $new exist - left as is; keep one and move or remove the other by hand"
                $blocked = $true; continue
            }
            if (-not (Test-WsSameRemote $old $m.Remote)) { Write-Warn "workspace: $old is not a clone of $($m.Remote) - not moved"; $blocked = $true; continue }
            $pending.Add(@($old, $new))
        }
        foreach ($c in $WorkspaceRetiredClones) {
            $old = Join-Path $LegacyRepoHome $c.Name
            if (Test-Path -LiteralPath (Join-Path $old ".git")) { $retire.Add(@($c.Remote, $old, $c.Imported)) }
        }
        if (Test-WorkspaceMoveDeferred) {
            if (($pending.Count + $retire.Count) -gt 0) {
                Write-Ok "workspace: waiting for this machine's move ($($pending.Count + $retire.Count) repo(s) still in $LegacyRepoHome); arm it with: Set-Content $WorkspaceMoveGate now"
            }
            return (-not $blocked)
        }
        $leftover = @(Get-ChildItem -LiteralPath $LegacyRepoHome -Directory -Filter "*.ws-probe" -ErrorAction SilentlyContinue)
        if ($leftover.Count -gt 0) {
            Write-Warn "workspace: a probe rename was left behind ($($leftover.FullName -join ', ')) - rename it back by hand, then re-run"
            return $false
        }
        if ($pending.Count -gt 0) {
            $preflight = $true
            if (-not (Get-WsPython)) { Write-Warn "workspace: no working Python for the path rewrites - nothing moved"; $preflight = $false }
            foreach ($p in $pending) {
                if (-not (Test-WsMovable $p[0])) { Write-Warn "workspace: $($p[0]) is in use (a shell, editor or agent in it) - close it, then re-run"; $preflight = $false }
            }
            if ($preflight) {
                foreach ($p in $pending) { if (-not (Move-WsOne $p[0] $p[1])) { $blocked = $true } }
            } else {
                Write-Warn "workspace: nothing moved (the repos move together or not at all)"; $blocked = $true
            }
        }
        foreach ($r in $retire) {
            if (-not (Invoke-WsRetireClone $r[0] $r[1] $r[2])) { $blocked = $true }
        }
        # The switch file goes only once nothing here is still waiting to move (mirror of the bash side).
        if ((Test-Path -LiteralPath $RetiredCodeRootSwitch) -and -not $blocked) {
            Add-WsJournal "switch|$RetiredCodeRootSwitch|$((Get-Content -Raw $RetiredCodeRootSwitch).Trim())"
            Remove-Item -LiteralPath $RetiredCodeRootSwitch -Force
            Write-Ok "workspace: retired the code-root switch file"
        }
    } finally { Pop-Location }
    return (-not $blocked)
}

function Undo-WorkspaceMigration {
    $ErrorActionPreference = 'Continue'
    if (-not (Test-Path -LiteralPath $WorkspaceJournal)) { Write-Warn "workspace rollback: no journal at $WorkspaceJournal - nothing to undo"; return $false }
    Push-Location $WsHome
    try {
        $lines = @(Get-Content -LiteralPath $WorkspaceJournal)
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            $f = $line -split '\|'
            switch ($f[0]) {
                "rewrite" { if (Test-Path -LiteralPath $f[1]) { Invoke-WsPaths rewrite $f[1] $f[3] $f[2] | Out-Null; Write-Ok "rollback: paths in $($f[1]) back to $($f[2])" } }
                "memory"  { if ((Test-Path -LiteralPath $f[2]) -and -not (Test-Path -LiteralPath $f[1])) { [IO.Directory]::Move($f[2], $f[1]) } }
                "repo"    {
                    if ((Test-Path -LiteralPath $f[2]) -and -not (Test-Path -LiteralPath $f[1])) {
                        [IO.Directory]::Move($f[2], $f[1]); git -C $f[1] worktree repair 2>$null | Out-Null
                        Write-Ok "rollback: moved $($f[2]) -> $($f[1])"
                    } else { Write-Warn "rollback: $($f[2]) missing or $($f[1]) exists - $($f[1]) not restored" }
                }
                "park"    { if ((Test-Path -LiteralPath $f[2]) -and -not (Test-Path -LiteralPath $f[1])) { [IO.Directory]::Move($f[2], $f[1]); Write-Ok "rollback: restored $($f[1])" } }
                "switch"  { Set-Content -LiteralPath $f[1] -Value $f[2]; Write-Ok "rollback: restored $($f[1])" }
            }
        }
        Move-Item -LiteralPath $WorkspaceJournal -Destination ("$WorkspaceJournal.rolled-back-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        Write-Warn "rollback: inside-repo worktrees need 'git worktree repair <path>' if listed broken; removed venvs rebuild on use"
    } finally { Pop-Location }
    return $true
}
