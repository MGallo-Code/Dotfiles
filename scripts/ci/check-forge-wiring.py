#!/usr/bin/env python3
"""check-forge-wiring.py - INV-11 Forge wiring gate.

Default mode is repo-deterministic and CI-safe: it checks the dotfiles-owned wiring
surfaces that must not drift. If the external EA source tree is present, it also checks
the Forge command/skill/templates/hooks source files.

--machine adds generated/local config checks (`~/.claude/commands`, generated Codex/Gemini
commands, and live Claude/Codex hook registration). That mode is for `sync`/manual local
verification, not bare GitHub CI.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Iterable


TRACKER_FIELDS = {
    "schema_version",
    "task_slug",
    "repo",
    "risk_class",
    "phase",
    "plan_path",
    "approved_plan_paths",
    "open_questions",
    "approved_decisions",
    "assumptions_made",
    "assumption_risk",
    "plan_clean_streak",
    "build_clean_streak",
    "plan_non_important_streak",
    "build_non_important_streak",
    "reviewers_required",
    "reviewers_completed",
    "degraded_reviewers",
    "open_findings_count",
    "crosscheck_stop_decisions",
    "finding_classifications",
    "gates_run",
    "visual_required",
    "visual_verified",
    "pr_allowed",
    "explicit_human_override",
    "last_evidence",
    "remaining_work",
    "next_action",
}


def dotfiles_root() -> Path:
    # This script is also run late in `sync`, after earlier repo checks may have
    # changed cwd. Anchor on this file, not on the caller's current directory.
    return Path(__file__).resolve().parents[2]


def expand(path: str) -> Path:
    return Path(os.path.expanduser(path))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def require(condition: bool, msg: str, findings: list[str]) -> None:
    if not condition:
        findings.append(msg)


def require_file(path: Path, findings: list[str]) -> bool:
    ok = path.is_file()
    require(ok, f"missing file: {path}", findings)
    return ok


def require_contains(path: Path, needles: Iterable[str], findings: list[str]) -> None:
    if not require_file(path, findings):
        return
    text = read(path)
    for needle in needles:
        require(needle in text, f"{path}: missing {needle!r}", findings)


def require_executable(path: Path, msg: str, findings: list[str]) -> None:
    if os.name == "nt":
        return
    require(path.stat().st_mode & 0o111 != 0, msg, findings)


def check_dotfiles(root: Path, findings: list[str]) -> None:
    checker = root / "scripts/forge/check-state.py"
    require_contains(checker, [
        "READY",
        "INCOMPLETE",
        "BLOCKED",
        "INVALID",
        "Documents/Agent-Forge",
        "plan_path",
        "approved_plan_paths",
        "remaining_work",
        "PLAN_CLEAN_STREAK",
        "BUILD_NON_IMPORTANT_STREAK",
        "finding_classifications",
        "crosscheck_stop_decisions",
    ], findings)
    if checker.is_file():
        require_executable(checker, "scripts/forge/check-state.py must be executable", findings)

    require_contains(root / "manifest.sh", [
        "global-commands|~/.claude/commands",
        "~/Documents/Agent-Forge",
    ], findings)
    require_contains(root / "manifest.ps1", [
        "global-commands",
        ".claude\\commands",
        "Documents\\Agent-Forge",
    ], findings)

    for rel in ("setup.sh", "sync.sh"):
        require_contains(root / rel, [
            "forge-guard.sh",
            "ensure_claude_pretooluse_hook",
            "ensure_codex_pretooluse_hook",
        ], findings)
    for rel in ("setup.ps1", "sync.ps1"):
        require_contains(root / rel, [
            "forge-guard.sh",
            "Ensure-ClaudePreToolUseHook",
            "Ensure-CodexPreToolUseHook",
        ], findings)

    require_contains(root / "scripts/ci/check-parity.py", [
        "Forge action guard registered in setup",
        "Forge action guard repaired in sync",
        "Forge state artifact directory ensured",
    ], findings)
    require_contains(root / "INVARIANTS.md", ["INV-11", "check-state.py", "forge-guard.sh"], findings)
    require_contains(root / ".github/PULL_REQUEST_TEMPLATE.md", [
        "## Forge",
        "Forge: `N/A | <slug> | READY`",
        "Tracker: `~/Documents/Agent-Forge/<slug>/tracker.json`",
        "Plan cross-check",
        "Build verification",
        "Visual verification",
        "Explicit PR approval",
    ], findings)
    require_contains(root / ".githooks/pre-commit", ["check-forge-wiring.py"], findings)
    require_contains(root / ".github/workflows/ci.yml", ["check-forge-wiring.py"], findings)


def check_external_sources(ea_config: Path, findings: list[str], required: bool) -> None:
    if not ea_config.exists():
        if required:
            findings.append(f"missing EA config tree: {ea_config}")
        else:
            print(f"check-forge-wiring: EA config tree not present at {ea_config} - external source checks skipped")
        return

    require_contains(ea_config / "global-commands/forge.md", [
        "status [slug-or-tracker-path]",
        "check-state.py",
        "Documents/Agent-Forge",
        "plan_path",
        "approved_plan_paths",
        "remaining_work",
        "Plan Authority",
        "2 clean rounds",
        "6 consecutive non-important rounds",
        "READY",
        "INCOMPLETE",
        "BLOCKED",
        "INVALID",
    ], findings)
    require_contains(ea_config / "global-commands/handoff.md", [
        "## Forge State",
        "Documents/Agent-Forge",
        "Remaining work",
        "Plan authority",
        "Michael-approved plans",
        "Plan cross-check",
        "Build verification",
        "Non-important finding classifications",
    ], findings)
    require_contains(ea_config / "global-skills/forge/SKILL.md", [
        "check-state.py",
        "Documents/Agent-Forge",
        "tracker.json",
        "approved_plan_paths",
        "remaining_work",
        "finding_classifications",
        "crosscheck_stop_decisions",
        "Michael-approved plan files are the source of truth",
        "Resume capsule",
    ], findings)
    require_contains(ea_config / "global-hooks/forge-guard.sh", [
        "check-state.py",
        "Documents/Agent-Forge",
        "FORGE_TRACKER",
        "gh pr create",
        "gh pr merge",
        "git push",
        "git commit",
        "permissionDecision",
    ], findings)
    hook = ea_config / "global-hooks/forge-guard.sh"
    if hook.exists():
        require_executable(hook, f"{hook} must be executable", findings)
    require_contains(ea_config / "global-hooks/README.md", ["forge-guard.sh", "check-state.py"], findings)

    tracker = ea_config / "global-skills/forge/templates/tracker.json"
    if require_file(tracker, findings):
        try:
            data = json.loads(read(tracker))
        except json.JSONDecodeError as exc:
            findings.append(f"{tracker}: invalid JSON: {exc}")
        else:
            missing = sorted(TRACKER_FIELDS - set(data))
            require(not missing, f"{tracker}: missing tracker field(s): {', '.join(missing)}", findings)
    require_contains(ea_config / "global-skills/forge/templates/tracker.md", [
        "check-state.py",
        "Documents/Agent-Forge",
        "Remaining Work",
        "Plan Authority",
        "Michael-approved plans",
        "Cross-Check Finding Classification",
        "Non-important streak",
    ], findings)


def check_machine(ea_config: Path, findings: list[str]) -> None:
    claude_commands = expand("~/.claude/commands")
    expected_commands = ea_config / "global-commands"
    require(claude_commands.is_symlink(), f"{claude_commands} must be a symlink", findings)
    if claude_commands.is_symlink():
        require(claude_commands.resolve() == expected_commands.resolve(),
                f"{claude_commands} must point to {expected_commands}", findings)

    require_contains(expand("~/.codex/prompts/forge.md"), ["Documents/Agent-Forge", "check-state.py"], findings)
    require_contains(expand("~/.gemini/commands/forge.toml"), ["Documents/Agent-Forge", "check-state.py"], findings)

    # Codex config: key on the DURABLE command path, not the "# dotfiles: Forge action guard"
    # comment. Codex rewrites config.toml and strips that comment (the hook block + command line
    # survive), so requiring the comment produced a false failure post-sync. The forge-guard.sh
    # command line is what actually proves the guard is registered as a Codex PreToolUse hook.

    claude_settings = expand("~/.claude/settings.json")
    if require_file(claude_settings, findings):
        try:
            data = json.loads(read(claude_settings))
        except json.JSONDecodeError as exc:
            findings.append(f"{claude_settings}: invalid JSON: {exc}")
        else:
            commands = []
            hooks = data.get("hooks", {})
            if not isinstance(hooks, dict):
                findings.append(f"{claude_settings}: hooks must be an object")
                hooks = {}
            pretooluse = hooks.get("PreToolUse", [])
            if not isinstance(pretooluse, list):
                findings.append(f"{claude_settings}: hooks.PreToolUse must be a list")
                pretooluse = []
            for entry in pretooluse:
                if not isinstance(entry, dict):
                    continue
                entry_hooks = entry.get("hooks", [])
                if not isinstance(entry_hooks, list):
                    continue
                for hook in entry_hooks:
                    if not isinstance(hook, dict):
                        continue
                    commands.append(hook.get("command", ""))
            require(any("forge-guard.sh" in cmd for cmd in commands),
                    f"{claude_settings}: missing forge-guard.sh PreToolUse command", findings)

    require_contains(expand("~/.codex/config.toml"), ["forge-guard.sh"], findings)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Check Forge wiring across dotfiles and local agent config.")
    parser.add_argument("--machine", action="store_true", help="also check generated local agent targets")
    parser.add_argument(
        "--require-external",
        action="store_true",
        help="fail if ~/Documents/EA/claude-config is unavailable",
    )
    args = parser.parse_args(argv)

    root = dotfiles_root()
    ea_config = expand(os.environ.get("EA_CLAUDE_CONFIG", "~/Documents/EA/claude-config"))
    findings: list[str] = []

    check_dotfiles(root, findings)
    check_external_sources(ea_config, findings, required=args.require_external or args.machine)
    if args.machine:
        check_machine(ea_config, findings)

    if findings:
        sys.stderr.write("check-forge-wiring FAILED:\n")
        for item in findings:
            sys.stderr.write(f"  - {item}\n")
        return 1

    mode = "machine" if args.machine else "repo"
    print(f"check-forge-wiring OK ({mode})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
