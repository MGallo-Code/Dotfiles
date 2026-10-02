#!/usr/bin/env python3
"""ws_paths.py - path helpers for the ADR-0007 workspace migration (INV-21), shared by
scripts/lib/workspace-migration.sh and workspace-migration.ps1 so both platforms rewrite paths
the same way.

  owner-repo URL                 -> "owner/repo" (lowercase), for comparing git remotes
  key PATH                       -> Claude Code's project-memory key for PATH
  rewrite FILE OLD NEW           -> replace OLD (as a path prefix) with NEW in FILE; prints the count
  memory BASE OLD NEW            -> rename Claude memory folders of OLD and its existing subfolders to
                                    NEW's keys; prints "memory|<from>|<to>" or "warn|<message>"
  venvs ROOT OLD                 -> print each .venv under ROOT (depth 4) that names OLD

A path matches only as a prefix: followed by a separator, a quote, a bracket, whitespace or the end,
never by more name (so a path never rewrites a sibling sharing its prefix, EA vs EA-backing). Windows-style paths
(a drive letter or backslashes) match either separator, TOML's doubled backslashes, and any case,
and each match keeps its own case and separator style (Codex writes 'c:\\users\\...').
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".ruff_cache"}


def owner_repo(url: str) -> str:
    u = url.strip().rstrip("/")
    u = re.sub(r"\.git$", "", u)
    m = re.search(r"([^/:]+)/([^/:]+)$", u)
    return f"{m.group(1)}/{m.group(2)}".lower() if m else u.lower()


def key(path: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def _is_windows_path(p: str) -> bool:
    return "\\" in p or bool(re.match(r"^[A-Za-z]:", p))


def _prefix_regex(old: str) -> re.Pattern[str]:
    if _is_windows_path(old):
        parts = [re.escape(x) for x in re.split(r"[\\/]+", old) if x]
        body = r"(?:\\\\|\\|/)".join(parts)
        return re.compile(body + r"(?=$|[\\/\"'\]\s])", re.IGNORECASE)
    return re.compile(re.escape(old) + r"(?=$|[/\"'\]\s])")


def rewrite(file: str, old: str, new: str) -> int:
    p = Path(file)
    if not p.is_file():
        return 0
    text = p.read_text(encoding="utf-8")
    rx = _prefix_regex(old)
    win = _is_windows_path(old)

    def repl(m: re.Match[str]) -> str:
        if not win:
            return new
        hit = m.group(0)
        sep = "\\\\" if "\\\\" in hit else ("/" if "/" in hit and "\\" not in hit else "\\")
        out = sep.join(x for x in re.split(r"[\\/]+", new) if x)
        if hit == hit.lower():
            out = out.lower()
        return out

    new_text, n = rx.subn(repl, text)
    if n:
        p.write_text(new_text, encoding="utf-8")
    return n


def _subdirs(root: Path, depth: int = 3):
    yield ""
    for dirpath, dirnames, _ in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        level = 0 if rel == "." else rel.count(os.sep) + 1
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".git")]
        if level >= depth:
            dirnames[:] = []
        if rel != ".":
            yield rel


def memory(base: str, old: str, new: str) -> list[str]:
    b = Path(base)
    out: list[str] = []
    if not b.is_dir() or not Path(new).is_dir():
        return out
    sep = "\\" if _is_windows_path(new) else "/"
    for rel in _subdirs(Path(new)):
        suffix = "" if not rel else sep + rel.replace(os.sep, sep)
        src, dst = b / key(old + suffix), b / key(new + suffix)
        if not src.is_dir():
            continue
        if dst.exists():
            out.append(f"warn|Claude memory {dst} already exists - left {src.name} as is")
            continue
        src.rename(dst)
        out.append(f"memory|{src}|{dst}")
    return out


def venvs(root: str, old: str) -> list[str]:
    hits: list[str] = []
    rx = _prefix_regex(old)
    for dirpath, dirnames, _ in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        level = 0 if rel == "." else rel.count(os.sep) + 1
        if ".venv" in dirnames:
            v = Path(dirpath) / ".venv"
            for probe in ("bin/activate", "Scripts/activate", "pyvenv.cfg"):
                f = v / probe
                try:
                    if f.is_file() and rx.search(f.read_text(encoding="utf-8", errors="replace")):
                        hits.append(str(v))
                        break
                except OSError:
                    pass
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if level >= 4:
            dirnames[:] = []
    return hits


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "owner-repo":
        print(owner_repo(args[0]))
    elif cmd == "key":
        print(key(args[0]))
    elif cmd == "rewrite":
        print(rewrite(*args[:3]))
    elif cmd == "memory":
        print("\n".join(memory(*args[:3])))
    elif cmd == "venvs":
        print("\n".join(venvs(*args[:2])))
    else:
        print(f"unknown command {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
