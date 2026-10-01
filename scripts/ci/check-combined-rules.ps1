# check-combined-rules.ps1 - INV-15 enforcer (PowerShell half; bash half: check-combined-rules.sh).
#
# Hermetic: dot-sources the real manifest.ps1, points Regen-CombinedAgentRules at a throwaway
# source dir and targets, and asserts the same contract as the bash half:
#   - both targets are generated from every source file, identical, and read-only
#   - $CombinedRulesQuiet prints nothing when current; a write is always reported
#   - a case-only source change propagates (the comparison is case-sensitive, like cmp)
#   - a stale copy (its body still matches the header hash) is replaced without a backup
#   - every other differing copy - unlocked edit, edit that kept ReadOnly, or a legacy
#     header - is warned about and saved under its own name, and no later run ever
#     overwrites an earlier backup
#   - an empty source or an unreadable rule file never replaces a real ruleset
#   - a copy that cannot be backed up is left unchanged, even when a write would succeed
#     (Windows only: needs icacls)
#   - a retired target (ADR-0004) is removed when it still carries our header, saved first
#     when hand-edited, and never touched when it is the user's own file
# Also parses regen-agent-rules.ps1 (the entrypoint dotfiles' git hooks call on Windows).
# Exit 0 = all assertions hold, 1 = a regression.
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$T = Join-Path ([System.IO.Path]::GetTempPath()) ("combined-rules-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $T | Out-Null
$script:Fail = $false
$script:Log = [System.Collections.Generic.List[string]]::new()

function Write-Ok   { param($msg) $script:Log.Add("[ok] $msg") }
function Write-Warn { param($msg) $script:Log.Add("[!] $msg") }
function Expect { param($name, [bool]$cond) if ($cond) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name"; $script:Fail = $true } }
function Says { param($text) return [bool]($script:Log | Where-Object { $_ -like "*$text*" }) }
function Has { param($path, $text) return ([System.IO.File]::ReadAllText($path)).Contains($text) }
function Locked { param($path) return (Test-Path $path) -and (Get-Item $path).IsReadOnly }
function Backups { param($path) return @(Get-ChildItem -Path (Split-Path $path -Parent) -Filter ((Split-Path $path -Leaf) + '.sync-backup-*') -File) }
function BackedUp { param($path, $text) return [bool](Backups $path | Where-Object { Has $_.FullName $text }) }
function Unlock-AndEdit { param($path, $text)
    Set-ItemProperty -Path $path -Name IsReadOnly -Value $false
    Add-Content -Path $path -Value $text
}
function Locked-Edit { param($path, $text)
    Unlock-AndEdit $path $text
    Set-ItemProperty -Path $path -Name IsReadOnly -Value $true
}
function Regen { param([switch]$Quiet)
    $script:Log.Clear()
    $script:CombinedRulesQuiet = [bool]$Quiet
    Regen-CombinedAgentRules
}

try {
    . (Join-Path $Root 'manifest.ps1')
    # Override AFTER dot-sourcing: $HOME is read-only in PowerShell, so repoint the
    # function's inputs instead of the home directory.
    $GlobalRulesDir = Join-Path $T 'global-rules'
    $Cx = Join-Path $T 'codex\AGENTS.md'
    $Gm = Join-Path $T 'gemini\GEMINI.md'
    $CombinedRulesTargets = @($Cx, $Gm)
    $RetiredCombinedRulesTargets = @()
    New-Item -ItemType Directory -Path $GlobalRulesDir | Out-Null
    Set-Content -Path (Join-Path $GlobalRulesDir 'a.md') -Value "# Rule A`nalpha"
    Set-Content -Path (Join-Path $GlobalRulesDir 'b.md') -Value "# Rule B`nbravo"

    Write-Host "check-combined-rules (ps1): entrypoint parses"
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'scripts\regen-agent-rules.ps1'), [ref]$null, [ref]$errs) | Out-Null
    Expect "regen-agent-rules.ps1 has no parse errors" ($errs.Count -eq 0)

    Write-Host "check-combined-rules (ps1): fresh generate"
    Regen -Quiet
    Expect "codex target has every source file" ((Has $Cx 'alpha') -and (Has $Cx 'bravo'))
    Expect "gemini target identical to codex" ([System.IO.File]::ReadAllText($Cx) -ceq [System.IO.File]::ReadAllText($Gm))
    Expect "both targets read-only" ((Locked $Cx) -and (Locked $Gm))
    Expect "a write is reported even when quiet" (Says 'generated')

    Write-Host "check-combined-rules (ps1): idempotent"
    Regen -Quiet
    Expect "quiet prints nothing when current" ($script:Log.Count -eq 0)
    Regen
    Expect "not quiet, reports current" (Says 'already current')

    Write-Host "check-combined-rules (ps1): case-only change"
    Set-Content -Path (Join-Path $GlobalRulesDir 'a.md') -Value "# Rule A`nALPHA"
    Regen -Quiet
    Expect "case-only change propagates" (Has $Cx 'ALPHA')

    Write-Host "check-combined-rules (ps1): source changed (stale copy)"
    Set-Content -Path (Join-Path $GlobalRulesDir 'c.md') -Value "# Rule C`ncharlie"
    Regen -Quiet
    Expect "target picks up the new source file" (Has $Cx 'charlie')
    Expect "stale copy replaced without a backup" ((Backups $Cx).Count -eq 0)
    Expect "stale copy is not reported as a hand-edit" (-not (Says 'did not match'))
    Expect "target read-only again" (Locked $Cx)

    Write-Host "check-combined-rules (ps1): hand-edited copy, twice, then a stale regen"
    Unlock-AndEdit $Cx 'HAND EDIT ONE'
    Regen -Quiet
    Expect "first hand-edit warned" (Says 'did not match')
    Expect "first hand-edit saved" (BackedUp $Cx 'HAND EDIT ONE')
    Expect "target restored from source and read-only" ((Locked $Cx) -and -not (Has $Cx 'HAND EDIT ONE'))
    Unlock-AndEdit $Cx 'HAND EDIT TWO'
    Regen -Quiet
    Expect "second hand-edit saved under its own name" ((Backups $Cx).Count -eq 2)
    Expect "second hand-edit saved" (BackedUp $Cx 'HAND EDIT TWO')
    Expect "first backup survives the second" (BackedUp $Cx 'HAND EDIT ONE')
    Set-Content -Path (Join-Path $GlobalRulesDir 'd.md') -Value "# Rule D`ndelta"
    Regen -Quiet
    Expect "a later stale regen leaves both backups" ((Backups $Cx).Count -eq 2)
    Expect "first backup survives a stale regen" (BackedUp $Cx 'HAND EDIT ONE')

    Write-Host "check-combined-rules (ps1): edit that kept ReadOnly"
    Locked-Edit $Cx 'LOCKED EDIT'
    Regen -Quiet
    Expect "locked edit warned" (Says 'did not match')
    Expect "locked edit saved" (BackedUp $Cx 'LOCKED EDIT')
    Expect "earlier backups untouched" ((Backups $Cx).Count -eq 3)

    Write-Host "check-combined-rules (ps1): legacy header (no hash)"
    Set-ItemProperty -Path $Gm -Name IsReadOnly -Value $false
    [System.IO.File]::WriteAllText($Gm, "<!-- AUTO-GENERATED by dotfiles from x. Edit the source rule files, not this copy. -->`n`nOLD RULES`n")
    Set-ItemProperty -Path $Gm -Name IsReadOnly -Value $true
    Regen -Quiet
    Expect "legacy copy saved" (BackedUp $Gm 'OLD RULES')
    Expect "legacy copy regenerated" (Has $Gm 'delta')

    Write-Host "check-combined-rules (ps1): empty source"
    $aside = Join-Path $T 'aside'
    New-Item -ItemType Directory -Path $aside | Out-Null
    Get-ChildItem -Path $GlobalRulesDir -Filter *.md | Move-Item -Destination $aside
    $before = [System.IO.File]::ReadAllText($Cx)
    Regen -Quiet
    Expect "empty source reported" (Says 'no readable rule files')
    Expect "empty source leaves the target unchanged" ([System.IO.File]::ReadAllText($Cx) -ceq $before)
    Get-ChildItem -Path $aside -Filter *.md | Move-Item -Destination $GlobalRulesDir

    Write-Host "check-combined-rules (ps1): retired target (ADR-0004)"
    $Rt = Join-Path $T 'retired\GEMINI.md'
    New-Item -ItemType Directory -Path (Split-Path $Rt -Parent) -Force | Out-Null
    $RetiredCombinedRulesTargets = @($Rt)
    [System.IO.File]::WriteAllText($Rt, [System.IO.File]::ReadAllText($Cx))
    Set-ItemProperty -Path $Rt -Name IsReadOnly -Value $true
    Regen -Quiet
    Expect "pristine retired copy removed" (-not (Test-Path $Rt))
    Expect "pristine retired copy not backed up" ((Backups $Rt).Count -eq 0)
    [System.IO.File]::WriteAllText($Rt, [System.IO.File]::ReadAllText($Cx))
    Locked-Edit $Rt 'HAND EDIT'
    Regen -Quiet
    Expect "edited retired copy removed" (-not (Test-Path $Rt))
    Expect "edited retired copy saved first" (BackedUp $Rt 'HAND EDIT')
    [System.IO.File]::WriteAllText($Rt, "# my own gemini notes`n")
    Regen -Quiet
    Expect "user-authored file at a retired path untouched" (Has $Rt 'my own gemini notes')
    $RetiredCombinedRulesTargets = @()

    if ($env:OS -eq 'Windows_NT') {
        $me = "$($env:USERNAME):(RD)"
        Write-Host "check-combined-rules (ps1): unreadable rule file"
        $rule = Join-Path $GlobalRulesDir 'b.md'
        $before = [System.IO.File]::ReadAllText($Cx)
        & icacls $rule /deny $me | Out-Null
        try { Regen -Quiet } finally { & icacls $rule /remove:d "$($env:USERNAME)" | Out-Null }
        Expect "unreadable rule file reported" (Says 'could not read')
        Expect "unreadable rule file leaves the target unchanged" ([System.IO.File]::ReadAllText($Cx) -ceq $before)

        Write-Host "check-combined-rules (ps1): backup impossible, write possible"
        # Deny reading the target's data: the backup copy fails, while clearing ReadOnly and
        # moving over it would still succeed, so only the fail-closed branch keeps the edit.
        Unlock-AndEdit $Gm 'UNSAVEABLE EDIT'
        & icacls $Gm /deny $me | Out-Null
        try { Regen -Quiet } finally { & icacls $Gm /remove:d "$($env:USERNAME)" | Out-Null }
        Expect "unsaveable copy reported" (Says 'could not save')
        Expect "unsaveable copy left unchanged" (Has $Gm 'UNSAVEABLE EDIT')
    }
}
finally {
    Get-ChildItem -Path $T -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -Path $T -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Fail) { Write-Host "check-combined-rules (ps1): FAILED"; exit 1 }
Write-Host "check-combined-rules (ps1) OK"
