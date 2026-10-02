# Sync all managed repos - pull updates, detect local changes, hand off to Claude for commits

$DotfilesDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$DotfilesDir\manifest.ps1"

# INV-6: set true when the machine-state skill-target check fails, so sync exits non-zero at
# the end (parity with sync.sh's SKILL_TARGET_FAIL). Initialized here so the end-of-run read
# is always defined.
$SkillTargetFail = $false

function Set-AgentDefaults { # AGENT_DEFAULTS_CONFIG
    $codexDir = Join-Path $HOME ".codex"
    $codexConfig = Join-Path $codexDir "config.toml"
    New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
    $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $pythonCmd) { throw "Agent defaults require Python; refusing partial configuration" }
    & $pythonCmd.Source (Join-Path $DotfilesDir "scripts/configure-codex-defaults.py") --home $HOME | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Codex settings are unsupported or inaccessible; defaults were not changed" }
    Write-Ok "Codex: defaults set (xhigh reasoning + full-access permissions)"

    # $CodexPin drift check (pin is canonical in the manifests; parity: sync.sh CODEX_PIN).
    # Warn-only: sync can't fix a version mismatch itself, and a blocked sync is worse.
    $codexCmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($codexCmd -and $CodexPin) {
        $codexInstalled = ((& $codexCmd.Source --version 2>$null | Select-Object -First 1) -replace '^codex-cli\s+', '').Trim()
        if ($codexInstalled -ne $CodexPin) {
            Write-Warn "Codex $codexInstalled drifts from pin $CodexPin - preflight (scripts/codex-pin-preflight.sh), then: npm install -g @openai/codex@$CodexPin"
        }
    }

    # Codex PreToolUse guards. Registration is machine-local in config.toml; scripts ride the
    # Claude global-hooks symlink and run via bash on Windows. Trust once via Codex /hooks.
    function Ensure-CodexPreToolUseHook {
        param([string]$Marker, [string]$Command, [string]$Label)
        $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        $codexExisting = if (Test-Path $codexConfig) { [IO.File]::ReadAllText($codexConfig, $utf8) } else { "" }
        # Key on the COMMAND path, not the marker comment: Codex strips the comment on rewrite
        # (block/command survive), so keying on the marker re-appended a duplicate block each sync.
        if ($codexExisting -notlike "*$Command*") {
        $codexGuardBlock = @"

$Marker
[[hooks.PreToolUse]]
matcher = "^Bash`$"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = '$Command'
  timeout = 30
"@
        [IO.File]::AppendAllText($codexConfig, $codexGuardBlock + "`n", $utf8)
            Write-Ok "Codex: wired $Label (run /hooks once to trust it)"
        } else {
            Write-Ok "Codex $Label already wired"
        }
    }
    Ensure-CodexPreToolUseHook "# dotfiles: flat-PR stacked-push guard" "bash `"$HOME/.claude/hooks/warn-stacked-git-push.sh`"" "stacked-push guard"

    & $pythonCmd.Source (Join-Path $DotfilesDir "scripts/configure-claude-defaults.py") --home $HOME | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Claude settings are malformed or inaccessible; defaults were not changed" }
    Write-Ok "Claude: user default permission mode set (auto)"

    $geminiDir = Join-Path $HOME ".gemini"
    $geminiSettings = Join-Path $geminiDir "settings.json"
    New-Item -ItemType Directory -Path $geminiDir -Force | Out-Null
    $settings = [ordered]@{}
    if (Test-Path $geminiSettings) {
        $raw = Get-Content $geminiSettings -Raw
        if ($raw) {
            $obj = $raw | ConvertFrom-Json
            if ($obj) {
                foreach ($prop in $obj.PSObject.Properties) {
                    $settings[$prop.Name] = $prop.Value
                }
            }
        }
    }
    if (-not $settings.Contains("general") -or $null -eq $settings["general"]) {
        $settings["general"] = [ordered]@{}
    }
    $general = $settings["general"]
    if (-not ($general -is [System.Collections.IDictionary])) {
        $newGeneral = [ordered]@{}
        foreach ($prop in $general.PSObject.Properties) {
            $newGeneral[$prop.Name] = $prop.Value
        }
        $general = $newGeneral
        $settings["general"] = $general
    }
    $general["defaultApprovalMode"] = "auto_edit"
    # Keep Gemini focused on source/control-plane roots. Do not append broad parents or
    # agent-state dirs; that caused reviews to roam caches, downloads, and stale generated
    # content after sync.
    $nvimRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "nvim" } else { Join-Path $HOME "AppData\Local\nvim" }
    $geminiWorkspaceRoots = @(
        (Get-WorkspaceHome "EA"),
        (Get-WorkspaceHome "GalloGrid"),
        "$HOME\.dotfiles",
        $nvimRoot
    ) | Where-Object { Test-Path $_ } | ForEach-Object { (Resolve-Path $_).Path }
    if (-not $settings.Contains("context") -or $null -eq $settings["context"]) {
        $settings["context"] = [ordered]@{}
    }
    $context = $settings["context"]
    if (-not ($context -is [System.Collections.IDictionary])) {
        $newContext = [ordered]@{}
        foreach ($prop in $context.PSObject.Properties) {
            $newContext[$prop.Name] = $prop.Value
        }
        $context = $newContext
        $settings["context"] = $context
    }
    $context["includeDirectories"] = $geminiWorkspaceRoots
    if (-not $settings.Contains("tools") -or $null -eq $settings["tools"]) {
        $settings["tools"] = [ordered]@{}
    }
    $tools = $settings["tools"]
    if (-not ($tools -is [System.Collections.IDictionary])) {
        $newTools = [ordered]@{}
        foreach ($prop in $tools.PSObject.Properties) {
            $newTools[$prop.Name] = $prop.Value
        }
        $tools = $newTools
        $settings["tools"] = $tools
    }
    $tools["sandboxAllowedPaths"] = $geminiWorkspaceRoots
    $tools["sandboxNetworkAccess"] = $true
    if (-not $settings.Contains("security") -or $null -eq $settings["security"]) {
        $settings["security"] = [ordered]@{}
    }
    $security = $settings["security"]
    if (-not ($security -is [System.Collections.IDictionary])) {
        $newSecurity = [ordered]@{}
        foreach ($prop in $security.PSObject.Properties) {
            $newSecurity[$prop.Name] = $prop.Value
        }
        $security = $newSecurity
        $settings["security"] = $security
    }
    if (-not $security.Contains("auth") -or $null -eq $security["auth"]) {
        $security["auth"] = [ordered]@{}
    }
    $auth = $security["auth"]
    if (-not ($auth -is [System.Collections.IDictionary])) {
        $newAuth = [ordered]@{}
        foreach ($prop in $auth.PSObject.Properties) {
            $newAuth[$prop.Name] = $prop.Value
        }
        $auth = $newAuth
        $security["auth"] = $auth
    }
    $auth["selectedType"] = "gemini-api-key"
    if (-not $settings.Contains("model") -or $null -eq $settings["model"]) {
        $settings["model"] = [ordered]@{}
    }
    $model = $settings["model"]
    if (-not ($model -is [System.Collections.IDictionary])) {
        $newModel = [ordered]@{}
        foreach ($prop in $model.PSObject.Properties) {
            $newModel[$prop.Name] = $prop.Value
        }
        $model = $newModel
        $settings["model"] = $model
    }
    $model["name"] = "gemini-3.1-flash-lite"
    $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $geminiSettings
    Write-Ok "Gemini: defaults set (auto_edit + workspace roots + gemini-3.1-flash-lite API-key auth)"
}

function Ensure-GeminiCrossCheckSetup { # GEMINI_CROSS_CHECK_SETUP
    if (-not (Get-Command gemini -ErrorAction SilentlyContinue)) {
        Write-Warn "Gemini cross-check: gemini CLI not found - install Gemini, then rerun sync"
        return
    }
    $script = Join-Path $DotfilesDir "scripts\setup-gemini-cross-check.ps1"
    if (-not (Test-Path $script)) {
        Write-Warn "Gemini cross-check: setup script missing at $script"
        return
    }

    $secret = Join-Path $HOME ".config\ea\gemini-api-key.dpapi"
    $shim = Join-Path $HOME ".local\bin\gemini.cmd"
    $ready = $env:GEMINI_API_KEY -or ((Test-Path $secret) -and (Test-Path $shim))
    if ($ready) {
        Write-Ok "Gemini cross-check setup present"
        return
    }

    Write-Warn "Gemini cross-check setup incomplete - launching installer"
    try {
        & powershell -ExecutionPolicy Bypass -File $script
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Gemini cross-check setup incomplete; rerun: powershell -ExecutionPolicy Bypass -File $script"
        }
    }
    catch {
        Write-Warn "Gemini cross-check setup incomplete; rerun: powershell -ExecutionPolicy Bypass -File $script"
    }
}

function Write-Ok   { param($msg) Write-Host "[ok] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "[error] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "[info] $msg" -ForegroundColor Cyan }

$Updated  = @()
$Pushed   = @()
$Dirty    = @()
$Diverged = @()
$Missing  = @()

function Sync-Repo {
    param([string]$Target)
    $name = Split-Path $Target -Leaf

    if (-not (Test-Path "$Target\.git")) {
        $script:Missing += $name
        Write-Warn "$name`: not found at $Target"
        return
    }

    Push-Location $Target

    git fetch origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$name`: fetch failed"
        Pop-Location
        return
    }

    $local  = git rev-parse "@"
    $remote = git rev-parse "@{u}" 2>$null
    $base   = git merge-base "@" "@{u}" 2>$null
    $dirty  = git status --porcelain

    if ($dirty) {
        $script:Dirty += $name
        Write-Info "$name`: has uncommitted changes"
        git status --short
        Pop-Location
        return
    }

    if (-not $remote) {
        Write-Warn "$name`: no upstream set"
        Pop-Location
        return
    }

    if ($local -eq $remote) {
        Write-Ok "$name`: up to date"
    }
    elseif ($local -eq $base) {
        git pull --ff-only 2>$null
        if ($LASTEXITCODE -eq 0) {
            $script:Updated += $name
            Write-Ok "$name`: pulled updates"
        }
        else {
            $script:Diverged += $name
            Write-Err "$name`: pull failed"
        }
    }
    elseif ($remote -eq $base) {
        git push 2>$null
        if ($LASTEXITCODE -eq 0) {
            $script:Pushed += $name
            Write-Ok "$name`: pushed to remote"
        }
        else {
            Write-Err "$name`: push failed"
        }
    }
    else {
        $script:Diverged += $name
        Write-Err "$name`: diverged from remote - manual resolution needed"
    }

    Pop-Location
}

