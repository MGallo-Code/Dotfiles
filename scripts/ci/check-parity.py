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
        "name": "codex/gemini agent-rules wired",
        "sh": ("manifest.sh", r"AGENTS\.md|GEMINI\.md"),
        "ps1": ("manifest.ps1", r"AGENTS\.md|GEMINI\.md"),
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
    {
        "name": "MCP server: nexus",
        "sh": ("setup.sh", r"nexus"),
        "ps1": ("setup.ps1", r"nexus"),
    },
    {
        "name": "MCP server: courier",
        "sh": ("setup.sh", r"courier"),
        "ps1": ("setup.ps1", r"courier"),
    },
    {
        "name": "MCP server: docgen",
        "sh": ("setup.sh", r"docgen"),
        "ps1": ("setup.ps1", r"docgen"),
    },
    {
        "name": "MCP server: calendar",
        "sh": ("setup.sh", r"calendar"),
        "ps1": ("setup.ps1", r"calendar"),
    },
    # --- Ported in this change; they FAIL until the .ps1 side lands (a built-in
    #     revert-test for the port). ---
    {
        "name": "~/.claude/hooks dir wired (enables all hook scripts)",
        "sh": ("manifest.sh", r"global-hooks"),
        "ps1": ("manifest.ps1", r"global-hooks"),
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
        "name": "combined agent-rules generated (full ruleset, not a subset)",
        "sh": ("setup.sh", r"regen_combined_agent_rules"),
        "ps1": ("setup.ps1", r"Regen-CombinedAgentRules"),
    },
    # --- courier remote per-OS wiring + cross-agent skills/commands/allowlist
    #     (ADR-0002 + handoff). Each is a paired sh/ps1 behavior. ---
    {
        # The role-aware courier wiring is defined ONCE in manifest.{sh,ps1} and CALLED by
        # both setup and sync. This feature checks the SETUP call site...
        "name": "courier per-role MCP wiring in setup (host stdio / client http)",
        "sh": ("setup.sh", r"register_courier_mcp"),
        "ps1": ("setup.ps1", r"Register-CourierMcp"),
    },
    {
        # ...and THIS one checks the SYNC call site. The ADR-0002 review caught sync owning
        # a separate copy that hardcoded stdio courier, silently clobbering the client's
        # http wiring on every run. This is the mechanical guard against that regression.
        "name": "courier per-role MCP wiring in sync (no stdio regression)",
        "sh": ("sync.sh", r"register_courier_mcp"),
        "ps1": ("sync.ps1", r"Register-CourierMcp"),
    },
    {
        "name": "courier host bootstrap script (idempotent repair path)",
        "sh": ("scripts/courier-host-bootstrap.sh", r"COURIER-HOST-BOOTSTRAP"),
        "ps1": ("scripts/courier-host-bootstrap.ps1", r"COURIER-HOST-BOOTSTRAP"),
    },
    {
        # The shared courier functions (incl. the ${COURIER_BEARER} env-var indirection)
        # live in manifest.{sh,ps1}.
        "name": "courier token never on a command line (env-var ref)",
        "sh": ("manifest.sh", r"COURIER_BEARER"),
        "ps1": ("manifest.ps1", r"COURIER_BEARER"),
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
        "name": "project skills namespaced into codex/gemini",
        "sh": ("sync.sh", r"PROJECT_SKILLS"),
        "ps1": ("sync.ps1", r"ProjectSkills"),
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
        "name": "Claude allowlist mirrored into codex/gemini",
        "sh": ("sync.sh", r"gen-agent-allowlist"),
        "ps1": ("sync.ps1", r"gen-agent-allowlist"),
    },
    {
        "name": "agent defaults configured (Codex xhigh user approvals + Michael workspace permissions + Gemini auto_edit)",
        "sh": ("setup.sh", r"AGENT_DEFAULTS_CONFIG|defaultApprovalMode|approvals_reviewer|default_permissions|michael_workspace"),
        "ps1": ("setup.ps1", r"AGENT_DEFAULTS_CONFIG|defaultApprovalMode|approvals_reviewer|default_permissions|michael_workspace"),
    },
    {
        "name": "agent defaults repaired during sync (Codex Michael workspace permissions)",
        "sh": ("sync.sh", r"AGENT_DEFAULTS_CONFIG|defaultApprovalMode|approvals_reviewer|default_permissions|michael_workspace"),
        "ps1": ("sync.ps1", r"AGENT_DEFAULTS_CONFIG|defaultApprovalMode|approvals_reviewer|default_permissions|michael_workspace"),
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
]

PARITY_EXEMPT = [
    {
        "name": "notify-when-done hook registration",
        "reason": "Claude Code notify hook is macOS-only by design (see "
                  "global-rules/notify-when-done.md: 'Claude Code on macOS only')."
    },
]

# Values that MUST be byte-identical across the two manifests. ADR-0002 frames the
# Mac-mini migration as "change MAIL_HOST" - but it lives in BOTH manifest.sh and
# manifest.ps1, so this enforces they can't silently drift apart. (label, sh_rx, ps1_rx);
# each regex captures group 1 = the value.
SHARED_VALUES = [
    ("MAIL_HOST",         r'MAIL_HOST="([^"]+)"',          r'\$MailHost\s*=\s*"([^"]+)"'),
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
