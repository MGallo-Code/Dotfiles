# INV-12 Windows enforcer: auto-git.ps1 never creates commits or touches dirty human work.
param([switch]$RevertTest)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$AutoPs1 = if ($env:AUTO_GIT_PS1) { $env:AUTO_GIT_PS1 } else { Join-Path $Root "auto-git.ps1" }
$BootstrapPs1 = if ($env:GIT_AUTOSYNC_BOOTSTRAP_PS1) { $env:GIT_AUTOSYNC_BOOTSTRAP_PS1 } else { Join-Path $Root "scripts\git-autosync-bootstrap.ps1" }
$TestTmpParent = if ($env:AUTO_GIT_TEST_TMP_PARENT) { $env:AUTO_GIT_TEST_TMP_PARENT } else { Join-Path $Root ".auto-git-test-tmp" }
$ScriptHost = if ($env:AUTO_GIT_PSHOST) { $env:AUTO_GIT_PSHOST } else { "pwsh" }
$script:Pass = 0
$script:Fail = 0

function Escape-GitHubActionsMessage {
    param([string]$Message)
    return (($Message -replace '%', '%25') -replace "`r", '%0D') -replace "`n", '%0A'
}

function Write-GitHubError {
    param([string]$Message)
    Write-Host "::error title=auto-git PowerShell safety::$(Escape-GitHubActionsMessage $Message)"
}

function Invoke-ScriptHostQuiet {
    param([string]$ScriptPath)
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $ScriptHost -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 1>$null 2>$null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
}

trap {
    $line = if ($_.InvocationInfo) { $_.InvocationInfo.ScriptLineNumber } else { "unknown" }
    $message = "Unhandled error at line ${line}: $($_.Exception.Message)"
    Write-Host "  ERROR - $message" -ForegroundColor Red
    Write-GitHubError $message
    exit 1
}

$env:GIT_CONFIG_NOSYSTEM = "1"
$env:GIT_CONFIG_GLOBAL = Join-Path $TestTmpParent "global.gitconfig"
$env:GIT_CONFIG_XDG = Join-Path $TestTmpParent "xdg.gitconfig"
$env:XDG_CONFIG_HOME = Join-Path $TestTmpParent "xdg"
New-Item -ItemType Directory -Path $TestTmpParent -Force | Out-Null
New-Item -ItemType Directory -Path $env:XDG_CONFIG_HOME -Force | Out-Null
$GitExe = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

function Ok { param([string]$Label) Write-Host "  ok - $Label"; $script:Pass++ }
function Bad { param([string]$Label) Write-Host "  FAIL - $Label" -ForegroundColor Red; Write-GitHubError $Label; $script:Fail++ }
function Assert {
    param([string]$Label, [scriptblock]$Check)
    try {
        if (& $Check) { Ok $Label } else { Bad $Label }
    }
    catch {
        Write-Host "  ERROR - $Label`: $($_.Exception.Message)" -ForegroundColor Red
        Write-GitHubError "$Label`: $($_.Exception.Message)"
        $script:Fail++
    }
}

function Git {
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $GitExe @args
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    if ($exitCode -ne 0) { throw "git $($args -join ' ') failed ($exitCode)" }
}

function GitOut {
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = & $GitExe @args 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    if ($exitCode -ne 0) { return "" }
    return (($out | Out-String).Trim())
}

function Set-GitConfig {
    param([string]$Repo)
    Git -C $Repo config user.email "auto-git-test@example.invalid" | Out-Null
    Git -C $Repo config user.name "Auto Git Test" | Out-Null
}

function New-Fixture {
    param([string]$Base)
    New-Item -ItemType Directory -Path $Base -Force | Out-Null
    Git init --bare (Join-Path $Base "remote.git") | Out-Null
    Git init -b main (Join-Path $Base "seed") | Out-Null
    Set-GitConfig (Join-Path $Base "seed")
    Set-Content -Path (Join-Path $Base "seed\file.txt") -Value "one"
    Git -C (Join-Path $Base "seed") add file.txt | Out-Null
    Git -C (Join-Path $Base "seed") commit -m "seed" | Out-Null
    Git -C (Join-Path $Base "seed") remote add origin (Join-Path $Base "remote.git") | Out-Null
    Git -C (Join-Path $Base "seed") push -u origin main | Out-Null
    Git "--git-dir=$(Join-Path $Base "remote.git")" symbolic-ref HEAD refs/heads/main | Out-Null
    Git clone -b main (Join-Path $Base "remote.git") (Join-Path $Base "work") | Out-Null
    Git clone -b main (Join-Path $Base "remote.git") (Join-Path $Base "other") | Out-Null
    Set-GitConfig (Join-Path $Base "work")
    Set-GitConfig (Join-Path $Base "other")
}

function Commit-InRepo {
    param([string]$Repo, [string]$Text)
    Add-Content -Path (Join-Path $Repo "file.txt") -Value $Text
    Git -C $Repo add file.txt | Out-Null
    Git -C $Repo commit -m $Text | Out-Null
}

function Git-MarkerPath {
    param([string]$Repo, [string]$Marker)
    $path = GitOut -C $Repo rev-parse --path-format=absolute --git-path $Marker
    if (-not $path) { $path = GitOut -C $Repo rev-parse --git-path $Marker }
    if ([System.IO.Path]::IsPathRooted($path)) { return $path }
    return (Join-Path $Repo $path)
}

function Write-List {
    param([string]$Repo, [string]$Path)
    Set-Content -Path $Path -Value $Repo
}

