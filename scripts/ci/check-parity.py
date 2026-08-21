#!/usr/bin/env python3
"""check-parity.py  -  INV-2 enforcer: macOS/Linux and Windows setup stay at parity.

This repo's defining property is one cross-platform setup. The bash (*.sh) and
powershell (*.ps1) sides must configure a machine the same way. This gate keys on a
human-curated FEATURE registry (a behavior marker on EACH side), NOT a naive token
grep - because a naive grep false-positives: trust_gemini_managed_repos exists on both
sides under different names, and agent-rule delivery uses different mechanisms (sh
regenerates a combined file; ps1 symlinks). Precision first: a noisy gate gets ignored.

Three lists:
  FEATURES       - behaviors confirmed at parity. A regression here FAILS the build.
  PARITY_EXEMPT  - genuinely OS-specific behaviors (with a reason). Never checked.
  PARITY_PENDING - known gaps being ported under review (with a tracking note). These
                   are REPORTED loudly every run (never silent) but do not fail the
                   build until ported - then they move up to FEATURES. See INVARIANTS.md
                   INV-2. This is a tracked backlog, not a hidden exemption.

Exit 0: all FEATURES at parity.  Exit 1: a FEATURE regressed (one side lost it).
Exit 2: fail-closed (a paired file is missing, or an internal error).
"""
import json
import os
import re
import subprocess
import sys


def repo_root():
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except Exception:
        return None


