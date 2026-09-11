# Regenerate the Codex/Gemini combined rule files (~\.codex\AGENTS.md, ~\.gemini\GEMINI.md)
# from EA's global-rules\*.md, outside a full setup/sync. Called by EA's post-commit,
# post-merge and post-checkout hooks so a rule change reaches every agent without waiting
# for the next sync.
# Same function setup.ps1/sync.ps1 call; this only supplies the helpers they define.
#   -Quiet   print nothing when the targets are already current
# macOS/Linux twin: regen-agent-rules.sh.
param([switch]$Quiet)

$DotfilesDir = Split-Path -Parent $PSScriptRoot
function Write-Ok   { param($msg) Write-Host "[ok] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }

$CombinedRulesQuiet = [bool]$Quiet

. "$DotfilesDir\manifest.ps1"
Regen-CombinedAgentRules