# ════════════════════════════════════════════════════════════════════
#  Skill links into each agent (mirrors sync.sh). The agent-skills fork itself is
#  synced like any origin repo; upstream is no longer merged automatically (ADR-0004).
# ════════════════════════════════════════════════════════════════════

function Get-PythonCmd {
    # Prefer a Python with tomllib (3.11+): the allowlist generator and the agent-integration check
    # read Codex TOML, and a Windows box can put an older Store `python3` alias ahead of `python`.
    $first = $null
    foreach ($c in @("python3", "python")) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        if (-not $first) { $first = $cmd.Source }
        & $cmd.Source -c "import tomllib" 2>$null
        if ($LASTEXITCODE -eq 0) { return $cmd.Source }
    }
    return $first
}

# Link each skill subdir of $SrcRoot into every $Targets dir as $Prefix<name>, using a
# directory JUNCTION. Windows Developer Mode is OFF here, so SymbolicLink would need
# elevation; junctions don't. Idempotent; never clobbers a real (non-reparse) dir; leaves
# an existing junction/symlink alone. Mirror of the sh link_skill_dirs (which uses
# symlinks - different mechanism, same behavior). (parity-checked: scripts/ci/check-parity.py)
function Link-SkillDirs {
    param([string]$SrcRoot, [string]$Prefix, [string[]]$Targets)
    if (-not (Test-Path $SrcRoot)) { Write-Warn "skills: no source dir $SrcRoot - skipping"; return }
    foreach ($tgtRoot in $Targets) {
        New-Item -ItemType Directory -Path $tgtRoot -Force | Out-Null
        foreach ($skill in (Get-ChildItem -Path $SrcRoot -Directory)) {
            if ($skill.Name.StartsWith(".")) { continue }   # skip .system etc.
            $link = Join-Path $tgtRoot ($Prefix + $skill.Name)
            if (Test-Path $link) {
                $item = Get-Item $link -Force
                if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    Write-Warn "skills: $link exists as a real path - left untouched"
                }
            }
            else {
                try {
                    New-Item -ItemType Junction -Path $link -Target $skill.FullName -ErrorAction Stop | Out-Null
                    Write-Ok "skills: linked $($Prefix + $skill.Name) -> $(Split-Path $tgtRoot -Leaf)"
                }
                catch {
                    Write-Err "skills: failed to junction $($skill.Name) ($($_.Exception.Message))"
                }
            }
        }
    }
}

