#!/usr/bin/env python3
"""Gate cross-agent completion-hook migration, idempotence, and live wiring.

Default mode is hermetic and CI-safe. ``--machine`` additionally checks the current
Claude/Codex/Gemini configs and exercises the EA hook's session-scoped state machine with
a stub sender. It never sends email.
"""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace


def root() -> Path:
    return Path(__file__).resolve().parents[2]


def toml_module():
    try:
        import tomllib

        return tomllib
    except ModuleNotFoundError:
        import tomli

        return tomli


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def commands(data: dict, event: str) -> list[str]:
    result = []
    hooks = data.get("hooks", {})
    for entry in hooks.get(event, []) if isinstance(hooks, dict) else []:
        for hook in entry.get("hooks", []) if isinstance(entry, dict) else []:
            command = hook.get("command") if isinstance(hook, dict) else None
            if isinstance(command, str):
                result.append(command)
    return result


def run_configurator(
    home: Path,
    hook: Path,
    runner: Path,
    disable_roots: list[Path],
    courier_url: str = "https://notify.invalid/mcp",
):
    argv = [
        sys.executable,
        str(root() / "scripts" / "configure-agent-integrations.py"),
        "--home",
        str(home),
        "--hook",
        str(hook),
        "--runner",
        str(runner),
        "--courier-url",
        courier_url,
        "--courier-token-file",
        str(home / ".config" / "courier" / "auth-token"),
        "--default-to",
        "notify@example.invalid",
        "--from-address",
        "sender@example.invalid",
        "--account",
        "test-account",
    ]
    for path in disable_roots:
        argv.extend(["--codex-disable-root", str(path)])
    return subprocess.run(argv, text=True, capture_output=True, check=False)


