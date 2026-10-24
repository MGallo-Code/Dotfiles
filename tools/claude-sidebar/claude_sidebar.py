#!/usr/bin/env python3
"""Choose which Code-tab chat list the Claude desktop app shows, whichever account is signed in.

    claude-sidebar              list the chat lists (one per account and org) and what each shows
    claude-sidebar use N        every account shows list N (a number from the listing)
    claude-sidebar split        undo: every account shows its own list again

The app files its sidebar under <app data>/claude-code-sessions/<account>/<org>/, so signing in
to another account shows that account's (often empty) folder. The chats themselves live in
~/.claude/projects and are shared already. `use` swaps every folder that has no chats of its own
for a link (a junction on Windows, a symlink on macOS) to the chosen list; the folder it replaces
is kept as <org>.bak and comes back on `split`. Folders with chats of their own are never touched.

Quit the app before `use` or `split`. CLAUDE_APP_DATA overrides the app data folder. Account
names (`name`) live in ~/.config/claude-sidebar/names.json on each machine (CLAUDE_SIDEBAR_NAMES
overrides), never in this repo, which is public.
Python 3.9 standard library only.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from pathlib import Path

BAK = ".bak"

HELP = """\
claude-sidebar: show the same Code-tab chats in the Claude app, whichever account is signed in.

  claude-sidebar            list your chat lists, numbered, and what each account shows
  claude-sidebar use N      every account shows list N (a number, or a name like personal)
  claude-sidebar split      undo: each account shows its own list again
  claude-sidebar name W X   call account W "X"; W is a list number, the 8 characters
                            after "account" in the listing, or me (signed in)
  claude-sidebar help       this text

Quit Claude fully (tray or menu bar icon > Quit) before `use` or `split`, then reopen it.
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


def link_target(p: Path) -> Path:
    t = os.readlink(p)
    return Path(t[4:] if t.startswith("\\\\?\\") else t)


def make_link(link: Path, target: Path) -> None:
    if sys.platform == "win32":
        import _winapi
        _winapi.CreateJunction(str(target), str(link))  # junctions need no admin rights
    else:
        os.symlink(target, link, target_is_directory=True)


def remove_link(link: Path) -> None:
    """Removes the link only, never what it points at."""
    os.rmdir(link) if sys.platform == "win32" else os.unlink(link)


def chats(folder: Path) -> list[Path]:
    return sorted(folder.glob("local_*.json"), key=lambda f: f.stat().st_mtime, reverse=True)


def count(folder: Path) -> str:
    n = len(chats(folder))
    return f"{n} chat" if n == 1 else f"{n} chats"


def latest_title(folder: Path) -> str:
    for f in chats(folder):
        try:
            return json.loads(f.read_text(encoding="utf-8")).get("title") or ""
        except (OSError, ValueError):
            continue
    return ""


def app_running() -> bool:
    if os.environ.get("CLAUDE_APP_DATA"):
        return False  # a test folder, not the live app
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


def folders(root: Path) -> list[Path]:
    """Every <account>/<org> folder, links included, backups excluded."""
    return sorted(o for a in root.iterdir() if a.is_dir() and not is_link(a)
                  for o in a.iterdir() if (o.is_dir() or is_link(o)) and not o.name.endswith(BAK))


def lists(root: Path) -> list[Path]:
    """Folders that hold chats of their own: the lists there are to choose from."""
    return [f for f in folders(root) if not is_link(f) and chats(f)]


def names_file() -> Path:
    # Kept on each machine, never in the repo: the account IDs stay off GitHub.
    return Path(os.environ.get("CLAUDE_SIDEBAR_NAMES") or Path.home() / ".config/claude-sidebar/names.json")