# Each feature: name, and for each platform a (filename, regex) behavior marker that
# must be present. The regexes are behavior tokens, not function names.
FEATURES = [
    {
        "name": "gemini-trust (trust managed repo folders)",
        "sh": ("setup.sh", r"trustedFolders"),
        "ps1": ("setup.ps1", r"trustedFolders"),
    },
    {
        "name": "agent-skills security gate (untrusted-diff scan)",
        "sh": ("sync.sh", r"skills-scan"),
        "ps1": ("sync.ps1", r"skills-scan"),
    },
    {
        # Both sync scripts carry a source-guard so the INV-3 gate corpus can pull in the gate
        # function without running the sync flow. If one side loses its guard, dot-sourcing it in
        # the test would run main (or the cross-check would silently stop covering that side).
        "name": "sync scripts test-sourceable (INV-3 corpus source-guard)",
        "sh": ("sync.sh", r"Sourceable for tests"),
        "ps1": ("sync.ps1", r"Sourceable for tests"),
    },
    {
        "name": "codex/gemini agent-rules wired",
        "sh": ("manifest.sh", r"AGENTS\.md|GEMINI\.md"),
        "ps1": ("manifest.ps1", r"AGENTS\.md|GEMINI\.md"),
    },
    {
        # Codex is pinned (manifest CODEX_PIN / $CodexPin): its config.toml MCP schema has
        # drifted across versions. Both syncs must warn on drift, or a floated install on
        # one OS silently reintroduces the cross-version config breakage.
        "name": "codex version pin + sync drift warning",
        "sh": ("sync.sh", r"CODEX_PIN"),
        "ps1": ("sync.ps1", r"CodexPin"),
    },
    {
        # Managed-root roles: archived roots are tracked separately and never synced, so
        # both manifests must carry the ARCHIVED_REPOS tombstone (IT-Worker). If one side
        # drops it, that root silently looks active again on that OS.
        "name": "archived repos tracked (role metadata, not an active sync list)",
        "sh": ("manifest.sh", r"ARCHIVED_REPOS"),
        "ps1": ("manifest.ps1", r"ArchivedRepos"),
    },
    {
        "name": "archived project skills tracked (not an active skill source)",
        "sh": ("manifest.sh", r"ARCHIVED_PROJECT_SKILLS"),
        "ps1": ("manifest.ps1", r"ArchivedProjectSkills"),
    },
    # The four managed MCP servers are named in the shared register_all_hub_mcp / Register-AllHubMcp
    # in manifest.{sh,ps1}, where the wiring was consolidated (remote-hubs Phase A). These rows key
    # on manifest (not setup) so they stay green after the setup/sync wiring was gutted.
    {
        "name": "MCP server: nexus",
        "sh": ("manifest.sh", r"\bnexus\b"),
        "ps1": ("manifest.ps1", r"\bnexus\b"),
    },
    {
        "name": "MCP server: courier",
        "sh": ("manifest.sh", r"\bcourier\b"),
        "ps1": ("manifest.ps1", r"\bcourier\b"),
    },
    {
        "name": "MCP server: docgen",
        "sh": ("manifest.sh", r"\bdocgen\b"),
        "ps1": ("manifest.ps1", r"\bdocgen\b"),
    },
    {
        "name": "MCP server: calendar",
        "sh": ("manifest.sh", r"\bcalendar\b"),
        "ps1": ("manifest.ps1", r"\bcalendar\b"),
    },
    # --- Ported in this change; they FAIL until the .ps1 side lands (a built-in
    #     revert-test for the port). ---
    {
        "name": "~/.claude/hooks dir wired (enables all hook scripts)",
        "sh": ("manifest.sh", r"global-hooks"),
        "ps1": ("manifest.ps1", r"global-hooks"),
    },
    {
        # ~/.claude/agents dir-symlinked so Claude subagent defs (human-voice) are managed +
        # reproducible, not a stale hand-linked copy. Claude-only (codex/gemini have no subagent
        # concept) - a SYMLINKS-array concern, never a skills-target one.
        "name": "~/.claude/agents dir wired (Claude subagent defs)",
        "sh": ("manifest.sh", r"global-agents"),
        "ps1": ("manifest.ps1", r"global-agents"),
    },
    {
        "name": "WezTerm config linked",
        "sh": ("manifest.sh", r"wezterm\.lua"),
        "ps1": ("manifest.ps1", r"wezterm\.lua"),
    },
    {
        "name": "Starship config linked",
        "sh": ("manifest.sh", r"starship\.toml"),
        "ps1": ("manifest.ps1", r"starship\.toml"),
    },
    {
        # Claude reads slash-command sources directly from ~/.claude/commands, while Codex/Gemini
        # get generated mirrors from the same source. If this dir is not wired, commands like
        # /forge exist in generated targets but not in Claude itself.
        "name": "~/.claude/commands dir wired (Claude slash commands)",
        "sh": ("manifest.sh", r"global-commands\|~/.claude/commands"),
        "ps1": ("manifest.ps1", r"global-commands.*\.claude\\commands"),
    },
    {
        "name": "repo git-hooks wired (core.hooksPath)",
        "sh": ("setup.sh", r"hooksPath"),
        "ps1": ("setup.ps1", r"hooksPath"),
    },
    {
        "name": "stacked-push guard registered",
        "sh": ("setup.sh", r"warn-stacked|stacked-push"),
        "ps1": ("setup.ps1", r"warn-stacked|stacked-push"),
    },
    {
        "name": "Forge action guard registered in setup",
        "sh": ("setup.sh", r"forge-guard"),
        "ps1": ("setup.ps1", r"forge-guard"),
    },
    {
        "name": "Forge action guard repaired in sync",
        "sh": ("sync.sh", r"forge-guard"),
        "ps1": ("sync.ps1", r"forge-guard"),
    },
    {
        "name": "auto-git entrypoint exists (INV-12)",
        "sh": ("auto-git.sh", r"AUTO_GIT_ENTRYPOINT"),
        "ps1": ("auto-git.ps1", r"AUTO_GIT_ENTRYPOINT"),
    },
    {
        "name": "auto-git repo union uses managed repos plus dotfiles (INV-12)",
        "sh": ("auto-git.sh", r"AUTO_GIT_REPO_UNION"),
        "ps1": ("auto-git.ps1", r"AUTO_GIT_REPO_UNION"),
    },
    {
        "name": "shared git sync lock helper exists (INV-12)",
        "sh": ("scripts/git-sync-lock.sh", r"GIT_SYNC_SHARED_LOCK"),
        "ps1": ("scripts/git-sync-lock.ps1", r"GIT_SYNC_SHARED_LOCK"),
    },
    {
        "name": "manual sync takes shared git sync lock (INV-12)",
        "sh": ("sync.sh", r"GIT_SYNC_SHARED_LOCK"),
        "ps1": ("sync.ps1", r"GIT_SYNC_SHARED_LOCK"),
    },
    {
        "name": "git autosync bootstrap exists (INV-12)",
        "sh": ("scripts/git-autosync-bootstrap.sh", r"GIT_AUTOSYNC_BOOTSTRAP"),
        "ps1": ("scripts/git-autosync-bootstrap.ps1", r"GIT_AUTOSYNC_BOOTSTRAP"),
    },
    {
        "name": "combined agent-rules generated (full ruleset, not a subset)",
        "sh": ("setup.sh", r"regen_combined_agent_rules"),
        "ps1": ("setup.ps1", r"Regen-CombinedAgentRules"),
    },
    {
        # Keep Gemini focused on real source/control-plane roots; broad parents and agent-state
        # dirs made cross-checks roam caches/downloads and confabulate irrelevant files.
        "name": "gemini workspace roots narrowed in setup",
        "sh": ("setup.sh", r"Documents/agent-skills"),
        "ps1": ("setup.ps1", r"Documents\\agent-skills"),
    },
    {
        "name": "gemini workspace roots narrowed in sync",
        "sh": ("sync.sh", r"Documents/agent-skills"),
        "ps1": ("sync.ps1", r"Documents\\agent-skills"),
    },
    # --- courier remote per-OS wiring + cross-agent skills/commands/allowlist
    #     (ADR-0002 + handoff). Each is a paired sh/ps1 behavior. ---
    {
        # The role-aware hub wiring is defined ONCE in manifest.{sh,ps1} (register_hub_mcp +
        # register_all_hub_mcp / Register-HubMcp + Register-AllHubMcp) and CALLED by both setup and
        # sync. This row checks the shared PRIMITIVE exists on both OSes (Phase A consolidation).
        "name": "hub per-role MCP wiring primitive (shared fn in manifest)",
        "sh": ("manifest.sh", r"register_hub_mcp"),
        "ps1": ("manifest.ps1", r"Register-HubMcp"),
    },
    {
        # ...this checks the SETUP call site routes through the shared fn...
        "name": "hub per-role MCP wiring in setup (host stdio / client http)",
        "sh": ("setup.sh", r"register_all_hub_mcp"),
        "ps1": ("setup.ps1", r"Register-AllHubMcp"),
    },
    {
        # ...and THIS one checks the SYNC call site. The ADR-0002 review caught sync owning
        # a separate copy that hardcoded stdio courier, silently clobbering the client's
        # http wiring on every run. This is the mechanical guard against that regression.
        "name": "hub per-role MCP wiring in sync (no stdio regression)",
        "sh": ("sync.sh", r"register_all_hub_mcp"),
        "ps1": ("sync.ps1", r"Register-AllHubMcp"),
    },
    {
        "name": "hub host bootstrap script (idempotent repair path)",
        "sh": ("scripts/hub-host-bootstrap.sh", r"HUB-HOST-BOOTSTRAP"),
        "ps1": ("scripts/hub-host-bootstrap.ps1", r"HUB-HOST-BOOTSTRAP"),
    },
    {
        # remote-hubs Phase B: --host/--client are first-class roles. The host role is macOS-only -
        # setup.sh fails loud for a host off Darwin, setup.ps1 rejects -Role host (Windows is always
        # a client). Both carry the ROLE_HOST_GUARD marker so neither side silently drops the guard.
        # (The host-DETECTION asymmetry - is_mcp_host has no Windows mirror - is in PARITY_EXEMPT.)
        "name": "host/client role guard (host is macOS-only, fails loud off-host)",
        "sh": ("setup.sh", r"ROLE_HOST_GUARD"),
        "ps1": ("setup.ps1", r"ROLE_HOST_GUARD"),
    },
    {
        # INV-4 defense: after a gemini http add, scrub known hub headers back to env refs and
        # re-lock ~/.gemini/settings.json. chmod 600 (sh) vs icacls (ps1): different permission
        # mechanism, same behavior - key on the scrub helper.
        "name": "gemini settings scrubbed/re-locked after http wiring",
        "sh": ("manifest.sh", r"gemini_scrub_settings_bearer_refs"),
        "ps1": ("manifest.ps1", r"Set-GeminiBearerRefs"),
    },
    {
        # INV-4 host-side complement: sync runs the generated-config bearer scan (flags a materialized
        # literal token for rotation; configs are machine-local, never in CI) on both OSes.
        "name": "hub bearer host-scan run in sync (generated-config INV-4)",
        "sh": ("sync.sh", r"HUB_BEARER_HOST_SCAN"),
        "ps1": ("sync.ps1", r"HUB_BEARER_HOST_SCAN"),
    },
    {
        # The shared courier functions (incl. the ${COURIER_BEARER} env-var indirection)
        # live in manifest.{sh,ps1}.
        "name": "courier token never on a command line (env-var ref)",
        "sh": ("manifest.sh", r"COURIER_BEARER"),
        "ps1": ("manifest.ps1", r"COURIER_BEARER"),
    },
    {
        # calendar (remote-hubs Phase C) is role-aware like courier: its ${CALENDAR_BEARER} env-var
        # indirection + http client wiring live in manifest.{sh,ps1} on both OSes (never inlined).
        "name": "calendar token never on a command line (env-var ref)",
        "sh": ("manifest.sh", r"CALENDAR_BEARER"),
        "ps1": ("manifest.ps1", r"CALENDAR_BEARER"),
    },
    {
        # nexus (remote-hubs Phase D) is role-aware behind the NEXUS_REMOTED / $NexusRemoted cutover
        # gate: its ${NEXUS_BEARER} env-var indirection + http client wiring live in manifest.{sh,ps1}
        # on both OSes (never inlined). The gate itself must exist on both sides so the cutover flip is
        # symmetric.
        "name": "nexus token never on a command line (env-var ref)",
        "sh": ("manifest.sh", r"NEXUS_BEARER"),
        "ps1": ("manifest.ps1", r"NEXUS_BEARER"),
    },
    {
        "name": "nexus cutover gate present (Phase-D one-flip remoting)",
        "sh": ("manifest.sh", r"NEXUS_REMOTED"),
        "ps1": ("manifest.ps1", r"NexusRemoted"),
    },
    {
        # Highest-stakes semantic divergence the ADR-0002 review flagged: the secret
        # file's permissions. chmod 600 (sh) has no Windows equivalent, so the ps1 side
        # MUST lock it with an ACL (icacls) instead - different mechanism, same behavior.
        # Both live in the shared manifest helpers (provision / Initialize-CourierClientToken).
        "name": "courier token-file permissions (chmod 600 / icacls)",
        "sh": ("manifest.sh", r"chmod 600"),
        "ps1": ("manifest.ps1", r"icacls"),
    },
    {
        "name": "custom global-skills linked into all 3 agents",
        "sh": ("sync.sh", r"GLOBAL_SKILLS_DIR|link_skill_dirs"),
        "ps1": ("sync.ps1", r"GlobalSkillsDir|Link-SkillDirs"),
    },
    {
        "name": "project skills use target-specific native sources",
        "sh": ("manifest.sh", r"CODEX_PROJECT_SKILLS[\s\S]*GEMINI_PROJECT_SKILLS"),
        "ps1": ("manifest.ps1", r"CodexProjectSkills[\s\S]*GeminiProjectSkills"),
    },
    {
        "name": "cross-agent completion notification wired during setup",
        "sh": ("setup.sh", r"configure_agent_integrations"),
        "ps1": ("setup.ps1", r"Set-AgentIntegrations"),
    },
    {
        "name": "cross-agent completion notification repaired during sync",
        "sh": ("sync.sh", r"configure_agent_integrations"),
        "ps1": ("sync.ps1", r"Set-AgentIntegrations"),
    },
    {
        "name": "combined global rules regenerated during routine sync",
        "sh": ("sync.sh", r"regen_combined_agent_rules"),
        "ps1": ("sync.ps1", r"Regen-CombinedAgentRules"),
    },
    {
        # Stale generated skill links (e.g. it-worker-* after the source was archived) get
        # pruned on every regen, on BOTH platforms, so codex/gemini never carry a dead skill.
        "name": "stale skill links pruned (dangling source removed, idempotent)",
        "sh": ("sync.sh", r"clean_stale_skill_symlinks"),
        "ps1": ("sync.ps1", r"Clean-StaleSkillSymlinks"),
    },
    {
        "name": "cross-agent commands generated (codex prompts + gemini TOML)",
        "sh": ("sync.sh", r"gen-agent-commands"),
        "ps1": ("sync.ps1", r"gen-agent-commands"),
    },
    {
        # After generating, sync verifies every source command actually produced a codex
        # prompt + gemini command (a missing mirror fails this local check), on both OSes.
        "name": "command mirror verified (source cmd -> codex prompt + gemini cmd)",
        "sh": ("sync.sh", r"COMMAND_MIRROR_VERIFY"),
        "ps1": ("sync.ps1", r"COMMAND_MIRROR_VERIFY"),
    },
    {
        "name": "Forge state artifact directory ensured",
        "sh": ("manifest.sh", r"Documents/Agent-Forge"),
        "ps1": ("manifest.ps1", r"Documents\\Agent-Forge"),
    },
    {
        # INV-6: sync runs the --machine check after pruning, so a dangling generated skill
        # link surfaces every sync (not just in the developer's head). Both OSes.
        "name": "skill-target machine verify run in sync (no dangling generated link)",
        "sh": ("sync.sh", r"check-skill-targets"),
        "ps1": ("sync.ps1", r"check-skill-targets"),
    },
    {
        # INV-8: sync runs the worktree advisory, so a top-level stray worktree is flagged
        # every sync. Advisory (never fails), but it must actually RUN on both OSes.
        "name": "worktree advisory run in sync (no top-level stray worktree)",
        "sh": ("sync.sh", r"check-worktrees"),
        "ps1": ("sync.ps1", r"check-worktrees"),
    },
    {
        "name": "Claude allowlist mirrored into codex/gemini",
        "sh": ("sync.sh", r"gen-agent-allowlist"),
        "ps1": ("sync.ps1", r"gen-agent-allowlist"),
    },
    {
        "name": "agent defaults configured (Codex xhigh user approvals + full-access permissions + Gemini auto_edit)",
        "sh": ("setup.sh", r"AGENT_DEFAULTS_CONFIG|defaultApprovalMode|approvals_reviewer|sandbox_mode|danger-full-access"),
        "ps1": ("setup.ps1", r"AGENT_DEFAULTS_CONFIG|defaultApprovalMode|approvals_reviewer|sandbox_mode|danger-full-access"),
    },
    {
        "name": "agent defaults repaired during sync (Codex full-access permissions)",
        "sh": ("sync.sh", r"AGENT_DEFAULTS_CONFIG|defaultApprovalMode|approvals_reviewer|sandbox_mode|danger-full-access"),
        "ps1": ("sync.ps1", r"AGENT_DEFAULTS_CONFIG|defaultApprovalMode|approvals_reviewer|sandbox_mode|danger-full-access"),
    },
    {
        "name": "Gemini cross-check setup repaired during setup",
        "sh": ("setup.sh", r"GEMINI_CROSS_CHECK_SETUP|setup-gemini-cross-check"),
        "ps1": ("setup.ps1", r"GEMINI_CROSS_CHECK_SETUP|setup-gemini-cross-check"),
    },
    {
        "name": "Gemini cross-check setup repaired during sync",
        "sh": ("sync.sh", r"GEMINI_CROSS_CHECK_SETUP|setup-gemini-cross-check"),
        "ps1": ("sync.ps1", r"GEMINI_CROSS_CHECK_SETUP|setup-gemini-cross-check"),
    },
    # --- Workspace launchers (shell/ea.zsh <-> shell/windows/ea.ps1). These convenience
    #     functions (ea/wiki/sbic/sysupdate) are the ONLY interactive codex/gemini launch
    #     surface and were previously ungated, so a one-OS drift shipped silently. ---
    {
        # codex launches must carry the bypass-approvals-and-sandbox flag on BOTH OSes, else
        # that side silently reverts to prompting/sandboxing the agent.
        "name": "workspace launchers auto-approve codex (no-sandbox bypass)",
        "sh": ("shell/ea.zsh", r"--dangerously-bypass-approvals-and-sandbox"),
        "ps1": ("shell/windows/ea.ps1", r"--dangerously-bypass-approvals-and-sandbox"),
    },
    {
        # gemini launches must carry --yolo (auto-approve all tools) on BOTH OSes.
        "name": "workspace launchers auto-approve gemini (--yolo)",
        "sh": ("shell/ea.zsh", r"gemini --yolo"),
        "ps1": ("shell/windows/ea.ps1", r"gemini --yolo"),
    },
    {
        # The sbic launcher (cd ~/Documents/SBIC + open an agent) exists on both OSes.
        "name": "sbic workspace launcher present",
        "sh": ("shell/ea.zsh", r"\bsbic\b"),
        "ps1": ("shell/windows/ea.ps1", r"\bsbic\b"),
    },
    {
        "name": "remote PC PowerShell/WSL shortcuts present",
        "sh": ("shell/core.zsh", r"pcpwsh\(\).*pc-pwsh[\s\S]*pcwsl\(\).*pc-wsl"),
        "ps1": ("shell/windows/core.ps1", r"function pcpwsh.*pc-pwsh[\s\S]*function pcwsl.*pc-wsl"),
    },
]