function Run-AutoGit {
    param([string]$ListFile, [string]$LockPath)
    $oldNoSnapshot = $env:AUTO_GIT_NO_SELF_SNAPSHOT
    $oldList = $env:AUTO_GIT_REPO_LIST_FILE
    $oldLock = $env:DOTFILES_GIT_SYNC_LOCK_DIR
    try {
        $env:AUTO_GIT_NO_SELF_SNAPSHOT = "1"
        $env:AUTO_GIT_REPO_LIST_FILE = $ListFile
        $env:DOTFILES_GIT_SYNC_LOCK_DIR = $LockPath
        $exitCode = Invoke-ScriptHostQuiet $AutoPs1
        if ($exitCode -ne 0) { throw "auto-git.ps1 exited $exitCode" }
    }
    finally {
        $env:AUTO_GIT_NO_SELF_SNAPSHOT = $oldNoSnapshot
        $env:AUTO_GIT_REPO_LIST_FILE = $oldList
        $env:DOTFILES_GIT_SYNC_LOCK_DIR = $oldLock
    }
}

function Run-AutoGitAsDotfiles {
    param([string]$DotfilesDir)
    $oldNoSnapshot = $env:AUTO_GIT_NO_SELF_SNAPSHOT
    $oldOverride = $env:DOTFILES_DIR_OVERRIDE
    $oldList = $env:AUTO_GIT_REPO_LIST_FILE
    $oldLock = $env:DOTFILES_GIT_SYNC_LOCK_DIR
    try {
        $env:AUTO_GIT_NO_SELF_SNAPSHOT = "1"
        $env:DOTFILES_DIR_OVERRIDE = $DotfilesDir
        $env:AUTO_GIT_REPO_LIST_FILE = $null
        $env:DOTFILES_GIT_SYNC_LOCK_DIR = $null
        $exitCode = Invoke-ScriptHostQuiet $AutoPs1
        if ($exitCode -ne 0) { throw "auto-git.ps1 exited $exitCode" }
    }
    finally {
        $env:AUTO_GIT_NO_SELF_SNAPSHOT = $oldNoSnapshot
        $env:DOTFILES_DIR_OVERRIDE = $oldOverride
        $env:AUTO_GIT_REPO_LIST_FILE = $oldList
        $env:DOTFILES_GIT_SYNC_LOCK_DIR = $oldLock
    }
}

function Remote-Contains {
    param([string]$RemoteGitDir, [string]$Ref, [string]$Text)
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = & $GitExe "--git-dir=$RemoteGitDir" show "$Ref`:file.txt" 2>$null
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    return (($out | Out-String) -match [regex]::Escape($Text))
}

function Current-Runtime {
    if ($IsWindows -or $env:OS -eq "Windows_NT") { return "pwsh-windows" }
    if ($IsMacOS) { return "pwsh-darwin" }
    if ((Test-Path "/proc/version") -and ((Get-Content "/proc/version" -Raw) -match "Microsoft|WSL")) { return "pwsh-wsl" }
    return "pwsh-linux"
}

function Current-ProcessStart {
    return (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")
}

function Invoke-Bootstrap {
    param([string]$ScriptPath, [string]$TaskName)
    $oldTask = $env:GIT_AUTOSYNC_TEST_TASK_NAME
    $oldNoStart = $env:GIT_AUTOSYNC_TEST_NO_START
    try {
        $env:GIT_AUTOSYNC_TEST_TASK_NAME = $TaskName
        $env:GIT_AUTOSYNC_TEST_NO_START = "1"
        $exitCode = Invoke-ScriptHostQuiet $ScriptPath
        if ($exitCode -ne 0) { throw "bootstrap exited $exitCode" }
    }
    finally {
        $env:GIT_AUTOSYNC_TEST_TASK_NAME = $oldTask
        $env:GIT_AUTOSYNC_TEST_NO_START = $oldNoStart
    }
}

function Invoke-BootstrapXml {
    param([string]$ScriptPath, [string]$XmlOut)
    $oldXml = $env:GIT_AUTOSYNC_TEST_XML_OUT
    try {
        $env:GIT_AUTOSYNC_TEST_XML_OUT = $XmlOut
        $exitCode = Invoke-ScriptHostQuiet $ScriptPath
        if ($exitCode -ne 0) { throw "bootstrap XML generation exited $exitCode" }
    }
    finally {
        $env:GIT_AUTOSYNC_TEST_XML_OUT = $oldXml
    }
}

function Test-NoUnguardedTaskEnable {
    param([string]$ScriptPath)
    $content = Get-Content $ScriptPath -Raw
    $match = [regex]::Match($content, '(?s)Register-ScheduledTask .*?if \(\$Disable\)')
    if (-not $match.Success) { return $false }
    return ($match.Value -notmatch 'Enable-ScheduledTask|Start-ScheduledTask')
}

function Get-CommandElementText {
    param($Element)
    if ($Element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return "$($Element.Value)"
    }
    $text = "$($Element.Extent.Text)".Trim()
    return $text.Trim("'").Trim('"')
}

function Test-NoForbiddenPowerShellAutoGitOps {
    param([string]$ScriptPath)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { return $false }

    $forbidden = @("add", "commit", "stash", "reset", "clean", "checkout", "restore", "rm", "pull", "rebase", "switch")
    $claudePromptPattern = '(?i)(^|\s|["''])-p($|\s|["''])'
    $commandAsts = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)
    foreach ($command in $commandAsts) {
        $elements = @($command.CommandElements)
        if ($elements.Count -eq 0) { continue }
        $name = $command.GetCommandName()
        $firstText = Get-CommandElementText $elements[0]
        $args = @()
        for ($i = 1; $i -lt $elements.Count; $i++) {
            $args += (Get-CommandElementText $elements[$i])
        }
        $commandText = "$($command.Extent.Text)"
        $isDirectGit = ($name -and ($name -ieq "git" -or $name -ieq "git.exe"))
        $isGitWrapper = ($name -and ($name -ieq "GitOut" -or $name -ieq "GitQuiet"))
        $isVariableGit = ((-not $name) -and ($firstText -match '(?i)^\$.*git.*$'))
        if ($isDirectGit -or $isGitWrapper -or $isVariableGit) {
            foreach ($arg in $args) {
                if ($forbidden -contains "$arg".ToLowerInvariant()) { return $false }
            }
            $lowerArgs = @($args | ForEach-Object { "$_".ToLowerInvariant() })
            $mergeIndex = [Array]::IndexOf($lowerArgs, "merge")
            if ($mergeIndex -ge 0) {
                $isAllowedPinnedMerge = $false
                if (($isDirectGit -or $isGitWrapper) -and $lowerArgs.Count -ge ($mergeIndex + 3)) {
                    $isAllowedPinnedMerge = (
                        ($lowerArgs[$mergeIndex + 1] -eq "--ff-only") -and
                        ($lowerArgs[$mergeIndex + 2] -eq '$remoterev')
                    )
                }
                if (-not $isAllowedPinnedMerge) { return $false }
            }
        }
        if ($name -and ($name -ieq "Start-Process" -or $name -ieq "saps")) {
            if (($commandText -match '(?i)\bgit(?:\.exe)?\b') -and ($commandText -match '(?i)\b(add|commit|stash|reset|clean|checkout|restore|rm|pull|rebase|switch|merge)\b')) {
                return $false
            }
            if (($commandText -match '(?i)\bclaude\b') -and ($commandText -match $claudePromptPattern)) {
                return $false
            }
        }
        if ($name -and ($name -ieq "Invoke-Expression" -or $name -ieq "iex")) {
            if (($commandText -match '(?i)\bgit(?:\.exe)?\b') -and ($commandText -match '(?i)\b(add|commit|stash|reset|clean|checkout|restore|rm|pull|rebase|switch|merge)\b')) {
                return $false
            }
            if (($commandText -match '(?i)\bclaude\b') -and ($commandText -match $claudePromptPattern)) {
                return $false
            }
        }
        if ($name -and ($name -ieq "claude")) {
            foreach ($arg in $args) {
                if ("$arg" -eq "-p") { return $false }
            }
        }
    }
    return $true
}

