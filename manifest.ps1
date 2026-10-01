# Dotfiles manifest - Windows (mirrors manifest.sh)

# ── Managed-root ROLES (mirror of manifest.sh) ───────────────────────
# Every root dotfiles manages has exactly one role: active-repo (synced, $Repos),
# archive-repo (NOT synced, $ArchivedRepos), external-managed ($AgentSkillsDir),
# generated-target (written by dotfiles), artifact-dir ($Directories). An archived root
# must NEVER appear in an active list or it resurrects stale generated affordances.
# See manifest.sh for the full taxonomy and INVARIANTS.md.

# Active managed repos (role: active-repo). Parity: must match manifest.sh REPOS.
$Repos = @(
    @{ Remote = "git@github:MGallo-Code/EA.git";         Target = "$HOME\Documents\EA" }
    @{ Remote = "git@github:MGallo-Code/GalloGrid.git";  Target = "$HOME\Documents\GalloGrid" }
    @{ Remote = "git@github:MGallo-Code/NVIM-Setup.git";  Target = "$env:LOCALAPPDATA\nvim" }
    @{ Remote = "git@github:MGallo-Code/Wiki.git";        Target = "$HOME\Documents\Wiki" }
    @{ Remote = "git@github:MGallo-Code/Notes.git";       Target = "$HOME\Documents\Notes" }
)

# Archived repos (role: archive-repo). NEVER synced. Currently EMPTY: IT-Worker local copy
# removed 2026-06-19 (archive on GitHub; artifacts in Customer-Work). Parity: manifest.sh ARCHIVED_REPOS.
$ArchivedRepos = @()

# EA-only repos (skipped with --dev) - subset of active $Repos. Parity: manifest.sh EA_REPOS.
$EARepos = @(
    "EA"
    "GalloGrid"
    "Wiki"
    "Notes"
)

# ── Codex CLI pin (parity: manifest.sh CODEX_PIN) ────────────────────
# Pinned, never floated - codex config.toml MCP schema has drifted across versions.
# Bump deliberately: scripts/codex-pin-preflight.sh <version>, update BOTH manifests +
# the kit MANIFEST, then npm install -g @openai/codex@<pin> on every machine (lockstep).
$CodexPin = "0.147.0"

$Symlinks = @(
    @{ Source = "$HOME\.dotfiles\claude-config\global-rules"; Target = "$HOME\.claude\rules" }
    # Mirror of manifest.sh: wire the global-hooks dir so hook scripts (notify,
    # stacked-push guard) are available on Windows too. Without this, ~/.claude/hooks
    # never exists on Windows. (parity-checked: scripts/ci/check-parity.py)
    @{ Source = "$HOME\.dotfiles\claude-config\global-hooks"; Target = "$HOME\.claude\hooks" }
    @{ Source = "$HOME\.dotfiles\terminal\wezterm\wezterm.lua"; Target = "$HOME\.wezterm.lua" }
    @{ Source = "$HOME\.dotfiles\terminal\starship\starship.toml"; Target = "$HOME\.config\starship.toml" }
    # Mirror of manifest.sh: global-agents -> ~/.claude/agents (Claude subagent defs).
    # Claude-only; codex/gemini have no subagent concept. (parity-checked: scripts/ci/check-parity.py)
    @{ Source = "$HOME\.dotfiles\claude-config\global-agents"; Target = "$HOME\.claude\agents" }
    # Mirror of manifest.sh: global-commands -> ~/.claude/commands. Codex/Gemini get generated
    # mirrors from the same source; Claude gets the source directory directly.
    @{ Source = "$HOME\.dotfiles\claude-config\global-commands"; Target = "$HOME\.claude\commands" }
)

# Moved link sources (ADR-0006). Parity: manifest.sh MOVED_LINK_SOURCES / retarget_moved_links.
# Update-MovedLinks repoints every managed link (the $Symlinks targets and each entry of the
# skill target dirs) whose target is under an Old prefix, live or dangling, to the same path
# under New. Only links are touched, never a real file or dir. setup and sync run it before the
# repo pulls. Keep an entry until every machine has synced twice past the move.
$MovedLinkSources = @(
    @{ Old = "$HOME\Documents\EA\claude-config"; New = "$HOME\.dotfiles\claude-config" }
)

# The link item at $Path, read from its parent's listing so a dangling link still resolves on
# Windows PowerShell 5.1 and pwsh 7. $null when $Path is not a link.
function Get-LinkItem {
    param([string]$Path)
    $parent = Split-Path $Path -Parent
    $leaf = Split-Path $Path -Leaf
    if (-not $parent -or -not (Test-Path -LiteralPath $parent)) { return $null }
    $item = Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $leaf } | Select-Object -First 1
    if (-not $item -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    return $item
}

