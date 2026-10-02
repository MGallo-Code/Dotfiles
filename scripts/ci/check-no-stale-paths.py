#!/usr/bin/env python3
"""check-no-stale-paths.py - INV-22: no live file names a repo's pre-ADR-0007 home.

ADR-0007 moved EA, Wiki, Notes and GalloGrid from ~/Documents to ~/Workspace, and agent-skills
into dotfiles. A live file (script, rule, skill, launcher, README) that still names
~/Documents/<repo> points every agent and machine at a folder that no longer exists.

Scans the tracked files of the repo it runs in (default: this dotfiles checkout; --root for EA or
the Wiki) for Documents + EA, Wiki, Notes, GalloGrid or agent-skills, joined by either slash. Exempt:
  - history, which describes the past on purpose: docs/decisions/, docs/plans/, docs/history/,
    .claude/resume/, dated handoff and audit docs (a YYYY-MM-DD in the file name), log.md;
  - vendored trees: agent-skills/ (dotfiles);
  - a line carrying the marker `stale-path-ok` (the migration's own list of old homes, fixtures
    that build them on purpose).
Extra exemptions for one repo go in <root>/.stale-paths-allow (one glob per line).

  --revert-test   plants a live stale path in a scratch copy of the file list and requires a FAIL.
"""
from __future__ import annotations

import argparse
import fnmatch
import re
import subprocess
import sys
from pathlib import Path

PATTERN = re.compile(r"Documents[/\\]+(EA|Wiki|Notes|GalloGrid|agent-skills)(?![A-Za-z0-9_-])")
MARKER = "stale-path-ok"
HISTORY_GLOBS = [
    "docs/decisions/*", "docs/plans/*", "docs/history/*", ".claude/resume/*",
    "agent-skills/*", "log.md", "*/log.md",
]
DATED = re.compile(r"\d{4}-\d{2}-\d{2}")


def exempt(path: str, extra: list[str]) -> bool:
    if any(fnmatch.fnmatch(path, g) for g in HISTORY_GLOBS + extra):
        return True
    return bool(DATED.search(Path(path).name))


def scan(root: Path, files: list[str], extra: list[str]) -> list[str]:
    hits: list[str] = []
    for rel in files:
        if exempt(rel, extra):
            continue
        p = root / rel
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError, PermissionError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if PATTERN.search(line) and MARKER not in line:
                hits.append(f"{rel}:{n}: {line.strip()[:140]}")
    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    ap.add_argument("--revert-test", action="store_true")
    args = ap.parse_args()
    root = Path(args.root).resolve()
    files = subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True,
                           check=True).stdout.splitlines()
    allow = root / ".stale-paths-allow"
    extra = [l.strip() for l in allow.read_text().splitlines() if l.strip() and not l.startswith("#")] \
        if allow.exists() else []

    if args.revert_test:
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            planted = Path(t) / "planted.sh"
            planted.write_text('cd "$HOME/Documents/EA"\n')  # stale-path-ok
            history = Path(t) / "docs" / "plans"; history.mkdir(parents=True)
            (history / "old.md").write_text("ran from ~/Documents/EA\n")  # stale-path-ok
            marked = Path(t) / "marked.sh"
            marked.write_text('OLD="~/Documents/EA"  # stale-path-ok\n')
            got = scan(Path(t), ["planted.sh", "docs/plans/old.md", "marked.sh"], [])
            if got == ['planted.sh:1: cd "$HOME/Documents/EA"']:  # stale-path-ok
                print("revert-test ok: a live stale path fails; history and marked lines pass")
                return 0
            print(f"revert-test FAILED: {got}")
            return 1

    hits = scan(root, files, extra)
    if hits:
        print(f"check-no-stale-paths: {len(hits)} live reference(s) to a pre-ADR-0007 home in {root}:")
        print("\n".join(f"  {h}" for h in hits))
        print("Point them at ~/Workspace/<repo> (or ~/.dotfiles/agent-skills). History stays as is; "
              "a deliberate old path carries `stale-path-ok`.")
        return 1
    print(f"check-no-stale-paths OK - no live file in {root.name} names an old ~/Documents home.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
