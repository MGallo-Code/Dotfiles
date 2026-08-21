#!/usr/bin/env python3
"""INV-14 gate for trusted Michael Workspace agent launches and diagnostics."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(os.environ.get("GATE_ROOT", Path(__file__).resolve().parents[2]))

STATIC_REQUIREMENTS = {
    "shell/ea.zsh": (
        "TRUSTED_WORKSPACE_SUBSHELL",
        "claude --permission-mode bypassPermissions",
        "codex --sandbox danger-full-access --ask-for-approval never",
        "workspace-access-diagnostics.py",
        "_workspace_prompt_access_guard",
        "_ws_trusted_root_is_redirected",
        "_ws_scope_override_present",
    ),
    "shell/windows/ea.ps1": (
        "TRUSTED_WORKSPACE_SUBSHELL",
        "claude --permission-mode bypassPermissions",
        "codex --sandbox danger-full-access --ask-for-approval never",
        "Push-Location",
        "Pop-Location",
        "workspace-access-diagnostics.py",
        "Test-WsRootRedirected",
        "Test-WsScopeOverride",
    ),
    "scripts/ci/check-workspace-access.ps1": (
        "Claude exit status was not preserved",
        "Codex exit status was not preserved",
        "missing trusted root did not recover to HOME",
    ),
    "setup.sh": ("AGENT_DEFAULTS_CONFIG", "configure-claude-defaults.py", "configure-codex-defaults.py"),
    "sync.sh": ("AGENT_DEFAULTS_CONFIG", "configure-claude-defaults.py", "configure-codex-defaults.py"),
    "setup.ps1": ("AGENT_DEFAULTS_CONFIG", "configure-claude-defaults.py", "configure-codex-defaults.py"),
    "sync.ps1": ("AGENT_DEFAULTS_CONFIG", "configure-claude-defaults.py", "configure-codex-defaults.py"),
    "INVARIANTS.md": ("INV-14", "check-workspace-access.py"),
    ".githooks/pre-commit": ("check-workspace-access.py",),
    ".github/workflows/ci.yml": ("workspace-access", "check-workspace-access.py --revert-test"),
    "docs/workspace-access-recovery.md": (
        "macos_tcc_system_policy",
        "inaccessible_cwd_or_file_provider",
        "read_only_mount",
        "zsh_history_or_prompt_hook",
        "agent_sandbox_envelope",
    ),
}


def static_findings(root: Path) -> list[str]:
    findings: list[str] = []
    for relative, needles in STATIC_REQUIREMENTS.items():
        path = root / relative
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            findings.append(f"cannot read {relative}: {exc}")
            continue
        for needle in needles:
            if needle not in text:
                findings.append(f"{relative}: missing {needle!r}")
    diagnostic = root / "scripts/workspace-access-diagnostics.py"
    claude_defaults = root / "scripts/configure-claude-defaults.py"
    codex_defaults = root / "scripts/configure-codex-defaults.py"
    for path in (diagnostic, claude_defaults, codex_defaults):
        if not path.is_file():
            findings.append(f"missing {path.relative_to(root)}")
    if diagnostic.is_file() and "history_file" not in diagnostic.read_text(encoding="utf-8"):
        findings.append("workspace diagnostic does not retain a distinct history-file probe")
    return findings


def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True, **kwargs)


def check_diagnostic_self_test(root: Path, findings: list[str]) -> None:
    result = run([sys.executable, str(root / "scripts/workspace-access-diagnostics.py"), "--self-test"])
    if result.returncode != 0:
        findings.append(
            "diagnostic self-test failed:\n" + (result.stdout + result.stderr).strip()
        )


def check_claude_defaults(root: Path, findings: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="workspace-access-config-") as raw_home:
        home = Path(raw_home)
        settings = home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        original = {
            "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "keep-me"}]}]},
            "permissions": {"allow": ["Read"]},
            "unrelated": {"preserved": True},
        }
        settings.write_text(json.dumps(original), encoding="utf-8")
        command = [
            sys.executable,
            str(root / "scripts/configure-claude-defaults.py"),
            "--home",
            str(home),
        ]
        first = run(command)
        if first.returncode != 0:
            findings.append("Claude defaults fixture failed: " + first.stderr.strip())
            return
        once = settings.read_bytes()
        second = run(command)
        twice = settings.read_bytes()
        if second.returncode != 0 or once != twice:
            findings.append("Claude defaults writer is not idempotent")
            return
        data = json.loads(once)
        permissions = data.get("permissions", {})
        if permissions.get("defaultMode") != "bypassPermissions":
            findings.append("Claude defaults did not set permissions.defaultMode=bypassPermissions")
        if permissions.get("skipDangerousModePermissionPrompt") is not True:
            findings.append("Claude defaults did not set skipDangerousModePermissionPrompt=true")
        if data.get("hooks") != original["hooks"] or data.get("unrelated") != original["unrelated"]:
            findings.append("Claude defaults writer did not preserve unrelated settings")

        before = b"{ malformed\n"
        settings.write_bytes(before)
        malformed = run(command)
        if malformed.returncode == 0 or settings.read_bytes() != before:
            findings.append("Claude defaults writer did not fail closed on malformed JSON")


def check_codex_defaults(root: Path, findings: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="workspace-access-codex-config-") as raw_home:
        home = Path(raw_home)
        config = home / ".codex/config.toml"
        config.parent.mkdir(parents=True)
        protected_multiline = (
            'developer_instructions = """Preserve Δ exactly.\n'
            "[not.a.table]\n"
            "sandbox_mode = 'inside-instructions'\n"
            '"""\n'
        )
        original_tail = "  [profiles.review]\nsandbox_mode = 'workspace-write'\nunrelated = true\n"
        config.write_text(
            "# keep this comment\n"
            + protected_multiline
            + '  model_reasoning_effort = """\nlow\n"""\n'
            "approval_policy = '''on-request'''\n"
            "'approvals_reviewer' = 'model'\n"
            '"sandbox_mode" = """read-only"""\n'
            "default_permissions = ':read-only'\n\n"
            "  [permissions.michael_workspace]\n"
            "description = 'replace me'\n\n"
            + original_tail,
            encoding="utf-8",
        )
        command = [
            sys.executable,
            str(root / "scripts/configure-codex-defaults.py"),
            "--home",
            str(home),
        ]
        first = run(command)
        if first.returncode != 0:
            findings.append("Codex defaults fixture failed: " + first.stderr.strip())
            return
        once = config.read_bytes()
        second = run(command)
        if second.returncode != 0 or config.read_bytes() != once:
            findings.append("Codex defaults writer is not idempotent")
            return
        text = once.decode("utf-8")
        expected = {
            'model_reasoning_effort = "xhigh"',
            'approval_policy = "never"',
            'approvals_reviewer = "user"',
            'sandbox_mode = "danger-full-access"',
        }
        if not expected.issubset(set(text.splitlines())) or any(
            text.count(line) != 1 for line in expected
        ):
            findings.append("Codex defaults did not converge all documented top-level values")
        if (
            "default_permissions" in text
            or original_tail not in text
            or protected_multiline not in text
            or text.count("[permissions.michael_workspace]") != 1
        ):
            findings.append("Codex defaults did not preserve multiline/profile TOML while replacing managed state")
        try:
            try:
                import tomllib as toml_reader
            except ImportError:
                import tomli as toml_reader  # type: ignore[no-redef]
        except ImportError:
            toml_reader = None
        if toml_reader is not None:
            try:
                parsed = toml_reader.loads(text)
            except Exception as exc:  # pragma: no cover - exact parser exception varies
                findings.append(f"Codex defaults output is not valid TOML: {exc}")
            else:
                if parsed.get("sandbox_mode") != "danger-full-access":
                    findings.append("Codex defaults TOML did not parse to danger-full-access")

        malformed = "sandbox_mode = '''read-only\nstill-open\n"
        config.write_text(malformed, encoding="utf-8")
        rejected = run(command)
        if rejected.returncode == 0 or config.read_text(encoding="utf-8") != malformed:
            findings.append("Codex defaults writer did not fail closed on a multiline managed value")