function Copy-ProjectSkill {
    param([string]$Source, [string]$Target, [string]$NamespacedName, [bool]$RewriteName)

    $marker = Join-Path $Target ".dotfiles-skill-source"
    if (Test-Path $Target) {
        $item = Get-Item $Target -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ((Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $Source))) {
            Remove-Item $Target -Recurse -Force
        }
        else {
            Write-Warn "skills: $Target exists as a real path - left untouched"
            return
        }
    }

    New-Item -ItemType Directory -Path (Split-Path $Target -Parent) -Force | Out-Null
    Copy-Item -Path $Source -Destination $Target -Recurse -Force
    Set-Content -Path $marker -Value $Source -NoNewline

    $skillFile = Join-Path $Target "SKILL.md"
    if ($RewriteName -and (Test-Path $skillFile)) {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in Get-Content $skillFile) {
            $lines.Add($line)
        }
        if ($lines.Count -gt 0 -and $lines[0].Trim() -eq "---") {
            for ($i = 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Trim() -eq "---") { break }
                if ($lines[$i].StartsWith("name:")) {
                    $lines[$i] = "name: $NamespacedName"
                    Set-Content -Path $skillFile -Value $lines
                    break
                }
            }
        }
    }
    Write-Ok "skills: materialized $NamespacedName -> $(Split-Path $Target -Parent | Split-Path -Leaf)"
}

