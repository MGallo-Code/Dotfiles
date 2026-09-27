#!/usr/bin/env python3
"""Converge documented top-level Codex defaults without rewriting unrelated TOML."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


DEFAULTS = (
    ("model_reasoning_effort", "xhigh"),
    ("approval_policy", "never"),
    ("approvals_reviewer", "user"),
    ("sandbox_mode", "danger-full-access"),
)
REMOVED_KEYS = ("default_permissions",)
PERMISSION_PROFILE = """# dotfiles: Codex Michael workspace permission profile
[permissions.michael_workspace]
description = "Michael's local workspace, dotfiles, and agent config"

[permissions.michael_workspace.filesystem]
":minimal" = "read"

[permissions.michael_workspace.filesystem.":workspace_roots"]
"." = "write"

[permissions.michael_workspace.workspace_roots]
"~/Documents" = true
"~/Downloads" = true
"~/.dotfiles" = true
"~/.codex" = true
"~/.claude" = true
"~/.gemini" = true
"~/.config/nvim" = true

[permissions.michael_workspace.network]
enabled = true
allow_local_binding = true
# dotfiles: end Codex Michael workspace permission profile
"""
PROFILE_MARKERS = {
    "# dotfiles: Codex Michael workspace permission profile",
    "# dotfiles: end Codex Michael workspace permission profile",
}


def is_escaped(text: str, position: int) -> bool:
    backslashes = 0
    position -= 1
    while position >= 0 and text[position] == "\\":
        backslashes += 1
        position -= 1
    return backslashes % 2 == 1


def advance_lexical_state(
    line: str, multiline: str | None, square_depth: int, curly_depth: int
) -> tuple[str | None, int, int]:
    quote: str | None = None
    index = 0
    while index < len(line):
        if multiline:
            closing = line.find(multiline, index)
            if closing < 0:
                return multiline, square_depth, curly_depth
            if multiline == '"""' and is_escaped(line, closing):
                index = closing + 1
                continue
            quote_character = multiline[0]
            run_end = closing
            while run_end < len(line) and line[run_end] == quote_character:
                run_end += 1
            if run_end - closing > 5:
                raise RuntimeError("unsupported quote run in multiline Codex config string")
            multiline = None
            # TOML permits one or two content quotes immediately before the closing triple.
            index = run_end
            continue

        if quote:
            character = line[index]
            if quote == '"' and character == "\\":
                index += 2
                continue
            if character == quote:
                quote = None
            index += 1
            continue

        if line.startswith(('"""', "'''"), index):
            multiline = line[index : index + 3]
            index += 3
            continue
        character = line[index]
        if character == "#":
            break
        if character in {'"', "'"}:
            quote = character
        elif character == "[":
            square_depth += 1
        elif character == "]":
            square_depth = max(0, square_depth - 1)
        elif character == "{":
            curly_depth += 1
        elif character == "}":
            curly_depth = max(0, curly_depth - 1)
        index += 1
    if quote:
        raise RuntimeError("unterminated single-line string in Codex config")
    return multiline, square_depth, curly_depth


def table_name(line: str) -> str | None:
    match = re.match(r"^[ \t]*\[\[?(.*?)\]\]?[ \t]*(?:#.*)?(?:\r?\n)?$", line)
    return match.group(1) if match else None


def managed_profile_table(name: str) -> bool:
    compact = re.sub(r"[ \t]", "", name)
    key = r'(?:permissions|"permissions"|\'permissions\')'
    workspace = r'(?:michael_workspace|"michael_workspace"|\'michael_workspace\')'
    return re.match(rf"^{key}\.{workspace}(?:\.|$)", compact) is not None


def layout(lines: list[str]) -> tuple[list[bool], list[tuple[int, str]]]:
    safe_at_start: list[bool] = []
    headers: list[tuple[int, str]] = []
    multiline: str | None = None
    square_depth = 0
    curly_depth = 0
    for index, line in enumerate(lines):
        safe = multiline is None and square_depth == 0 and curly_depth == 0
        safe_at_start.append(safe)
        header = table_name(line) if safe else None
        if header is not None:
            headers.append((index, header))
            continue
        multiline, square_depth, curly_depth = advance_lexical_state(
            line, multiline, square_depth, curly_depth
        )
    if multiline:
        raise RuntimeError("unterminated multiline string in Codex config")
    return safe_at_start, headers


def assignment_pattern(key: str) -> re.Pattern[str]:
    escaped = re.escape(key)
    key_form = rf'(?:{escaped}|"{escaped}"|\'{escaped}\')'
    return re.compile(rf"^[ \t]*{key_form}[ \t]*=([^\r\n]*)(?:\r?\n)?$")


def scalar_assignment_end(lines: list[str], start: int) -> int:
    multiline, square_depth, curly_depth = advance_lexical_state(lines[start], None, 0, 0)
    end = start
    while multiline:
        end += 1
        if end >= len(lines):
            raise RuntimeError("unterminated multiline managed Codex value")
        multiline, square_depth, curly_depth = advance_lexical_state(
            lines[end], multiline, square_depth, curly_depth
        )
    if square_depth or curly_depth:
        raise RuntimeError("unsupported collection value for managed Codex key")
    return end


STATE_KEY = re.compile(
    r'^hooks[ \t]*\.[ \t]*state[ \t]*\.[ \t]*"(?P<path>(?:[^"\\]|\\.)*):pre_tool_use:(?P<entry>\d+):(?P<hook>\d+)"$'
)


def last_content_line(lines: list[str], start: int, end: int) -> int:
    last = start
    for index in range(start, end):
        stripped = lines[index].strip()
        if stripped and not stripped.startswith("#"):
            last = index
    return last


def normalized_path(path: str) -> str:
    return os.path.normcase(os.path.normpath(path))


