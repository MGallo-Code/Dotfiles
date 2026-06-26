# AUTO_GIT_ENTRYPOINT
# Conservative document sync: pull/push already-committed work only.

$ErrorActionPreference = "Stop"
$DotfilesDir = if ($env:DOTFILES_DIR_OVERRIDE) { $env:DOTFILES_DIR_OVERRIDE } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $DotfilesDir "manifest.ps1")

function Write-Ok   { param($msg) Write-Host "[ok] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "[error] $msg" -ForegroundColor Red }

$script:GitExitCode = 0

function GitOut {
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & git @args 2>$null
        $script:GitExitCode = $LASTEXITCODE
        return $output
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
}

function GitQuiet {
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git @args 1>$null 2>$null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
}

function Invoke-QuietCommand {
    param([scriptblock]$Command)
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Command 1>$null 2>$null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
}

. (Join-Path $DotfilesDir "scripts\git-sync-lock.ps1")

function Resolve-GitPath {
    param([string]$Repo, [string]$Marker)
    $path = (GitOut -C $Repo rev-parse --path-format=absolute --git-path $Marker)
    if (-not $path) {
        $path = (GitOut -C $Repo rev-parse --git-path $Marker)
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
        $dir = (GitOut -C $Repo rev-parse --path-format=absolute $gitDirFlag)
        if (-not $dir) {
            $dir = (GitOut -C $Repo rev-parse $gitDirFlag)
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
    $status = (GitOut -C $Repo status --porcelain=v1 --untracked-files=all)
    if ($script:GitExitCode -ne 0) { return $true }
    return [bool]$status
}

function Get-RemoteDefaultBranch {
    param([string]$Repo, [string]$Remote)
    $lines = (GitOut -C $Repo ls-remote --symref $Remote HEAD)
    foreach ($line in $lines) {
        if ($line -match '^ref:\s+refs/heads/([^\s]+)\s+HEAD') { return $Matches[1] }
    }
    return ""
}

function Get-RemoteRefOid {
    param([string]$Repo, [string]$Remote, [string]$MergeRef)
    $lines = (GitOut -C $Repo ls-remote $Remote $MergeRef)
    foreach ($line in $lines) {
        $parts = "$line" -split '\s+'
        if (($parts.Count -ge 2) -and ($parts[1] -eq $MergeRef)) { return $parts[0] }
    }
    return ""
}

function Test-IncomingIgnoredCollision {
    param([string]$Repo, [string]$LocalRev, [string]$RemoteRev)
    $paths = @(GitOut -C $Repo diff --name-only --diff-filter=ACMRT $LocalRev $RemoteRev --)
    foreach ($path in $paths) {
        if (-not $path) { continue }
        $check = $path
        while ($check) {
            $ignored = @(GitOut -C $Repo ls-files --others --ignored --exclude-standard -- $check)
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
        Invoke-QuietCommand { & $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK $Repo $Mode $Branch $LocalRev $RemoteRev $MergeRef } | Out-Null
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
    $currentBranch = (GitOut -C $Repo symbolic-ref --short HEAD)
    if ($currentBranch -ne $Branch) {
        Write-Warn "$Name`: branch changed before mutation - skipped"
        return $false
    }
    $currentRemote = (GitOut -C $Repo config "branch.$Branch.remote")
    $currentMergeRef = (GitOut -C $Repo config "branch.$Branch.merge")
    if (($currentRemote -ne $Remote) -or ($currentMergeRef -ne $MergeRef)) {
        Write-Warn "$Name`: upstream config changed before mutation - skipped"
        return $false
    }
    $currentLocalRev = (GitOut -C $Repo rev-parse "@")
    $currentRemoteRev = (GitOut -C $Repo rev-parse '@{u}')
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
    if ((GitQuiet -C $Repo rev-parse --is-inside-work-tree) -ne 0) {
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

    $branch = (GitOut -C $Repo symbolic-ref --short HEAD)
    if (-not $branch) {
        Write-Warn "$name`: detached HEAD - skipped"
        return
    }
    $upstream = (GitOut -C $Repo rev-parse --abbrev-ref --symbolic-full-name '@{u}')
    $remote = (GitOut -C $Repo config "branch.$branch.remote")
    $mergeRef = (GitOut -C $Repo config "branch.$branch.merge")
    if ((-not $upstream) -or (-not $remote) -or (-not $mergeRef)) {
        Write-Warn "$name`: no configured upstream - skipped"
        return
    }

    if ((GitQuiet -C $Repo fetch $remote) -ne 0) {
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

    $localRev = (GitOut -C $Repo rev-parse "@")
    $remoteRev = (GitOut -C $Repo rev-parse '@{u}')
    $baseRev = (GitOut -C $Repo merge-base "@" '@{u}')
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
        if ((GitQuiet -C $Repo merge --ff-only $remoteRev) -eq 0) {
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
        if ((GitQuiet -C $Repo push "--force-with-lease=${mergeRef}:$remoteRev" $remote "${localRev}:$mergeRef") -eq 0) {
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
