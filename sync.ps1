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

    $hasClaude = [bool](Get-Command claude -ErrorAction SilentlyContinue)

    foreach ($name in $Dirty) {
        # Find repo path
        $repoPath = $null
        $repo = $Repos | Where-Object { (Split-Path $_.Target -Leaf) -eq $name }
        if ($repo) { $repoPath = $repo.Target }
        if ($name -eq (Split-Path $DotfilesDir -Leaf)) { $repoPath = $DotfilesDir }
        if (-not $repoPath) { continue }

        Push-Location $repoPath

        # Build changes summary
        $diffStat = git diff --stat 2>$null
        $untracked = git ls-files --others --exclude-standard 2>$null
        $changes = ""
        if ($diffStat) { $changes += "Modified:`n$($diffStat -join "`n")`n" }
        if ($untracked) { $changes += "New files:`n$($untracked -join "`n")`n" }

        Write-Host ""
        Write-Info "$name changes:"
        Write-Host $changes

        if ($hasClaude) {
            $prompt = @"
You are a commit message generator. Given these changes in the '$name' repo:

$changes

Respond with ONLY one of:
1. A single-line commit message (no quotes, no prefix) if the changes are safe to commit
2. REVIEW: <reason> if the changes need human review (e.g. secrets, large deletions, config that looks wrong)

Nothing else. No explanation.
"@

            Write-Info "$name`: asking Claude for commit message..."
            $msg = & claude -p $prompt 2>$null

            if (-not $msg) {
                Write-Warn "$name`: Claude returned empty response - skipping"
                Pop-Location
                continue
            }

            $msg = ($msg -join " ").Trim()

            if ($msg.StartsWith("REVIEW:")) {
                Write-Warn "$name`: $msg"
                Pop-Location
                continue
            }

            Write-Ok "$name`: committing with message: $msg"
            git add -A
            git commit -m $msg
            git push 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "$name`: pushed"
            }
            else {
                Write-Err "$name`: push failed"
            }
        }
        else {
            Write-Warn "$name`: Claude Code not available - commit manually"
        }

        Pop-Location
    }
}

Write-Host ""