def write_stub(path: Path) -> None:
    path.write_text(
        "#!/bin/sh\n"
        "{\n"
        "  printf 'cli=%s\\n' \"$(basename \"$0\")\"\n"
        "  printf 'cwd=%s\\n' \"$PWD\"\n"
        "  for arg in \"$@\"; do printf 'arg=%s\\n' \"$arg\"; done\n"
        "} >> \"$TRACE_FILE\"\n"
        "if [ \"${REMOVE_WORKSPACE_AFTER:-0}\" = 1 ]; then /bin/rmdir \"$PWD\"; fi\n"
        "exit \"${STUB_RC:-0}\"\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


def run_zsh(root: Path, home: Path, trace: Path, body: str, *, rc: int = 0, remove: bool = False) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "PATH": str(home / "bin") + os.pathsep + env.get("PATH", ""),
            "TRACE_FILE": str(trace),
            "STUB_RC": str(rc),
            "REMOVE_WORKSPACE_AFTER": "1" if remove else "0",
            "TERM_PROGRAM": "Apple_Terminal",
        }
    )
    program = (
        "compdef() { :; }\n"
        f"source {shlex.quote(str(root / 'shell/ea.zsh'))}\n"
        f"cd {shlex.quote(str(home / 'start'))}\n"
        + body
    )
    return run(["zsh", "-f", "-c", program], env=env, timeout=30)