function Invoke-RevertTest {
    Write-Host "==> PowerShell auto-git revert fixtures"
    $tmp = Join-Path $TestTmpParent ("ps-revert." + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $mutated = Join-Path $tmp "git-autosync-bootstrap.ps1"
    Copy-Item $BootstrapPs1 $mutated
    $content = Get-Content $mutated -Raw
    $content = $content -replace '(Register-ScheduledTask -TaskName \$taskName -Xml \$taskXml -Force \| Out-Null)', "`$1`nEnable-ScheduledTask -TaskName `$taskName | Out-Null"
    Set-Content -Path $mutated -Value $content
    $xmlOut = Join-Path $tmp "task.xml"
    Invoke-BootstrapXml $mutated $xmlOut
    Assert "revert-test unguarded PowerShell enable is caught without registering task" { -not (Test-NoUnguardedTaskEnable $mutated) }

    $lineContinuation = Join-Path $tmp "auto-git-line-continuation.ps1"
    Copy-Item $AutoPs1 $lineContinuation
    Add-Content -Path $lineContinuation -Value @'
git `
commit -m bad
'@
    Assert "revert-test PowerShell line-continuation git commit is caught" { -not (Test-NoForbiddenPowerShellAutoGitOps $lineContinuation) }

    $callOperator = Join-Path $tmp "auto-git-call-operator.ps1"
    Copy-Item $AutoPs1 $callOperator
    Add-Content -Path $callOperator -Value @'
$git = "git"
& $git commit -m bad
'@
    Assert "revert-test PowerShell call-operator git commit is caught" { -not (Test-NoForbiddenPowerShellAutoGitOps $callOperator) }

    $startProcess = Join-Path $tmp "auto-git-start-process.ps1"
    Copy-Item $AutoPs1 $startProcess
    Add-Content -Path $startProcess -Value 'Start-Process git -ArgumentList "commit -m bad"'
    Assert "revert-test PowerShell Start-Process git commit is caught" { -not (Test-NoForbiddenPowerShellAutoGitOps $startProcess) }

    $invokeExpression = Join-Path $tmp "auto-git-iex.ps1"
    Copy-Item $AutoPs1 $invokeExpression
    Add-Content -Path $invokeExpression -Value 'Invoke-Expression "git reset --hard"'
    Assert "revert-test PowerShell Invoke-Expression git reset is caught" { -not (Test-NoForbiddenPowerShellAutoGitOps $invokeExpression) }

    $plainPull = Join-Path $tmp "auto-git-pull.ps1"
    Copy-Item $AutoPs1 $plainPull
    Add-Content -Path $plainPull -Value 'git pull'
    Assert "revert-test PowerShell plain pull is caught" { -not (Test-NoForbiddenPowerShellAutoGitOps $plainPull) }

    $rebase = Join-Path $tmp "auto-git-rebase.ps1"
    Copy-Item $AutoPs1 $rebase
    Add-Content -Path $rebase -Value "git rebase '@{u}'"
    Assert "revert-test PowerShell rebase is caught" { -not (Test-NoForbiddenPowerShellAutoGitOps $rebase) }

    $switch = Join-Path $tmp "auto-git-switch.ps1"
    Copy-Item $AutoPs1 $switch
    Add-Content -Path $switch -Value 'git switch main'
    Assert "revert-test PowerShell switch is caught" { -not (Test-NoForbiddenPowerShellAutoGitOps $switch) }

    $merge = Join-Path $tmp "auto-git-merge.ps1"
    Copy-Item $AutoPs1 $merge
    Add-Content -Path $merge -Value 'git merge origin/main'
    Assert "revert-test PowerShell non-ff merge is caught" { -not (Test-NoForbiddenPowerShellAutoGitOps $merge) }

    Remove-Item -LiteralPath $TestTmpParent -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "auto-git PowerShell revert safety: $script:Pass passed, $script:Fail failed"
    if ($script:Fail -ne 0) { exit 1 }
    exit 0
}

if ($RevertTest) { Invoke-RevertTest }

Assert "PowerShell AST scan has no forbidden auto-git operations" { Test-NoForbiddenPowerShellAutoGitOps $AutoPs1 }

Write-Host "==> PowerShell auto-git behavioral fixtures"
$tmp = Join-Path $TestTmpParent ("ps-run." + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

New-Fixture (Join-Path $tmp "dirty")
$dirtyHead = GitOut -C (Join-Path $tmp "dirty\work") rev-parse HEAD
Add-Content -Path (Join-Path $tmp "dirty\work\file.txt") -Value "human edit"
Write-List (Join-Path $tmp "dirty\work") (Join-Path $tmp "dirty\list")
Run-AutoGit (Join-Path $tmp "dirty\list") (Join-Path $tmp "dirty\lock")
Assert "dirty repo keeps HEAD" { (GitOut -C (Join-Path $tmp "dirty\work") rev-parse HEAD) -eq $dirtyHead }
Assert "dirty repo remains dirty" { (GitOut -C (Join-Path $tmp "dirty\work") status --porcelain) }

New-Fixture (Join-Path $tmp "untrackedhidden")
Git -C (Join-Path $tmp "untrackedhidden\work") config status.showUntrackedFiles no | Out-Null
Set-Content -Path (Join-Path $tmp "untrackedhidden\work\untracked.txt") -Value "human untracked"
Commit-InRepo (Join-Path $tmp "untrackedhidden\other") "hidden-remote"
Git -C (Join-Path $tmp "untrackedhidden\other") push | Out-Null
Write-List (Join-Path $tmp "untrackedhidden\work") (Join-Path $tmp "untrackedhidden\list")
Run-AutoGit (Join-Path $tmp "untrackedhidden\list") (Join-Path $tmp "untrackedhidden\lock")
Assert "hidden untracked file keeps repo skipped" { -not ((Get-Content (Join-Path $tmp "untrackedhidden\work\file.txt") -Raw) -match "hidden-remote") }

New-Fixture (Join-Path $tmp "behind")
Commit-InRepo (Join-Path $tmp "behind\other") "behind"
Git -C (Join-Path $tmp "behind\other") push | Out-Null
$behindRemoteRev = GitOut "--git-dir=$(Join-Path $tmp "behind\remote.git")" rev-parse main
Write-List (Join-Path $tmp "behind\work") (Join-Path $tmp "behind\list")
Run-AutoGit (Join-Path $tmp "behind\list") (Join-Path $tmp "behind\lock")
Assert "clean-behind repo pulls" { (Get-Content (Join-Path $tmp "behind\work\file.txt") -Raw) -match "behind" }
Assert "clean-behind fast-forwards exactly to fetched upstream" { (GitOut -C (Join-Path $tmp "behind\work") rev-parse HEAD) -eq $behindRemoteRev }
$behindParentCount = ((GitOut -C (Join-Path $tmp "behind\work") rev-list --parents -n 1 HEAD) -split '\s+').Count
Assert "clean-behind creates no merge commit" { $behindParentCount -eq 2 }

New-Fixture (Join-Path $tmp "ahead")
Commit-InRepo (Join-Path $tmp "ahead\work") "ahead"
Write-List (Join-Path $tmp "ahead\work") (Join-Path $tmp "ahead\list")
Run-AutoGit (Join-Path $tmp "ahead\list") (Join-Path $tmp "ahead\lock")
Git -C (Join-Path $tmp "ahead\other") pull --ff-only | Out-Null
Assert "clean-ahead default branch pushes" { (Get-Content (Join-Path $tmp "ahead\other\file.txt") -Raw) -match "ahead" }

New-Fixture (Join-Path $tmp "ignoredcollision")
Set-Content -Path (Join-Path $tmp "ignoredcollision\work\.gitignore") -Value "ignored.txt"
Git -C (Join-Path $tmp "ignoredcollision\work") add .gitignore | Out-Null
Git -C (Join-Path $tmp "ignoredcollision\work") commit -m "ignore fixture" | Out-Null
Git -C (Join-Path $tmp "ignoredcollision\work") push | Out-Null
Git -C (Join-Path $tmp "ignoredcollision\other") pull --ff-only | Out-Null
Set-Content -Path (Join-Path $tmp "ignoredcollision\work\ignored.txt") -Value "local ignored"
Set-Content -Path (Join-Path $tmp "ignoredcollision\other\ignored.txt") -Value "remote tracked"
Git -C (Join-Path $tmp "ignoredcollision\other") add -f ignored.txt | Out-Null
Git -C (Join-Path $tmp "ignoredcollision\other") commit -m "track ignored path" | Out-Null
Git -C (Join-Path $tmp "ignoredcollision\other") push | Out-Null
Write-List (Join-Path $tmp "ignoredcollision\work") (Join-Path $tmp "ignoredcollision\list")
Run-AutoGit (Join-Path $tmp "ignoredcollision\list") (Join-Path $tmp "ignoredcollision\lock")
Assert "ignored local file blocks colliding pull" { (Get-Content (Join-Path $tmp "ignoredcollision\work\ignored.txt") -Raw) -match "local ignored" }
$ignoredTracked = GitOut -C (Join-Path $tmp "ignoredcollision\work") ls-files --error-unmatch ignored.txt
Assert "ignored collision path remains untracked" { -not $ignoredTracked }

New-Fixture (Join-Path $tmp "ignoreddircollision")
Set-Content -Path (Join-Path $tmp "ignoreddircollision\work\.gitignore") -Value "ignored-dir/"
Git -C (Join-Path $tmp "ignoreddircollision\work") add .gitignore | Out-Null
Git -C (Join-Path $tmp "ignoreddircollision\work") commit -m "ignore dir fixture" | Out-Null
Git -C (Join-Path $tmp "ignoreddircollision\work") push | Out-Null
Git -C (Join-Path $tmp "ignoreddircollision\other") pull --ff-only | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp "ignoreddircollision\work\ignored-dir") -Force | Out-Null
Set-Content -Path (Join-Path $tmp "ignoreddircollision\work\ignored-dir\cache.txt") -Value "local ignored dir data"
Set-Content -Path (Join-Path $tmp "ignoreddircollision\other\ignored-dir") -Value "remote tracked file"
Git -C (Join-Path $tmp "ignoreddircollision\other") add -f ignored-dir | Out-Null
Git -C (Join-Path $tmp "ignoreddircollision\other") commit -m "track ignored dir path" | Out-Null
Git -C (Join-Path $tmp "ignoreddircollision\other") push | Out-Null
Write-List (Join-Path $tmp "ignoreddircollision\work") (Join-Path $tmp "ignoreddircollision\list")
Run-AutoGit (Join-Path $tmp "ignoreddircollision\list") (Join-Path $tmp "ignoreddircollision\lock")
Assert "ignored directory blocks colliding tracked file pull" { (Get-Content (Join-Path $tmp "ignoreddircollision\work\ignored-dir\cache.txt") -Raw) -match "local ignored dir data" }
$ignoredDirTracked = GitOut -C (Join-Path $tmp "ignoreddircollision\work") ls-files --error-unmatch ignored-dir
Assert "ignored directory collision path remains untracked" { -not $ignoredDirTracked }

New-Fixture (Join-Path $tmp "ignoredparentcollision")
Set-Content -Path (Join-Path $tmp "ignoredparentcollision\work\.gitignore") -Value "ignored-parent"
Git -C (Join-Path $tmp "ignoredparentcollision\work") add .gitignore | Out-Null
Git -C (Join-Path $tmp "ignoredparentcollision\work") commit -m "ignore parent fixture" | Out-Null
Git -C (Join-Path $tmp "ignoredparentcollision\work") push | Out-Null
Git -C (Join-Path $tmp "ignoredparentcollision\other") pull --ff-only | Out-Null
Set-Content -Path (Join-Path $tmp "ignoredparentcollision\work\ignored-parent") -Value "local ignored parent file"
New-Item -ItemType Directory -Path (Join-Path $tmp "ignoredparentcollision\other\ignored-parent") -Force | Out-Null
Set-Content -Path (Join-Path $tmp "ignoredparentcollision\other\ignored-parent\child.txt") -Value "remote child"
Git -C (Join-Path $tmp "ignoredparentcollision\other") add -f ignored-parent/child.txt | Out-Null
Git -C (Join-Path $tmp "ignoredparentcollision\other") commit -m "track child under ignored parent" | Out-Null
Git -C (Join-Path $tmp "ignoredparentcollision\other") push | Out-Null
Write-List (Join-Path $tmp "ignoredparentcollision\work") (Join-Path $tmp "ignoredparentcollision\list")
Run-AutoGit (Join-Path $tmp "ignoredparentcollision\list") (Join-Path $tmp "ignoredparentcollision\lock")
Assert "ignored parent file blocks colliding tracked child pull" { (Get-Content (Join-Path $tmp "ignoredparentcollision\work\ignored-parent") -Raw) -match "local ignored parent file" }
$ignoredParentTracked = GitOut -C (Join-Path $tmp "ignoredparentcollision\work") ls-files --error-unmatch ignored-parent/child.txt
Assert "ignored parent collision path remains untracked" { -not $ignoredParentTracked }

New-Fixture (Join-Path $tmp "racepull")
Commit-InRepo (Join-Path $tmp "racepull\other") "race-pull"
Git -C (Join-Path $tmp "racepull\other") push | Out-Null
$racePullHook = Join-Path $tmp "racepull\hook.ps1"
Set-Content -Path $racePullHook -Value @'
param($Repo, $Mode, $Branch, $LocalRev, $RemoteRev, $MergeRef)
if ($Mode -eq "pull") {
    & git -C $Repo checkout -b race-side *> $null
}
'@
Write-List (Join-Path $tmp "racepull\work") (Join-Path $tmp "racepull\list")
$oldHook = $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK
try {
    $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK = $racePullHook
    Run-AutoGit (Join-Path $tmp "racepull\list") (Join-Path $tmp "racepull\lock")
}
finally {
    $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK = $oldHook
}
Assert "branch race blocks pull mutation" { -not ((Get-Content (Join-Path $tmp "racepull\work\file.txt") -Raw) -match "race-pull") }

New-Fixture (Join-Path $tmp "racepush")
Commit-InRepo (Join-Path $tmp "racepush\work") "race-push"
$racePushHook = Join-Path $tmp "racepush\hook.ps1"
Set-Content -Path $racePushHook -Value @'
param($Repo, $Mode, $Branch, $LocalRev, $RemoteRev, $MergeRef)
if ($Mode -eq "push") {
    & git -C $Repo checkout -b race-side *> $null
}
'@
Write-List (Join-Path $tmp "racepush\work") (Join-Path $tmp "racepush\list")
$oldHook = $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK
try {
    $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK = $racePushHook
    Run-AutoGit (Join-Path $tmp "racepush\list") (Join-Path $tmp "racepush\lock")
}
finally {
    $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK = $oldHook
}
Assert "branch race blocks push mutation" { -not (Remote-Contains (Join-Path $tmp "racepush\remote.git") "main" "race-push") }

New-Fixture (Join-Path $tmp "remotedefaultrace")
Git "--git-dir=$(Join-Path $tmp "remotedefaultrace\remote.git")" branch side main | Out-Null
Commit-InRepo (Join-Path $tmp "remotedefaultrace\work") "remote-default-race"
$remoteDefaultHook = Join-Path $tmp "remotedefaultrace\hook.ps1"
$remoteDefaultGitDir = Join-Path $tmp "remotedefaultrace\remote.git"
Set-Content -Path $remoteDefaultHook -Value @"
param(`$Repo, `$Mode, `$Branch, `$LocalRev, `$RemoteRev, `$MergeRef)
if (`$Mode -eq "push") {
    & git "--git-dir=$remoteDefaultGitDir" symbolic-ref HEAD refs/heads/side *> `$null
}
"@
Write-List (Join-Path $tmp "remotedefaultrace\work") (Join-Path $tmp "remotedefaultrace\list")
$oldHook = $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK
try {
    $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK = $remoteDefaultHook
    Run-AutoGit (Join-Path $tmp "remotedefaultrace\list") (Join-Path $tmp "remotedefaultrace\lock")
}
finally {
    $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK = $oldHook
}
Assert "remote default race blocks push mutation" { -not (Remote-Contains (Join-Path $tmp "remotedefaultrace\remote.git") "main" "remote-default-race") }

New-Fixture (Join-Path $tmp "remoterefdeletepull")
Commit-InRepo (Join-Path $tmp "remoterefdeletepull\other") "remote-ref-delete"
Git -C (Join-Path $tmp "remoterefdeletepull\other") push | Out-Null
$remoteRefDeleteHook = Join-Path $tmp "remoterefdeletepull\hook.ps1"
$remoteRefDeleteGitDir = Join-Path $tmp "remoterefdeletepull\remote.git"
Set-Content -Path $remoteRefDeleteHook -Value @"
param(`$Repo, `$Mode, `$Branch, `$LocalRev, `$RemoteRev, `$MergeRef)
if (`$Mode -eq "pull") {
    & git "--git-dir=$remoteRefDeleteGitDir" update-ref -d refs/heads/main *> `$null
}
"@
Write-List (Join-Path $tmp "remoterefdeletepull\work") (Join-Path $tmp "remoterefdeletepull\list")
$oldHook = $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK
try {
    $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK = $remoteRefDeleteHook
    Run-AutoGit (Join-Path $tmp "remoterefdeletepull\list") (Join-Path $tmp "remoterefdeletepull\lock")
}
finally {
    $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK = $oldHook
}
Assert "remote ref delete race blocks pull mutation" { -not ((Get-Content (Join-Path $tmp "remoterefdeletepull\work\file.txt") -Raw) -match "remote-ref-delete") }

New-Fixture (Join-Path $tmp "remoterefracepush")
$remoteRefRaceGitDir = Join-Path $tmp "remoterefracepush\remote.git"
$remoteRefSeedRev = GitOut "--git-dir=$remoteRefRaceGitDir" rev-parse main
Commit-InRepo (Join-Path $tmp "remoterefracepush\other") "remote-ref-base"
Git -C (Join-Path $tmp "remoterefracepush\other") push | Out-Null
Git -C (Join-Path $tmp "remoterefracepush\work") pull --ff-only | Out-Null
Commit-InRepo (Join-Path $tmp "remoterefracepush\work") "remote-ref-local"
$remoteRefRaceHook = Join-Path $tmp "remoterefracepush\hook.ps1"
Set-Content -Path $remoteRefRaceHook -Value @"
param(`$Repo, `$Mode, `$Branch, `$LocalRev, `$RemoteRev, `$MergeRef)
if (`$Mode -eq "push") {
    & git "--git-dir=$remoteRefRaceGitDir" update-ref refs/heads/main $remoteRefSeedRev *> `$null
}
"@
Write-List (Join-Path $tmp "remoterefracepush\work") (Join-Path $tmp "remoterefracepush\list")
$oldHook = $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK
try {
    $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK = $remoteRefRaceHook
    Run-AutoGit (Join-Path $tmp "remoterefracepush\list") (Join-Path $tmp "remoterefracepush\lock")
}
finally {
    $env:AUTO_GIT_TEST_BEFORE_MUTATE_HOOK = $oldHook
}
Assert "remote ref rewind race blocks push mutation" { -not (Remote-Contains $remoteRefRaceGitDir "main" "remote-ref-local") }

New-Fixture (Join-Path $tmp "selfdotfiles")
New-Item -ItemType Directory -Path (Join-Path $tmp "selfdotfiles\work\scripts") -Force | Out-Null
Copy-Item (Join-Path $Root "scripts\git-sync-lock.ps1") (Join-Path $tmp "selfdotfiles\work\scripts\git-sync-lock.ps1")
Set-Content -Path (Join-Path $tmp "selfdotfiles\work\manifest.ps1") -Value '$Repos = @()'
Git -C (Join-Path $tmp "selfdotfiles\work") add manifest.ps1 scripts/git-sync-lock.ps1 | Out-Null
Git -C (Join-Path $tmp "selfdotfiles\work") commit -m "dotfiles shim" | Out-Null
Git -C (Join-Path $tmp "selfdotfiles\work") push | Out-Null
Git -C (Join-Path $tmp "selfdotfiles\other") pull --ff-only | Out-Null
Commit-InRepo (Join-Path $tmp "selfdotfiles\work") "selfdotfiles"
Run-AutoGitAsDotfiles (Join-Path $tmp "selfdotfiles\work")
Git -C (Join-Path $tmp "selfdotfiles\other") pull --ff-only | Out-Null
Assert "dotfiles repo syncs while holding default shared lock" { (Get-Content (Join-Path $tmp "selfdotfiles\other\file.txt") -Raw) -match "selfdotfiles" }

New-Fixture (Join-Path $tmp "legacydotlock")
New-Item -ItemType Directory -Path (Join-Path $tmp "legacydotlock\work\scripts") -Force | Out-Null
Copy-Item (Join-Path $Root "scripts\git-sync-lock.ps1") (Join-Path $tmp "legacydotlock\work\scripts\git-sync-lock.ps1")
Set-Content -Path (Join-Path $tmp "legacydotlock\work\manifest.ps1") -Value '$Repos = @()'
Git -C (Join-Path $tmp "legacydotlock\work") add manifest.ps1 scripts/git-sync-lock.ps1 | Out-Null
Git -C (Join-Path $tmp "legacydotlock\work") commit -m "dotfiles shim" | Out-Null
Git -C (Join-Path $tmp "legacydotlock\work") push | Out-Null
Set-Content -Path (Join-Path $tmp "legacydotlock\work\.git\dotfiles-git-sync.lock") -Value "stale legacy lock"
Commit-InRepo (Join-Path $tmp "legacydotlock\work") "legacy-dot-lock"
Run-AutoGitAsDotfiles (Join-Path $tmp "legacydotlock\work")
Git -C (Join-Path $tmp "legacydotlock\other") pull --ff-only | Out-Null
Assert "stale legacy dotfiles lock does not block self-sync" { (Get-Content (Join-Path $tmp "legacydotlock\other\file.txt") -Raw) -match "legacy-dot-lock" }

New-Fixture (Join-Path $tmp "statusfail")
Commit-InRepo (Join-Path $tmp "statusfail\work") "statusfail"
Set-Content -Path (Git-MarkerPath (Join-Path $tmp "statusfail\work") "index") -Value "not a git index"
Write-List (Join-Path $tmp "statusfail\work") (Join-Path $tmp "statusfail\list")
Run-AutoGit (Join-Path $tmp "statusfail\list") (Join-Path $tmp "statusfail\lock")
Assert "status failure does not push" { -not (Remote-Contains (Join-Path $tmp "statusfail\remote.git") "main" "statusfail") }

New-Fixture (Join-Path $tmp "gitlock")
Commit-InRepo (Join-Path $tmp "gitlock\work") "gitlock"
New-Item -ItemType File -Path (Git-MarkerPath (Join-Path $tmp "gitlock\work") "index.lock") -Force | Out-Null
Write-List (Join-Path $tmp "gitlock\work") (Join-Path $tmp "gitlock\list")
Run-AutoGit (Join-Path $tmp "gitlock\list") (Join-Path $tmp "gitlock\lock")
Assert "active git lockfile does not push" { -not (Remote-Contains (Join-Path $tmp "gitlock\remote.git") "main" "gitlock") }

New-Fixture (Join-Path $tmp "misupstream")
Git "--git-dir=$(Join-Path $tmp "misupstream\remote.git")" branch side main | Out-Null
Git -C (Join-Path $tmp "misupstream\work") fetch origin side | Out-Null
Git -C (Join-Path $tmp "misupstream\work") branch --set-upstream-to=origin/side main | Out-Null
Commit-InRepo (Join-Path $tmp "misupstream\work") "misupstream"
Write-List (Join-Path $tmp "misupstream\work") (Join-Path $tmp "misupstream\list")
Run-AutoGit (Join-Path $tmp "misupstream\list") (Join-Path $tmp "misupstream\lock")
Assert "default branch tracking non-default ref does not push" { -not (Remote-Contains (Join-Path $tmp "misupstream\remote.git") "side" "misupstream") }

New-Fixture (Join-Path $tmp "diverged")
Commit-InRepo (Join-Path $tmp "diverged\other") "remote"
Git -C (Join-Path $tmp "diverged\other") push | Out-Null
Commit-InRepo (Join-Path $tmp "diverged\work") "local"
$divergedHead = GitOut -C (Join-Path $tmp "diverged\work") rev-parse HEAD
Write-List (Join-Path $tmp "diverged\work") (Join-Path $tmp "diverged\list")
Run-AutoGit (Join-Path $tmp "diverged\list") (Join-Path $tmp "diverged\lock")
Assert "diverged repo keeps local HEAD" { (GitOut -C (Join-Path $tmp "diverged\work") rev-parse HEAD) -eq $divergedHead }

New-Fixture (Join-Path $tmp "inprogressahead")
Commit-InRepo (Join-Path $tmp "inprogressahead\work") "should-not-push"
New-Item -ItemType File -Path (Git-MarkerPath (Join-Path $tmp "inprogressahead\work") "MERGE_HEAD") -Force | Out-Null
Write-List (Join-Path $tmp "inprogressahead\work") (Join-Path $tmp "inprogressahead\list")
Run-AutoGit (Join-Path $tmp "inprogressahead\list") (Join-Path $tmp "inprogressahead\lock")
Assert "in-progress ahead repo does not push" { -not (Remote-Contains (Join-Path $tmp "inprogressahead\remote.git") "main" "should-not-push") }

New-Fixture (Join-Path $tmp "partiallock")
Commit-InRepo (Join-Path $tmp "partiallock\other") "partial"
Git -C (Join-Path $tmp "partiallock\other") push | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp "partiallock\dotfiles-git-sync.lock.d") -Force | Out-Null
Write-List (Join-Path $tmp "partiallock\work") (Join-Path $tmp "partiallock\list")
Run-AutoGit (Join-Path $tmp "partiallock\list") (Join-Path $tmp "partiallock\dotfiles-git-sync.lock.d")
Assert "partial owner lock blocks auto-git" { -not ((Get-Content (Join-Path $tmp "partiallock\work\file.txt") -Raw) -match "partial") }

New-Fixture (Join-Path $tmp "lockheld")
Commit-InRepo (Join-Path $tmp "lockheld\other") "locked"
Git -C (Join-Path $tmp "lockheld\other") push | Out-Null
$heldLock = Join-Path $tmp "lockheld\dotfiles-git-sync.lock.d"
New-Item -ItemType Directory -Path $heldLock -Force | Out-Null
$heldOwner = @{ pid = "$PID"; host = [System.Net.Dns]::GetHostName(); runtime = (Current-Runtime); started_at = "1"; heartbeat_at = "1"; process_start = (Current-ProcessStart) }
$heldOwner | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $heldLock "owner.json") -NoNewline
Write-List (Join-Path $tmp "lockheld\work") (Join-Path $tmp "lockheld\list")
Run-AutoGit (Join-Path $tmp "lockheld\list") $heldLock
Assert "live lock holder blocks PowerShell auto-git" { -not ((Get-Content (Join-Path $tmp "lockheld\work\file.txt") -Raw) -match "locked") }
Assert "live lock holder is not reclaimed by PowerShell auto-git" { Test-Path $heldLock }

New-Fixture (Join-Path $tmp "deadlock")
Commit-InRepo (Join-Path $tmp "deadlock\other") "deadlock"
Git -C (Join-Path $tmp "deadlock\other") push | Out-Null
$deadLock = Join-Path $tmp "deadlock\dotfiles-git-sync.lock.d"
New-Item -ItemType Directory -Path $deadLock -Force | Out-Null
$deadOwner = @{ pid = "99999999"; host = [System.Net.Dns]::GetHostName(); runtime = (Current-Runtime); started_at = "1"; heartbeat_at = "1"; process_start = "dead" }
$deadOwner | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $deadLock "owner.json") -NoNewline
Write-List (Join-Path $tmp "deadlock\work") (Join-Path $tmp "deadlock\list")
Run-AutoGit (Join-Path $tmp "deadlock\list") $deadLock
Assert "same-runtime dead owner lock is reclaimed" { (Get-Content (Join-Path $tmp "deadlock\work\file.txt") -Raw) -match "deadlock" }

New-Fixture (Join-Path $tmp "foreignlock")
Commit-InRepo (Join-Path $tmp "foreignlock\other") "foreignlock"
Git -C (Join-Path $tmp "foreignlock\other") push | Out-Null
$foreignLock = Join-Path $tmp "foreignlock\dotfiles-git-sync.lock.d"
New-Item -ItemType Directory -Path $foreignLock -Force | Out-Null
$foreignOwner = @{ pid = "99999999"; host = [System.Net.Dns]::GetHostName(); runtime = "foreign-runtime"; started_at = "1"; heartbeat_at = "1"; process_start = "dead" }
$foreignOwner | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $foreignLock "owner.json") -NoNewline
Write-List (Join-Path $tmp "foreignlock\work") (Join-Path $tmp "foreignlock\list")
Run-AutoGit (Join-Path $tmp "foreignlock\list") $foreignLock
Assert "foreign-runtime lock blocks auto-git" { -not ((Get-Content (Join-Path $tmp "foreignlock\work\file.txt") -Raw) -match "foreignlock") }

Assert "auto-git.ps1 never aborts rebase" { -not ((Get-Content $AutoPs1 -Raw) -match "rebase --abort") }
Assert "PowerShell bootstrap registers disabled task atomically" { (Get-Content $BootstrapPs1 -Raw) -match "<Enabled>false</Enabled>" }
Assert "PowerShell bootstrap has no unguarded task enable/start" { Test-NoUnguardedTaskEnable $BootstrapPs1 }
$xmlOut = Join-Path $tmp "default-task.xml"
Invoke-BootstrapXml $BootstrapPs1 $xmlOut
Assert "PowerShell bootstrap XML is disabled by default" { (Get-Content $xmlOut -Raw) -match "<Enabled>false</Enabled>" }

# Self-clean the gitignored test temp tree on exit (parity with the .sh half).
Remove-Item -LiteralPath $TestTmpParent -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "auto-git PowerShell safety: $script:Pass passed, $script:Fail failed"
if ($script:Fail -ne 0) { exit 1 }
