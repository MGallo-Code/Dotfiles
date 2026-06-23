# hub-host-bootstrap.ps1  --  HUB-HOST-BOOTSTRAP (ADR-0002, remote-hubs Phase A), Windows guard.
#
# Windows is NEVER the host for any MCP hub: the host role needs macOS launchd + (for courier)
# the macOS *login keychain* (himalaya reads 14 account passwords from it) + `tailscale serve`,
# none of which apply here. So there is no host bootstrap to perform on Windows - this machine is
# always a CLIENT, wired by setup.ps1 to reach the hubs on the MCP host over Tailscale.
#
# This guard exists so the host-bootstrap behavior is PAIRED with hub-host-bootstrap.sh
# (parity-checked: scripts/ci/check-parity.py) and so an accidental invocation states the role
# clearly instead of pretending to bootstrap a host. Accepts (and ignores) the same args the .sh
# takes so a registry-driven caller can invoke it uniformly.
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "manifest.ps1")   # for $McpHost / $CourierRemoteUrl

$hubName = if ($args.Count -ge 1) { $args[0] } else { "hub" }
Write-Host "hub host bootstrap is macOS-only; Windows is always a CLIENT of host '$McpHost'." -ForegroundColor Yellow
Write-Host "Nothing to bootstrap here for '$hubName'. setup.ps1 wires the HTTP client(s) -> $CourierRemoteUrl" -ForegroundColor Yellow
exit 0