def trace_values(trace: Path) -> list[str]:
    return trace.read_text(encoding="utf-8").splitlines() if trace.exists() else []


def check_zsh_behavior(root: Path, findings: list[str]) -> None:
    if shutil.which("zsh") is None:
        findings.append("zsh is required for launcher behavior fixtures")
        return
    with tempfile.TemporaryDirectory(prefix="workspace-access-zsh-") as raw_home:
        home = Path(raw_home)
        for relative in ("bin", "start", "Documents/EA", "Documents/Wiki", "Documents/SBIC", ".dotfiles"):
            (home / relative).mkdir(parents=True, exist_ok=True)
        for cli in ("claude", "codex", "gemini"):
            write_stub(home / "bin" / cli)
        trace = home / "trace"

        claude = run_zsh(
            root,
            home,
            trace,
            'ea --claude marker\nlaunch_rc=$?\nprint -r -- "RESULT rc=$launch_rc pwd=$PWD"\n',
            rc=23,
        )
        values = trace_values(trace)
        if claude.returncode != 0 or f"RESULT rc=23 pwd={home / 'start'}" not in claude.stdout:
            findings.append("Zsh launcher did not preserve agent status and restore parent cwd")
        if "bad math expression" in claude.stderr or "command not found" in claude.stderr:
            findings.append("Zsh launcher emitted a source-time error")
        for expected in (
            "cli=claude",
            f"cwd={home / 'Documents/EA'}",
            "arg=--permission-mode",
            "arg=bypassPermissions",
            "arg=marker",
        ):
            if expected not in values:
                findings.append(f"Zsh Claude fixture missing trace {expected!r}")

        trace.unlink(missing_ok=True)
        codex = run_zsh(
            root,
            home,
            trace,
            'wiki --codex marker\nlaunch_rc=$?\nprint -r -- "RESULT rc=$launch_rc pwd=$PWD"\n',
        )
        values = trace_values(trace)
        if codex.returncode != 0 or f"RESULT rc=0 pwd={home / 'start'}" not in codex.stdout:
            findings.append("Zsh Codex launcher did not restore parent cwd")
        for expected in (
            "cli=codex",
            f"cwd={home / 'Documents/Wiki'}",
            "arg=--sandbox",
            "arg=danger-full-access",
            "arg=--ask-for-approval",
            "arg=never",
            "arg=marker",
        ):
            if expected not in values:
                findings.append(f"Zsh Codex fixture missing trace {expected!r}")

        trace.unlink(missing_ok=True)
        untrusted = home / "Documents/untrusted"
        untrusted.mkdir()
        refused = run_zsh(
            root,
            home,
            trace,
            f'_ws_launch {shlex.quote(str(untrusted))} --claude\nprint -r -- "RESULT rc=$? pwd=$PWD"\n',
        )
        if "RESULT rc=64" not in refused.stdout or trace.exists():
            findings.append("Zsh launcher did not refuse an unnamed/untrusted root before invoking an agent")

        scope_override = run_zsh(
            root,
            home,
            trace,
            'wiki --codex --cd /tmp\nprint -r -- "RESULT rc=$? pwd=$PWD"\n',
        )
        if "RESULT rc=64" not in scope_override.stdout or trace.exists():
            findings.append("Zsh launcher allowed Codex to override the trusted cwd")
        short_scope_override = run_zsh(
            root,
            home,
            trace,
            'wiki --codex -C/tmp\nprint -r -- "RESULT rc=$? pwd=$PWD"\n',
        )
        if "RESULT rc=64" not in short_scope_override.stdout or trace.exists():
            findings.append("Zsh launcher allowed Codex's attached short cwd override")

        # A fixed trusted name redirected through a symlink must not inherit autonomous policy.
        trusted_ea = home / "Documents/EA"
        trusted_ea_backing = home / "Documents/EA-backing"
        trusted_ea.rename(trusted_ea_backing)
        trusted_ea.symlink_to(untrusted, target_is_directory=True)
        redirected = run_zsh(
            root,
            home,
            trace,
            'ea --claude\nprint -r -- "RESULT rc=$? pwd=$PWD"\n',
        )
        if "RESULT rc=64" not in redirected.stdout or trace.exists():
            findings.append("Zsh launcher did not refuse a redirected trusted root")
        trusted_ea.unlink()
        trusted_ea_backing.rename(trusted_ea)

        # Remove a named root to exercise fail-loud preflight without invoking the agent.
        shutil.rmtree(home / "Documents/EA")
        missing = run_zsh(
            root,
            home,
            trace,
            'ea --claude\nprint -r -- "RESULT rc=$? pwd=$PWD"\n',
        )
        if "RESULT rc=74" not in missing.stdout or trace.exists():
            findings.append("Zsh launcher did not fail loudly before launching in a missing trusted root")

        (home / "Documents/EA").mkdir()
        trace.unlink(missing_ok=True)
        recovery = run_zsh(
            root,
            home,
            trace,
            'ea --claude\nprint -r -- "RESULT rc=$? pwd=$PWD"\n',
            remove=True,
        )
        if f"RESULT rc=74 pwd={home}" not in recovery.stdout:
            findings.append("Zsh launcher did not recover to HOME after the launch workspace disappeared")