PARITY_EXEMPT = [
    {
        # remote-hubs Phase D / INV-10: the fresh-client abort-free gate exercises bash setup/sync in a
        # Linux container. The behavior IS mirrored on Windows (setup.ps1 client wiring), but a
        # clean-Windows run is not cheaply CI-able here, so the ENFORCER is Linux-only.
        "name": "fresh-client setup gate (INV-10 enforcer)",
        "reason": "check-fresh-client-setup.sh runs the bash client wiring in a Linux container; a "
                  "clean-Windows setup.ps1 run is not cheaply CI-able. The Windows client wiring itself "
                  "stays at parity via the Register-AllHubMcp / Initialize-AllClientTokens feature rows."
    },
    {
        # remote-hubs Phase B: the host/client ROLE GUARD is mirrored (ROLE_HOST_GUARD feature row),
        # but host self-DETECTION is genuinely macOS-only.
        "name": "MCP host-role detection (is_mcp_host)",
        "reason": "Host self-detection is macOS-only: is_mcp_host keys on the macOS LocalHostName and "
                  "host capability needs the login keychain / launchd / tailscale serve. Windows is "
                  "ALWAYS a client (manifest.ps1 hardcodes the client wiring; setup.ps1 -Role host fails "
                  "loud), so there is no ps1 host-detection function to mirror."
    },
    {
        "name": "setup.sh --client Linux/WSL safety (Darwin-gated pbcopy/open, headless reads, npm guard)",
        "reason": "Making setup.sh runnable on a non-Darwin client (gating the Darwin exit, skipping "
                  "pbcopy/open, [ -t 0 ]-guarding interactive reads) is bash-only: WSL/Linux clients run "
                  "setup.sh, while setup.ps1 is the Windows-native entrypoint and never runs on Linux. "
                  "The host-role guard itself IS mirrored (ROLE_HOST_GUARD feature row)."
    },
    {
        "name": "git autosync trigger backend",
        "reason": "The auto-git entrypoints and bootstrap command are paired, but the trigger backend is "
                  "genuinely OS-specific: launchd on macOS, systemd/cron on Linux/WSL, and Task Scheduler "
                  "on Windows. Disabled-by-default behavior is enforced by check-auto-git-safety.sh."
    },
]

