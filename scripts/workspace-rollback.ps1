# workspace-rollback.ps1 - undo the ADR-0007 move on this machine (INV-21). Mirror of
# workspace-rollback.sh: replays the migration journal in reverse. Then check out the dotfiles commit
# before ADR-0007 and run sync, or the next sync moves them again.
$DotfilesDir = Split-Path -Parent $PSScriptRoot
function Write-Ok   { param($msg) Write-Host "[ok] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "[error] $msg" -ForegroundColor Red }
. (Join-Path $DotfilesDir "manifest.ps1")
if (-not (Undo-WorkspaceMigration)) { exit 1 }
