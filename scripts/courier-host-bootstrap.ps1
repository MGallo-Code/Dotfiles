# courier-host-bootstrap.ps1  --  COURIER-HOST-BOOTSTRAP (ADR-0002), Windows guard.
#
# Windows is NEVER the mail host: courier needs the macOS *login keychain* (himalaya
# reads 14 account passwords from it), which has no equivalent here. So there is no
# host bootstrap to perform on Windows - this machine is always a courier CLIENT,
# wired by setup.ps1 to reach the mail host over Tailscale.
#
# This guard exists so the host-bootstrap behavior is PAIRED with courier-host-bootstrap.sh
# (parity-checked: scripts/ci/check-parity.py) and so an accidental invocation states
# the role clearly instead of pretending to bootstrap a host.
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "manifest.ps1")   # for $MailHost / $CourierRemoteUrl

Write-Host "courier host bootstrap is macOS-only; Windows is always a CLIENT of mail host '$MailHost'." -ForegroundColor Yellow
Write-Host "Nothing to bootstrap here. setup.ps1 wires the courier HTTP client -> $CourierRemoteUrl" -ForegroundColor Yellow
exit 0
