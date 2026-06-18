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
]

PARITY_EXEMPT = [
    {
        "name": "notify-when-done hook registration",
        "reason": "Claude Code notify hook is macOS-only by design (see "
                  "global-rules/notify-when-done.md: 'Claude Code on macOS only')."
    },
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

    print(f"check-parity: checked {len(FEATURES)} feature(s), "
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
