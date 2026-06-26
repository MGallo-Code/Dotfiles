# Shared git-sync lock for manual sync.ps1 and auto-git.ps1.
# GIT_SYNC_SHARED_LOCK

function Get-GitSyncRuntime {
    if ($IsWindows -or $env:OS -eq "Windows_NT") { return "pwsh-windows" }
    if ($IsMacOS) { return "pwsh-darwin" }
    if ((Test-Path "/proc/version") -and ((Get-Content "/proc/version" -Raw) -match "Microsoft|WSL")) {
        return "pwsh-wsl"
    }
    return "pwsh-linux"
}

function Get-GitSyncLockDir {
    if ($env:DOTFILES_GIT_SYNC_LOCK_DIR) { return $env:DOTFILES_GIT_SYNC_LOCK_DIR }
    $gitCommon = (& git -C $DotfilesDir rev-parse --git-common-dir 2>$null)
    if (-not $gitCommon) { $gitCommon = Join-Path $DotfilesDir ".git" }
    if (-not [System.IO.Path]::IsPathRooted($gitCommon)) {
        $gitCommon = Join-Path $DotfilesDir $gitCommon
    }
    return (Join-Path $gitCommon "dotfiles-git-sync.owner")
}

function Get-GitSyncProcessStart {
    param([string]$PidText)
    $pidValue = 0
    if (-not [int]::TryParse($PidText, [ref]$pidValue)) { return "" }
    try {
        return (Get-Process -Id $pidValue -ErrorAction Stop).StartTime.ToUniversalTime().ToString("o")
    }
    catch { }
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        try {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction Stop
            if ($process -and $process.CreationDate) {
                if ($process.CreationDate -is [DateTime]) {
                    return $process.CreationDate.ToUniversalTime().ToString("o")
                }
                return ([System.Management.ManagementDateTimeConverter]::ToDateTime("$($process.CreationDate)")).ToUniversalTime().ToString("o")
            }
        }
        catch { }
    }
    return ""
}

function Test-GitSyncProcessStartMatches {
    param([string]$LiveProcessStart, [string]$OwnerProcessStart)
    if (-not $OwnerProcessStart) { return $true }
    if ($OwnerProcessStart -eq "unknown") { return $true }
    if ($LiveProcessStart -eq $OwnerProcessStart) { return $true }
    try {
        $live = [DateTimeOffset]::Parse($LiveProcessStart)
        $owner = [DateTimeOffset]::Parse($OwnerProcessStart)
        return ([Math]::Abs(($live.UtcDateTime - $owner.UtcDateTime).TotalSeconds) -le 2)
    }
    catch {
        return $false
    }
}

function Test-GitSyncPidMatchesOwner {
    param([string]$PidText, [string]$OwnerProcessStart)
    $liveProcessStart = Get-GitSyncProcessStart $PidText
    if (-not $liveProcessStart) { return $false }
    if (-not (Test-GitSyncProcessStartMatches $liveProcessStart $OwnerProcessStart)) { return $false }
    return $true
}

function New-GitSyncOwner {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $processStart = Get-GitSyncProcessStart "$PID"
    if (-not $processStart) { $processStart = "unknown" }
    [ordered]@{
        pid = "$PID"
        host = [System.Net.Dns]::GetHostName()
        runtime = Get-GitSyncRuntime
        started_at = "$now"
        heartbeat_at = "$now"
        process_start = $processStart
    }
}

function Test-GitSyncOwnerComplete {
    param($Owner)
    if ($null -eq $Owner) { return $false }
    foreach ($field in @("pid", "host", "runtime", "started_at", "heartbeat_at", "process_start")) {
        if (-not $Owner.PSObject.Properties[$field]) { return $false }
        if ([string]::IsNullOrWhiteSpace("$($Owner.$field)")) { return $false }
    }
    if ("$($Owner.pid)" -notmatch '^\d+$') { return $false }
    if ("$($Owner.started_at)" -notmatch '^\d+$') { return $false }
    if ("$($Owner.heartbeat_at)" -notmatch '^\d+$') { return $false }
    return $true
}