def names() -> dict[str, str]:
    """Account ID -> name."""
    try:
        return json.loads(names_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def short(p: Path, root: Path) -> str:
    acct, org = p.relative_to(root).parts
    return f"{names().get(acct) or 'account ' + acct[:8]} / org {org[:8]}"


def name(data: Path, root: Path, who: str, label: str) -> None:
    if label.isdigit() or not label.replace("-", "").isalnum():
        sys.exit("A name is one word that isn't a number, for example personal or business.")
    accounts = sorted({f.parent.name for f in folders(root)})
    choices = lists(root)
    if who == "me":
        acct = signed_in(data)
    elif who.isdigit() and 1 <= int(who) <= len(choices):
        acct = choices[int(who) - 1].parent.name
    else:
        acct = next((a for a in accounts if a.startswith(who)), "") if len(who) >= 4 else ""
    if not acct:
        sys.exit("Say which account: a list number, the 8 characters after 'account', or me (signed in).")
    table = {a: n for a, n in names().items() if n != label.lower()}
    table[acct] = label.lower()
    names_file().parent.mkdir(parents=True, exist_ok=True)
    names_file().write_text(json.dumps(table, indent=2) + "\n", encoding="utf-8")
    print(f"  account {acct[:8]} is now {label.lower()}")


def pick(root: Path, arg: str) -> Path:
    choices = lists(root)
    if arg.isdigit():
        if not 1 <= int(arg) <= len(choices):
            sys.exit(f"Pick a list number from 1 to {len(choices)} (run claude-sidebar to see them).")
        return choices[int(arg) - 1]
    acct = next((a for a, n in names().items() if n == arg.lower()), None)
    if not acct:
        sys.exit(f"No account is named {arg}. Name one with: claude-sidebar name <list number or me> {arg}")
    mine = [c for c in choices if c.parent.name == acct]
    if not mine:
        sys.exit(f"{arg} has no chats of its own yet, so there's no list to show.")
    if len(mine) > 1:
        sys.exit(f"{arg} has more than one list; pick it by number (run claude-sidebar to see them).")
    return mine[0]


def show(data: Path, root: Path) -> None:
    me = signed_in(data)
    choices = lists(root)
    if not choices:
        print("No chat lists yet.")
    for i, f in enumerate(choices, 1):
        title = latest_title(f)
        print(f"  {i}. {short(f, root)}  {count(f)}" + (f"  (latest: {title})" if title else ""))
    print()
    for f in folders(root):
        acct = f.parent.name
        who = " (signed in)" if acct == me else ""
        if is_link(f):
            t = link_target(f)
            n = next((i for i, c in enumerate(choices, 1) if c.resolve() == t.resolve()), "?")
            print(f"  {short(f, root)}{who}: shows list {n}")
        elif chats(f):
            print(f"  {short(f, root)}{who}: its own list")
        else:
            print(f"  {short(f, root)}{who}: empty")


def use(root: Path, chosen: Path) -> None:
    n = lists(root).index(chosen) + 1
    # Every account gets a folder for every org seen, so an org the app opens later is covered too.
    accounts = {f.parent for f in folders(root)}
    orgs = {f.name for f in folders(root)}
    for acct in sorted(accounts):
        for org in sorted(orgs):
            f = acct / org
            if f == chosen:
                continue
            if is_link(f):
                if link_target(f).resolve() == chosen.resolve():
                    continue
                remove_link(f)
            elif f.is_dir():
                if chats(f):
                    print(f"  kept {short(f, root)}: it has {count(f)} of its own")
                    continue
                bak = f.with_name(org + BAK)
                if bak.exists():
                    sys.exit(f"{bak} already exists; move it aside and run again.")
                f.rename(bak)
            make_link(f, chosen)
            print(f"  {short(f, root)} now shows list {n}")


def split(root: Path) -> None:
    for f in folders(root):
        if not is_link(f):
            continue
        remove_link(f)
        bak = f.with_name(f.name + BAK)
        if bak.is_dir():
            bak.rename(f)
        else:
            f.mkdir()
        print(f"  {short(f, root)} shows its own list again")


def main(argv: list[str]) -> None:
    cmd = argv[0] if argv else "list"
    if cmd in ("help", "-h", "--help"):
        return print(HELP)
    if cmd not in ("list", "ls", "use", "split", "name") or (cmd == "use" and len(argv) != 2) \
            or (cmd == "name" and len(argv) != 3):
        sys.exit(HELP)
    data = app_data()
    root = data / "claude-code-sessions"
    if cmd in ("list", "ls"):
        return show(data, root)
    if cmd == "name":
        return name(data, root, argv[1], argv[2])
    chosen = pick(root, argv[1]) if cmd == "use" else None
    if app_running():
        sys.exit("Quit the Claude desktop app first (tray or menu bar icon > Quit), then run this again.")
    use(root, chosen) if chosen else split(root)
    print("\nStart Claude again to see it.")


if __name__ == "__main__":
    main(sys.argv[1:])
