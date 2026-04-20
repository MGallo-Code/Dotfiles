# Core dev shell commands (PowerShell)

function sync { & "$HOME\.dotfiles\sync.ps1" }

function proj {
    param(
        [Parameter(Position=0)]
        [string]$Name,
        [Alias('n')]
        [switch]$New
    )

    $ProjectDir = "$HOME\Documents\Projects"

    if ($New) {
        if (-not $Name) {
            Write-Host "Error: Please provide a name for the new project."
            Write-Host "Usage: proj -n <project_name>"
            return
        }
        $Target = Join-Path $ProjectDir $Name
        if (Test-Path $Target) {
            Write-Host "Error: Directory '$Name' already exists."
            return
        }
        Write-Host "Creating project '$Name'..."
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        Set-Location $Target
    }
    else {
        if (-not $Name) {
            Set-Location $ProjectDir
        }
        else {
            $Target = Join-Path $ProjectDir $Name
            if (Test-Path $Target) {
                Set-Location $Target
            }
            else {
                Write-Host "Error: Project '$Name' not found. Use flag '-n' to create a new project"
                Write-Host "Usage: proj -n <project_name>"
            }
        }
    }
}

# Tab completion for proj
Register-ArgumentCompleter -CommandName proj -ParameterName Name -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    $ProjectDir = "$HOME\Documents\Projects"
    if (Test-Path $ProjectDir) {
        Get-ChildItem -Path $ProjectDir -Directory |
            Where-Object { $_.Name -like "$wordToComplete*" } |
            ForEach-Object { $_.Name }
    }
}

# Launch Claude Code with local models on remote PC via Tailscale
function _ollama_claude {
    param([string]$Model, [Parameter(ValueFromRemainingArguments)]$Args)
    $env:ANTHROPIC_AUTH_TOKEN = "ollama"
    $env:ANTHROPIC_API_KEY = ""
    $env:ANTHROPIC_BASE_URL = "http://100.124.149.107:11434"
    & claude --model $Model @Args
    Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
}

function qwen { _ollama_claude "qwen3.5:27b" @args }
function qwen-coder { _ollama_claude "qwen2.5-coder:32b" @args }
function gemma { _ollama_claude "gemma4:26b" @args }
function gemma31b { _ollama_claude "gemma4:31b" @args }
