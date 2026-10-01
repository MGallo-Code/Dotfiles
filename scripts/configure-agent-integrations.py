#!/usr/bin/env python3
"""Converge machine-local completion hooks, resume-card hooks, and Codex duplicate-skill suppression.

EA owns the hook implementation and global instructions. Dotfiles owns propagation into
the three agents' machine-local configs. This configurator is the shared Bash/PowerShell
chokepoint, so the two setup paths cannot silently implement different migrations.

Every source config is parsed and every candidate is validated before the first write;
each resulting file is replaced atomically. Unrelated hooks and TOML tables are preserved.
Because Codex exposes one ``notify`` command, a pre-existing callback is retained as an
argument-safe passthrough behind the managed entry point.

Resume-card hooks (``claude-config/global-hooks/context-card.py``, design EA ADR-0004, INV-16/INV-17) are registered for
Claude when that script sits beside the notify hook, and removed when it is gone.
"""

from __future__ import annotations

import argparse
import base64
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
CODEX_PASSTHROUGH_FLAG = "--codex-passthrough"
MAX_CODEX_PASSTHROUGH_ARGS = 64
MAX_CODEX_PASSTHROUGH_ARG_CHARS = 4_096
MAX_CODEX_PASSTHROUGH_TOTAL_CHARS = 8_192
MAX_CODEX_PASSTHROUGH_TOKEN_CHARS = 12_000
SKILLS_BEGIN = "# dotfiles: begin Codex duplicate skill suppression"
CONTEXT_SCRIPT = "context-card.py"
CONTEXT_TIMEOUT = 15
# (event, matcher, subcommand). The clear guard keys on the Desktop tool's name (INV-17
# limit). The role guard fires on every edit and shell call and is silent for sessions without
# an orchestration role; it runs on the same stable runner as the others (uv, about 30 ms).
CONTEXT_HOOKS = (
    ("SessionStart", "startup|resume|clear|compact", "session-start"),
    ("PreCompact", None, "pre-compact"),
    ("PreToolUse", "mcp__ccd_session_mgmt__clear_session", "clear-guard"),
    ("PreToolUse", "Edit|Write|NotebookEdit|Bash|PowerShell", "role-guard"),
)
_CONTEXT_SUB = re.compile(r"""context-card\.py["']?\s+(session-start|pre-compact|clear-guard|role-guard)\b""")
_CONTEXT_TOKEN = re.compile(r"""(?:^|[\s"'/\\])context-card\.py(?=["'\s]|$)""")
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


def _keep_order(hooks: dict[str, Any], order: list[str]) -> None:
    """Put surviving events back in their original order (new ones last), so removing and
    re-adding a managed hook never moves an event and a second run stays byte-identical."""
    items = dict(hooks)
    hooks.clear()
    for event in order:
        if event in items:
            hooks[event] = items.pop(event)
    hooks.update(items)


def _configure_claude(original: dict[str, Any], command: str) -> dict[str, Any]:
    data = json.loads(json.dumps(original))
    hooks = _hooks_object(data)
    order = list(hooks)
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
    _keep_order(hooks, order)
    return data


def _is_context_command(value: Any) -> bool:
    return isinstance(value, str) and bool(_CONTEXT_TOKEN.search(value))


def _hook_quote(value: str) -> str:
    # Forward slashes and double quotes on every OS: Claude Code runs hook commands through
    # a POSIX shell (/bin/sh on macOS, Git Bash on Windows), where a bare C:\ path loses its
    # backslashes.
    return '"' + value.replace("\\", "/").replace('"', '\\"') + '"'


def _context_command(prefix: list[str], subcommand: str) -> str:
    base = " ".join(_hook_quote(part) for part in prefix) + f" {subcommand}"
    if subcommand == "clear-guard":
        # Fail closed: a missing runner or script, or any crash, must block the clear, not
        # fall through as a non-blocking hook error. Exit 2 is the guard's own block.
        return (
            f'{base}; rc=$?; [ "$rc" -eq 0 ] || {{ [ "$rc" -eq 2 ] || '
            f'echo "clear blocked: the resume-card guard could not run (exit $rc)" >&2; exit 2; }}'
        )
    if subcommand == "role-guard":
        # Only the guard's own block (exit 3, mapped to Claude's 2) blocks. Python and uv exit 2
        # themselves when the script is missing or unreadable, and that must never stop every
        # edit and shell call in sessions that have no role.
        return f'{base}; [ "$?" -eq 3 ] && exit 2; exit 0'
    return f"{base} || true"


