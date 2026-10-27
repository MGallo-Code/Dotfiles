#!/usr/bin/env python3
"""Keep the Claude desktop app's Code-tab chat list the same on every account.

The app files each sidebar entry as <app data>/claude-code-sessions/<account>/<org>/local_<id>.json,
so signing in to another account shows that account's own list. The chats themselves live in
~/.claude/projects and are shared already. `sync` copies the newest version of every entry
(by its lastActivityAt) into every account's folders, and carries deletions (deleted_<id> markers)
the same way.

Real copies, never links: the app reads through a junction or symlink but refuses to save
through one, so an earlier link-based version lost updates. `sync` turns any such link back
into a folder. While the app is open it leaves the signed-in account's folders alone (the app
holds those in memory and would write over them); that account catches up on the next sync
made while another account is signed in, which is why sync runs right before a switch.

CLAUDE_APP_DATA overrides the app data folder. Account names live in
~/.config/claude-sidebar/names.json on each machine (CLAUDE_SIDEBAR_NAMES overrides), never in
this repo, which is public. Python 3.9 standard library only.
"""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

HELP = """\
claude-sidebar: keep the Claude app's Code-tab chat list the same on every account.

  claude-sidebar          show each account's chats
  claude-sidebar sync     copy the newest version of every chat to every account
  claude-sidebar name X   call the signed-in account X (for example personal)

Run sync right before you switch accounts in the app.
A chat runs on whichever account is signed in when you send a message."""


def app_data() -> Path:
    if os.environ.get("CLAUDE_APP_DATA"):
        return Path(os.environ["CLAUDE_APP_DATA"])
    if sys.platform == "win32":
        local = Path(os.environ["LOCALAPPDATA"])
        # The Store build keeps its data in Claude-Data\claude_<package id>; the plain installer in %APPDATA%\Claude.
        for p in sorted((local / "Claude-Data").glob("claude_*")) + [Path(os.environ["APPDATA"]) / "Claude"]:
            if (p / "claude-code-sessions").is_dir():
                return p
    else:
        p = Path.home() / "Library/Application Support/Claude"
        if (p / "claude-code-sessions").is_dir():
            return p
    sys.exit("Claude desktop app data not found. Set CLAUDE_APP_DATA to the folder holding claude-code-sessions.")


