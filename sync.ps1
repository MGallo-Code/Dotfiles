# Sync all managed repos - pull updates, detect local changes, hand off to Claude for commits

$DotfilesDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$DotfilesDir\manifest.ps1"

function Write-Ok   { param($msg) Write-Host "[ok] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "[error] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "[info] $msg" -ForegroundColor Cyan }

$Updated  = @()
$Pushed   = @()
$Dirty    = @()
$Diverged = @()
$Missing  = @()

function Sync-Repo {
    param([string]$Target)
    $name = Split-Path $Target -Leaf

    if (-not (Test-Path "$Target\.git")) {
        $script:Missing += $name
        Write-Warn "$name`: not found at $Target"
        return
    }

    Push-Location $Target

    git fetch origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$name`: fetch failed"
        Pop-Location
        return
    }

    $local  = git rev-parse "@"
    $remote = git rev-parse "@{u}" 2>$null
    $base   = git merge-base "@" "@{u}" 2>$null
    $dirty  = git status --porcelain

    if ($dirty) {
        $script:Dirty += $name
        Write-Info "$name`: has uncommitted changes"
        git status --short
        Pop-Location
        return
    }

    if (-not $remote) {
        Write-Warn "$name`: no upstream set"
        Pop-Location
        return
    }

    if ($local -eq $remote) {
        Write-Ok "$name`: up to date"
    }
    elseif ($local -eq $base) {
        git pull --ff-only 2>$null
        if ($LASTEXITCODE -eq 0) {
            $script:Updated += $name
            Write-Ok "$name`: pulled updates"
        }
        else {
            $script:Diverged += $name
            Write-Err "$name`: pull failed"
        }
    }
    elseif ($remote -eq $base) {
        git push 2>$null
        if ($LASTEXITCODE -eq 0) {
            $script:Pushed += $name
            Write-Ok "$name`: pushed to remote"
        }
        else {
            Write-Err "$name`: push failed"
        }
    }
    else {
        $script:Diverged += $name
        Write-Err "$name`: diverged from remote - manual resolution needed"
    }

    Pop-Location
}

# ── Sync dotfiles repo itself ────────────────────────────────────────
Write-Host "`n==> Syncing dotfiles" -ForegroundColor Green
Sync-Repo $DotfilesDir

# ── Sync manifest repos ─────────────────────────────────────────────
Write-Host "`n==> Syncing managed repos" -ForegroundColor Green
foreach ($repo in $Repos) {
    Sync-Repo $repo.Target
}

# ── Verify symlinks ─────────────────────────────────────────────────
Write-Host "`n==> Checking symlinks" -ForegroundColor Green
foreach ($link in $Symlinks) {
    $target = $link.Target
    $source = $link.Source
    $name = Split-Path $target -Leaf

    if ((Test-Path $target) -and ((Get-Item $target).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Write-Ok "$name`: linked correctly"
    }
    elseif (Test-Path $target) {
        Write-Warn "$name`: exists but wrong symlink"
    }
    else {
        Write-Warn "$name`: missing"
    }
}

# ── Summary ──────────────────────────────────────────────────────────
Write-Host "`n==> Summary" -ForegroundColor Green
if ($Updated.Count -gt 0)  { Write-Ok "Updated: $($Updated -join ', ')" }
if ($Pushed.Count -gt 0)   { Write-Ok "Pushed: $($Pushed -join ', ')" }
if ($Diverged.Count -gt 0) { Write-Err "Diverged (manual fix): $($Diverged -join ', ')" }
if ($Missing.Count -gt 0)  { Write-Warn "Missing: $($Missing -join ', ')" }

# ── Handle dirty repos with Claude ──────────────────────────────────
if ($Dirty.Count -gt 0) {
    Write-Host ""
    Write-Warn "Dirty repos: $($Dirty -join ', ')"
    Write-Host ""

    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeCmd) {
        $answer = Read-Host "Launch Claude to commit and push changes? (y/n)"
        if ($answer -eq "y") {
            $summary = "The following repos have uncommitted changes: $($Dirty -join ', ')."
            foreach ($name in $Dirty) {
                $repo = $Repos | Where-Object { (Split-Path $_.Target -Leaf) -eq $name }
                if ($repo) {
                    Push-Location $repo.Target
                    $diff = git diff --stat 2>$null
                    $summary += " $name ($($repo.Target)): $diff"
                    Pop-Location
                }
            }

            # Hand off to Claude in first dirty repo
            foreach ($name in $Dirty) {
                $repo = $Repos | Where-Object { (Split-Path $_.Target -Leaf) -eq $name }
                if ($repo) {
                    Push-Location $repo.Target
                    & claude -p "These repos have uncommitted changes: $($Dirty -join ', '). For this repo ($name), review the changes with git diff and git status, commit with a clear message, and push. Then tell me which other repos still need attention."
                    Pop-Location
                    break
                }
            }
        }
    }
    else {
        Write-Host "Claude Code not available. Commit and push manually:"
        foreach ($name in $Dirty) { Write-Host "  - $name" }
    }
}

Write-Host ""
