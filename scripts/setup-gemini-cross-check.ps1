param(
  [string]$Model = "gemini-3.1-flash-lite",
  [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"

$ConfigDir = Join-Path $HOME ".config\ea"
$SecretPath = Join-Path $ConfigDir "gemini-api-key.dpapi"
$LocalBin = Join-Path $HOME ".local\bin"
$WrapperPath = Join-Path $LocalBin "gemini-flash-lite.ps1"
$ShimPath = Join-Path $LocalBin "gemini.cmd"
$SettingsPath = Join-Path $HOME ".gemini\settings.json"

function Assert-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $Name"
  }
}

function Protect-SecretFile {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return }
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  & icacls $Path /inheritance:r /grant:r "${identity}:F" *> $null
}

function Read-GeminiApiKey {
  if ($env:GEMINI_API_KEY) {
    return $env:GEMINI_API_KEY
  }
  if (-not (Test-Path $SecretPath)) {
    return ""
  }

  $secure = Get-Content $SecretPath -Raw | ConvertTo-SecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Store-GeminiApiKey {
  New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null

  $hasExisting = Test-Path $SecretPath
  if ($hasExisting) {
    Write-Host "A Gemini key is already stored in $SecretPath."
    $secure = Read-Host "Press Enter to keep it, or paste a replacement key" -AsSecureString
  }
  else {
    $secure = Read-Host "Paste GEMINI_API_KEY for Gemini CLI" -AsSecureString
  }

  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }

  if ([string]::IsNullOrWhiteSpace($plain)) {
    if ($hasExisting) {
      Write-Host "Keeping existing DPAPI-protected Gemini key."
      return
    }
    throw "No key provided and no existing key found."
  }

  $plain | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -Path $SecretPath -NoNewline
  Remove-Variable plain
  Protect-SecretFile $SecretPath
  Write-Host "Stored Gemini API key in a DPAPI-protected per-user file."
}

function Add-UserPathEntry {
  param([string]$PathEntry)

  $current = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @()
  if ($current) {
    $parts = $current -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  }

  $alreadyPresent = $false
  foreach ($part in $parts) {
    if ($part.TrimEnd("\") -ieq $PathEntry.TrimEnd("\")) {
      $alreadyPresent = $true
      break
    }
  }

  if (-not $alreadyPresent) {
    $updated = @($PathEntry) + $parts
    [Environment]::SetEnvironmentVariable("Path", ($updated -join ";"), "User")
    $env:Path = "$PathEntry;$env:Path"
    Write-Host "Prepended $PathEntry to the user PATH."
  }
}

function Write-GeminiWrapper {
  New-Item -ItemType Directory -Path $LocalBin -Force | Out-Null

  $wrapper = @'
$ErrorActionPreference = "Stop"

$GeminiArgs = $args
$Model = if ($env:GEMINI_MODEL) { $env:GEMINI_MODEL } elseif ($env:GEMINI_CROSS_CHECK_MODEL) { $env:GEMINI_CROSS_CHECK_MODEL } else { "__MODEL__" }
$SecretPath = Join-Path $HOME ".config\ea\gemini-api-key.dpapi"
$ShimPath = Join-Path $HOME ".local\bin\gemini.cmd"

function Read-DpapiSecret {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return "" }
  $secure = Get-Content $Path -Raw | ConvertTo-SecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

if (-not $env:GEMINI_API_KEY) {
  $key = Read-DpapiSecret $SecretPath
  if ($key) {
    $env:GEMINI_API_KEY = $key
  }
  Remove-Variable key -ErrorAction SilentlyContinue
}

if (-not $env:GEMINI_API_KEY) {
  throw "GEMINI_API_KEY is not available. Run the setup-gemini-cross-check.ps1 installer."
}

$env:GEMINI_MODEL = $Model
$commands = @(Get-Command gemini -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -and ($_.Source -ine $ShimPath) })
if ($commands.Count -eq 0) {
  throw "Real Gemini CLI not found after excluding shim $ShimPath."
}

& $commands[0].Source @GeminiArgs
exit $LASTEXITCODE
'@
  $wrapper = $wrapper.Replace("__MODEL__", $Model)
  Set-Content -Path $WrapperPath -Value $wrapper

  $shim = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.local\bin\gemini-flash-lite.ps1" %*
"@
  Set-Content -Path $ShimPath -Value $shim

  Add-UserPathEntry $LocalBin
  Write-Host "Created Gemini shim: $ShimPath"
  Write-Host "Created Gemini wrapper: $WrapperPath"
}

function Update-GeminiSettings {
  $settingsDir = Split-Path $SettingsPath -Parent
  New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null

  function ConvertTo-OrderedMap {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
      return [ordered]@{} + $Value
    }
    $map = [ordered]@{}
    if ($null -ne $Value) {
      foreach ($prop in $Value.PSObject.Properties) {
        $map[$prop.Name] = $prop.Value
      }
    }
    return $map
  }

  $settings = [ordered]@{}
  if (Test-Path $SettingsPath) {
    $raw = Get-Content $SettingsPath -Raw
    if ($raw) {
      $obj = $raw | ConvertFrom-Json
      if ($obj) {
        foreach ($prop in $obj.PSObject.Properties) {
          $settings[$prop.Name] = $prop.Value
        }
      }
    }
  }

  $security = if ($settings.Contains("security")) { ConvertTo-OrderedMap $settings["security"] } else { [ordered]@{} }
  $auth = if ($security.Contains("auth")) { ConvertTo-OrderedMap $security["auth"] } else { [ordered]@{} }
  $auth["selectedType"] = "gemini-api-key"
  $security["auth"] = $auth
  $settings["security"] = $security

  $modelMap = if ($settings.Contains("model")) { ConvertTo-OrderedMap $settings["model"] } else { [ordered]@{} }
  $modelMap["name"] = $Model
  $settings["model"] = $modelMap

  $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $SettingsPath
  Write-Host "Updated Gemini settings for API-key auth and model $Model."
}

function Set-ModelEnvironment {
  [Environment]::SetEnvironmentVariable("GEMINI_MODEL", $Model, "User")
  [Environment]::SetEnvironmentVariable("GEMINI_CROSS_CHECK_MODEL", $Model, "User")
  $env:GEMINI_MODEL = $Model
  $env:GEMINI_CROSS_CHECK_MODEL = $Model
}

function Test-Gemini {
  $key = Read-GeminiApiKey
  if ([string]::IsNullOrWhiteSpace($key)) {
    throw "No Gemini key found in the environment or DPAPI secret file."
  }
  $env:GEMINI_API_KEY = $key
  Remove-Variable key

  Write-Host "Verifying Gemini CLI with model $Model..."
  & $WrapperPath --skip-trust --approval-mode plan -m $Model -p "Reply with exactly GEMINI_FLASH_LITE_OK."
}

Assert-Command gemini

if (-not $VerifyOnly) {
  Store-GeminiApiKey
  Set-ModelEnvironment
  Write-GeminiWrapper
  Update-GeminiSettings
}

Test-Gemini