function Get-GitSyncOwnerPath {
    param([string]$LockPath)
    if (Test-Path $LockPath -PathType Container) {
        return (Join-Path $LockPath "owner.json")
    }
    return $LockPath
}

function New-GitSyncLockFile {
    param([string]$LockPath)
    if (Test-Path $LockPath) { return $false }
    $parent = Split-Path $LockPath -Parent
    $base = Split-Path $LockPath -Leaf
    $tmp = Join-Path $parent ".$base.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    New-GitSyncOwner | ConvertTo-Json -Compress | Set-Content -Path $tmp -NoNewline
    try {
        New-Item -ItemType HardLink -Path $LockPath -Target $tmp -ErrorAction Stop | Out-Null
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Release-GitSyncLock {
    if (-not $script:GitSyncLockAcquired) { return }
    $ownerPath = Get-GitSyncOwnerPath $script:GitSyncLockDirPath
    try {
        $owner = Get-Content $ownerPath -Raw | ConvertFrom-Json
        if ($owner.pid -eq "$PID") {
            Remove-Item -Path $script:GitSyncLockDirPath -Recurse -Force
        }
    }
    catch { }
    $script:GitSyncLockAcquired = $false
}

function Try-ReclaimGitSyncLock {
    param([string]$LockDir)
    $ownerPath = Get-GitSyncOwnerPath $LockDir
    if (-not (Test-Path $ownerPath)) {
        Write-Warn "git-sync lock: incomplete owner metadata at $LockDir; not reclaiming automatically"
        return $false
    }
    try {
        $owner = Get-Content $ownerPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warn "git-sync lock: unreadable owner metadata at $LockDir; not reclaiming automatically"
        return $false
    }
    if (-not (Test-GitSyncOwnerComplete $owner)) {
        Write-Warn "git-sync lock: invalid owner metadata at $LockDir; not reclaiming automatically"
        return $false
    }
    $thisHost = [System.Net.Dns]::GetHostName()
    $thisRuntime = Get-GitSyncRuntime
    if (($owner.host -ne $thisHost) -or ($owner.runtime -ne $thisRuntime)) {
        Write-Warn "git-sync lock: held by $($owner.host)/$($owner.runtime) pid $($owner.pid); not reclaiming across host/runtime"
        return $false
    }
    if (Test-GitSyncPidMatchesOwner "$($owner.pid)" "$($owner.process_start)") {
        Write-Warn "git-sync lock: already held by live pid $($owner.pid); skipping"
        return $false
    }
    if (($LockDir -notlike "*dotfiles-git-sync.owner") -and ($LockDir -notlike "*dotfiles-git-sync.lock") -and ($LockDir -notlike "*dotfiles-git-sync.lock.d")) {
        Write-Warn "git-sync lock: refusing to remove unexpected lock path $LockDir"
        return $false
    }
    Remove-Item -Path $LockDir -Recurse -Force
    return $true
}

function Acquire-GitSyncLock {
    param([string]$Label = "git-sync")
    $lockDir = Get-GitSyncLockDir
    $parent = Split-Path $lockDir -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (New-GitSyncLockFile $lockDir) {
        $script:GitSyncLockDirPath = $lockDir
        $script:GitSyncLockAcquired = $true
        Write-Ok "git-sync lock acquired ($Label)"
        return $true
    }
    if ((Try-ReclaimGitSyncLock $lockDir)) {
        if (New-GitSyncLockFile $lockDir) {
            $script:GitSyncLockDirPath = $lockDir
            $script:GitSyncLockAcquired = $true
            Write-Ok "git-sync lock reclaimed and acquired ($Label)"
            return $true
        }
    }
    Write-Warn "git-sync lock unavailable ($Label); another sync is running or manual cleanup is needed"
    return $false
}