# A link item's target as a plain absolute path (no \??\ or \\?\ prefix, no trailing slash).
function Get-LinkTargetPath {
    param($Item)
    $target = @($Item.Target)[0]
    if (-not $target) { return $null }
    $target = [string]$target
    foreach ($prefix in @('\??\', '\\?\')) {
        if ($target.StartsWith($prefix)) { $target = $target.Substring($prefix.Length) }
    }
    return $target.TrimEnd('\', '/')
}

function Update-MovedLinks {
    $paths = @($Symlinks | ForEach-Object { $_.Target })
    foreach ($root in (@($AgentSkillsTargets + $ProjectSkillsTargets) | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($entry in (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $paths += $entry.FullName }
        }
    }
    foreach ($path in $paths) {
        $item = Get-LinkItem $path
        if (-not $item) { continue }
        $current = Get-LinkTargetPath $item
        if (-not $current) { continue }
        foreach ($move in $MovedLinkSources) {
            $old = $move.Old.TrimEnd('\')
            if (-not ($current -ieq $old -or $current.StartsWith($old + '\', [StringComparison]::OrdinalIgnoreCase))) { continue }
            $dest = $move.New.TrimEnd('\') + $current.Substring($old.Length)
            if (-not (Test-Path -LiteralPath $dest)) {
                Write-Warn "moved link: $path points at $current, but $dest is missing - left as is"
                break
            }
            try {
                # Remove the link itself, never what it points at.
                if ($item.Attributes -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($path, $false) }
                else { [IO.File]::Delete($path) }
                try { New-Item -ItemType SymbolicLink -Path $path -Target $dest -ErrorAction Stop | Out-Null }
                catch { New-Item -ItemType Junction -Path $path -Target $dest -ErrorAction Stop | Out-Null }
                Write-Ok "moved link: $path -> $dest"
            }
            catch { Write-Err "moved link: could not repoint $path ($($_.Exception.Message))" }
            break
        }
    }
}

# ── Code root (GalloGrid split, EA docs/plans/gallogrid-split.md) ──────
# Mirror of manifest.sh resolve_code_root: GalloGrid once that checkout exists, else EA, so no
# machine is stranded whatever order it pulls in. The live nexus store is pinned.
$CodeRootNew = "$HOME\Documents\GalloGrid"
$CodeRootOld = "$HOME\Documents\EA"
# The machine-local switch (mirror of manifest.sh CODE_ROOT_SWITCH): a machine moves to GalloGrid
# only at its own cutover, when this file says "GalloGrid". Never by cloning alone.
$CodeRootSwitch = "$HOME\.config\dotfiles\code-root"
$NexusHostStore = "$HOME\.local\share\nexus\nexus.db"
function Resolve-CodeRoot {
    $switched = (Test-Path $CodeRootSwitch) -and ((Get-Content $CodeRootSwitch -Raw -ErrorAction SilentlyContinue).Trim() -eq "GalloGrid")
    if ((Test-Path (Join-Path $CodeRootNew ".git")) -and $switched) { return $CodeRootNew }
    if ((Test-Path (Join-Path $CodeRootOld "nexus")) -or (Test-Path (Join-Path $CodeRootOld "courier"))) { return $CodeRootOld }
    # EA no longer holds the code (after the split): GalloGrid is the only home left.
    if (Test-Path (Join-Path $CodeRootNew ".git")) { return $CodeRootNew }
    Write-Warn "code root: no service code in $CodeRootNew or $CodeRootOld"
    return $CodeRootOld
}

# Retired project MCP files. Mirror of manifest.sh retire_project_mcp_files: removed while it is
# still exactly the generated docgen-only file; an edited one is kept with a warning.
$RetiredProjectMcpFiles = @(
    "$HOME\Documents\EA\.mcp.json"
)
function Remove-RetiredProjectMcp {
    foreach ($f in $RetiredProjectMcpFiles) {
        if (-not (Test-Path $f)) { continue }
        $generated = $false
        try {
            $d = Get-Content $f -Raw | ConvertFrom-Json
            $top = @($d.PSObject.Properties.Name)
            $servers = @($d.mcpServers.PSObject.Properties.Name)
            $generated = ($top.Count -eq 1) -and ($top[0] -eq "mcpServers") -and ($servers.Count -eq 1) -and ($servers[0] -eq "docgen") -and (@($d.mcpServers.docgen.args) -contains "docgen.server")
        } catch { $generated = $false }
        if ($generated) { Remove-Item $f -Force; Write-Ok "project MCP: removed retired $f (global docgen serves it)" }
        else { Write-Warn "project MCP: $f is not the generated docgen-only file - left as is" }
    }
}

# Sync's dirty-repo commit path (INV-20; mirror of pull_keeping_changes in manifest.sh). Pull while
# keeping local changes, and pop ONLY a stash this call made: with untracked-only changes
# `git stash` saves nothing, so a bare pop applied an older, unrelated stash.
function Invoke-PullKeepingChanges {
    $before = git rev-parse -q --verify refs/stash 2>$null
    git stash -q 2>$null
    $after = git rev-parse -q --verify refs/stash 2>$null
    git pull -q --ff-only 2>$null
    if ("$after" -ne "$before") { git stash pop -q 2>$null }
}

# A generated commit message is usable only from a clean exit and as one non-empty line (mirror of
# usable_commit_message): a logged-out `claude -p` exits 1 printing "Not logged in".
function Test-UsableCommitMessage {
    param($Message, [int]$ExitCode)
    if ($ExitCode -ne 0) { return $false }
    $lines = @(@($Message) | ForEach-Object { "$_" -split "`r?`n" } | Where-Object { $_.Trim() })
    return ($lines.Count -eq 1)
}

# Codex loads ONE global instruction file. Mirror of manifest.sh:
# instead of symlinking only agent-skills.md, GENERATE a combined file from ALL
# global-rules/*.md so Windows agents get the FULL ruleset, not a subset. Generated by
# Regen-CombinedAgentRules during setup and sync, and between syncs by dotfiles'
# post-commit/merge/checkout hooks via scripts/regen-agent-rules.ps1.
# (parity-checked: scripts/ci/check-parity.py)
$GlobalRulesDir = "$HOME\.dotfiles\claude-config\global-rules"
$CombinedRulesTargets = @(
    "$HOME\.codex\AGENTS.md"
)
# Retired generated rule files (ADR-0004). Parity: manifest.sh RETIRED_COMBINED_RULES_TARGETS.
$RetiredCombinedRulesTargets = @(
    "$HOME\.gemini\GEMINI.md"
)

function Get-CombinedRulesBodyHash {
    param([string]$Body)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Body)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

# Mirror of manifest.sh _combined_rules_pristine: the generated header records a hash of
# the body below it. A target whose body still matches is untouched generated output;
# anything else was edited, whatever its ReadOnly flag, or predates the hash.
function Test-CombinedRulesPristine {
    param([string]$Path)
    try { $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)) } catch { return $false }
    $i = $text.IndexOf("`n`n")
    if ($i -lt 0) { return $false }
    if (-not ($text.Substring(0, $i) -match 'body-sha256: ([0-9a-f]{64}) -->$')) { return $false }
    return $Matches[1] -ceq (Get-CombinedRulesBodyHash $text.Substring($i + 2))
}

function Regen-CombinedAgentRules {
    if (-not (Test-Path $GlobalRulesDir)) {
        Write-Warn "combined-rules: no global-rules dir at $GlobalRulesDir"
        return
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $sb = [System.Text.StringBuilder]::new()
    $files = @(Get-ChildItem -Path $GlobalRulesDir -Filter *.md -File -ErrorAction SilentlyContinue | Sort-Object Name)
    # Never publish an empty ruleset over a real one (an unlistable dir yields no files).
    if ($files.Count -eq 0) {
        Write-Warn "combined-rules: no readable rule files in $GlobalRulesDir; targets left unchanged"
        return
    }
    try {
        foreach ($file in $files) {
            [void]$sb.Append([System.IO.File]::ReadAllText($file.FullName, $utf8NoBom))
            [void]$sb.Append("`n`n")
        }
    } catch {
        Write-Warn "combined-rules: could not read a rule file ($($_.Exception.Message)); targets left unchanged"
        return
    }
    $body = $sb.ToString()
    $content = "<!-- AUTO-GENERATED by dotfiles from $GlobalRulesDir. Edit the source rule files, not this copy. body-sha256: $(Get-CombinedRulesBodyHash $body) -->`n`n" + $body
    # pwsh 7 (.NET Core) can replace in one rename; Windows PowerShell 5.1 falls back to
    # Move-Item, which deletes then moves.
    $canReplace = $null -ne [System.IO.File].GetMethod('Move', [type[]]@([string], [string], [bool]))
    foreach ($target in $CombinedRulesTargets) {
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        if ((Test-Path $target) -and ((Get-Item $target).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item $target -Force
        }
        # -ceq: case-sensitive, matching manifest.sh's cmp. An unreadable target counts as
        # different and meets the diff-guard below instead of aborting setup/sync.
        $current = $null
        if (Test-Path $target) { try { $current = [System.IO.File]::ReadAllText($target, $utf8NoBom) } catch { $current = $null } }
        if ($null -ne $current -and $current -ceq $content) {
            Set-ItemProperty -Path $target -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
            # $CombinedRulesQuiet: the EA git hooks run this on every commit/pull, so the
            # no-change case stays silent there. setup/sync still report it.
            if (-not $CombinedRulesQuiet) { Write-Ok "combined-rules: $target already current (read-only)" }
            continue
        }
        # Diff-guard (mirror of manifest.sh). A differing copy that is still pristine
        # generated output is merely stale; EA history rebuilds it, so it is replaced without
        # a backup. Anything else may carry a hand-edit: save it under a fresh name (never
        # over an earlier backup) and never replace it when that save fails.
        if ((Test-Path $target) -and -not (Test-CombinedRulesPristine $target)) {
            $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$PID"
            try {
                Copy-Item $target "$target.sync-backup-$stamp" -ErrorAction Stop
            } catch {
                Write-Warn "combined-rules: could not save $target to $target.sync-backup-$stamp; left it unchanged (resolve manually, then re-run)"
                continue
            }
            Write-Warn "combined-rules: $target did not match what dotfiles generated (hand-edited, or from an older dotfiles); saved to $target.sync-backup-$stamp before regenerating (edit the global-rules source, not this copy)"
        }
        # Stage beside the target and move it over, so a reader never sees a partial file
        # and concurrent runs (git hooks in several worktrees) each publish a whole one.
        $staged = "$target.tmp.$PID"
        $wasReadOnly = (Test-Path $target) -and (Get-Item $target).IsReadOnly
        try {
            [System.IO.File]::WriteAllText($staged, $content, $utf8NoBom)
            if (Test-Path $target) { Set-ItemProperty -Path $target -Name IsReadOnly -Value $false -ErrorAction Stop }
            if ($canReplace) { [System.IO.File]::Move($staged, $target, $true) }
            else { Move-Item -Path $staged -Destination $target -Force -ErrorAction Stop }
            Set-ItemProperty -Path $target -Name IsReadOnly -Value $true -ErrorAction Stop
        } catch {
            Remove-Item $staged -Force -ErrorAction SilentlyContinue
            # The target is untouched; put its read-only lock back if this run lifted it.
            if ($wasReadOnly -and (Test-Path $target)) { Set-ItemProperty -Path $target -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue }
            Write-Warn "combined-rules: could not write $target ($($_.Exception.Message)); left it unchanged"
            continue
        }
        Write-Ok "combined-rules: generated $target (read-only; edit the global-rules source)"
    }
    # Retired targets (ADR-0004): remove a copy that still carries our generated header. A
    # hand-edited one is saved under its own .sync-backup-* name first, and left in place when
    # that save fails. A file without our header is never touched.
    foreach ($target in $RetiredCombinedRulesTargets) {
        if (-not (Test-Path $target -PathType Leaf)) { continue }
        $first = $null
        try { $first = [System.IO.File]::ReadAllLines($target, $utf8NoBom) | Select-Object -First 1 } catch { continue }
        if (-not ($first -like "*AUTO-GENERATED by dotfiles*")) { continue }
        if (-not (Test-CombinedRulesPristine $target)) {
            $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$PID"
            try { Copy-Item $target "$target.sync-backup-$stamp" -ErrorAction Stop }
            catch { Write-Warn "combined-rules: could not save retired $target; left it in place"; continue }
        }
        try {
            Set-ItemProperty -Path $target -Name IsReadOnly -Value $false -ErrorAction Stop
            Remove-Item $target -Force -ErrorAction Stop
            Write-Ok "combined-rules: removed retired $target"
        } catch { Write-Warn "combined-rules: could not remove retired $target ($($_.Exception.Message))" }
    }
}

# The completion-email hook and its machine-local wiring both live in dotfiles (ADR-0006).
$AgentNotifyHook = "$HOME\.dotfiles\claude-config\global-hooks\agent-notify.py"
$AgentNotifyConfigurator = "$HOME\.dotfiles\scripts\configure-agent-integrations.py"
$AgentNotifyDefaultTo = "mgallo2043@gmail.com"
$AgentNotifyFromAddress = "michaelgallo.va@gmail.com"
$AgentNotifyAccount = "mgallo-va"

# Register one command hook in ~/.claude/settings.json under -HookEvent with -Matcher, once, by exact
# command; unrelated hooks and their order are untouched, and the previous file is kept as .bak.
# Mirror of manifest.sh ensure_claude_hook. Used for the UI-workflow nudge (INV-19).
function Ensure-ClaudeHook {
    param([string]$HookEvent, [string]$Matcher, [string]$Command, [string]$Label)
    $file = Join-Path $HOME ".claude\settings.json"
    if (-not (Test-Path $file)) { Write-Warn "${Label}: no settings.json - wire manually"; return }
    try { $cfg = Get-Content $file -Raw | ConvertFrom-Json } catch { Write-Warn "${Label}: settings.json unreadable - left untouched"; return }
    $current = @()
    if ($cfg.hooks -and $cfg.hooks.$HookEvent) { $current = @($cfg.hooks.$HookEvent) }
    foreach ($entry in $current) {
        foreach ($hook in @($entry.hooks)) {
            if ($hook.command -eq $Command) { Write-Ok "$Label already wired in settings.json"; return }
        }
    }
    Copy-Item $file "$file.bak" -Force
    if (-not $cfg.hooks) { Add-Member -InputObject $cfg -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
    $new = [pscustomobject]@{ matcher = $Matcher; hooks = @([pscustomobject]@{ type = "command"; command = $Command }) }
    Add-Member -InputObject $cfg.hooks -NotePropertyName $HookEvent -NotePropertyValue @($current + $new) -Force
    $cfg | ConvertTo-Json -Depth 12 | Set-Content -Path $file
    Write-Ok "Wired $Label into settings.json"
}
# The UI-workflow nudge's registered command (INV-19). The script itself always exits 0.
$UiNudgeHookCmd = "python `"$($HOME -replace '\\','/')/.claude/hooks/ui-nudge.py`""

function Set-AgentIntegrations { # AGENT_NOTIFY_CROSS_AGENT_CONFIG
    $python = $null
    $pythonPrefix = @()
    $tomlProbe = "import importlib.util,sys; sys.exit(not (importlib.util.find_spec('tomllib') or importlib.util.find_spec('tomli')))"
    foreach ($name in @("python3", "python")) {
        $candidate = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $candidate) { continue }
        & $candidate.Source -c $tomlProbe 2>$null
        if ($LASTEXITCODE -eq 0) { $python = $candidate.Source; break }
    }
    if (-not $python) {
        $uv = Get-Command uv -ErrorAction SilentlyContinue
        if ($uv) {
            $python = $uv.Source
            $pythonPrefix = @("run", "--no-project", "--with", "tomli", "python")
        }
        else {
            Write-Warn "agent integrations: Python with tomllib/tomli or uv not found - completion hooks not updated"
            return
        }
    }
    if (-not (Test-Path $AgentNotifyConfigurator) -or -not (Test-Path $AgentNotifyHook)) {
        Write-Warn "agent integrations: configurator or hook source missing"
        return
    }
    $argsList = @(
        "--home", $HOME,
        "--hook", $AgentNotifyHook,
        "--courier-url", $CourierRemoteUrl,
        "--courier-token-file", $CourierTokenFile,
        "--default-to", $AgentNotifyDefaultTo,
        "--from-address", $AgentNotifyFromAddress,
        "--account", $AgentNotifyAccount
    )
    foreach ($root in $CodexLocalSkillDisableRoots) {
        $argsList += @("--codex-disable-root", $root)
    }
    foreach ($root in $CodexRetiredSkillDisableRoots) {
        $argsList += @("--codex-retired-disable-root", $root)
    }
    & $python @pythonPrefix $AgentNotifyConfigurator @argsList
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "agent integrations: configuration failed; existing files were preserved"
    }
}

# ── Forked agent-skills (addyosmani/agent-skills) ────────────────────
# Michael's fork, synced with origin by Sync-Repo like any repo (ADR-0004). Upstream is not
# merged automatically; the link below is kept for a manual, reviewed fetch.
$AgentSkillsDir = "$HOME\Documents\agent-skills"
$AgentSkillsUpstream = "https://github.com/addyosmani/agent-skills.git"

# Each tool reads global skills from its own dir; sync symlinks every
# skills\<name> from the vendor repo into each (idempotent, never clobbers
# existing real skill dirs like calendar/contact/dev-update).
$AgentSkillsTargets = @(
    "$HOME\.claude\skills"
    "$HOME\.codex\skills"
)
# Retired skill targets (ADR-0004). Parity: manifest.sh RETIRED_SKILL_TARGETS.
$RetiredSkillTargets = @(
    "$HOME\.gemini\skills"
)

# ── MCP host identity (ADR-0002 / remote-hubs, mirror of manifest.sh) ──
# The HOST is the ONE machine that runs + serves the MCP hubs (courier today; calendar/nexus as
# they are remoted) over Tailscale. Mac-only (login keychain / chat.db). Every other machine is a
# CLIENT reaching the hubs over Tailscale. "MCP host" is a ROLE keyed on $McpHost: migrating to the
# always-on Mac mini = change $McpHost + run the host bootstrap there. Windows is NEVER the host
# (no macOS login keychain), so this box is always a client; $McpHost only supplies the client URL
# here. (Was $MailHost when courier was the only remoted hub; generalized in remote-hubs Phase B.)
# (parity-checked: scripts/ci/check-parity.py)
$McpHost = "mikes-mac-mini"
$Tailnet = "tail7a0764.ts.net"
$CourierHttpPort = "8765"
$CourierRemoteUrl = "https://$McpHost.$Tailnet/mcp"
# Mandatory bearer token: ONE current-user-only file per machine, OUTSIDE any repo
# (never in git). Consumed via the COURIER_BEARER env var - NEVER passed on a command
# line. On Windows the file gets a restrictive ACL (icacls) since there is no chmod 600.
$CourierTokenFile = "$HOME\.config\courier\auth-token"

# calendar (remote-hubs Phase C): role-aware exactly like courier; Windows is always its CLIENT. Its
# OWN per-hub bearer (${CALENDAR_BEARER}) + token file, NEVER shared with courier. Port + serve/mcp
# paths are sole-sourced in hubs.json. (parity-checked: scripts/ci/check-parity.py)
$CalendarRemoteUrl = "https://$McpHost.$Tailnet/calendar/mcp"
$CalendarTokenFile = "$HOME\.config\calendar\auth-token"

# nexus (live personal data; remoted in remote-hubs Phase D): role-aware exactly like courier/calendar;
# Windows is always its CLIENT. Its OWN per-hub bearer (${NEXUS_BEARER}) + token file, NEVER shared.
# Port + serve/mcp paths are sole-sourced in hubs.json. (parity-checked: scripts/ci/check-parity.py)
$NexusRemoteUrl = "https://$McpHost.$Tailnet/nexus/mcp"
$NexusTokenFile = "$HOME\.config\nexus\auth-token"
# CUTOVER GATE (remote-hubs Phase D §0): until the coordinated nexus migration runs, nexus stays
# stdio so the live local-stdio agent + still-tracked nexus.db keep working. The Phase-D cutover flips
# this to $true (here AND in manifest.sh's NEXUS_REMOTED) in ONE coordinated step, AFTER the host seeds
# the authoritative nexus.db and serves it over HTTP - that flip turns every client into a thin
# http+bearer nexus client. Do NOT flip it before the drain (handoff §4).
$NexusRemoted = $true

# Clients never build or run the central services (2026-10-01; mirror of needs_local_nexus in
# manifest.sh). Windows is always a client, so nexus is built here only before the Phase-D cutover,
# when it is still stdio-wired; after it, docgen is the one local server.
function Test-NeedsLocalNexus { return (-not $NexusRemoted) }

# The global MCP wiring needs what this box runs locally: the built nexus where nexus is stdio, else
# the code root's docgen. Reads $NexusServer/$DocgenPath from the caller (setup/sync's MCP section).
function Test-McpWiringReady {
    if (Test-NeedsLocalNexus) { return (Test-Path $NexusServer) }
    return (Test-Path $DocgenPath)
}

# ── Custom global skills (tracked in dotfiles), linked into Claude and Codex ──
$GlobalSkillsDir = "$HOME\.dotfiles\claude-config\global-skills"

# ── Project skills -> each agent's native source, namespaced globally ────────
$CodexProjectSkills = @(
    @{ Label = "ea";   Dir = "$HOME\Documents\EA\.claude\skills";   Mode = "link" }
    @{ Label = "wiki"; Dir = "$HOME\Documents\Wiki\.claude\skills"; Mode = "link" }
)
# Archived project skills (role: archive-project-skills): repos stay on disk, their generated
# skills are pruned everywhere. SBIC retired 2026-09-27 (ADR-0004). Parity: manifest.sh ARCHIVED_PROJECT_SKILLS.
$ArchivedProjectSkills = @(
    @{ Label = "sbic"; Dir = "$HOME\Documents\SBIC\.codex\skills" }
    @{ Label = "sbic"; Dir = "$HOME\Documents\SBIC\.claude\skills" }
)
$ProjectSkillsTargets = @(
    "$HOME\.codex\skills"
)
# Empty since the SBIC copies were retired (ADR-0004); an empty list removes the managed block.
$CodexLocalSkillDisableRoots = @()
# Tombstone: former disable roots, stripped by path because Codex can drop the block marker.
$CodexRetiredSkillDisableRoots = @(
    "$HOME\Documents\SBIC\.codex\skills"
    "$HOME\Documents\SBIC\.agents\skills"
)

# ── Claude slash-commands -> codex prompts ────────────────────────────
# Source of truth stays the tracked Claude `.md`. Empty prefix = bare name.
$CommandSources = @(
    @{ Prefix = "";     Dir = "$HOME\.dotfiles\claude-config\global-commands" }
)

$Directories = @(
    "$HOME\Documents\Learning"
    "$HOME\Documents\Jobs"
)

# ── Per-ROLE hub client token (shared by setup.ps1 AND sync.ps1) ──────
# Dot-sourced by both so the wiring lives in ONE place (the ADR-0002 review caught setup and sync
# each owning a copy, with the repeatable sync re-wiring courier as broken stdio). Windows is ALWAYS
# a CLIENT (no macOS login keychain) -> always the http path. GENERIC over (name, token file, bearer
# env-var) so every role-aware hub (courier + calendar) reuses it; per-hub tokens, never shared.
function Initialize-HubClientToken {
    param([string]$Name, [string]$TokenFile, [string]$BearerVar)
    $tokenDir = Split-Path $TokenFile -Parent
    New-Item -ItemType Directory -Path $tokenDir -Force | Out-Null
    # Lock the DIRECTORY down FIRST (current-user SID, inheritance removed) so a freshly written token
    # file inherits a restricted ACL - no window where it sits world/group readable (ADR-0002 review:
    # token-file perms are the highest-stakes parity divergence; there is no chmod 600 on Windows, so
    # icacls is the mechanism).
    $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    icacls $tokenDir /inheritance:r /grant:r "*${sid}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warn "${Name}: icacls on $tokenDir failed (exit $LASTEXITCODE)" }

    $haveToken = (Test-Path $TokenFile) -and ((Get-Content $TokenFile -Raw -ErrorAction SilentlyContinue))
    if (-not $haveToken) {
        Write-Warn "$Name client needs the bearer token from the MCP host ($McpHost)."
        Write-Warn "On the host run:  cat $TokenFile   then paste it here."
        $sec = Read-Host "  Paste $Name token (hidden; empty to skip)" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if ($tok) {
            [IO.File]::WriteAllText($TokenFile, $tok)   # no trailing newline
            Write-Ok "$Name token saved ($TokenFile)"
        }
        else {
            Write-Warn "no token entered - $Name client will 401 until $TokenFile exists."
        }
    }
    else {
        Write-Ok "$Name client token present ($TokenFile)"
    }
    if (Test-Path $TokenFile) {
        # Lock the FILE explicitly too (current-user SID), then persist <HUB>_BEARER (User scope +
        # Process) so every CLI's runtime sees it without the token ever being argv.
        icacls $TokenFile /inheritance:r /grant:r "*${sid}:F" | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "${Name}: icacls on token file failed (exit $LASTEXITCODE)" }
        $tokVal = (Get-Content $TokenFile -Raw).Trim()
        if ($tokVal) {
            [Environment]::SetEnvironmentVariable($BearerVar, $tokVal, "User")
            [Environment]::SetEnvironmentVariable($BearerVar, $tokVal, "Process")
        }
    }
}

# Provision EVERY role-aware hub's client bearer in one pass (Windows is always a client). courier +
# calendar (Phase C); each its own COURIER_BEARER / CALENDAR_BEARER token + env var, never shared.
function Initialize-AllClientTokens {
    Initialize-HubClientToken "courier"  $CourierTokenFile  "COURIER_BEARER"
    Initialize-HubClientToken "calendar" $CalendarTokenFile "CALENDAR_BEARER"
    # nexus only once it is remoted (Phase-D cutover): before the flip the host is not serving nexus
    # over HTTP, so prompting a client for a nexus bearer it cannot get yet would only confuse.
    if ($NexusRemoted) { Initialize-HubClientToken "nexus" $NexusTokenFile "NEXUS_BEARER" }
}

# ── Per-ROLE hub MCP wiring (mirror of manifest.sh register_hub_mcp / register_all_hub_mcp) ──
# Phase A of the remote-hubs plan generalized the single courier function into hub primitives so
# the same per-role wiring covers EVERY hub (dotfiles INV-5, scripts/ci/check-hub-wiring.py).
# Windows is NEVER the MCP host: courier is always the http CLIENT, the rest are local stdio.

# stdio add for one hub on one CLI (local role). nexus/docgen/calendar only - courier is never
# wired stdio on Windows (always the http client; see Register-AllHubMcp). The `--` exec
# separator is cli-specific: claude/codex take it, gemini does not.
function Add-HubStdioMcp {
    param([string]$Cli, $CmdSource, [string]$Name)
    $envArgs = @(); $exec = @()
    switch ($Name) {
        "nexus"    { $exec = @("node", $NexusServer) }
        "docgen"   { $envArgs = @("--env", "PYTHONPATH=$DocgenSrc", "--env", "PLAYWRIGHT_BROWSERS_PATH=$DocgenBrowsers"); $exec = @("uv", "run", "--project", $DocgenPath, "--no-sync", "python", "-m", "docgen.server") }
        "calendar" { $envArgs = @("--env", "PYTHONPATH=$CalendarSrc"); $exec = @("uv", "run", "--project", $CalendarPath, "--no-sync", "python", "-m", "ea_calendar.server") }
    }
    switch ($Cli) {
        "claude" { & $CmdSource mcp add --scope=user $Name @envArgs -- @exec | Out-Null }
        "codex"  { & $CmdSource mcp add $Name @envArgs -- @exec | Out-Null }
        "gemini" { & $CmdSource mcp add --scope user $Name @envArgs @exec | Out-Null }
    }
}

# http client add for one hub on one CLI. GENERIC over (url, token_env). The header is built by
# SINGLE-QUOTE concatenation so the literal ${<TokenEnv>} REFERENCE (not its value) reaches the
# CLI, which stores the ref and resolves it at runtime (dotfiles INV-4). Single-quote concat
# avoids the backtick-escape fragility of an interpolated string.
# INV-4 defense: Gemini may materialize bearer values into ~/.gemini/settings.json. Normalize known
# managed hub headers back to env refs before locking the file. The cross-platform backstop is
# check-hub-wiring.py --host, which DETECTS any materialized literal token that still appears.
function Set-GeminiBearerRefs {
    $gset = Join-Path $HOME ".gemini\settings.json"
    if (-not (Test-Path $gset)) { return }
    try {
        $settings = Get-Content $gset -Raw | ConvertFrom-Json
    }
    catch {
        return
    }
    if (-not $settings.mcpServers) { return }
    $map = @{
        courier = "COURIER_BEARER"
        nexus = "NEXUS_BEARER"
        calendar = "CALENDAR_BEARER"
    }
    foreach ($name in $map.Keys) {
        $server = $settings.mcpServers.$name
        if ($server -and $server.headers -and ($server.headers.PSObject.Properties.Name -contains "Authorization")) {
            $server.headers.Authorization = 'Bearer ${' + $map[$name] + '}'
        }
    }
    $settings | ConvertTo-Json -Depth 20 | Set-Content -Path $gset
}

# Re-lock ~/.gemini/settings.json to the current user after a gemini http add. Unlike the courier
# token file - which WE create inside an already-locked dir, so it is clean by construction and needs no
# reset - settings.json is created by GEMINI and may carry a pre-existing EXPLICIT ACE. So `icacls
# /reset` FIRST strips any explicit ACE (back to inherited), THEN /inheritance:r removes inherited and
# /grant:r grants owner-only: a FULL owner lock, not best-effort.
function Lock-GeminiSettings {
    $gset = Join-Path $HOME ".gemini\settings.json"
    if (Test-Path $gset) {
        Set-GeminiBearerRefs
        $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        icacls $gset /reset | Out-Null
        icacls $gset /inheritance:r /grant:r "*${sid}:F" | Out-Null
    }
}

function Add-HubHttpMcp {
    param([string]$Cli, $CmdSource, [string]$Name, [string]$Url, [string]$TokenEnv)
    $hdr = 'Authorization: Bearer ${' + $TokenEnv + '}'  # hub-wiring-allow (audited: env-ref via single-quote concat; PS has no bash ${$var} indirection)
    switch ($Cli) {
        "claude" { & $CmdSource mcp add --scope=user --transport http $Name $Url --header $hdr | Out-Null }
        "gemini" {
            & $CmdSource mcp add --scope user --transport http -H $hdr $Name $Url | Out-Null
            Lock-GeminiSettings
        }
        "codex"  { & $CmdSource mcp add $Name --url $Url --bearer-token-env-var $TokenEnv | Out-Null }
    }
}

# Wire ONE hub for its role, for one CLI (the per-hub primitive; folds the old Register-CourierMcp).
function Register-HubMcp {
    param([string]$Cli, $CmdSource, [string]$Name, [string]$Role, [string]$Url = "", [string]$TokenEnv = "")
    switch ($Role) {
        "host"   { Add-HubStdioMcp $Cli $CmdSource $Name }
        "client" { Add-HubHttpMcp  $Cli $CmdSource $Name $Url $TokenEnv }
        default  { Write-Warn "Register-HubMcp: unknown role '$Role' for $Name" }
    }
}

# Wire ALL global hubs for one CLI - the dedup'd replacement for the Register-GlobalMcp that
# setup.ps1 and sync.ps1 each carried. Idempotent (remove-then-add). Windows is always a client,
# so courier is wired http; nexus/docgen/calendar are local stdio. EVERY hub `mcp add` lives HERE.
function Register-AllHubMcp {
    param([string]$Cli)
    $cmd = Get-Command $Cli -ErrorAction SilentlyContinue
    if (-not $cmd) { Write-Warn "$Cli not found - skipping its global MCP wiring"; return }
    function Remove-HubMcpIfPresent {
        param([string]$Name)
        $scopeArgs = if ($Cli -eq "claude") { @("--scope=user") } else { @("--scope", "user") }
        $oldEap = $ErrorActionPreference
        try {
            # Removing an absent server is expected on fresh/partially wired machines.
            # Under Windows PowerShell, native stderr can become a NativeCommandError when
            # $ErrorActionPreference is Stop, so make remove-if-present best-effort.
            $ErrorActionPreference = "Continue"
            & $cmd.Source mcp remove @scopeArgs $Name *> $null
        }
        catch {}
        finally {
            $ErrorActionPreference = $oldEap
        }
    }
    if ($Cli -eq "codex") {
        # codex keeps MCP servers in config.toml; `codex mcp` can't run when that file won't parse
        # (a drifted-version entry with an invalid transport), deadlocking re-wiring. Text-strip
        # the managed blocks first so codex can always load.
        $cfg = Join-Path $HOME ".codex\config.toml"
        if (Test-Path $cfg) {
            $c = Get-Content $cfg -Raw
            $c = [regex]::Replace($c, '(?m)^\[mcp_servers\.(?:nexus|courier|docgen|calendar)(?:\.[^\]]*)?\][^\r\n]*\r?\n(?:(?!^\[)[^\r\n]*\r?\n?)*', '')
            $c = [regex]::Replace($c, '(\r?\n){3,}', "`n`n")
            Set-Content -Path $cfg -Value $c -NoNewline
        }
    } else {
        foreach ($name in @("nexus", "courier", "docgen", "calendar")) { Remove-HubMcpIfPresent $name }
    }
    # nexus: role-aware ONLY after the Phase-D cutover ($NexusRemoted). Until then it stays stdio so
    # the live local-stdio agent + the still-tracked nexus.db keep working (handoff §0). Windows is
    # always a client, so the flip wires it as an http+bearer client (its own per-hub token).
    if ($NexusRemoted) {
        Register-HubMcp $Cli $cmd.Source "nexus" "client" $NexusRemoteUrl "NEXUS_BEARER"
    } else {
        Register-HubMcp $Cli $cmd.Source "nexus" "host"
    }
    Register-HubMcp $Cli $cmd.Source "docgen"   "host"
    # Windows is always a client: courier + calendar over http+bearer (each its own per-hub token).
    Register-HubMcp $Cli $cmd.Source "courier"  "client" $CourierRemoteUrl  "COURIER_BEARER"
    Register-HubMcp $Cli $cmd.Source "calendar" "client" $CalendarRemoteUrl  "CALENDAR_BEARER"
    Write-Ok "$Cli`: global MCP wired (nexus + courier + docgen + calendar)"
}