def hermetic(findings: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="agent-integrations-check-") as raw:
        base = Path(raw)
        home = base / "home"
        hook = base / "agent-notify.py"
        runner = base / "python"
        hook.write_text("# fixture\n", encoding="utf-8")
        runner.write_text("# fixture\n", encoding="utf-8")
        codex_root = base / "SBIC" / ".codex" / "skills"
        agents_root = base / "SBIC" / ".agents" / "skills"
        for source, name in ((codex_root, "native"), (agents_root, "converted")):
            skill = source / name / "SKILL.md"
            skill.parent.mkdir(parents=True)
            skill.write_text("---\nname: fixture\n---\n", encoding="utf-8")

        claude_path = home / ".claude" / "settings.json"
        codex_path = home / ".codex" / "config.toml"
        gemini_path = home / ".gemini" / "settings.json"
        claude_path.parent.mkdir(parents=True)
        codex_path.parent.mkdir(parents=True)
        gemini_path.parent.mkdir(parents=True)
        claude_path.write_text(
            json.dumps(
                {
                    "keep": 1,
                    "hooks": {
                        "Stop": [
                            {
                                "matcher": "",
                                "hooks": [
                                    {"type": "command", "command": "/old/notify-claude.sh"},
                                    {"type": "command", "command": "keep-stop"},
                                ],
                            }
                        ],
                        "Notification": [
                            {"matcher": "", "hooks": [{"type": "command", "command": "/old/notify-claude.sh"}]}
                        ],
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        codex_path.write_text('[unrelated]\nvalue = "keep"\n', encoding="utf-8")
        gemini_path.write_text(
            json.dumps(
                {
                    "keep": 2,
                    "hooks": {
                        "AfterAgent": [
                            {"matcher": "*", "hooks": [{"type": "command", "command": "keep-after"}]}
                        ]
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        result = run_configurator(home, hook, runner, [codex_root, agents_root])
        require(result.returncode == 0, f"configurator fixture failed: {result.stderr.strip()}", findings)
        if result.returncode != 0:
            return

        claude = json.loads(claude_path.read_text(encoding="utf-8"))
        gemini = json.loads(gemini_path.read_text(encoding="utf-8"))
        codex = toml_module().loads(codex_path.read_text(encoding="utf-8"))
        require(claude.get("keep") == 1, "Claude unrelated config was not preserved", findings)
        require("keep-stop" in commands(claude, "Stop"), "Claude unrelated Stop hook was not preserved", findings)
        require(not commands(claude, "Notification"), "legacy Claude Notification email hook survived", findings)
        require(sum("agent-notify.py" in value for value in commands(claude, "Stop")) == 1,
                "Claude must have exactly one managed Stop hook", findings)
        require(gemini.get("keep") == 2, "Gemini unrelated config was not preserved", findings)
        require("keep-after" in commands(gemini, "AfterAgent"), "Gemini unrelated hook was not preserved", findings)
        require(sum("agent-notify.py" in value for value in commands(gemini, "AfterAgent")) == 1,
                "Gemini must have exactly one managed AfterAgent hook", findings)
        require(sum("agent-notify.py" in value for value in commands(gemini, "AfterTool")) == 1,
                "Gemini must have exactly one managed AfterTool arm hook", findings)
        require(codex.get("unrelated", {}).get("value") == "keep", "Codex unrelated TOML was not preserved", findings)
        notify = codex.get("notify", [])
        require(isinstance(notify, list) and "agent-notify.py" in " ".join(notify),
                "Codex native notify program is missing", findings)
        disabled = codex.get("skills", {}).get("config", [])
        require(len(disabled) == 2 and all(item.get("enabled") is False for item in disabled),
                "Codex duplicate skill paths were not disabled exactly", findings)

        tracked = [claude_path, codex_path, gemini_path, home / ".config" / "agent-notify" / "config.json"]
        before = {path: path.read_bytes() for path in tracked}
        second = run_configurator(home, hook, runner, [codex_root, agents_root])
        require(second.returncode == 0, "second configurator run failed", findings)
        require(before == {path: path.read_bytes() for path in tracked}, "configurator is not byte-idempotent", findings)

        malformed_home = base / "malformed-home"
        bad_claude = malformed_home / ".claude" / "settings.json"
        bad_codex = malformed_home / ".codex" / "config.toml"
        bad_gemini = malformed_home / ".gemini" / "settings.json"
        bad_claude.parent.mkdir(parents=True)
        bad_codex.parent.mkdir(parents=True)
        bad_gemini.parent.mkdir(parents=True)
        bad_claude.write_text('{"hooks":', encoding="utf-8")
        bad_codex.write_text('keep = "yes"\n', encoding="utf-8")
        bad_gemini.write_text('{}\n', encoding="utf-8")
        before_bad = {path: path.read_bytes() for path in (bad_claude, bad_codex, bad_gemini)}
        failed = run_configurator(malformed_home, hook, runner, [])
        require(failed.returncode != 0, "malformed source config did not fail closed", findings)
        require(before_bad == {path: path.read_bytes() for path in before_bad},
                "transaction wrote a file after malformed input", findings)

        invalid_url_home = base / "invalid-url-home"
        failed = run_configurator(
            invalid_url_home, hook, runner, [], courier_url="http://notify.invalid/mcp"
        )
        require(failed.returncode != 0, "non-HTTPS Courier URL did not fail closed", findings)
        require(not invalid_url_home.exists(), "invalid Courier URL wrote machine config", findings)


def load_hook(path: Path):
    spec = importlib.util.spec_from_file_location("agent_notify_live_check", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load hook module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def machine(findings: list[str]) -> None:
    home = Path.home()
    hook_path = home / "Documents" / "EA" / "claude-config" / "global-hooks" / "agent-notify.py"
    require(hook_path.is_file(), f"live hook missing: {hook_path}", findings)
    if not hook_path.is_file():
        return
    try:
        claude = json.loads((home / ".claude" / "settings.json").read_text(encoding="utf-8"))
        gemini = json.loads((home / ".gemini" / "settings.json").read_text(encoding="utf-8"))
        codex = toml_module().loads((home / ".codex" / "config.toml").read_text(encoding="utf-8"))
    except Exception as exc:
        findings.append(f"live agent config is malformed: {type(exc).__name__}")
        return
    require(sum("agent-notify.py" in value for value in commands(claude, "Stop")) == 1,
            "live Claude Stop hook is not converged", findings)
    require(not any("agent-notify.py" in value or "notify-claude.sh" in value for value in commands(claude, "Notification")),
            "live Claude still has a Notification email hook", findings)
    require(sum("agent-notify.py" in value for value in commands(gemini, "AfterAgent")) == 1,
            "live Gemini AfterAgent hook is not converged", findings)
    require(sum("agent-notify.py" in value for value in commands(gemini, "AfterTool")) == 1,
            "live Gemini AfterTool hook is not converged", findings)
    require("agent-notify.py" in " ".join(codex.get("notify", [])), "live Codex notify is missing", findings)

    expected_disabled = set()
    for source in (home / "Documents" / "SBIC" / ".codex" / "skills", home / "Documents" / "SBIC" / ".agents" / "skills"):
        if source.is_dir():
            expected_disabled.update(str(path.resolve()) for path in source.glob("*/SKILL.md") if path.is_file())
    actual_disabled = {
        item.get("path")
        for item in codex.get("skills", {}).get("config", [])
        if isinstance(item, dict) and item.get("enabled") is False
    }
    require(expected_disabled <= actual_disabled, "live Codex duplicate-skill suppression is incomplete", findings)

    with tempfile.TemporaryDirectory(prefix="agent-notify-state-check-") as raw:
        old_state = os.environ.get("AGENT_NOTIFY_STATE_DIR")
        old_codex = os.environ.get("CODEX_THREAD_ID")
        os.environ["AGENT_NOTIFY_STATE_DIR"] = raw
        try:
            module = load_hook(hook_path)
            state = Path(raw)
            module._atomic_json(
                state / "config.json",
                {
                    "account": "test",
                    "courier_token_file": str(state / "token"),
                    "courier_url": "https://notify.invalid/mcp",
                    "default_to": "notify@example.invalid",
                    "from_address": "sender@example.invalid",
                    "version": 1,
                },
            )
            token = state / "token"
            token.write_text("fixture-token-material", encoding="utf-8")
            if os.name == "posix":
                token.chmod(0o640)
                try:
                    module._token(module._load_config())
                except module.NotifyError as exc:
                    require(str(exc) == "courier_token_permissions",
                            "group-readable Courier token was not rejected", findings)
                else:
                    findings.append("group-readable Courier token was accepted")
                token.chmod(0o600)
            calls = []
            module._send = lambda record: calls.append(record["notification_id"]) or "stub"

            # An ordinary unarmed completion creates no state, log, or send.
            module._complete("codex", {"thread-id": "unarmed"})
            require(not calls and not (state / "notify.log").exists(),
                    "unarmed completion was not inert", findings)

            os.environ["CODEX_THREAD_ID"] = "codex-session"
            with contextlib.redirect_stdout(io.StringIO()):
                module._cmd_arm(SimpleNamespace(agent="codex", label="fixture", to=None))
            module._complete("codex", {"thread-id": "codex-session"})
            module._complete("codex", {"thread-id": "codex-session"})
            require(len(calls) == 1, "one Codex arm did not produce exactly one successful send", findings)

            marker = module._gemini_marker("fixture", None)
            module._gemini_after_tool(
                {
                    "session_id": "gemini-session",
                    "tool_name": "run_shell_command",
                    "tool_input": {"command": "printf unrelated"},
                    "tool_response": {"llmContent": marker},
                }
            )
            armed, _pending, _lock = module._paths("gemini", "gemini-session")
            require(not armed.exists(), "unrelated Gemini command output armed a notification", findings)
            module._gemini_after_tool(
                {
                    "session_id": "gemini-session",
                    "tool_name": "run_shell_command",
                    "tool_input": {"command": "/managed/agent-notify.py arm --label fixture"},
                    "tool_response": {"llmContent": marker},
                }
            )
            module._complete("gemini", {"session_id": "gemini-session"})
            require(len(calls) == 2, "Gemini AfterTool arm was not consumed by AfterAgent", findings)

            os.environ["CODEX_THREAD_ID"] = "retry-session"
            with contextlib.redirect_stdout(io.StringIO()):
                module._cmd_arm(SimpleNamespace(agent="codex", label="retry", to=None))
            module._send = lambda _record: (_ for _ in ()).throw(module.NotifyError("stub_failure"))
            module._complete("codex", {"thread-id": "retry-session"})
            _armed, pending, _lock = module._paths("codex", "retry-session")
            require(pending.exists(), "failed send did not retain durable pending state", findings)
            module._send = lambda record: calls.append(record["notification_id"]) or "stub"
            module._complete("codex", {"thread-id": "retry-session"})
            require(not pending.exists() and len(calls) == 3,
                    "acknowledged retry did not consume pending state once", findings)

            module._complete = lambda _agent, _payload: (_ for _ in ()).throw(RuntimeError("fixture"))
            result = module._cmd_hook(
                SimpleNamespace(
                    agent="codex",
                    event_json=json.dumps({"type": "agent-turn-complete", "thread-id": "internal-error"}),
                )
            )
            require(result == 0, "unexpected hook exception was not swallowed", findings)
            require("code=internal_error" in (state / "notify.log").read_text(encoding="utf-8"),
                    "unexpected hook exception did not produce a payload-free status code", findings)
        except Exception as exc:
            findings.append(f"hook state-machine fixture failed: {type(exc).__name__}: {exc}")
        finally:
            if old_state is None:
                os.environ.pop("AGENT_NOTIFY_STATE_DIR", None)
            else:
                os.environ["AGENT_NOTIFY_STATE_DIR"] = old_state
            if old_codex is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = old_codex


def static_wiring(findings: list[str]) -> None:
    files = {
        "manifest.sh": ["AGENT_NOTIFY_CROSS_AGENT_CONFIG", "CODEX_LOCAL_SKILL_DISABLE_ROOTS"],
        "manifest.ps1": ["AGENT_NOTIFY_CROSS_AGENT_CONFIG", "CodexLocalSkillDisableRoots"],
        "setup.sh": ["configure_agent_integrations"],
        "sync.sh": ["configure_agent_integrations"],
        "setup.ps1": ["Set-AgentIntegrations"],
        "sync.ps1": ["Set-AgentIntegrations"],
    }
    for relative, needles in files.items():
        text = (root() / relative).read_text(encoding="utf-8")
        for needle in needles:
            require(needle in text, f"{relative}: missing {needle}", findings)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--machine", action="store_true")
    args = parser.parse_args()
    findings: list[str] = []
    static_wiring(findings)
    hermetic(findings)
    if args.machine:
        machine(findings)
    if findings:
        print("AGENT-INTEGRATIONS violation:", file=sys.stderr)
        for finding in findings:
            print(f"  - {finding}", file=sys.stderr)
        return 1
    scope = "hermetic + machine" if args.machine else "hermetic"
    print(f"check-agent-integrations [{scope}] OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