def _configure_claude_context(original: dict[str, Any], prefixes: dict[str, list[str]] | None) -> dict[str, Any]:
    """Register (prefixes given, one per subcommand) or remove (None) the resume-card hooks.

    Our hook is recognised by the ``context-card.py <subcommand>`` token in its command. A hook
    sitting alone in its entry keeps its position (so other writers appending after it do not
    make the file flip-flop); anywhere else it is removed and re-added as its own entry. Events
    that are not arrays are left untouched rather than failing the whole convergence.
    """
    data = json.loads(json.dumps(original))
    hooks = _hooks_object(data)
    wanted = {
        sub: (event, matcher, _context_command(prefixes[sub], sub))
        for event, matcher, sub in CONTEXT_HOOKS
    } if prefixes else {}
    for event in list(hooks):
        raw = hooks[event]
        if not isinstance(raw, list):
            if any(w[0] == event for w in wanted.values()):
                print(f"agent integrations: hooks.{event} is not an array; resume-card hook not registered there", file=sys.stderr)
                wanted = {s: w for s, w in wanted.items() if w[0] != event}
            continue
        placed: set[str] = set()
        kept: list[Any] = []
        for entry in raw:
            inner = entry.get("hooks") if isinstance(entry, dict) else None
            if not isinstance(inner, list) or not any(isinstance(h, dict) and _is_context_command(h.get("command")) for h in inner):
                kept.append(entry)
                continue
            ours = [h for h in inner if isinstance(h, dict) and _is_context_command(h.get("command"))]
            others = [h for h in inner if not (isinstance(h, dict) and _is_context_command(h.get("command")))]
            if not others and len(ours) == 1:
                found = _CONTEXT_SUB.search(str(ours[0].get("command")))
                sub = found.group(1) if found else None
                want = wanted.get(sub) if sub else None
                if want and want[0] == event and sub not in placed:
                    replacement = {k: v for k, v in entry.items() if k not in ("matcher", "hooks")}
                    if want[1] is not None:
                        replacement["matcher"] = want[1]
                    replacement["hooks"] = [{"type": "command", "command": want[2], "timeout": CONTEXT_TIMEOUT}]
                    kept.append(replacement)
                    placed.add(sub)
                continue
            if others:
                kept.append({**entry, "hooks": others})
        for sub, (want_event, matcher, command) in wanted.items():
            if want_event == event and sub not in placed:
                fresh: dict[str, Any] = {} if matcher is None else {"matcher": matcher}
                fresh["hooks"] = [{"type": "command", "command": command, "timeout": CONTEXT_TIMEOUT}]
                kept.append(fresh)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event)
        wanted = {s: w for s, w in wanted.items() if w[0] != event}
    for sub, (event, matcher, command) in wanted.items():
        fresh = {} if matcher is None else {"matcher": matcher}
        fresh["hooks"] = [{"type": "command", "command": command, "timeout": CONTEXT_TIMEOUT}]
        hooks.setdefault(event, []).append(fresh)
    if not hooks:
        data.pop("hooks", None)
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
    module = _toml_module()
    try:
        value = module.loads(text)
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


SKILL_TABLE = re.compile(r"^\[\[\s*skills\s*\.\s*config\s*\]\]\s*(?:#.*)?$")
SKILL_PATH = re.compile(r"""^\s*path\s*=\s*(?:"((?:[^"\\]|\\.)*)"|'([^']*)')""")


def _under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root)
        return True
    except ValueError:
        return False