# Values that MUST be byte-identical across the two manifests. ADR-0002 frames the
# Mac-mini migration as "change MCP_HOST" - but it lives in BOTH manifest.sh and
# manifest.ps1, so this enforces they can't silently drift apart. (label, sh_rx, ps1_rx);
# each regex captures group 1 = the value. (MAIL_HOST was generalized to MCP_HOST in
# remote-hubs Phase B; the regexes require the `= "..."` assignment so prose mentions don't match.)
SHARED_VALUES = [
    ("MCP_HOST",          r'MCP_HOST="([^"]+)"',           r'\$McpHost\s*=\s*"([^"]+)"'),
    ("TAILNET",           r'\bTAILNET="([^"]+)"',          r'\$Tailnet\s*=\s*"([^"]+)"'),
    ("COURIER_HTTP_PORT", r'COURIER_HTTP_PORT="([^"]+)"',  r'\$CourierHttpPort\s*=\s*"([^"]+)"'),
]

PARITY_PENDING = [
    # (empty) - stacked-push guard registration and combined agent-rules generation are
    # now ported to setup.ps1 and enforced as FEATURES above. PowerShell logic is
    # validated + applied live on pc-lan (no pwsh on the authoring Mac). Whether Claude
    # Code on Windows fires a bash PreToolUse hook is a downstream Claude Code behavior,
    # not a dotfiles-wiring concern; the wiring parity is enforced.
]


