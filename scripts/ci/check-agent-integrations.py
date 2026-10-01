#!/usr/bin/env python3
"""Gate cross-agent completion-hook migration, idempotence, and live wiring.

Default mode is hermetic and CI-safe. ``--machine`` additionally checks the current
Claude/Codex/Gemini configs and exercises the EA hook's session-scoped state machine with
a stub sender. It never sends email.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import importlib.util
import io
import json
import re
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


def codex_passthrough(notify: list[str]) -> list[str] | None:
    try:
        index = notify.index("--codex-passthrough")
        token = notify[index + 1]
        raw = base64.urlsafe_b64decode(token + "=" * (-len(token) % 4))
        value = json.loads(raw.decode("utf-8"))
    except (ValueError, IndexError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, list) and all(isinstance(item, str) for item in value) else None


def run_configurator(
    home: Path,
    hook: Path,
    runner: Path,
    disable_roots: list[Path],
    courier_url: str = "https://notify.invalid/mcp",
    retired_roots: list[Path] | None = None,
    configurator: Path | None = None,
):
    argv = [
        sys.executable,
        str(configurator or root() / "scripts" / "configure-agent-integrations.py"),
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
    for path in retired_roots or []:
        argv.extend(["--codex-retired-disable-root", str(path)])
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
        native_notify = ["/native/codex-desktop", "turn-ended"]
        codex_path.write_text(
            'notify = ["/native/codex-desktop", "turn-ended"]\n\n[unrelated]\nvalue = "keep"\n',
            encoding="utf-8",
        )
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
        require(codex_passthrough(notify) == native_notify,
                "Codex Desktop notify callback was not preserved as a passthrough", findings)
        disabled = codex.get("skills", {}).get("config", [])
        require(len(disabled) == 2 and all(item.get("enabled") is False for item in disabled),
                "Codex duplicate skill paths were not disabled exactly", findings)

        tracked = [claude_path, codex_path, gemini_path, home / ".config" / "agent-notify" / "config.json"]
        before = {path: path.read_bytes() for path in tracked}
        second = run_configurator(home, hook, runner, [codex_root, agents_root])
        require(second.returncode == 0, "second configurator run failed", findings)
        require(before == {path: path.read_bytes() for path in tracked}, "configurator is not byte-idempotent", findings)

        # A retired disable root: Codex dropped the block's begin marker and moved a table in
        # front of the end marker. Entries under the retired root go; a user's own toggle stays.
        retired_home = base / "retired-home"
        retired_codex = retired_home / ".codex" / "config.toml"
        retired_codex.parent.mkdir(parents=True)
        user_skill = base / "elsewhere" / "mine" / "SKILL.md"
        retired_codex.write_text(
            '[unrelated]\nvalue = "keep"\n\n'
            f'[[skills.config]]\npath = "{(codex_root / "native" / "SKILL.md").resolve()}"\nenabled = false\n\n'
            f'[[skills.config]]\npath = "{user_skill}"\nenabled = false\n\n'
            f'[[skills.config]]\npath = "{(agents_root / "converted" / "SKILL.md").resolve()}"\nenabled = false\n\n'
            '[moved]\nx = 1\n\n# dotfiles: end Codex duplicate skill suppression\n',
            encoding="utf-8",
        )
        retired = run_configurator(retired_home, hook, runner, [], retired_roots=[codex_root, agents_root])
        require(retired.returncode == 0, f"retired-root fixture failed: {retired.stderr.strip()}", findings)
        if retired.returncode == 0:
            text = retired_codex.read_text(encoding="utf-8")
            data = toml_module().loads(text)
            paths = [item.get("path") for item in data.get("skills", {}).get("config", [])]
            require(paths == [str(user_skill)], f"retired skill entries not stripped exactly: {paths}", findings)
            require("duplicate skill suppression" not in text, "orphaned skill-block marker survived", findings)
            require(data.get("moved", {}).get("x") == 1 and data.get("unrelated", {}).get("value") == "keep",
                    "retired-root strip touched unrelated tables", findings)
            again = run_configurator(retired_home, hook, runner, [], retired_roots=[codex_root, agents_root])
            require(again.returncode == 0 and retired_codex.read_text(encoding="utf-8") == text,
                    "retired-root strip is not idempotent", findings)

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


CONTEXT_SUBS = {
    "session-start": ("SessionStart", "startup|resume|clear|compact"),
    "pre-compact": ("PreCompact", None),
    "clear-guard": ("PreToolUse", "mcp__ccd_session_mgmt__clear_session"),
    "role-guard": ("PreToolUse", "Edit|Write|NotebookEdit|Bash|PowerShell"),
}
CONTEXT_EVENTS = sorted({event for event, _ in CONTEXT_SUBS.values()})


def context_entries(data: dict, event: str, sub: str | None = None) -> list[tuple[int, dict, str]]:
    found = []
    raw = data.get("hooks", {}).get(event, [])
    for index, entry in enumerate(raw if isinstance(raw, list) else []):
        for hook in entry.get("hooks", []) if isinstance(entry, dict) else []:
            command = hook.get("command") if isinstance(hook, dict) else None
            if isinstance(command, str) and "context-card.py" in command and (sub is None or f" {sub}" in command):
                found.append((index, entry, command))
    return found


def context_fixtures(findings: list[str], configurator: Path | None = None) -> None:
    """dotfiles INV-16: resume-card hooks converge in place, fail closed, and leave others alone."""
    with tempfile.TemporaryDirectory(prefix="context-hooks-check-") as raw:
        base = Path(raw)
        hook = base / "hooks" / "agent-notify.py"
        context = hook.parent / "context-card.py"
        runner = base / "python"
        hook.parent.mkdir()
        for path in (hook, context, runner):
            path.write_text("# fixture\n", encoding="utf-8")
        keep_bash = {"matcher": "Bash", "hooks": [{"type": "command", "command": "keep-bash"}]}

        def fresh_home(name: str, claude: dict) -> Path:
            home = base / name
            (home / ".claude").mkdir(parents=True)
            (home / ".claude" / "settings.json").write_text(json.dumps(claude, indent=2) + "\n", encoding="utf-8")
            return home

        def load(home: Path) -> dict:
            return json.loads((home / ".claude" / "settings.json").read_text(encoding="utf-8"))

        def run(home: Path):
            return run_configurator(home, hook, runner, [], configurator=configurator)

        home = fresh_home("fresh", {"hooks": {"PreToolUse": [keep_bash]}})
        result = run(home)
        require(result.returncode == 0, f"context fixture failed: {result.stderr.strip()}", findings)
        data = load(home)
        for sub, (event, matcher) in CONTEXT_SUBS.items():
            found = context_entries(data, event, sub)
            require(len(found) == 1, f"{sub}: expected one resume-card hook, found {len(found)}", findings)
            if found:
                require(found[0][1].get("matcher") == matcher, f"{sub}: wrong matcher {found[0][1].get('matcher')!r}", findings)
        role = context_entries(data, "PreToolUse", "role-guard")
        require(bool(role) and role[0][2].endswith('[ "$?" -eq 3 ] && exit 2; exit 0'),
                "role guard is not wrapped so that only its own block (exit 3) blocks", findings)
        require(len({c.split('"')[1] for sub in CONTEXT_SUBS for _, _, c in context_entries(data, CONTEXT_SUBS[sub][0], sub)}) == 1,
                "resume-card hooks do not all use the one configured runner", findings)
        guard = context_entries(data, "PreToolUse", "clear-guard")
        require(bool(guard) and "exit 2" in guard[0][2] and guard[0][2].split('"')[1] == str(runner.resolve()).replace("\\", "/"),
                "clear guard is not wrapped fail-closed on the configured runner", findings)
        require(any("keep-bash" in c for c in commands(data, "PreToolUse")), "unrelated PreToolUse hook was dropped", findings)
        before = (home / ".claude" / "settings.json").read_bytes()
        run(home)
        require(before == (home / ".claude" / "settings.json").read_bytes(), "resume-card registration is not byte-idempotent", findings)

        # A throwaway python3 first on PATH (the manifest's uv fallback does this) must not leak
        # into the registration: two PATH contexts, byte-identical settings.
        decoy_bin = base / "decoy-bin"
        decoy_bin.mkdir()
        (decoy_bin / "python3").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (decoy_bin / "python3").chmod(0o755)
        home2 = fresh_home("path-a", {})
        run(home2)
        first = (home2 / ".claude" / "settings.json").read_bytes()
        saved_path = os.environ.get("PATH", "")
        os.environ["PATH"] = f"{decoy_bin}{os.pathsep}{saved_path}"
        try:
            run(home2)
        finally:
            os.environ["PATH"] = saved_path
        require(first == (home2 / ".claude" / "settings.json").read_bytes() and str(decoy_bin) not in first.decode(),
                "an ephemeral python3 on PATH changed the hook registration", findings)

        stale = {"type": "command", "command": 'python3 "/old/context-card.py" clear-guard'}
        home = fresh_home("in-place", {"hooks": {"PreToolUse": [
            {"matcher": "mcp__ccd_session_mgmt__clear_session", "hooks": [stale]}, keep_bash]}})
        run(home)
        found = context_entries(load(home), "PreToolUse", "clear-guard")
        require(len(found) == 1 and found[0][0] == 0 and "/old/" not in found[0][2],
                "a stale resume-card hook was not replaced in place", findings)

        home = fresh_home("embedded", {"hooks": {"PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "keep-bash"}, stale]}]}})
        run(home)
        data = load(home)
        first = data["hooks"]["PreToolUse"][0]
        found = context_entries(data, "PreToolUse", "clear-guard")
        require(first.get("matcher") == "Bash" and [h["command"] for h in first["hooks"]] == ["keep-bash"]
                and len(found) == 1 and found[0][1].get("matcher") == CONTEXT_SUBS["clear-guard"][1],
                "a resume-card hook inside a shared entry was not moved to its own entry", findings)

        home = fresh_home("odd", {"hooks": {"SessionStart": "not-an-array", "PreToolUse": [keep_bash]}})
        result = run(home)
        data = load(home)
        require(result.returncode == 0 and data["hooks"]["SessionStart"] == "not-an-array"
                and len(context_entries(data, "PreCompact")) == 1 and len(context_entries(data, "PreToolUse")) == 2,
                "a malformed unrelated event blocked or was rewritten by resume-card registration", findings)

        if os.name == "posix":
            codex_home = fresh_home("codex", {})
            codex_cfg = codex_home / ".codex" / "config.toml"
            codex_cfg.parent.mkdir(parents=True)
            keep_codex = ('[[hooks.PreToolUse]]\nmatcher = "^Bash$"\n\n[[hooks.PreToolUse.hooks]]\ntype = "command"\n'
                          'command = "/x/warn.sh"\ntimeout = 30\n\n[hooks.state."/x:pre_tool_use:0:0"]\ntrusted_hash = "sha256:abc"\n')
            codex_cfg.write_text(keep_codex, encoding="utf-8")
            run(codex_home)
            text = codex_cfg.read_text(encoding="utf-8")
            parsed = toml_module().loads(text)
            groups = parsed.get("hooks", {}).get("SessionStart", [])
            ours = [g for g in groups for h in g.get("hooks", []) if "context-card.py" in h.get("command", "")]
            require(len(ours) == 1 and "session-start --agent codex" in ours[0]["hooks"][0]["command"]
                    and ours[0]["hooks"][0].get("additionalContextLimit") == 0,
                    "Codex: expected one resume-card SessionStart hook with no context cap", findings)
            require(parsed["hooks"]["PreToolUse"][0]["hooks"][0]["command"] == "/x/warn.sh"
                    and parsed["hooks"]["state"]["/x:pre_tool_use:0:0"]["trusted_hash"] == "sha256:abc",
                    "Codex: the existing PreToolUse hook or its trust state was disturbed", findings)
            before = codex_cfg.read_bytes()
            run(codex_home)
            require(before == codex_cfg.read_bytes(), "Codex: resume-card registration is not byte-idempotent", findings)
            ml = 'note = """a\n\n\n\nb"""\n'
            codex_cfg.write_text(ml + "\n".join(l for l in text.splitlines() if not l.startswith("# dotfiles: ")) + "\n", encoding="utf-8")
            run(codex_home)
            again = toml_module().loads(codex_cfg.read_text(encoding="utf-8"))
            require(sum("context-card.py" in h.get("command", "") for g in again["hooks"].get("SessionStart", []) for h in g.get("hooks", [])) == 1,
                    "Codex: with its markers dropped (Codex rewrites config.toml) the block was duplicated", findings)
            require(again.get("note") == "a\n\n\n\nb",
                    "Codex: a multi-line string outside our block was altered", findings)
            inline_home = fresh_home("codex-inline", {})
            (inline_home / ".codex").mkdir()
            (inline_home / ".codex" / "config.toml").write_text('hooks.SessionStart = []\n', encoding="utf-8")
            result = run(inline_home)
            require(result.returncode == 0 and "inline array" in result.stderr,
                    "Codex: an inline SessionStart array aborted convergence instead of skipping with a warning", findings)

        context.unlink()
        home = fresh_home("removed", {"hooks": {"PreToolUse": [
            {"matcher": "mcp__ccd_session_mgmt__clear_session", "hooks": [stale]}, keep_bash]}})
        run(home)
        data = load(home)
        require(not any(context_entries(data, event) for event in CONTEXT_EVENTS)
                and any("keep-bash" in c for c in commands(data, "PreToolUse")),
                "resume-card hooks survived with no context-card.py beside the hook", findings)
        if os.name == "posix":
            run(codex_home)
            left = toml_module().loads((codex_home / ".codex" / "config.toml").read_text(encoding="utf-8"))
            require(not any("context-card.py" in h.get("command", "") for g in left.get("hooks", {}).get("SessionStart", []) for h in g.get("hooks", [])),
                    "Codex: the resume-card hook survived with no context-card.py", findings)

    if os.name == "posix":
        spec = importlib.util.spec_from_file_location("configure_ai", str(configurator or root() / "scripts" / "configure-agent-integrations.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        require(module._hook_quote("C:\\Users\\moses\\x y\\context-card.py") == '"C:/Users/moses/x y/context-card.py"',
                "hook paths are not forward-slash, double-quoted", findings)
        with tempfile.TemporaryDirectory(prefix="guard-wrapper-") as raw:
            for exit_code, want in ((0, 0), (2, 2), (1, 2), (127, 2)):
                stub = Path(raw) / f"exit{exit_code}.sh"
                stub.write_text(f"#!/bin/sh\nexit {exit_code}\n", encoding="utf-8")
                stub.chmod(0o755)
                command = module._context_command([str(stub)], "clear-guard")
                got = subprocess.run(["/bin/sh", "-c", command], capture_output=True).returncode
                require(got == want, f"guard wrapper: a guard exiting {exit_code} gave {got}, want {want}", findings)
            missing = module._context_command([str(Path(raw) / "missing-runner")], "clear-guard")
            got = subprocess.run(["/bin/sh", "-c", missing], capture_output=True).returncode
            require(got == 2, f"guard wrapper: a missing runner gave {got}, want 2 (fail closed)", findings)
            for exit_code in (3,):
                stub = Path(raw) / f"exit{exit_code}.sh"
                stub.write_text(f"#!/bin/sh\nexit {exit_code}\n", encoding="utf-8")
                stub.chmod(0o755)
            for exit_code, want in ((0, 0), (3, 2), (2, 0), (1, 0), (127, 0)):
                stub = Path(raw) / f"exit{exit_code}.sh"
                command = module._context_command([str(stub)], "role-guard")
                got = subprocess.run(["/bin/sh", "-c", command], capture_output=True).returncode
                require(got == want, f"role-guard wrapper: a guard exiting {exit_code} gave {got}, want {want}", findings)
            missing = module._context_command([str(Path(raw) / "missing-runner")], "role-guard")
            got = subprocess.run(["/bin/sh", "-c", missing], capture_output=True).returncode
            require(got == 0, f"role-guard wrapper: a missing runner gave {got}, want 0 (never lock up role-less sessions)", findings)
            gone = module._context_command([sys.executable, str(Path(raw) / "missing-context-card.py")], "role-guard")
            got = subprocess.run(["/bin/sh", "-c", gone], capture_output=True).returncode
            require(got == 0, f"role-guard wrapper: a real Python with the script missing gave {got}, want 0 (Python itself exits 2)", findings)


def machine_context(findings: list[str], home: Path, claude: dict) -> None:
    script = home / ".dotfiles" / "claude-config" / "global-hooks" / "context-card.py"
    if not script.is_file():
        require(not any(context_entries(claude, event) for event in CONTEXT_EVENTS),
                "live resume-card hooks are registered but context-card.py is missing", findings)
        return
    for sub, (event, _matcher) in CONTEXT_SUBS.items():
        found = context_entries(claude, event, sub)
        require(len(found) == 1, f"live {sub}: expected one resume-card hook, found {len(found)}", findings)
    guard = context_entries(claude, "PreToolUse", "clear-guard")
    if len(guard) != 1:
        return
    command = guard[0][2]
    runner = command.split('"')[1] if command.startswith('"') else ""
    require(bool(runner) and Path(runner).exists(), f"live clear guard runner is missing: {runner or command[:60]}", findings)
    if os.name != "posix":
        return
    with tempfile.TemporaryDirectory(prefix="guard-live-") as raw:
        transcript = Path(raw) / "t.jsonl"
        transcript.write_text(json.dumps({"type": "user", "origin": {"kind": "human"},
                                          "message": {"role": "user", "content": "please clear"}}) + "\n", encoding="utf-8")
        payload = json.dumps({"tool_input": {"session_id": "self"}, "transcript_path": str(transcript)})
        env = {**os.environ, "CONTEXT_CARD_STATE": str(Path(raw) / "state")}
        got = subprocess.run(["/bin/sh", "-c", command], input=payload, text=True, capture_output=True, env=env)
        require(got.returncode == 2, f"live clear guard did not block a self-clear without /wrap (exit {got.returncode})", findings)


def machine(findings: list[str]) -> None:
    home = Path.home()
    hook_path = home / ".dotfiles" / "claude-config" / "global-hooks" / "agent-notify.py"
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
    machine_context(findings, home, claude)
    require(not any("agent-notify.py" in value or "notify-claude.sh" in value for value in commands(claude, "Notification")),
            "live Claude still has a Notification email hook", findings)
    require(sum("agent-notify.py" in value for value in commands(gemini, "AfterAgent")) == 1,
            "live Gemini AfterAgent hook is not converged", findings)
    require(sum("agent-notify.py" in value for value in commands(gemini, "AfterTool")) == 1,
            "live Gemini AfterTool hook is not converged", findings)
    live_notify = codex.get("notify", [])
    require("agent-notify.py" in " ".join(live_notify), "live Codex notify is missing", findings)
    if "--codex-passthrough" in live_notify:
        require(codex_passthrough(live_notify) is not None,
                "live Codex notify passthrough is malformed", findings)

    manifest = (root() / "manifest.sh").read_text(encoding="utf-8")

    def manifest_paths(name: str) -> list[Path]:
        match = re.search(rf"^{name}=\((.*?)\)[ \t]*$", manifest, re.S | re.M)
        entries = re.findall(r'"([^"]+)"', match.group(1)) if match else []
        return [Path(entry.replace("~", str(home), 1)).resolve() for entry in entries]

    expected_disabled = set()
    for source in manifest_paths("CODEX_LOCAL_SKILL_DISABLE_ROOTS"):
        if source.is_dir():
            expected_disabled.update(str(path.resolve()) for path in source.glob("*/SKILL.md") if path.is_file())
    actual_disabled = {
        item.get("path")
        for item in codex.get("skills", {}).get("config", [])
        if isinstance(item, dict) and item.get("enabled") is False
    }
    require(expected_disabled <= actual_disabled, "live Codex duplicate-skill suppression is incomplete", findings)
    retired_roots = manifest_paths("CODEX_RETIRED_SKILL_DISABLE_ROOTS")
    leftover = sorted(path for path in actual_disabled if isinstance(path, str)
                      and any(Path(path).resolve().is_relative_to(r) for r in retired_roots))
    require(not leftover, f"live Codex config still disables skills under a retired root: {leftover}", findings)

    with tempfile.TemporaryDirectory(prefix="agent-notify-state-check-") as raw:
        old_state = os.environ.get("AGENT_NOTIFY_STATE_DIR")
        old_codex = os.environ.get("CODEX_THREAD_ID")
        os.environ["AGENT_NOTIFY_STATE_DIR"] = raw
        try:
            module = load_hook(hook_path)
            state = Path(raw)
            passthrough_capture = state / "codex-desktop-passthrough.json"
            passthrough_event = json.dumps({"type": "agent-turn-complete", "thread-id": "passthrough"})
            passthrough_argv = [
                sys.executable,
                "-c",
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2], encoding='utf-8')",
                str(passthrough_capture),
            ]
            passthrough_token = base64.urlsafe_b64encode(
                json.dumps(passthrough_argv).encode("utf-8")
            ).decode("ascii").rstrip("=")
            module._forward_codex_notification(passthrough_token, passthrough_event)
            require(
                passthrough_capture.is_file()
                and passthrough_capture.read_text(encoding="utf-8") == passthrough_event,
                "Codex Desktop notify passthrough did not receive the unchanged event payload",
                findings,
            )
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
        "manifest.sh": ["AGENT_NOTIFY_CROSS_AGENT_CONFIG", "CODEX_LOCAL_SKILL_DISABLE_ROOTS", "CODEX_RETIRED_SKILL_DISABLE_ROOTS"],
        "manifest.ps1": ["AGENT_NOTIFY_CROSS_AGENT_CONFIG", "CodexLocalSkillDisableRoots", "CodexRetiredSkillDisableRoots"],
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
    parser.add_argument("--revert-test", action="store_true",
                        help="the resume-card fixtures must FAIL against a configurator that skips registration")
    args = parser.parse_args()
    if args.revert_test:
        source = (root() / "scripts" / "configure-agent-integrations.py").read_text(encoding="utf-8")
        needle = "    claude = _configure_claude_context(claude, context_prefixes)\n"
        if needle not in source:
            print("revert-test: registration call not found", file=sys.stderr)
            return 1
        with tempfile.TemporaryDirectory(prefix="context-revert-") as raw:
            mutant = Path(raw) / "configure-agent-integrations.py"
            mutant.write_text(source.replace(needle, "", 1), encoding="utf-8")
            caught: list[str] = []
            context_fixtures(caught, configurator=mutant)
        if caught:
            print(f"revert-test ok: skipping registration fails {len(caught)} resume-card fixture(s)")
            return 0
        print("revert-test FAILED: fixtures passed without registration", file=sys.stderr)
        return 1
    findings: list[str] = []
    static_wiring(findings)
    hermetic(findings)
    context_fixtures(findings)
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