def _strip_retired_skill_entries(text: str, retired_roots: list[Path]) -> str:
    """Drop [[skills.config]] tables under a retired disable root, plus orphaned block markers.

    Codex rewrites config.toml and can drop the begin marker or move tables into the managed
    block, so a marker-only strip would leave retired entries behind. The intact block has
    already been stripped by the caller, so any marker still present is an orphan.
    """
    lines = text.splitlines(keepends=True)
    kept: list[str] = []
    index = 0
    while index < len(lines):
        stripped = lines[index].strip()
        if stripped in (SKILLS_BEGIN, SKILLS_END):
            index += 1
            continue
        if retired_roots and SKILL_TABLE.match(stripped):
            end = index + 1
            while end < len(lines) and not lines[end].lstrip().startswith(("[", "#")):
                end += 1
            recorded = None
            for line in lines[index + 1 : end]:
                match = SKILL_PATH.match(line)
                if match:
                    recorded = match.group(1) if match.group(1) is not None else match.group(2)
                    recorded = recorded.replace('\\"', '"').replace("\\\\", "\\")
                    break
            if recorded is not None and any(_under(Path(recorded), root) for root in retired_roots):
                index = end
                continue
        kept.append(lines[index])
        index += 1
    return "".join(kept)


def _validate_passthrough(value: Any) -> list[str]:
    if not isinstance(value, list) or not value or len(value) > MAX_CODEX_PASSTHROUGH_ARGS:
        raise ConfigError("Codex notify passthrough must be a non-empty string array")
    if not all(
        isinstance(item, str) and item and len(item) <= MAX_CODEX_PASSTHROUGH_ARG_CHARS
        for item in value
    ) or sum(len(item) for item in value) > MAX_CODEX_PASSTHROUGH_TOTAL_CHARS:
        raise ConfigError("Codex notify passthrough contains an invalid argument")
    return value


