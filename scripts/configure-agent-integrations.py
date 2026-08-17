#!/usr/bin/env python3
"""Converge machine-local completion hooks and Codex duplicate-skill suppression.

EA owns the hook implementation and global instructions. Dotfiles owns propagation into
the three agents' machine-local configs. This configurator is the shared Bash/PowerShell
chokepoint, so the two setup paths cannot silently implement different migrations.

Every source config is parsed and every candidate is validated before the first write;
each resulting file is replaced atomically. Unrelated hooks and TOML tables are preserved.
An unknown pre-existing Codex ``notify`` program is a conflict, not something this script
overwrites.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path
from typing import Any


MANAGED_SCRIPT = "agent-notify.py"
LEGACY_SCRIPT = "notify-claude.sh"
SKILLS_BEGIN = "# dotfiles: begin Codex duplicate skill suppression"
SKILLS_END = "# dotfiles: end Codex duplicate skill suppression"


class ConfigError(RuntimeError):
    pass


def _json_object(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"malformed JSON: {path}") from exc
    if not isinstance(value, dict):
        raise ConfigError(f"JSON root must be an object: {path}")
    return value


def _managed_command(value: Any) -> bool:
    return isinstance(value, str) and (MANAGED_SCRIPT in value or LEGACY_SCRIPT in value)


def _clean_hook_event(hooks: dict[str, Any], event: str) -> None:
    raw = hooks.get(event)
    if raw is None:
        return
    if not isinstance(raw, list):
        raise ConfigError(f"hooks.{event} must be an array")
    kept_entries: list[dict[str, Any]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            raise ConfigError(f"hooks.{event} entries must be objects")
        commands = entry.get("hooks")
        if not isinstance(commands, list):
            raise ConfigError(f"hooks.{event}[].hooks must be an array")
        kept_commands = []
        for command in commands:
            if not isinstance(command, dict):
                raise ConfigError(f"hooks.{event}[].hooks entries must be objects")
            if not _managed_command(command.get("command")):
                kept_commands.append(command)
        if kept_commands:
            replacement = dict(entry)
            replacement["hooks"] = kept_commands
            kept_entries.append(replacement)
    if kept_entries:
        hooks[event] = kept_entries
    else:
        hooks.pop(event, None)


def _hooks_object(data: dict[str, Any]) -> dict[str, Any]:
    hooks = data.get("hooks")
    if hooks is None:
        hooks = {}
        data["hooks"] = hooks
    if not isinstance(hooks, dict):
        raise ConfigError("hooks must be an object")
    return hooks


def _configure_claude(original: dict[str, Any], command: str) -> dict[str, Any]:
    data = json.loads(json.dumps(original))
    hooks = _hooks_object(data)
    for event in ("Stop", "Notification"):
        _clean_hook_event(hooks, event)
    hooks.setdefault("Stop", []).append(
        {
            "matcher": "",
            "hooks": [
                {
                    "type": "command",
                    "command": command,
                    "timeout": 30,
                }
            ],
        }
    )
    return data


def _configure_gemini(original: dict[str, Any], command: str) -> dict[str, Any]:
    data = json.loads(json.dumps(original))
    hooks = _hooks_object(data)
    for event in ("AfterTool", "AfterAgent"):
        _clean_hook_event(hooks, event)
    hooks.setdefault("AfterTool", []).append(
        {
            "matcher": "^run_shell_command$",
            "hooks": [
                {
                    "name": "agent-notify-arm",
                    "type": "command",
                    "command": command,
                    "timeout": 5000,
                }
            ],
        }
    )
    hooks.setdefault("AfterAgent", []).append(
        {
            "matcher": "*",
            "hooks": [
                {
                    "name": "agent-notify-complete",
                    "type": "command",
                    "command": command,
                    "timeout": 30000,
                }
            ],
        }
    )
    return data


def _toml_module():
    try:
        import tomllib

        return tomllib
    except ModuleNotFoundError:
        try:
            import tomli

            return tomli
        except ModuleNotFoundError as exc:
            raise ConfigError("Python tomllib/tomli is required to update Codex config safely") from exc


def _toml_loads(text: str, path: Path) -> dict[str, Any]:
    try:
        value = _toml_module().loads(text)
    except Exception as exc:
        raise ConfigError(f"malformed TOML: {path}") from exc
    if not isinstance(value, dict):
        raise ConfigError(f"TOML root must be a table: {path}")
    return value


def _toml_string(value: str) -> str:
    # JSON basic-string escaping is valid TOML basic-string escaping for these paths/args.
    return json.dumps(value, ensure_ascii=False)


def _strip_top_level_notify(text: str, had_notify: bool) -> str:
    pattern = re.compile(r"(?m)^notify\s*=\s*\[[^\n]*\]\s*\r?\n?")
    stripped, count = pattern.subn("", text)
    if had_notify and count != 1:
        raise ConfigError("managed Codex notify assignment is not a supported one-line array")
    return stripped


def _strip_skill_block(text: str) -> str:
    pattern = re.compile(
        rf"(?ms)^\s*{re.escape(SKILLS_BEGIN)}\r?\n.*?^{re.escape(SKILLS_END)}\r?\n?"
    )
    stripped, count = pattern.subn("", text)
    if count > 1:
        raise ConfigError("multiple managed Codex skill-suppression blocks")
    return stripped


def _skill_files(roots: list[Path]) -> list[Path]:
    result = set()
    for root in roots:
        if not root.is_dir():
            continue
        for child in root.iterdir():
            skill = child / "SKILL.md"
            if child.is_dir() and skill.is_file():
                result.add(skill.resolve())
    return sorted(result, key=lambda path: str(path))


def _configure_codex(
    original: str, path: Path, notify_argv: list[str], disabled_skills: list[Path]
) -> str:
    parsed = _toml_loads(original, path)
    existing_notify = parsed.get("notify")
    if existing_notify is not None:
        if not isinstance(existing_notify, list) or not all(
            isinstance(item, str) for item in existing_notify
        ):
            raise ConfigError("Codex notify must be a string array")
        if MANAGED_SCRIPT not in " ".join(existing_notify):
            raise ConfigError("Codex notify is already owned by another program")

    body = _strip_top_level_notify(original, existing_notify is not None)
    body = _strip_skill_block(body).strip()
    notify_line = "notify = [" + ", ".join(_toml_string(item) for item in notify_argv) + "]"
    chunks = [notify_line]
    if body:
        chunks.append(body)
    if disabled_skills:
        lines = [SKILLS_BEGIN]
        for skill in disabled_skills:
            lines.extend(
                [
                    "[[skills.config]]",
                    f"path = {_toml_string(str(skill))}",
                    "enabled = false",
                    "",
                ]
            )
        lines.append(SKILLS_END)
        chunks.append("\n".join(lines))
    candidate = "\n\n".join(chunks).rstrip() + "\n"
    _toml_loads(candidate, path)
    return candidate


def _shell_command(argv: list[str]) -> str:
    return subprocess.list2cmdline(argv) if os.name == "nt" else shlex.join(argv)


def _json_text(value: dict[str, Any]) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def _atomic_write(path: Path, text: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    old_mode = None
    if path.exists():
        try:
            old_mode = stat.S_IMODE(path.stat().st_mode)
        except OSError:
            old_mode = None
    fd, raw_tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp = Path(raw_tmp)
    try:
        if os.name == "posix":
            os.fchmod(fd, mode if mode is not None else (old_mode or 0o600))
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        if os.name == "posix" and mode is not None:
            path.chmod(mode)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def _backup_and_write(path: Path, text: str, mode: int | None = None) -> bool:
    current = path.read_text(encoding="utf-8") if path.exists() else None
    if current == text:
        if os.name == "posix" and mode is not None and path.exists():
            path.chmod(mode)
        return False
    if path.exists():
        shutil.copy2(path, Path(str(path) + ".agent-integrations-bak"))
    _atomic_write(path, text, mode)
    return True


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--hook", type=Path, required=True)
    parser.add_argument("--runner", type=Path)
    parser.add_argument("--courier-url", required=True)
    parser.add_argument("--courier-token-file", type=Path, required=True)
    parser.add_argument("--default-to", required=True)
    parser.add_argument("--from-address", required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--codex-disable-root", type=Path, action="append", default=[])
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    home = args.home.expanduser().resolve()
    hook = args.hook.expanduser().resolve()
    if not hook.is_file():
        raise ConfigError(f"hook source is missing: {hook}")
    runner = args.runner.expanduser().resolve() if args.runner else None
    if runner is None:
        uv = shutil.which("uv")
        runner = Path(uv).resolve() if uv else Path(sys.executable).resolve()
    if not runner.is_file():
        raise ConfigError(f"hook runner is missing: {runner}")
    courier_url = urllib.parse.urlsplit(args.courier_url)
    if (
        courier_url.scheme != "https"
        or not courier_url.hostname
        or courier_url.username is not None
        or courier_url.password is not None
    ):
        raise ConfigError("Courier URL must be an HTTPS endpoint without embedded credentials")

    prefix = [str(runner), "run", "--no-project", str(hook)] if runner.name.startswith("uv") else [str(runner), str(hook)]
    claude_argv = [*prefix, "hook", "--agent", "claude"]
    codex_argv = [*prefix, "hook", "--agent", "codex"]
    gemini_argv = [*prefix, "hook", "--agent", "gemini"]

    claude_path = home / ".claude" / "settings.json"
    codex_path = home / ".codex" / "config.toml"
    gemini_path = home / ".gemini" / "settings.json"
    state_path = home / ".config" / "agent-notify" / "config.json"

    # Build and validate every candidate before writing any of them.
    claude = _configure_claude(_json_object(claude_path), _shell_command(claude_argv))
    gemini = _configure_gemini(_json_object(gemini_path), _shell_command(gemini_argv))
    codex_original = codex_path.read_text(encoding="utf-8") if codex_path.exists() else ""
    disabled = _skill_files([root.expanduser().resolve() for root in args.codex_disable_root])
    codex = _configure_codex(codex_original, codex_path, codex_argv, disabled)
    state = {
        "account": args.account,
        "courier_token_file": str(args.courier_token_file.expanduser().resolve()),
        "courier_url": args.courier_url,
        "default_to": args.default_to,
        "from_address": args.from_address,
        "version": 1,
    }

    changed = []
    if _backup_and_write(claude_path, _json_text(claude), 0o600):
        changed.append("claude")
    if _backup_and_write(codex_path, codex, 0o600):
        changed.append("codex")
    if _backup_and_write(gemini_path, _json_text(gemini), 0o600):
        changed.append("gemini")
    if _backup_and_write(state_path, _json_text(state), 0o600):
        changed.append("state")
    if os.name == "posix":
        state_path.parent.chmod(0o700)

    summary = ", ".join(changed) if changed else "already converged"
    print(f"agent integrations: {summary}; {len(disabled)} duplicate Codex skill path(s) disabled")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ConfigError as exc:
        print(f"agent integrations: {exc}; no files changed", file=sys.stderr)
        raise SystemExit(1)