def is_link(p: Path) -> bool:
    try:
        st = os.lstat(p)
    except FileNotFoundError:
        return False
    return stat.S_ISLNK(st.st_mode) or bool(getattr(st, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
                                            if sys.platform == "win32" else 0)


def remove_link(link: Path) -> None:
    """Removes the link only, never what it points at."""
    os.rmdir(link) if sys.platform == "win32" else os.unlink(link)


def app_running() -> bool:
    if os.environ.get("CLAUDE_APP_DATA"):
        return os.environ.get("CLAUDE_APP_RUNNING") == "1"  # a test folder, not the live app
    if sys.platform == "win32":
        cmd = ["powershell", "-NoProfile", "-Command",
               "@(Get-Process claude -EA 0 | ? Path -like '*\\WindowsApps\\Claude_*').Count + "
               "@(Get-Process claude -EA 0 | ? Path -like '*\\Programs\\Claude\\*').Count"]
        out = subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
        return out not in ("", "0")
    return subprocess.run(["pgrep", "-x", "Claude"], capture_output=True).returncode == 0


def signed_in(data: Path) -> str:
    try:
        return json.loads((data / "config.json").read_text(encoding="utf-8")).get("lastKnownAccountUuid", "")
    except (OSError, ValueError):
        return ""


def names_file() -> Path:
    # Kept on each machine, never in the repo: the account IDs stay off GitHub.
    return Path(os.environ.get("CLAUDE_SIDEBAR_NAMES") or Path.home() / ".config/claude-sidebar/names.json")


def names() -> dict[str, str]:
    """Account ID -> name."""
    try:
        return json.loads(names_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def label(acct: str) -> str:
    n = names().get(acct)
    return n.capitalize() if n else f"Account {acct[:8]}"


def unlink_folders(root: Path) -> None:
    """Turns links left by the old link-based version back into real folders."""
    for acct in root.iterdir():
        for f in list(acct.iterdir()) if acct.is_dir() else []:
            if not is_link(f):
                continue
            remove_link(f)
            bak = f.with_name(f.name + ".bak")
            bak.rename(f) if bak.is_dir() else f.mkdir()


def folders(root: Path) -> list[Path]:
    """Every <account>/<org> folder."""
    return sorted(o for a in root.iterdir() if a.is_dir() and not is_link(a)
                  for o in a.iterdir() if o.is_dir() and not is_link(o) and not o.name.endswith(".bak"))


def version(f: Path) -> tuple[int, float]:
    """Newer chat state sorts higher; a file the app is mid-way through writing sorts lowest."""
    try:
        return int(json.loads(f.read_text(encoding="utf-8")).get("lastActivityAt") or 0), f.stat().st_mtime
    except (OSError, ValueError):
        return -1, 0.0


def newest(root: Path) -> tuple[dict[str, tuple[tuple[int, float], Path]], dict[str, Path]]:
    """Newest copy of every chat entry, and every deletion marker, across all folders."""
    best: dict[str, tuple[tuple[int, float], Path]] = {}
    deleted: dict[str, Path] = {}
    for folder in folders(root):
        for f in folder.glob("local_*.json"):
            v = version(f)
            if v[0] >= 0 and (f.name not in best or v > best[f.name][0]):
                best[f.name] = (v, f)
        for m in folder.glob("deleted_*"):
            deleted.setdefault(m.name[len("deleted_"):], m)
    for chat_id in deleted:
        best.pop(f"local_{chat_id}.json", None)
    return best, deleted


def behind(folder: Path, best: dict) -> list[str]:
    """Entries this folder is missing or holds an older copy of."""
    return [n for n, (v, _) in best.items() if not (folder / n).exists() or version(folder / n) < v]


def show(data: Path, root: Path) -> None:
    me = signed_in(data)
    best, _ = newest(root)
    by_acct: dict[str, list[Path]] = {}
    for f in folders(root):
        by_acct.setdefault(f.parent.name, []).append(f)
    stale = False
    for acct, fs in sorted(by_acct.items(), key=lambda kv: kv[0] != me):
        mine = {n: max(version(f / n) for f in fs if (f / n).exists())
                for n in best if any((f / n).exists() for f in fs)}
        have = set(mine)
        older = {n for n, v in mine.items() if v < best[n][0]}
        stale = stale or bool(older) or have != set(best) or any(behind(f, best) for f in fs)
        line = f"  {label(acct) + (' (signed in)' if acct == me else ''):<24} {len(have)} of {len(best)} chats"
        print(line + (f", {len(older)} out of date" if older else ""))
    if any(is_link(f) for a in root.iterdir() if a.is_dir() for f in a.iterdir()):
        print("\n  Old links from an earlier version are in place. Quit Claude once and run claude-sidebar sync.")
    else:
        print("\n  Run claude-sidebar sync before you switch accounts." if stale else "\n  All accounts match.")


def sync(data: Path, root: Path) -> None:
    running = app_running()
    if running and any(is_link(f) for a in root.iterdir() if a.is_dir() for f in a.iterdir()):
        sys.exit("Quit the Claude desktop app once (tray or menu bar icon > Quit) so sync can replace the "
                 "old links, then run it again.")
    unlink_folders(root)
    me = signed_in(data) if running else ""
    best, deleted = newest(root)
    copied: dict[str, set[str]] = {}
    for folder in folders(root):
        acct = folder.parent.name
        if acct == me:
            continue  # the open app holds this account's chats in memory
        for chat_id, marker in deleted.items():
            if not (folder / marker.name).exists():
                shutil.copy2(marker, folder / marker.name)
            (folder / f"local_{chat_id}.json").unlink(missing_ok=True)
        for name in behind(folder, best):
            tmp = folder / (name + ".sync-tmp")
            shutil.copy2(best[name][1], tmp)
            os.replace(tmp, folder / name)
            copied.setdefault(acct, set()).add(name)
    for acct in sorted({f.parent.name for f in folders(root)}):
        n = len(copied.get(acct, ()))
        if acct == me:
            print(f"  {label(acct)}: signed in, so left as is")
        else:
            print(f"  {label(acct)}: {'up to date' if not n else f'{n} chat' + ('s' if n != 1 else '') + ' updated'}")


def name(data: Path, label_: str) -> None:
    if label_.isdigit() or not label_.replace("-", "").isalnum():
        sys.exit("A name is one word that isn't a number, for example personal or business.")
    acct = signed_in(data)
    if not acct:
        sys.exit("Can't tell which account is signed in. Open the Claude app and sign in first.")
    table = {a: n for a, n in names().items() if n != label_.lower()}
    table[acct] = label_.lower()
    names_file().parent.mkdir(parents=True, exist_ok=True)
    names_file().write_text(json.dumps(table, indent=2) + "\n", encoding="utf-8")
    print(f"  The signed-in account is now {label_.lower()}.")


def main(argv: list[str]) -> None:
    cmd = argv[0] if argv else "status"
    if cmd in ("help", "-h", "--help"):
        return print(HELP)
    if (cmd, len(argv)) not in (("status", 0), ("status", 1), ("sync", 1), ("name", 2)):
        sys.exit(HELP)
    data = app_data()
    root = data / "claude-code-sessions"
    if cmd == "status":
        show(data, root)
    elif cmd == "sync":
        sync(data, root)
    else:
        name(data, argv[1])


if __name__ == "__main__":
    main(sys.argv[1:])
