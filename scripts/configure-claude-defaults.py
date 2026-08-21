#!/usr/bin/env python3
"""Converge Michael's documented Claude permission defaults without clobbering settings."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


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
    permissions["defaultMode"] = "bypassPermissions"
    permissions["skipDangerousModePermissionPrompt"] = True

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
