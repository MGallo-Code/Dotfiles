# EA-specific shell commands (PowerShell)

# ── Workspace launchers ──────────────────────────────────────────────
# Set-Location into a workspace root and open an agent. An optional FIRST flag picks the CLI:
#   --claude (default) | --codex | --gemini ; remaining args pass through.
function Invoke-WsLaunch {
    param([string]$Dir, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    $r = @($Rest)   # force array: a remaining-args param is $null when empty
    $cli = "claude"
    if ($r.Count -ge 1) {
        switch ($r[0]) {
            "--claude" { $cli = "claude"; $r = @($r | Select-Object -Skip 1) }
            "--codex"  { $cli = "codex";  $r = @($r | Select-Object -Skip 1) }
            "--gemini" { $cli = "gemini"; $r = @($r | Select-Object -Skip 1) }
        }
    }
    Set-Location $Dir
    & $cli @r
}

function ea   { Invoke-WsLaunch "$HOME\Documents\EA" @args }        # active personal ops + MCP tools
function wiki { Invoke-WsLaunch "$HOME\Documents\Wiki" @args }      # LLM-curated research

# Update the Michael Workspace SYSTEM: open an agent in the dotfiles control plane (manifest.sh
# = root/role map). Claude (default) gets the EA + agent-skills source roots added; Codex/Gemini
# already see the whole workspace via the michael_workspace profile. Same --claude/--codex/--gemini flag.
function sysupdate {
    Set-Location "$HOME\.dotfiles"
    $rest = $args
    if ($rest.Count -ge 1 -and $rest[0] -eq "--codex")  { & codex  @($rest | Select-Object -Skip 1); return }
    if ($rest.Count -ge 1 -and $rest[0] -eq "--gemini") { & gemini @($rest | Select-Object -Skip 1); return }
    if ($rest.Count -ge 1 -and $rest[0] -eq "--claude") { $rest = @($rest | Select-Object -Skip 1) }
    & claude --add-dir "$HOME\Documents\EA" --add-dir "$HOME\Documents\agent-skills" @rest
}

# Tab-complete the agent flags for the workspace launchers.
$WsAgentCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)
    @('--claude', '--codex', '--gemini') |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterName', $_) }
}
Register-ArgumentCompleter -CommandName ea, wiki, sysupdate -ScriptBlock $WsAgentCompleter

function practice {
    $WorkspaceDir = "$HOME\Documents\EA\exercises\workspace"
    $VenvDir = "$HOME\Documents\EA\exercises\.venv"

    New-Item -ItemType Directory -Path $WorkspaceDir -Force | Out-Null

    if (-not (Test-Path "$VenvDir\Scripts\Activate.ps1")) {
        Write-Host "Setting up practice environment..."
        & python3 -m venv $VenvDir
        & "$VenvDir\Scripts\pip.exe" install pytest
        Write-Host "Done!"
    }

    & "$VenvDir\Scripts\Activate.ps1"
    Set-Location $WorkspaceDir
    & nvim .
}