def _encode_passthrough(argv: list[str]) -> str:
    raw = json.dumps(argv, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _decode_passthrough(token: str) -> list[str]:
    if not token or len(token) > MAX_CODEX_PASSTHROUGH_TOKEN_CHARS:
        raise ConfigError("managed Codex notify passthrough is invalid")
    try:
        raw = base64.b64decode(
            token + "=" * (-len(token) % 4), altchars=b"-_", validate=True
        )
        value = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConfigError("managed Codex notify passthrough is invalid") from exc
    return _validate_passthrough(value)


def _managed_passthrough(notify_argv: list[str]) -> list[str] | None:
    positions = [index for index, value in enumerate(notify_argv) if value == CODEX_PASSTHROUGH_FLAG]
    if not positions:
        return None
    if len(positions) != 1 or positions[0] + 1 >= len(notify_argv):
        raise ConfigError("managed Codex notify passthrough is malformed")
    return _decode_passthrough(notify_argv[positions[0] + 1])


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


CODEX_CONTEXT_BEGIN = "# dotfiles: begin resume-card hooks (EA context-card.py)"
CODEX_CONTEXT_END = "# dotfiles: end resume-card hooks"


def _strip_codex_context_hooks(text: str) -> str:
    """Drop every [[hooks.SessionStart]] group whose handler runs context-card.py, by content:
    Codex rewrites config.toml itself and can drop the marker comments around the block."""
    lines = text.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        if lines[i].strip() == "[[hooks.SessionStart]]":
            j = i + 1
            while j < len(lines) and not (lines[j].startswith("[") and not lines[j].startswith("[[hooks.SessionStart.hooks]]")):
                j += 1
            group = lines[i:j]
            # TOML escapes the command's quotes (\\"), so match the script name on the raw line.
            if any(line.strip().startswith("command") and CONTEXT_SCRIPT in line for line in group):
                i = j
                while out and out[-1].strip() == "" and i < len(lines) and lines[i].strip() == "":
                    i += 1  # close the seam: drop one blank line, touch nothing else
                continue
            out.extend(group)
            i = j
            continue
        if lines[i].strip() in (CODEX_CONTEXT_BEGIN, CODEX_CONTEXT_END):
            i += 1
            continue
        out.append(lines[i])
        i += 1
    return "\n".join(out)


def _configure_codex(
    original: str,
    path: Path,
    notify_argv: list[str],
    disabled_skills: list[Path],
    retired_roots: list[Path] | None = None,
    context_argv: list[str] | None = None,
) -> str:
    parsed = _toml_loads(original, path)
    existing_notify = parsed.get("notify")
    passthrough = None
    if existing_notify is not None:
        if not isinstance(existing_notify, list) or not all(
            isinstance(item, str) for item in existing_notify
        ):
            raise ConfigError("Codex notify must be a string array")
        if MANAGED_SCRIPT in " ".join(existing_notify):
            passthrough = _managed_passthrough(existing_notify)
        elif existing_notify:
            passthrough = _validate_passthrough(existing_notify)

    body = _strip_top_level_notify(original, existing_notify is not None)
    body = _strip_codex_context_hooks(_strip_retired_skill_entries(_strip_skill_block(body), retired_roots or [])).strip()
    managed_argv = list(notify_argv)
    if passthrough:
        managed_argv.extend([CODEX_PASSTHROUGH_FLAG, _encode_passthrough(passthrough)])
    notify_line = "notify = [" + ", ".join(_toml_string(item) for item in managed_argv) + "]"
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
    if context_argv and re.search(r"(?m)^\s*(hooks\.)?SessionStart\s*=", body):
        print("agent integrations: Codex hooks.SessionStart is an inline array; resume-card hook not registered for Codex", file=sys.stderr)
        context_argv = None
    if context_argv:
        # Codex reloads the card after compaction through SessionStart(compact); it ignores
        # PreCompact output and has no Desktop clear tool, so only this hook applies. Codex
        # asks Michael once to trust a new hook (hooks.state); dotfiles never writes trust.
        command = " ".join(_hook_quote(part) for part in context_argv) + " session-start --agent codex"
        chunks.append("\n".join([
            CODEX_CONTEXT_BEGIN,
            "[[hooks.SessionStart]]",
            'matcher = "^(startup|resume|clear|compact)$"',
            "",
            "[[hooks.SessionStart.hooks]]",
            'type = "command"',
            f"command = {_toml_string(command)}",
            f"timeout = {CONTEXT_TIMEOUT}",
            "additionalContextLimit = 0",
            CODEX_CONTEXT_END,
        ]))
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
    parser.add_argument("--codex-retired-disable-root", type=Path, action="append", default=[])
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
        # Not resolved: /opt/homebrew/bin/uv survives `brew upgrade uv`; the Cellar path does not.
        runner = Path(uv).absolute() if uv else Path(sys.executable).resolve()
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

    uses_uv = runner.name.startswith("uv")
    prefix = [str(runner), "run", "--no-project", str(hook)] if uses_uv else [str(runner), str(hook)]
    context_script = hook.parent / CONTEXT_SCRIPT
    context_prefix = (
        ([str(runner), "run", "--no-project", str(context_script)] if uses_uv else [str(runner), str(context_script)])
        if context_script.is_file() else None
    )
    # One stable runner for every hook. Never `shutil.which("python3")`: under the manifest's
    # uv fallback that resolves to a throwaway environment deleted after the run.
    context_prefixes = {sub: context_prefix for _event, _matcher, sub in CONTEXT_HOOKS} if context_prefix else None
    claude_argv = [*prefix, "hook", "--agent", "claude"]
    codex_argv = [*prefix, "hook", "--agent", "codex"]
    gemini_argv = [*prefix, "hook", "--agent", "gemini"]

    claude_path = home / ".claude" / "settings.json"
    codex_path = home / ".codex" / "config.toml"
    gemini_path = home / ".gemini" / "settings.json"
    state_path = home / ".config" / "agent-notify" / "config.json"

    # Build and validate every candidate before writing any of them.
    claude = _configure_claude(_json_object(claude_path), _shell_command(claude_argv))
    claude = _configure_claude_context(claude, context_prefixes)
    gemini = _configure_gemini(_json_object(gemini_path), _shell_command(gemini_argv))
    codex_original = codex_path.read_text(encoding="utf-8") if codex_path.exists() else ""
    disabled = _skill_files([root.expanduser().resolve() for root in args.codex_disable_root])
    retired = [root.expanduser().resolve() for root in args.codex_retired_disable_root]
    # POSIX only: how Codex runs a hook command on Windows is unverified (dotfiles INV-16).
    codex_context = context_prefix if context_prefix and os.name == "posix" else None
    codex = _configure_codex(codex_original, codex_path, codex_argv, disabled, retired, codex_context)
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
    context = "resume-card hooks registered" if context_prefix else "resume-card hooks absent (no context-card.py beside the hook)"
    print(f"agent integrations: {summary}; {context}; {len(disabled)} duplicate Codex skill path(s) disabled")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ConfigError as exc:
        print(f"agent integrations: {exc}; no files changed", file=sys.stderr)
        raise SystemExit(1)
