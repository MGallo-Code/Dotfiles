#!/usr/bin/env python3
"""Converge Michael's documented Claude permission defaults without clobbering settings.

The user default is `auto` (Michael, 2026-09-29, F8): no prompts for routine work, with the
auto-mode safety check on risky actions. The `ea` launcher still starts trusted roots in
`bypassPermissions` per launch (INV-14); `skipDangerousModePermissionPrompt` serves that path.

Model defaults (Michael, 2026-09-27: "opus default, fable for orchestration prompts"; research
in Wiki "Fable 5.1 and Opus 5.5: Model and Effort Selection"): the default model is `opus`
(Opus 5.5), with per-model effort in `modelSettings` (Opus 5.5 `medium`, its API default;
Fable 5.1 `high`, its default and the level Anthropic says to start from). The top-level
`effortLevel` is left alone: it still applies to models without an entry, such as the EA
hub's pinned `claude-opus-4-8`, whose owner lane inherits user settings.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


# Hook scripts that no longer exist (ADR-0004). A registration left behind would fail on every
# tool call, so every machine that syncs drops it. Matched by file name inside the command.
RETIRED_HOOK_SCRIPTS = ("forge-guard.sh",)


def drop_retired_hooks(data: dict) -> None:
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event, entries in list(hooks.items()):
        if not isinstance(entries, list):
            continue
        kept_entries = []
        changed = False
        for entry in entries:
            inner = entry.get("hooks") if isinstance(entry, dict) else None
            if not isinstance(inner, list):
                kept_entries.append(entry)
                continue
            kept = [
                hook for hook in inner
                if not (isinstance(hook, dict)
                        and any(name in str(hook.get("command", "")) for name in RETIRED_HOOK_SCRIPTS))
            ]
            if len(kept) != len(inner):
                changed = True
            if kept:
                kept_entries.append({**entry, "hooks": kept})
        if changed:
            if kept_entries:
                hooks[event] = kept_entries
            else:
                del hooks[event]


def configure(home: Path) -> Path:
    settings_dir = home / ".claude"
    settings = settings_dir / "settings.json"
    settings_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if settings.is_symlink():
        raise RuntimeError(f"refusing to replace symlink: {settings}")

    if settings.exists():
        try:
            data = json.loads(settings.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"malformed Claude settings JSON at line {exc.lineno}") from exc
        if not isinstance(data, dict):
            raise RuntimeError("Claude settings root must be a JSON object")
    else:
        data = {}

    permissions = data.setdefault("permissions", {})
    if not isinstance(permissions, dict):
        raise RuntimeError("Claude permissions setting must be a JSON object")
    permissions["defaultMode"] = "auto"
    permissions["skipDangerousModePermissionPrompt"] = True
    data["model"] = "opus"
    model_settings = data.setdefault("modelSettings", {})
    if not isinstance(model_settings, dict):
        raise RuntimeError("Claude modelSettings must be a JSON object")
    for model_id, effort in (("claude-opus-5-5", "medium"), ("claude-fable-5-1", "high")):
        entry = model_settings.setdefault(model_id, {})
        if not isinstance(entry, dict):
            raise RuntimeError(f"Claude modelSettings.{model_id} must be a JSON object")
        entry["effortLevel"] = effort
    drop_retired_hooks(data)

    rendered = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    existing = settings.read_text(encoding="utf-8") if settings.exists() else None
    if existing == rendered:
        os.chmod(settings, 0o600)
        return settings

    descriptor, temporary_name = tempfile.mkstemp(
        dir=str(settings_dir), prefix=".settings.json.", suffix=".tmp"
    )
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(descriptor, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, settings)
        os.chmod(settings, 0o600)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return settings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, default=Path.home())
    args = parser.parse_args()
    try:
        path = configure(args.home)
    except (OSError, RuntimeError) as exc:
        print(f"configure-claude-defaults: {exc}", file=sys.stderr)
        return 1
    print(f"Claude autonomous default configured: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