# Prune generated links and materialized copies whose recorded source no longer exists.
# User-authored real directories have no marker and are never touched. Idempotent.
# (parity-checked: scripts/ci/check-parity.py)
function Test-SkillSourceArchived {
    param([string]$Source)
    foreach ($entry in $ArchivedProjectSkills) {
        $dir = [IO.Path]::GetFullPath($entry.Dir).TrimEnd('\', '/')
        if ([IO.Path]::GetFullPath($Source).StartsWith($dir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Clean-StaleSkillSymlinks {
    $targets = @($AgentSkillsTargets + $ProjectSkillsTargets) | Select-Object -Unique
    foreach ($tgtRoot in $targets) {
        if (-not (Test-Path $tgtRoot)) { continue }
        foreach ($item in (Get-ChildItem -Path $tgtRoot -Force -ErrorAction SilentlyContinue)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $target = (Get-Item $item.FullName -Force).Target
                if (-not $target -or -not (Test-Path $target) -or (Test-SkillSourceArchived $target)) {
                    Remove-Item $item.FullName -Force
                    Write-Ok "skills: pruned stale link $($item.Name) (source archived/removed)"
                }
            }
            elseif (Test-Path (Join-Path $item.FullName ".dotfiles-skill-source")) {
                $source = (Get-Content (Join-Path $item.FullName ".dotfiles-skill-source") -Raw).Trim()
                if (-not $source -or -not (Test-Path $source) -or (Test-SkillSourceArchived $source)) {
                    Remove-Item $item.FullName -Recurse -Force
                    Write-Ok "skills: pruned stale materialized skill $($item.Name) (source archived/removed)"
                }
            }
        }
    }
    # Retired targets (ADR-0004): drop every generated junction/link or marked copy (never a
    # user-authored real dir), then the dir itself once nothing is left in it.
    foreach ($tgtRoot in $RetiredSkillTargets) {
        if (-not (Test-Path $tgtRoot)) { continue }
        foreach ($item in (Get-ChildItem -Path $tgtRoot -Force -ErrorAction SilentlyContinue)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                # A junction: remove the link itself, never the source directory it points at.
                [System.IO.Directory]::Delete($item.FullName, $false)
                Write-Ok "skills: removed $($item.Name) from retired $tgtRoot"
            }
            elseif (Test-Path (Join-Path $item.FullName ".dotfiles-skill-source")) {
                Remove-Item $item.FullName -Recurse -Force
                Write-Ok "skills: removed $($item.Name) from retired $tgtRoot"
            }
        }
        if (-not (Get-ChildItem -Path $tgtRoot -Force -ErrorAction SilentlyContinue)) {
            Remove-Item $tgtRoot -Force
            Write-Ok "skills: removed empty retired dir $tgtRoot"
        }
    }
}

# Vendor/global skills go to all agents. Project skills come from the native source
# declared for Codex; Codex-native (copy-mode) skills are distinct materialized copies.
function Update-AgentSkillsLinks {
    Link-SkillDirs (Join-Path $AgentSkillsDir "skills") "" $AgentSkillsTargets
    Link-SkillDirs $GlobalSkillsDir "" $AgentSkillsTargets
    $codexTarget = Join-Path $HOME ".codex\skills"
    foreach ($ps in $CodexProjectSkills) {
        if ($ps.Mode -eq "copy") {
            if (-not (Test-Path $ps.Dir)) {
                Write-Warn "skills: no source dir $($ps.Dir) - skipping"
                continue
            }
            foreach ($skill in (Get-ChildItem -Path $ps.Dir -Directory)) {
                if ($skill.Name.StartsWith(".")) { continue }
                Copy-ProjectSkill $skill.FullName (Join-Path $codexTarget "$($ps.Label)-$($skill.Name)") "$($ps.Label)-$($skill.Name)" $false
            }
        }
        else {
            Link-SkillDirs $ps.Dir "$($ps.Label)-" @($codexTarget)
        }
    }
    Clean-StaleSkillSymlinks   # prune links whose source was removed/archived (idempotent)
}

# Sourceable for tests and targeted runs: stop here when DOT-SOURCED (InvocationName '.') so a
# caller can use the functions above without running the sync flow. Normal execution
# (`& sync.ps1` from shell/windows/core.ps1) has InvocationName '&', so main always runs - a
# no-op in production. (parity with sync.sh's BASH_SOURCE source-guard.)
if ($MyInvocation.InvocationName -eq '.') { return }

# GIT_SYNC_SHARED_LOCK: serialize manual sync with auto-git timers.
. (Join-Path $DotfilesDir "scripts\git-sync-lock.ps1")
if (-not (Acquire-GitSyncLock "manual-sync")) { exit 0 }
try {

# ── Move repos out of ~\Documents (ADR-0007, INV-21) ────────────────
# First, so every later step sees the repos where they now are. A blocked move moves nothing and
# fails the run at the end; a pending move keeps the old paths for this run. Mirror of sync.sh.
Write-Host "`n==> Workspace layout" -ForegroundColor Green
$WorkspaceMoveFail = -not (Move-ToWorkspace)
Set-PendingWorkspacePaths

# ── Checkpoint Nexus DB (flush WAL into main file before syncing) ────
# The host's live store by its real path (INV-18); a client has none, so this skips there.
$checkpointDb = $NexusHostStore
if ((Test-Path $checkpointDb) -and (Get-Command sqlite3 -ErrorAction SilentlyContinue)) {
    & sqlite3 $checkpointDb "PRAGMA wal_checkpoint(TRUNCATE);" 2>$null | Out-Null
    Write-Ok "Nexus DB: WAL checkpointed"
}

# ── Repoint links left at a moved source (ADR-0006) ──────────────────
# Before the pulls, while the old targets still exist. A sync runs the code it started with,
# so a move reaches a machine on its second sync after the dotfiles push.
Write-Host "`n==> Checking moved link sources" -ForegroundColor Green
Update-MovedLinks

# ── Sync dotfiles repo itself ────────────────────────────────────────
Write-Host "`n==> Syncing dotfiles" -ForegroundColor Green
Sync-Repo $DotfilesDir

# ── Sync manifest repos ─────────────────────────────────────────────
Write-Host "`n==> Syncing managed repos" -ForegroundColor Green
foreach ($repo in $Repos) {
    Sync-Repo $repo.Target
}

# ── Per-agent skill links (agent-skills lives in dotfiles, ADR-0007) ──
if ($AgentSkillsDir) {
    Write-Host "`n==> Linking agent skills" -ForegroundColor Green
    Update-AgentSkillsLinks
}

# Routine sync repairs the generated instruction bundles and every agent's completion
# hook registration before the live machine gate evaluates them.
Regen-CombinedAgentRules
Set-AgentIntegrations

# ── Regenerate cross-agent COMMANDS + mirror Claude ALLOWLIST ─────────
# Shared python generators (same scripts the sh side calls) - one source of truth, no
# PowerShell duplication of the markdown/TOML/JSON transforms. (parity-checked.)
$pyCmd = Get-PythonCmd
if ($pyCmd) {
    Write-Host "`n==> Regenerating cross-agent commands + allowlist" -ForegroundColor Green
    $cmdArgs = @()
    foreach ($cs in $CommandSources) { $cmdArgs += "$($cs.Prefix):$($cs.Dir)" }
    & $pyCmd (Join-Path $DotfilesDir "scripts\gen-agent-commands.py") @cmdArgs
    if ($LASTEXITCODE -ne 0) { Write-Warn "command generation reported an issue" }
    # COMMAND_MIRROR_VERIFY: every source command produced a codex prompt.
    & $pyCmd (Join-Path $DotfilesDir "scripts\gen-agent-commands.py") --verify @cmdArgs
    if ($LASTEXITCODE -ne 0) { Write-Warn "COMMAND_MIRROR_VERIFY: a source command is missing its generated codex output" }
    & $pyCmd (Join-Path $DotfilesDir "scripts\gen-agent-allowlist.py")
    if ($LASTEXITCODE -ne 0) { Write-Warn "allowlist mirror reported an issue" }
    # Machine-state verification (INV-6 BLOCKING + INV-8 advisory; parity with sync.sh). Runs
    # AFTER regen, so dangling/missing/colliding links mean the tree is genuinely wrong: flag now,
    # fail the run at the end. Guarded: absent target dirs (fresh machine) are skipped in the check.
    & $pyCmd (Join-Path $DotfilesDir "scripts\ci\check-skill-targets.py") --machine
    if ($LASTEXITCODE -ne 0) { Write-Err "check-skill-targets --machine: skill links incomplete/dangling/colliding (above) - run a full sync; if it persists, investigate"; $SkillTargetFail = $true }
    & $pyCmd (Join-Path $DotfilesDir "scripts\ci\check-agent-integrations.py") --machine
    if ($LASTEXITCODE -ne 0) { Write-Warn "agent integration machine check reported an issue" }
    & $pyCmd (Join-Path $DotfilesDir "scripts\ci\check-worktrees.py")
}
else {
    Write-Warn "python not found - skipping cross-agent command + allowlist generation"
}

# ── Verify symlinks (auto-create if missing) ────────────────────────
Write-Host "`n==> Checking symlinks" -ForegroundColor Green
foreach ($link in $Symlinks) {
    $target = $link.Target
    $source = $link.Source
    $name = Split-Path $target -Leaf

    $linkItem = Get-LinkItem $target
    if ($linkItem -and ((Get-LinkTargetPath $linkItem) -ieq $source.TrimEnd('\'))) {
        Write-Ok "$name`: linked correctly"
    }
    elseif ($linkItem) {
        # A link to somewhere else, possibly dangling - don't auto-overwrite (verify by target, as
        # setup.ps1 does; a moved source was already repointed by Update-MovedLinks).
        Write-Warn "$name`: links to $(Get-LinkTargetPath $linkItem), not $source - resolve manually (remove and re-run, or run setup.ps1)"
    }
    elseif (Test-Path $target) {
        # Real file - don't auto-overwrite (could lose local edits)
        Write-Warn "$name`: exists but not the expected symlink - resolve manually (remove and re-run, or run setup.ps1)"
    }
    elseif (-not (Test-Path $source)) {
        Write-Warn "$name`: source missing at $source"
    }
    else {
        # Target absent, source present - safe to auto-create
        $parent = Split-Path $target -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path $target -Target $source -ErrorAction Stop | Out-Null
            Write-Ok "$name`: created symlink -> $source"
        }
        catch {
            Write-Err "$name`: failed to create symlink (enable Developer Mode or run as Admin)"
        }
    }
}

# Wire PreToolUse guards into the per-machine Claude settings.json. Scripts ride the
# global-hooks symlink; registration is machine-local, so routine sync repairs it.
$settingsPath = "$HOME\.claude\settings.json"
function Ensure-ClaudePreToolUseHook {
    param([string]$Command, [string]$Label)
    if (-not (Test-Path $settingsPath)) {
        Write-Warn "${Label}: no settings.json - wire manually"
        return
    }
    $cfg = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $existing = @()
    if ($cfg.hooks -and $cfg.hooks.PreToolUse) {
        foreach ($entry in @($cfg.hooks.PreToolUse)) {
            foreach ($hook in @($entry.hooks)) {
                if ($hook.command) { $existing += $hook.command }
            }
        }
    }
    if ($existing -contains $Command) {
        Write-Ok "$Label already wired in settings.json"
        return
    }

    Copy-Item $settingsPath "$settingsPath.bak" -Force
    if (-not $cfg.hooks) {
        Add-Member -InputObject $cfg -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $preExisting = @()
    if ($cfg.hooks.PreToolUse) { $preExisting = @($cfg.hooks.PreToolUse) }
    $preEntry = [pscustomobject]@{ matcher = "Bash"; hooks = @([pscustomobject]@{ type = "command"; command = $Command }) }
    Add-Member -InputObject $cfg.hooks -NotePropertyName PreToolUse -NotePropertyValue @($preExisting + $preEntry) -Force
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -Path $settingsPath
    Write-Ok "Wired $Label into settings.json"
}
Ensure-ClaudePreToolUseHook "bash `"$HOME/.claude/hooks/warn-stacked-git-push.sh`"" "stacked-push guard"
Ensure-ClaudeHook -HookEvent PostToolUse -Matcher "Edit|Write|MultiEdit" -Command $UiNudgeHookCmd -Label "UI-workflow nudge"
Set-AgentDefaults

# ── Rebuild Nexus from the code root ─────────────────────────────────
$CodeRoot = Resolve-CodeRoot
$NexusPath = "$CodeRoot\nexus"
if ((Test-NeedsLocalNexus) -and (Test-Path "$NexusPath\package.json")) {
    Push-Location $NexusPath
    npm install --silent 2>$null | Out-Null
    npm run build 2>$null | Out-Null
    Write-Ok "Nexus: rebuilt"
    Pop-Location
}

# ── Refresh MCP runtime deps + global wiring ─────────────────────────
$CourierPath = "$CodeRoot\courier"
$DocgenPath = "$DotfilesDir\tools\docgen"
$CalendarPath = "$CodeRoot\calendar"
Remove-RetiredProjectMcp
$NexusServer = "$NexusPath\dist\server.js"
$CourierSrc = "$CourierPath\src"
$DocgenSrc = "$DocgenPath\src"
$CalendarSrc = "$CalendarPath\src"
$DocgenBrowsers = "$HOME\.cache\docgen-playwright"

$uvCmd = Get-Command uv -ErrorAction SilentlyContinue
if ($uvCmd) {
    # Courier and calendar run ONLY on the MCP host (macOS); Windows is always a client reaching
    # them over http, so syncing their Python deps here is wasted work - skip both. (ADR-0002.)
    if (Test-Path $DocgenPath) {
        Push-Location $DocgenPath
        uv sync --quiet 2>$null
        Pop-Location
        Write-Ok "Docgen: deps synced"

        $oldBrowsers = $env:PLAYWRIGHT_BROWSERS_PATH
        $env:PLAYWRIGHT_BROWSERS_PATH = $DocgenBrowsers
        uv run --project $DocgenPath --no-sync playwright install chromium 2>$null | Out-Null
        $env:PLAYWRIGHT_BROWSERS_PATH = $oldBrowsers
        Write-Ok "Docgen: Chromium installed"
    }
}
else {
    Write-Warn "uv not found - skipping courier/docgen/calendar dep sync"
}

# Hubs are wired per-ROLE through Register-AllHubMcp / Register-HubMcp (manifest.ps1, dot-sourced
# at the top) - ONE copy shared with setup.ps1; check-hub-wiring (INV-5) proves no script wires a
# hub directly. Windows is always a CLIENT (no macOS login keychain): courier http, the rest stdio.
if (Test-McpWiringReady) {
    Initialize-AllClientTokens   # Windows is always a CLIENT of every hub (ADR-0002)
    Register-AllHubMcp "claude"
    Register-AllHubMcp "codex"
    Register-AllHubMcp "gemini"

    # Host-side INV-4 (HUB_BEARER_HOST_SCAN): a gemini http add can materialize the bearer into
    # ~/.gemini/settings.json; the wiring re-locks it (icacls), this flags any literal for ROTATION.
    # Advisory (configs not in git). (parity-checked: scripts/ci/check-parity.py)
    $hubWire = Join-Path $DotfilesDir "scripts\ci\check-hub-wiring.py"
    foreach ($pc in @("python3", "python")) {
        if (Get-Command $pc -ErrorAction SilentlyContinue) {
            & $pc $hubWire --host
            if ($LASTEXITCODE -ne 0) { Write-Warn "hub bearer host-scan flagged an exposure (above) - rotate the token" }
            break
        }
    }

    function Test-CalendarHealth {
        # Windows is always a client: it reaches the host's calendar over http and keeps no
        # calendar identity or token, so there is nothing local to check (mirror of is_mcp_host in sh).
        return
        if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { return }
        if (-not (Test-Path $CalendarPath)) { return }
        $oldPyPath = $env:PYTHONPATH
        $env:PYTHONPATH = $CalendarSrc
        & uv run --project $CalendarPath --no-sync python -m ea_calendar.cli status --check-events --quiet *> $null
        $healthExit = $LASTEXITCODE
        $env:PYTHONPATH = $oldPyPath
        if ($healthExit -eq 0) {
            Write-Ok "Calendar: healthy (identity and login)"
        }
        else {
            Write-Warn "Calendar: health check failed - run: python -m ea_calendar.cli status (identity-set if the identity is missing, else login)"
        }
    }
    Test-CalendarHealth

    function Trust-GeminiManagedRepos {
        if (-not (Get-Command gemini -ErrorAction SilentlyContinue)) { return }
        $trustFile = "$HOME\.gemini\trustedFolders.json"
        $trustDir = Split-Path $trustFile -Parent
        New-Item -ItemType Directory -Path $trustDir -Force | Out-Null

        $trust = @{}
        if (Test-Path $trustFile) {
            $raw = Get-Content $trustFile -Raw
            if ($raw) {
                $obj = $raw | ConvertFrom-Json
                if ($obj) {
                    foreach ($prop in $obj.PSObject.Properties) {
                        $trust[$prop.Name] = $prop.Value
                    }
                }
            }
        }

        foreach ($repo in $Repos) {
            if (Test-Path $repo.Target) {
                $trust[(Resolve-Path $repo.Target).Path] = "TRUST_FOLDER"
            }
        }
        $nvimRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "nvim" } else { Join-Path $HOME "AppData\Local\nvim" }
        foreach ($root in @("$HOME\Documents", "$HOME\Downloads", "$HOME\.dotfiles", "$HOME\.codex", "$HOME\.claude", "$HOME\.gemini", $nvimRoot)) {
            if (Test-Path $root) {
                $trust[(Resolve-Path $root).Path] = "TRUST_FOLDER"
            }
        }

        $trust | ConvertTo-Json -Depth 4 | Set-Content -Path $trustFile
        Write-Ok "Gemini: trusted managed repo + workspace folders"
    }
    Trust-GeminiManagedRepos
}
else {
    if (Test-NeedsLocalNexus) { Write-Warn "MCP wiring skipped - Nexus server not built at $NexusServer" }
    else { Write-Warn "MCP wiring skipped - docgen not found at $DocgenPath (is the code root cloned?)" }
}
Ensure-GeminiCrossCheckSetup

# ── Summary ──────────────────────────────────────────────────────────
Write-Host "`n==> Summary" -ForegroundColor Green
if ($Updated.Count -gt 0)  { Write-Ok "Updated: $($Updated -join ', ')" }
if ($Pushed.Count -gt 0)   { Write-Ok "Pushed: $($Pushed -join ', ')" }
if ($Diverged.Count -gt 0) { Write-Err "Diverged (manual fix): $($Diverged -join ', ')" }
if ($Missing.Count -gt 0)  { Write-Warn "Missing: $($Missing -join ', ')" }

# ── Handle dirty repos with Claude ──────────────────────────────────
if ($Dirty.Count -gt 0) {
    Write-Host ""
    Write-Warn "Dirty repos: $($Dirty -join ', ')"

    $hasClaude = [bool](Get-Command claude -ErrorAction SilentlyContinue)

    foreach ($name in $Dirty) {
        # Find repo path
        $repoPath = $null
        $repo = $Repos | Where-Object { (Split-Path $_.Target -Leaf) -eq $name }
        if ($repo) { $repoPath = $repo.Target }
        if ($name -eq (Split-Path $DotfilesDir -Leaf)) { $repoPath = $DotfilesDir }
        if (-not $repoPath) { continue }

        Push-Location $repoPath

        # Build changes summary
        $diffStat = git diff --stat 2>$null
        $untracked = git ls-files --others --exclude-standard 2>$null
        $changes = ""
        if ($diffStat) { $changes += "Modified:`n$($diffStat -join "`n")`n" }
        if ($untracked) { $changes += "New files:`n$($untracked -join "`n")`n" }

        Write-Host ""
        Write-Info "$name changes:"
        Write-Host $changes

        # Pull remote changes before committing to avoid non-fast-forward
        Invoke-PullKeepingChanges

        if ($hasClaude) {
            $prompt = @"
You are a commit message generator. Given these changes in the '$name' repo:

$changes

Respond with ONLY one of:
1. A single-line commit message (no quotes, no prefix) if the changes are safe to commit
2. REVIEW: <reason> if the changes need human review (e.g. secrets, large deletions, config that looks wrong)

Nothing else. No explanation.
"@

            Write-Info "$name`: asking Claude for commit message..."
            # Headless on purpose: run from inside an agent session, an inherited Desktop session id
            # would put this prompt on that session's request queue and resume-card hooks (ADR-0008).
            $savedHost = $env:CLAUDE_CODE_HOST_SESSION_ID; $savedEntry = $env:CLAUDE_CODE_ENTRYPOINT
            Remove-Item Env:CLAUDE_CODE_HOST_SESSION_ID -ErrorAction SilentlyContinue
            $env:CLAUDE_CODE_ENTRYPOINT = "sdk-cli"
            try {
                $msg = & claude -p $prompt 2>$null
                $msgExit = $LASTEXITCODE
            } finally {
                $env:CLAUDE_CODE_HOST_SESSION_ID = $savedHost; $env:CLAUDE_CODE_ENTRYPOINT = $savedEntry
            }

            if (-not (Test-UsableCommitMessage $msg $msgExit)) {
                Write-Warn "$name`: no usable commit message from Claude (exit $msgExit; is it logged in?) - commit manually"
                Pop-Location
                continue
            }

            $msg = ($msg -join " ").Trim()

            if ($msg.StartsWith("REVIEW:")) {
                Write-Warn "$name`: $msg"
                Pop-Location
                continue
            }

            Write-Ok "$name`: committing with message: $msg"
            git add -A
            git commit -m $msg
            git push 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "$name`: pushed"
            }
            else {
                Write-Err "$name`: push failed"
            }
        }
        else {
            Write-Warn "$name`: Claude Code not available - commit manually"
        }

        Pop-Location
    }
}

Write-Host ""

# INV-6: a machine-state skill-target violation (flagged above) fails the whole sync run
# (parity with sync.sh). Sync still completed its other work first.
if ($SkillTargetFail) {
    Write-Err "sync: skill-target machine check FAILED (see above) - run a full sync or investigate"
    exit 1
}
if ($WorkspaceMoveFail) {
    Write-Err "sync: a workspace move was blocked or a clone could not retire (see 'workspace:' above) - fix it and re-run"
    exit 1
}
}
finally {
    Release-GitSyncLock
}

