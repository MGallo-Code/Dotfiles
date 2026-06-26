# AUTO_GIT_ENTRYPOINT
# Conservative document sync: pull/push already-committed work only.

$ErrorActionPreference = "Stop"
$DotfilesDir = if ($env:DOTFILES_DIR_OVERRIDE) { $env:DOTFILES_DIR_OVERRIDE } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $DotfilesDir "manifest.ps1")

function Write-Ok   { param($msg) Write-Host "[ok] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "[error] $msg" -ForegroundColor Red }

. (Join-Path $DotfilesDir "scripts\git-sync-lock.ps1")

function Resolve-GitPath {
    param([string]$Repo, [string]$Marker)
    $path = (& git -C $Repo rev-parse --path-format=absolute --git-path $Marker 2>$null)
    if (-not $path) {
        $path = (& git -C $Repo rev-parse --git-path $Marker 2>$null)
    }
    if (-not $path) { return "" }
    if ([System.IO.Path]::IsPathRooted($path)) { return $path }
    return (Join-Path $Repo $path)
}

function Get-AutoGitRepoPaths { # AUTO_GIT_REPO_UNION
    if ($env:AUTO_GIT_REPO_LIST_FILE) {
        Get-Content $env:AUTO_GIT_REPO_LIST_FILE | Where-Object { $_ }
        return
    }
    foreach ($repo in $Repos) { $repo.Target }
    $DotfilesDir
}

function Test-GitPathExists {
    param([string]$Repo, [string]$Marker)
    $path = Resolve-GitPath $Repo $Marker
    return ($path -and (Test-Path $path))
}

function Test-GitOperationInProgress {
    param([string]$Repo)
    foreach ($marker in @("rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG")) {
        if (Test-GitPathExists $Repo $marker) { return $true }
    }
    foreach ($marker in @("index.lock", "HEAD.lock", "config.lock", "packed-refs.lock", "shallow.lock")) {
        if (Test-GitPathExists $Repo $marker) { return $true }
    }
    foreach ($gitDirFlag in @("--git-dir", "--git-common-dir")) {
        $dir = (& git -C $Repo rev-parse --path-format=absolute $gitDirFlag 2>$null)
        if (-not $dir) {
            $dir = (& git -C $Repo rev-parse $gitDirFlag 2>$null)
            if ($dir -and -not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $Repo $dir }
        }
        if ($dir -and (Test-Path $dir)) {
            foreach ($lock in (Get-ChildItem -Path $dir -Filter "*.lock" -File -Recurse -ErrorAction SilentlyContinue)) {
                if ($lock.Name -eq "dotfiles-git-sync.lock") { continue }
                return $true
            }
        }
    }
    return $false
}

function Test-RepoDirtyOrUnreadable {
    param([string]$Repo)
    $status = (& git -C $Repo status --porcelain=v1 --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0) { return $true }
    return [bool]$status
}

function Get-RemoteDefaultBranch {
    param([string]$Repo, [string]$Remote)
    $lines = (& git -C $Repo ls-remote --symref $Remote HEAD 2>$null)
    foreach ($line in $lines) {
        if ($line -match '^ref:\s+refs/heads/([^\s]+)\s+HEAD') { return $Matches[1] }
    }
    return ""
}

function Get-RemoteRefOid {
    param([string]$Repo, [string]$Remote, [string]$MergeRef)
    $lines = (& git -C $Repo ls-remote $Remote $MergeRef 2>$null)
    foreach ($line in $lines) {
        $parts = "$line" -split '\s+'
        if (($parts.Count -ge 2) -and ($parts[1] -eq $MergeRef)) { return $parts[0] }
    }
    return ""
}

function Test-IncomingIgnoredCollision {
    param([string]$Repo, [string]$LocalRev, [string]$RemoteRev)
    $paths = @(& git -C $Repo diff --name-only --diff-filter=ACMRT $LocalRev $RemoteRev -- 2>$null)
    foreach ($path in $paths) {
        if (-not $path) { continue }
        $check = $path
        while ($check) {
            $ignored = @(& git -C $Repo ls-files --others --ignored --exclude-standard -- $check 2>$null)
            if ($ignored.Count -gt 0) { return $true }
            if ($check -notmatch "/") { break }
            $check = $check -replace '/[^/]+$', ''
        }
    }
    return $false
}

function Invoke-TestBeforeMutateHook {
    param(
        [string]$Repo,
        [string]$Mode,
        [string]$Branch,
        [string]$LocalRev,
        [string]$RemoteRev,
        [string]$MergeRef
    )
    if ($env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK -and (Test-Path $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK)) {
        & $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK $Repo $Mode $Branch $LocalRev $RemoteRev $MergeRef *> $null
    }
}

function Test-RepoStateStillSafe {
    param(
        [string]$Repo,
        [string]$Name,
        [string]$Branch,
        [string]$Remote,
        [string]$MergeRef,
        [string]$LocalRev,
        [string]$RemoteRev
    )
    if (Test-RepoDirtyOrUnreadable $Repo) {
        Write-Warn "$Name`: became dirty or unreadable before mutation - skipped"
        return $false
    }
    if (Test-GitOperationInProgress $Repo) {
        Write-Warn "$Name`: git operation appeared before mutation - skipped"
        return $false
    }
    $currentBranch = (& git -C $Repo symbolic-ref --short HEAD 2>$null)
    if ($currentBranch -ne $Branch) {
        Write-Warn "$Name`: branch changed before mutation - skipped"
        return $false
    }
    $currentRemote = (& git -C $Repo config "branch.$Branch.remote" 2>$null)
    $currentMergeRef = (& git -C $Repo config "branch.$Branch.merge" 2>$null)
    if (($currentRemote -ne $Remote) -or ($currentMergeRef -ne $MergeRef)) {
        Write-Warn "$Name`: upstream config changed before mutation - skipped"
        return $false
    }
    $currentLocalRev = (& git -C $Repo rev-parse "@" 2>$null)
    $currentRemoteRev = (& git -C $Repo rev-parse '@{u}' 2>$null)
    if (($currentLocalRev -ne $LocalRev) -or ($currentRemoteRev -ne $RemoteRev)) {
        Write-Warn "$Name`: ref state changed before mutation - skipped"
        return $false
    }
    return $true
}

function Test-RemoteDefaultBranchStillSafe {
    param(
        [string]$Repo,
        [string]$Name,
        [string]$Remote,
        [string]$ExpectedDefaultBranch
    )
    $currentDefaultBranch = Get-RemoteDefaultBranch $Repo $Remote
    if ((-not $currentDefaultBranch) -or ($currentDefaultBranch -ne $ExpectedDefaultBranch)) {
        Write-Warn "$Name`: remote default branch changed before push - skipped"
        return $false
    }
    return $true
}

function Test-RemoteRefStillSafe {
    param(
        [string]$Repo,
        [string]$Name,
        [string]$Remote,
        [string]$MergeRef,
        [string]$ExpectedOid
    )
    $currentOid = Get-RemoteRefOid $Repo $Remote $MergeRef
    if ((-not $currentOid) -or ($currentOid -ne $ExpectedOid)) {
        Write-Warn "$Name`: remote ref changed after fetch - skipped"
        return $false
    }
    return $true
}

function Sync-AutoGitRepo {
    param([string]$Repo)
    $name = Split-Path $Repo -Leaf
    & git -C $Repo rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "$name`: missing or not a git worktree - skipped"
        return
    }
    if (Test-RepoDirtyOrUnreadable $Repo) {
        Write-Warn "$name`: dirty or unreadable worktree - skipped"
        return
    }
    if (Test-GitOperationInProgress $Repo) {
        Write-Warn "$name`: git operation in progress - skipped"
        return
    }

    $branch = (& git -C $Repo symbolic-ref --short HEAD 2>$null)
    if (-not $branch) {
        Write-Warn "$name`: detached HEAD - skipped"
        return
    }
    $upstream = (& git -C $Repo rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    $remote = (& git -C $Repo config "branch.$branch.remote" 2>$null)
    $mergeRef = (& git -C $Repo config "branch.$branch.merge" 2>$null)
    if ((-not $upstream) -or (-not $remote) -or (-not $mergeRef)) {
        Write-Warn "$name`: no configured upstream - skipped"
        return
    }

    & git -C $Repo fetch $remote *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$name`: fetch failed - skipped"
        return
    }
    if (Test-RepoDirtyOrUnreadable $Repo) {
        Write-Warn "$name`: became dirty or unreadable after fetch - skipped"
        return
    }
    if (Test-GitOperationInProgress $Repo) {
        Write-Warn "$name`: git operation appeared after fetch - skipped"
        return
    }

    $localRev = (& git -C $Repo rev-parse "@" 2>$null)
    $remoteRev = (& git -C $Repo rev-parse '@{u}' 2>$null)
    $baseRev = (& git -C $Repo merge-base "@" '@{u}' 2>$null)
    if ((-not $localRev) -or (-not $remoteRev) -or (-not $baseRev)) {
        Write-Warn "$name`: cannot classify history - skipped"
        return
    }

    if ($localRev -eq $remoteRev) {
        Write-Ok "$name`: up to date"
    }
    elseif ($localRev -eq $baseRev) {
        Invoke-TestBeforeMutateHook $Repo "pull" $branch $localRev $remoteRev $mergeRef
        if (-not (Test-RepoStateStillSafe $Repo $name $branch $remote $mergeRef $localRev $remoteRev)) { return }
        if (Test-IncomingIgnoredCollision $Repo $localRev $remoteRev) {
            Write-Warn "$name`: incoming tracked path collides with ignored local file - skipped"
            return
        }
        if (-not (Test-RepoStateStillSafe $Repo $name $branch $remote $mergeRef $localRev $remoteRev)) { return }
        if (-not (Test-RemoteRefStillSafe $Repo $name $remote $mergeRef $remoteRev)) { return }
        & git -C $Repo merge --ff-only $remoteRev *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$name`: pulled updates"
        }
        else {
            Write-Err "$name`: fast-forward failed - skipped"
        }
    }
    elseif ($remoteRev -eq $baseRev) {
        $defaultBranch = Get-RemoteDefaultBranch $Repo $remote
        if (-not $defaultBranch) {
            Write-Warn "$name`: cannot determine $remote default branch - skipped"
            return
        }
        if ($branch -ne $defaultBranch) {
            Write-Warn "$name`: ahead on non-default branch $branch - skipped"
            return
        }
        if ($mergeRef -ne "refs/heads/$defaultBranch") {
            Write-Warn "$name`: upstream $mergeRef is not $remote default branch - skipped"
            return
        }
        Invoke-TestBeforeMutateHook $Repo "push" $branch $localRev $remoteRev $mergeRef
        if (-not (Test-RepoStateStillSafe $Repo $name $branch $remote $mergeRef $localRev $remoteRev)) { return }
        if (-not (Test-RemoteDefaultBranchStillSafe $Repo $name $remote $defaultBranch)) { return }
        if (-not (Test-RemoteRefStillSafe $Repo $name $remote $mergeRef $remoteRev)) { return }
        & git -C $Repo push "--force-with-lease=${mergeRef}:$remoteRev" $remote "${localRev}:$mergeRef" *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$name`: pushed committed work"
        }
        else {
            Write-Err "$name`: push failed - skipped"
        }
    }
    else {
        Write-Warn "$name`: diverged from upstream - skipped"
    }
}

if (-not (Acquire-GitSyncLock "auto-git")) { exit 0 }
try {
    foreach ($repo in (Get-AutoGitRepoPaths)) {
        Sync-AutoGitRepo $repo
    }
}
finally {
    Release-GitSyncLock
}
