#!/usr/bin/env python3
"""check-worktrees.py  -  ADVISORY: a temporary git worktree must not masquerade as a
canonical workspace root at the top of ~/Workspace, ~/Projects or ~/Documents.

A linked worktree has a `.git` FILE (a `gitdir:` pointer); a normal clone has a `.git`
DIR. This scans the immediate children of each workspace base (ADR-0007: ~/Workspace for the
synced repos, ~/Projects for his own, ~/Documents for personal files) and WARNS for any linked
worktree sitting as a top-level sibling of the real project roots, unless it lives under the
canonical worktree home (~/.worktrees, 2026-10-02) or is in the ALLOWLIST below.

ADVISORY ONLY: it informs, it never gates - exit is always 0 so it can be run during sync
or by hand without ever blocking. (Run: `python3 scripts/ci/check-worktrees.py`.)
The goal is just that a top-level view does not make a transient worktree look like a
canonical project root. The clean resolutions, in order of preference:
  1. it's done (branch merged)        -> `git worktree remove <path>`
  2. still active, keep it tidy        -> `git worktree move <path> ~/.worktrees/<repo>-<branch>`
  3. intentionally a sibling for now    -> add its full path to ALLOWLIST below
"""
import os
import sys

_BASES_ENV = os.environ.get("WORKSPACE_BASE")  # os.pathsep-separated (":" on macOS/Linux, ";" on Windows)
BASES = [os.path.expanduser(b) for b in
         (_BASES_ENV.split(os.pathsep) if _BASES_ENV else ["~/Workspace", "~/Projects", "~/Documents"])]
CANONICAL_HOME = os.path.expanduser("~/.worktrees")

# Sibling worktrees explicitly accepted in place (absolute paths). Empty by default so the
# convention is "worktrees live under ~/.worktrees", not scattered at the top level.
ALLOWLIST = set()


def is_linked_worktree(path):
    # A linked worktree's `.git` is a FILE ("gitdir: ...") pointing into the main repo's
    # .git/worktrees/. A normal clone's `.git` is a directory. That distinction is the test.
    return os.path.isfile(os.path.join(path, ".git"))


def main():
    canon = os.path.realpath(CANONICAL_HOME)
    stray = []
    for base in BASES:
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            p = os.path.join(base, name)
            if not os.path.isdir(p):
                continue
            if os.path.realpath(p).startswith(canon):
                continue
            if p in ALLOWLIST:
                continue
            if is_linked_worktree(p):
                stray.append(p)

    if stray:
        sys.stderr.write("check-worktrees ADVISORY - top-level worktrees masquerading as roots:\n")
        for p in stray:
            sys.stderr.write(f"  - {p}\n")
        sys.stderr.write(
            f"  Resolve: `git worktree remove <path>` if its branch is merged; else "
            f"`git worktree move <path> {CANONICAL_HOME}/<repo>-<branch>`;\n"
            f"  or, if intentional, add the full path to ALLOWLIST in scripts/ci/check-worktrees.py.\n")
    else:
        print(f"check-worktrees OK - no stray top-level worktrees under {', '.join(BASES)}")
    return 0  # advisory: never fails


if __name__ == "__main__":
    sys.exit(main())