def read(root, fname):
    path = os.path.join(root, fname)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def main():
    root = repo_root()
    if not root:
        sys.stderr.write("check-parity: not a git repo - failing closed\n")
        return 2

    # Fail closed if any paired file is missing.
    needed = set()
    for feat in FEATURES:
        needed.add(feat["sh"][0])
        needed.add(feat["ps1"][0])
    cache = {}
    for fname in needed:
        content = read(root, fname)
        if content is None:
            sys.stderr.write(f"check-parity: required file missing: {fname} - failing closed\n")
            return 2
        cache[fname] = content

    failures = []
    for feat in FEATURES:
        sf, sr = feat["sh"]
        pf, pr = feat["ps1"]
        sh_ok = re.search(sr, cache[sf]) is not None
        ps_ok = re.search(pr, cache[pf]) is not None
        if not (sh_ok and ps_ok):
            missing = []
            if not sh_ok:
                missing.append(f"{sf} (sh)")
            if not ps_ok:
                missing.append(f"{pf} (ps1)")
            failures.append((feat["name"], ", ".join(missing)))

    # Shared-value parity: MAIL_HOST/TAILNET/port must be identical across the manifests.
    msh, mps = cache.get("manifest.sh") or read(root, "manifest.sh"), \
               cache.get("manifest.ps1") or read(root, "manifest.ps1")
    for label, shrx, psrx in SHARED_VALUES:
        sm = re.search(shrx, msh or "")
        pm = re.search(psrx, mps or "")
        sv = sm.group(1) if sm else None
        pv = pm.group(1) if pm else None
        if sv != pv:
            failures.append((f"shared value {label} differs across manifests",
                             f"manifest.sh={sv!r} vs manifest.ps1={pv!r}"))

    # hubs.json is the single registry for per-hub config (serve_path/mcp_path/token_file/run_cmd
    # live ONLY there - not duplicated as manifest constants). The one per-hub value also mirrored as
    # a manifest literal is courier's port (manifest builds COURIER_REMOTE_URL from it), so assert the
    # registry and the manifest agree and can't drift. FAIL CLOSED on a missing OR unparseable
    # registry: post-Phase-A hubs.json is a required tracked file, and a silent "missing -> skip" is
    # the exact gap that let an untracked registry pass green in CI.
    hubs_path = os.path.join(root, "hubs.json")
    if not os.path.exists(hubs_path):
        sys.stderr.write("check-parity: hubs.json registry missing - failing closed (required tracked file; stage/commit it)\n")
        return 2
    try:
        with open(hubs_path, encoding="utf-8") as f:
            hubs = json.load(f)
    except Exception as e:
        sys.stderr.write(f"check-parity: hubs.json unparseable ({e}) - failing closed\n")
        return 2
    courier = next((h for h in hubs if h.get("name") == "courier"), None)
    if courier is not None:
        mport = re.search(r'COURIER_HTTP_PORT="([^"]+)"', msh or "")
        mport_v = mport.group(1) if mport else None
        if mport_v is not None and str(courier.get("port")) != str(mport_v):
            failures.append(("hubs.json courier.port differs from manifest COURIER_HTTP_PORT",
                             f"hubs.json={courier.get('port')!r} vs manifest.sh={mport_v!r}"))

    print(f"check-parity: checked {len(FEATURES)} feature(s) + {len(SHARED_VALUES)} shared value(s), "
          f"{len(PARITY_EXEMPT)} exempt, {len(PARITY_PENDING)} pending")

    if PARITY_PENDING:
        sys.stderr.write("\n  PENDING parity ports (tracked in INVARIANTS.md INV-2, not yet enforced):\n")
        for p in PARITY_PENDING:
            sys.stderr.write(f"    - {p['name']}: {p['reason']}\n")

    if failures:
        sys.stderr.write("\nPARITY REGRESSION - a feature exists on one platform but not the other:\n\n")
        for name, where in failures:
            sys.stderr.write(f"  {name}\n      missing in: {where}\n")
        sys.stderr.write(
            "\nAdd the behavior to the missing side, or - if it is genuinely OS-specific -\n"
            "move it to PARITY_EXEMPT with a one-line reason.\n")
        return 1

    print("check-parity OK - all registered features present on both platforms.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