def copy_static_surface(source: Path, destination: Path) -> None:
    for relative in set(STATIC_REQUIREMENTS) | {
        "scripts/workspace-access-diagnostics.py",
        "scripts/configure-claude-defaults.py",
        "scripts/configure-codex-defaults.py",
    }:
        src = source / relative
        dst = destination / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def revert_test(root: Path) -> int:
    with tempfile.TemporaryDirectory(prefix="workspace-access-revert-") as raw:
        copy_root = Path(raw)
        copy_static_surface(root, copy_root)
        zsh = copy_root / "shell/ea.zsh"
        text = zsh.read_text(encoding="utf-8")
        old = "codex --sandbox danger-full-access --ask-for-approval never"
        if old not in text:
            print("revert-test setup failed: canonical Codex launch flag not found", file=sys.stderr)
            return 2
        zsh.write_text(text.replace(old, "codex --sandbox read-only --ask-for-approval never", 1), encoding="utf-8")
        findings = static_findings(copy_root)
        if not any("shell/ea.zsh" in finding and "codex --sandbox" in finding for finding in findings):
            print("revert-test FAILED: weakened Codex sandbox escaped the gate", file=sys.stderr)
            return 1
    print("check-workspace-access revert-test OK - weakened launcher was rejected")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--revert-test", action="store_true")
    args = parser.parse_args()

    findings = static_findings(ROOT)
    if findings:
        for finding in findings:
            print(f"check-workspace-access: {finding}", file=sys.stderr)
        return 1

    check_diagnostic_self_test(ROOT, findings)
    check_claude_defaults(ROOT, findings)
    check_codex_defaults(ROOT, findings)
    check_zsh_behavior(ROOT, findings)
    if findings:
        for finding in findings:
            print(f"check-workspace-access: {finding}", file=sys.stderr)
        return 1

    print("check-workspace-access OK - trusted launch/config/diagnostic contract holds")
    if args.revert_test:
        return revert_test(ROOT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