def same_file(recorded: str, config_path: str) -> bool:
    unescaped = recorded.replace('\\"', '"').replace("\\\\", "\\")
    candidates = {normalized_path(config_path), normalized_path(os.path.realpath(config_path))}
    return normalized_path(unescaped) in candidates


def dedupe_pretooluse_hooks(content: str, config_path: str | None) -> str:
    """Drop repeated identical [[hooks.PreToolUse]] entries, keeping the first.

    Codex records hook trust by position (`<config>:pre_tool_use:<entry>:<hook>`), so the
    trust keys of surviving entries are renumbered to their new positions and the keys of
    removed entries are dropped. A trusted hook stays trusted; nothing new becomes trusted.
    """
    lines = content.splitlines(keepends=True)
    _safe, headers = layout(lines)
    entries: list[tuple[int, int, int]] = []  # (ordinal, start, end)
    for position, (start, name) in enumerate(headers):
        compact = re.sub(r"[ \t]", "", name)
        if compact != "hooks.PreToolUse" or not lines[start].lstrip().startswith("[["):
            continue
        end = len(lines)
        for next_start, next_name in headers[position + 1 :]:
            if not re.sub(r"[ \t]", "", next_name).startswith("hooks.PreToolUse."):
                end = next_start
                break
        entries.append((len(entries), start, end))

    seen: set[tuple[str, ...]] = set()
    removed: set[int] = set()
    drop: set[int] = set()
    for ordinal, start, end in entries:
        signature = tuple(
            line.strip() for line in lines[start:end] if line.strip() and not line.strip().startswith("#")
        )
        if signature not in seen:
            seen.add(signature)
            continue
        removed.add(ordinal)
        drop.update(range(start, last_content_line(lines, start, end) + 1))
        above = start - 1
        while above >= 0 and lines[above].strip().startswith("# dotfiles:"):
            drop.add(above)
            above -= 1
        if above >= 0 and not lines[above].strip():
            drop.add(above)
    if not removed:
        return content

    for position, (start, name) in enumerate(headers):
        match = STATE_KEY.match(name.strip())
        if match is None or config_path is None or not same_file(match.group("path"), config_path):
            continue
        old = int(match.group("entry"))
        if old in removed or old >= len(entries):
            end = headers[position + 1][0] if position + 1 < len(headers) else len(lines)
            drop.update(range(start, last_content_line(lines, start, end) + 1))
            if start > 0 and not lines[start - 1].strip():
                drop.add(start - 1)
            continue
        new = old - sum(1 for gone in removed if gone < old)
        if new != old:
            lines[start] = lines[start].replace(
                f":pre_tool_use:{old}:{match.group('hook')}\"", f":pre_tool_use:{new}:{match.group('hook')}\"", 1
            )
    return "".join(line for index, line in enumerate(lines) if index not in drop)


def render(content: str, config_path: str | None = None) -> str:
    content = dedupe_pretooluse_hooks(content, config_path)
    lines = content.splitlines(keepends=True)
    safe_at_start, headers = layout(lines)
    first_table = headers[0][0] if headers else len(lines)
    remove: set[int] = set()

    managed_keys = (*REMOVED_KEYS, *(key for key, _value in DEFAULTS))
    patterns = {key: assignment_pattern(key) for key in managed_keys}
    for index in range(first_table):
        if not safe_at_start[index]:
            continue
        for key, pattern in patterns.items():
            match = pattern.match(lines[index])
            if match is None:
                continue
            value = match.group(1).lstrip()
            if not value.startswith(('"', "'")):
                raise RuntimeError(f"unsupported non-scalar value for managed Codex key: {key}")
            remove.update(range(index, scalar_assignment_end(lines, index) + 1))
            break

    for position, (start, name) in enumerate(headers):
        if not managed_profile_table(name):
            continue
        end = headers[position + 1][0] if position + 1 < len(headers) else len(lines)
        remove.update(range(start, end))
    for index, line in enumerate(lines):
        if safe_at_start[index] and line.strip() in PROFILE_MARKERS:
            remove.add(index)

    preserved = "".join(line for index, line in enumerate(lines) if index not in remove)
    preserved_lines = preserved.splitlines(keepends=True)
    _safe, preserved_headers = layout(preserved_lines)
    boundary = preserved_headers[0][0] if preserved_headers else len(preserved_lines)
    prefix = "".join(preserved_lines[:boundary]).rstrip()
    tables = "".join(preserved_lines[boundary:]).lstrip("\r\n")
    managed = "\n".join(f'{key} = "{value}"' for key, value in DEFAULTS)
    result = f"{prefix}\n{managed}\n" if prefix else f"{managed}\n"
    if tables:
        result += "\n" + tables.lstrip("\r\n")
    return result.rstrip() + "\n\n" + PERMISSION_PROFILE


def configure(home: Path) -> Path:
    config_dir = home / ".codex"
    config = config_dir / "config.toml"
    config_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if config.is_symlink():
        raise RuntimeError(f"refusing to replace symlink: {config}")
    original = config.read_text(encoding="utf-8") if config.exists() else ""
    rendered = render(original, str(config))
    if rendered == original:
        os.chmod(config, 0o600)
        return config

    descriptor, temporary_name = tempfile.mkstemp(
        dir=str(config_dir), prefix=".config.toml.", suffix=".tmp"
    )
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(descriptor, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, config)
        os.chmod(config, 0o600)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return config


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, default=Path.home())
    args = parser.parse_args()
    try:
        path = configure(args.home)
    except (OSError, RuntimeError, UnicodeError) as exc:
        print(f"configure-codex-defaults: {exc}", file=sys.stderr)
        return 1
    print(f"Codex autonomous defaults configured: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
