# GIT_AUTOSYNC_BOOTSTRAP

param(
    [switch]$Enable,
    [switch]$Disable,
    [int]$IntervalSeconds = 1800
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
$autoGit = Join-Path $repoRoot "auto-git.ps1"
$stateDir = Join-Path $HOME ".local\state\dotfiles"
$log = Join-Path $stateDir "git-autosync.log"
$taskName = if ($env:GIT_AUTOSYNC_TEST_TASK_NAME) { $env:GIT_AUTOSYNC_TEST_TASK_NAME } else { "EA Git Autosync" }
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

$escapedArgs = [System.Security.SecurityElement]::Escape("-NoProfile -ExecutionPolicy Bypass -File `"$autoGit`"")
$startBoundary = (Get-Date).Date.ToString("s")
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Dormant by default. Runs dotfiles auto-git when explicitly enabled.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
      <Repetition>
        <Interval>PT${IntervalSeconds}S</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>false</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$escapedArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

if ($env:GIT_AUTOSYNC_TEST_XML_OUT) {
    Set-Content -Path $env:GIT_AUTOSYNC_TEST_XML_OUT -Value $taskXml
    Write-Host "[ok] wrote Task Scheduler XML: $($env:GIT_AUTOSYNC_TEST_XML_OUT)"
    return
}

Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
Write-Host "[ok] wrote disabled Task Scheduler task: $taskName"
Write-Host "[ok] log path: $log"

if ($Disable) {
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    Write-Host "[ok] git autosync disabled"
}

if ($Enable) {
    Enable-ScheduledTask -TaskName $taskName | Out-Null
    if (-not $env:GIT_AUTOSYNC_TEST_NO_START) {
        Start-ScheduledTask -TaskName $taskName
    }
    Write-Host "[ok] git autosync enabled"
}
