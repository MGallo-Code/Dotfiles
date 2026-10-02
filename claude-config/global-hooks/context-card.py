#!/usr/bin/env python3
"""Resume cards for Claude Code sessions. Design: EA docs/decisions/0004-self-refreshing-sessions.md.

A session opts in by binding a resume card (`/wrap`). Only bound sessions are touched:
their compaction keeps just what happened since the card was last updated, and the card
comes back after every compaction and clear. Separately, no session clears itself unless
Michael's latest typed message was a bare `/wrap`.

Hook subcommands (registered by dotfiles `configure-agent-integrations.py`):
  session-start   SessionStart: reload the bound card after a compaction or clear.
  pre-compact     PreCompact: stdout is appended to the compaction instructions.
  request-capture Stop: sweep what Michael typed this turn (prompts and mid-turn messages) from the
                  transcript onto this conversation's request queue (ADR-0008). PreCompact and
                  SessionStart sweep too; SessionStart then prints every open request verbatim.
  clear-guard     PreToolUse on the Desktop clear_session tool (exit 2 blocks).
  role-guard      PreToolUse on Edit/Write/NotebookEdit/Bash/PowerShell: enforces an orchestration
                  role (skill `build-orchestration`) for sessions that set one; silent for everyone else.
                  Blocks with exit 3 (the registered wrapper maps 3 to 2), so an interpreter's own
                  exit 2 (script missing or unreadable) can never block a session.
  challenger-guard  Agent-scoped PreToolUse for the `challenger` subagent (its frontmatter):
                  pass-1 isolation from the canonical checkout, evidence-only writes, read-only git.
Helper subcommands (run by /wrap and the orchestrate skill):
  status | bind <name> | bind --file <path> | unbind | commit <message> | autowrap on|off|status|limit <tokens>
  queue [list [--all|--project]] | queue show|done|drop|reopen <ids> [--note ...] | queue add <text>
  role orchestrator --orch-dir <path> [--allow <path>]... | role builder [--worktree <path>] | role off
  orchestration new <name> [--builder-worktree <path>] [--allow <path>]... | on | off | end [<name>] | status
      (the /orchestrate command: `new` sets an orchestration up; `off`/`on` pause and resume it,
      the chat acting as a normal agent while paused; `end` tears it down)

Python 3.9+, standard library only. SessionStart and PreCompact never fail the session;
clear-guard fails closed.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

STATE = Path(os.environ.get("CONTEXT_CARD_STATE") or Path.home() / ".claude" / "resume-state")
PROFILES = Path(
    os.environ.get("CONTEXT_CARD_PROFILES")
    or Path(__file__).resolve().parent.parent / "model-profiles" / "compact"
)
# Michael's remotes use the SSH alias `git@github:` (git.md), not only github.com.
OWNER_RE = re.compile(r"github(?:\.com)?[:/]+MGallo-Code/", re.IGNORECASE)
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
WINDOW = 350000
WINDOW_MIN = 150000   # below this, ~70K of fixed load refills the chat right after each compaction (thrash)
WINDOW_MAX = 1000000
CARD_LINES_MAX = 200
TAIL_BYTES = 4 * 1024 * 1024
STALE_BINDING_DAYS = 30

TEMPLATE = """# {name}

## Goal

## Decisions (stated exactly)

## Discoveries paid for

## Done and verified

## Next exact step

## Queued after that
"""

NOTES = """Working notes (this session is bound to the resume card above):
- The card and git are the source of truth for this work. After a compaction, your summary covers only what happened since the card was last updated.
- After a commit that completes a step, update the card as the /wrap command describes (keep mode) and commit it.
- Never clear this session yourself; a hook blocks it unless Michael typed /wrap.
- If you notice trouble (corrected twice on the same thing, re-deciding what the card settles, announcing a step without doing it, a verified fact reverting), say so in one line and suggest /wrap.
- Build end-of-run reports from git log and the card, not from memory."""


FILE_NOTES = """Working notes (this session's card is a file its own process maintains, such as an Orchestrator's RESUME.md):
- That file and the ledger are the source of truth; after a compaction your summary covers only what happened since the file was last written.
- Keep it current the way its process says (for RESUME.md: rewritten on every ledger write). Do not rewrite it into another format.
- Never clear this session yourself; a hook blocks it unless Michael typed /wrap."""


# ---------------------------------------------------------------- basics

# Set by main() for hooks registered with `--agent codex`: Codex hooks get the thread id on
# stdin (`session_id`) and not in their environment, which may even hold stale CLAUDE_* values
# when Codex was started from a Claude session.
HOOK_AGENT = "claude"
CODEX_HOOK_SESSION: str | None = None


IN_HOOK = False  # set by main() when running as a Claude hook


def nearest_agent() -> str | None:
    """Which agent CLI is the closest ancestor of this process: "codex", "claude" or None.
    Decides between a Codex thread id and Claude ids when both are in the environment (Codex
    started from a Claude shell, or the reverse). POSIX `ps`; None when it cannot tell.
    CONTEXT_CARD_NEAREST overrides the process walk (fixtures only)."""
    forced = os.environ.get("CONTEXT_CARD_NEAREST")
    if forced in ("codex", "claude"):
        return forced
    pid = os.getppid()
    for _ in range(12):
        if pid <= 1:
            return None
        try:
            out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], capture_output=True,
                                 text=True, timeout=3).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
        if not out:
            return None
        ppid, _, comm = out.partition(" ")
        name = os.path.basename(comm.strip()).lower()
        if name.startswith("codex"):
            return "codex"
        if name.startswith("claude"):
            return "claude"
        pid = int(ppid) if ppid.strip().isdigit() else 0
    return None


def session_id() -> str | None:
    """Stable per-conversation identity: Desktop session id (survives clears), else the CLI
    process (survives /clear), else a Codex thread (hooks: stdin; model shells: CODEX_THREAD_ID)."""
    claude = os.environ.get("CLAUDE_CODE_HOST_SESSION_ID") or (
        f"pid-{os.environ['CLAUDE_PID']}" if os.environ.get("CLAUDE_PID") else ""
    )
    codex = f"codex-{os.environ['CODEX_THREAD_ID']}" if os.environ.get("CODEX_THREAD_ID") else ""
    if HOOK_AGENT == "codex":
        raw = f"codex-{CODEX_HOOK_SESSION}" if CODEX_HOOK_SESSION else ""
    elif IN_HOOK or not codex:
        raw = claude  # a Claude hook: an inherited CODEX_THREAD_ID is stale by definition
    elif not claude:
        raw = codex
    else:
        raw = codex if nearest_agent() == "codex" else claude
    return re.sub(r"[^A-Za-z0-9_.-]", "_", raw) or None


def headless() -> bool:
    if HOOK_AGENT == "codex":
        return False
    return os.environ.get("CLAUDE_CODE_ENTRYPOINT", "").startswith("sdk")


def quiet_lane() -> bool:
    """No cards and no request capture: headless, or a `claude -p` run nested in a session. The
    guards keep using headless() alone, so a nested `claude -p` never slips out of a role's guard."""
    return headless() or print_mode()


def print_mode() -> bool:
    """A `claude -p` started from inside a session inherits that session's environment (its
    CLAUDE_CODE_ENTRYPOINT stays claude-desktop), so read the nearest claude CLI ancestor's
    arguments instead. The Desktop app runs Claude Code in-process: reaching it means interactive.
    POSIX `ps`; False when it cannot tell. CONTEXT_CARD_PRINT_MODE=1/0 overrides (fixtures)."""
    forced = os.environ.get("CONTEXT_CARD_PRINT_MODE")
    if forced in ("0", "1"):
        return forced == "1"
    if os.name == "nt":
        return False
    pid = os.getppid()
    for _ in range(12):
        if pid <= 1:
            return False
        try:
            out = subprocess.run(["ps", "-o", "ppid=", "-o", "args=", "-p", str(pid)], capture_output=True,
                                 text=True, timeout=3).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return False
        ppid, _, args = out.partition(" ")
        argv = args.split()
        if not argv:
            return False
        name = os.path.basename(argv[0])
        if name in ("claude", "claude.exe") or (name in ("node", "bun") and any(os.path.basename(a).startswith("claude") for a in argv[1:2])):
            return any(a in ("-p", "--print") for a in argv[1:])
        if name == "Claude":
            return False
        pid = int(ppid) if ppid.strip().isdigit() else 0
    return False


def project_dir() -> Path:
    return Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())


def git_env() -> dict:
    # Drop GIT_DIR and friends: if this runs under a git hook, an inherited GIT_DIR would
    # point every `git -C <repo>` call at the hook's repository instead.
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def git(cwd: Path, *args: str) -> str | None:
    try:
        done = subprocess.run(
            ["git", "-C", str(cwd), *args], capture_output=True, text=True, timeout=10, env=git_env()
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() if done.returncode == 0 else None


def repo_root(start: Path) -> Path | None:
    top = git(start, "rev-parse", "--show-toplevel")
    return Path(top) if top else None


def owned(root: Path) -> bool:
    origin = git(root, "remote", "get-url", "origin")
    return origin is None or bool(OWNER_RE.search(origin))


def card_dir(root: Path) -> Path:
    if owned(root):
        return root / ".claude" / "resume"
    key = hashlib.sha1(str(root.resolve()).encode("utf-8")).hexdigest()[:10]
    return STATE / "cards" / f"{root.name}-{key}"


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def log(event: str, detail: str) -> None:
    try:
        path = STATE / "log.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(f"{dt.datetime.now().isoformat(timespec='seconds')} {event} {detail}\n")
        if path.stat().st_size > 256 * 1024:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()[-1000:]
            atomic_write(path, "\n".join(lines) + "\n")
    except OSError:
        pass


def read_stdin_json() -> dict:
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def fmt_time(epoch: float) -> str:
    return dt.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M")


# ---------------------------------------------------------------- bindings

def binding_path(sid: str) -> Path:
    return STATE / "bind" / f"{sid}.json"


def load_binding(sid: str | None) -> dict | None:
    if not sid:
        return None
    path = binding_path(sid)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not Path(str(data.get("card", ""))).is_file():
        return None
    return data


def touch_binding(sid: str) -> None:
    try:
        os.utime(binding_path(sid))
    except OSError:
        pass


def prune_bindings() -> None:
    cutoff = time.time() - STALE_BINDING_DAYS * 86400
    for path in (STATE / "bind").glob("*.json"):
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink()
        except OSError:
            pass


def card_updated(binding: dict) -> float:
    """When the card last changed: its last commit, or its mtime if uncommitted or local."""
    card = Path(binding["card"])
    mtime = card.stat().st_mtime
    if binding.get("mode") != "repo":
        return mtime
    root = Path(binding["repo"])
    if git(root, "status", "--porcelain", "--", str(card)):
        return mtime
    committed = git(root, "log", "-1", "--format=%ct", "--", str(card))
    return float(committed) if committed else mtime


def commits_since(binding: dict, since: float) -> list[str]:
    out = git(Path(binding["repo"]), "log", "-n", "40", "--format=%h%x09%ct%x09%s")
    found = []
    for line in (out or "").splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3 and parts[1].isdigit() and float(parts[1]) > since:
            if not parts[2].startswith("checkpoint:"):
                found.append(f"{parts[0]} {parts[2]}")
    return found


def show_card(binding: dict) -> str:
    lines = Path(binding["card"]).read_text(encoding="utf-8", errors="replace").splitlines()
    if len(lines) > CARD_LINES_MAX:
        lines = lines[:CARD_LINES_MAX] + [f"[card truncated at {CARD_LINES_MAX} lines; read the file for the rest]"]
    return "\n".join(lines)


# ---------------------------------------------------------------- transcripts

def tail_entries(path: str | None):
    """Transcript entries, newest first, from the last TAIL_BYTES of the file."""
    if not path:
        return
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        handle.seek(max(0, size - TAIL_BYTES))
        chunk = handle.read().decode("utf-8", errors="replace")
    lines = chunk.splitlines()
    if size > TAIL_BYTES:
        lines = lines[1:]  # the first line may be cut
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict):
            yield entry


def working_model(path: str | None) -> str | None:
    try:
        for entry in tail_entries(path):
            if entry.get("type") != "assistant" or entry.get("isSidechain"):
                continue
            model = (entry.get("message") or {}).get("model")
            if isinstance(model, str) and model.startswith("claude-"):
                return re.sub(r"-\d{8}$", "", model)
    except OSError:
        return None
    return None


def entry_text(entry: dict) -> str:
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return ""


def turn_start(path: str | None) -> tuple[str, str, str]:
    """The event that started the current turn: ("typed" | "other", text, timestamp).

    Typed prompts carry origin.kind "human". Messages from other sessions carry a
    non-human origin; messages typed mid-turn are queued_command attachments. Tool
    results, command expansions (isMeta, no origin) and compaction summaries are skipped.
    """
    for entry in tail_entries(path):
        kind = entry.get("type")
        if kind == "attachment":
            if (entry.get("attachment") or {}).get("type") == "queued_command":
                return ("other", "queued message", entry.get("timestamp", ""))
            continue
        if kind != "user":
            continue
        if entry.get("isCompactSummary") or entry.get("isVisibleInTranscriptOnly"):
            continue
        content = (entry.get("message") or {}).get("content")
        if isinstance(content, list) and any(
            isinstance(part, dict) and part.get("type") == "tool_result" for part in content
        ):
            continue
        origin = entry.get("origin")
        origin_kind = origin.get("kind") if isinstance(origin, dict) else None
        if origin_kind == "human" and not entry.get("isMeta"):
            return ("typed", entry_text(entry), entry.get("timestamp", ""))
        if origin_kind or entry.get("turnOrigin") == "peer":
            return ("other", entry_text(entry)[:80], entry.get("timestamp", ""))
        if entry.get("isMeta") or entry.get("sourceToolUseID"):
            continue
        return ("typed", entry_text(entry), entry.get("timestamp", ""))
    return ("other", "no turn start found", "")


def bare_wrap(text: str) -> bool:
    if "<command-name>/wrap</command-name>" not in text:
        return False
    args = re.search(r"<command-args>(.*?)</command-args>", text, re.DOTALL)
    return not args or not args.group(1).strip()


def iso_epoch(stamp: str) -> float | None:
    try:
        return dt.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


# ---------------------------------------------------------------- request queue (ADR-0008)
#
# A checklist of what Michael asked for, kept all the time and not only at compaction (his ask,
# 2026-10-02: "just a checklist of items ... it should add/remove tasks as they are worked on").
# Two layers, one append-only file per conversation:
# - tasks R<n>: short titles the agent adds as requests come in and closes as they are done;
# - an inbox m<n>: every message he types, captured by hooks (the transcript sweep at the end of
#   each turn, before a compaction, at session start), unreviewed until the agent has turned the
#   requests in it into tasks and run `queue reviewed`.
# After a compaction or resume the open tasks come back one line each, plus any unreviewed
# messages, so a request survives even if the agent never wrote it down. Three or more unreviewed
# messages make the Stop hook ask the agent, once, to update the checklist. No UserPromptSubmit
# hook: in Claude Code 2.1.285 one makes mid-turn messages wait for the turn to end.

QUEUE_TEXT_MAX = 8000        # stored per captured message
QUEUE_TITLE_MAX = 120        # a task title, and a message's one-line view
QUEUE_NAG_UNREVIEWED = 3     # unreviewed messages that make the Stop hook ask for a checklist update
QUEUE_SHOW_INBOX = 10        # unreviewed messages printed after a compaction (newest)
QUEUE_PRUNE_DAYS = 90        # by age alone: unattended queues (scripted runs) must not pile up
QUEUE_LOOKBACK = 900         # a conversation's first sweep also takes the last 15 minutes
QUEUE_FIRST_BYTES = 8 * 1024 * 1024
QUEUE_LOCK_WAIT = 3.0
QUEUE_HELP = "python3 ~/.claude/hooks/context-card.py queue"
CONTROL_RE = re.compile(r"^/[A-Za-z0-9:_-]+$")  # a bare slash command, e.g. /clear or /wrap
# Notices the harness attaches to a typed message (a background task ending, a file change);
# they are not Michael's words.
REMINDER_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.DOTALL)
ID_RE = re.compile(r"^R(\d+)$")
MSG_RE = re.compile(r"^m(\d+)$")
CODEX_INTERACTIVE = ("cli", "vscode")  # session_meta sources Michael types into (not exec, not subagents)


def queue_path(sid: str) -> Path:
    return STATE / "queue" / f"{sid}.jsonl"


def sweep_path(sid: str) -> Path:
    return STATE / "queue" / f"{sid}.sweep.json"


class QueueLock:
    """An exclusive lock beside the queue file: id assignment reads then appends, and two hooks
    of one conversation (a prompt and a compaction) can run at once. O_EXCL works on every OS;
    a lock left by a killed process is broken after QUEUE_LOCK_WAIT seconds."""

    def __init__(self, sid: str) -> None:
        self.path = STATE / "queue" / f"{sid}.lock"

    def __enter__(self) -> "QueueLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        deadline = time.time() + QUEUE_LOCK_WAIT
        while True:
            try:
                os.close(os.open(str(self.path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
                return self
            except FileExistsError:
                if time.time() > deadline:
                    try:
                        os.unlink(self.path)  # stale: its writer died holding it
                    except OSError:
                        pass
                    deadline = time.time() + QUEUE_LOCK_WAIT
                time.sleep(0.02)

    def __exit__(self, *exc) -> None:
        try:
            os.unlink(self.path)
        except OSError:
            pass


def load_state(sid: str | None) -> tuple[list[dict], list[dict]]:
    """(tasks, messages). A task has a title and a status ("open", "done" or "dropped"); a captured
    message has its text and whether it was reviewed. A pre-checklist item (an "add" with only a
    text) reads as a task titled by its first line."""
    tasks: dict[str, dict] = {}
    msgs: dict[str, dict] = {}
    reviewed_through = 0
    try:
        lines = queue_path(sid).read_text(encoding="utf-8", errors="replace").splitlines() if sid else []
    except OSError:
        lines = []
    for line in lines:
        try:
            rec = json.loads(line)
        except ValueError:
            continue  # a torn last line from a crashed writer
        if not isinstance(rec, dict):
            continue
        op = rec.get("op")
        if op == "add" and isinstance(rec.get("id"), str):
            title = rec.get("title") or " ".join(str(rec.get("text", "")).split())[:QUEUE_TITLE_MAX]
            tasks[rec["id"]] = {**rec, "title": title, "status": "open"}
        elif op == "msg" and isinstance(rec.get("id"), str):
            msgs[rec["id"]] = dict(rec)
        elif op == "title" and rec.get("id") in tasks:
            tasks[rec["id"]]["title"] = rec.get("title") or tasks[rec["id"]]["title"]
        elif op in ("close", "reopen"):
            for rid in rec.get("ids") or []:
                if rid in tasks:
                    tasks[rid]["status"] = rec.get("status", "done") if op == "close" else "open"
                    tasks[rid]["note"] = rec.get("note") or tasks[rid].get("note")
        elif op == "reviewed":
            m = MSG_RE.match(str(rec.get("through", "")))
            reviewed_through = max(reviewed_through, int(m.group(1)) if m else 0)
    def num(rx, key):
        m = rx.match(key)
        return int(m.group(1)) if m else 0
    for mid, msg in msgs.items():
        msg["reviewed"] = num(MSG_RE, mid) <= reviewed_through
    return (sorted(tasks.values(), key=lambda i: num(ID_RE, i["id"])),
            sorted(msgs.values(), key=lambda i: num(MSG_RE, i["id"])))


def load_queue(sid: str | None) -> list[dict]:
    return load_state(sid)[0]


def queue_append(sid: str, rec: dict) -> None:
    path = queue_path(sid)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(rec, ensure_ascii=False) + "\n")


def capturable(text: object) -> str | None:
    if not isinstance(text, str):
        return None
    text = REMINDER_RE.sub("", text).strip()
    command = re.match(r"^<command-message>.*?</command-message>\s*<command-name>(/[^<]+)</command-name>(?:\s*<command-args>(.*?)</command-args>)?\s*$", text, re.DOTALL)
    if command:  # a slash command as the transcript records it
        text = f"{command.group(1)} {(command.group(2) or '').strip()}".strip()
    if not text or CONTROL_RE.match(text):
        return None
    return text


def _next_id(items: list[dict], rx: re.Pattern) -> int:
    return max((int(m.group(1)) for i in items for m in [rx.match(i["id"])] if m), default=0) + 1


def capture_messages(sid: str, entries: list[tuple[str, str, str]]) -> list[str]:
    """Append (text, source, timestamp) messages to the inbox; a source already captured is
    skipped. Returns the new message ids."""
    added: list[str] = []
    with QueueLock(sid):
        _, msgs = load_state(sid)
        seen = {i.get("src") for i in msgs if i.get("src")}
        n = _next_id(msgs, MSG_RE)
        for text, src, stamp in entries:
            if src and src in seen:
                continue
            if len(text) > QUEUE_TEXT_MAX:
                text = text[:QUEUE_TEXT_MAX] + f" [cut at {QUEUE_TEXT_MAX} characters; the transcript has the rest]"
            mid = f"m{n}"
            queue_append(sid, {"op": "msg", "id": mid, "ts": stamp or dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
                               "text": text, "src": src, "cwd": str(project_dir().resolve())})
            seen.add(src)
            added.append(mid)
            n += 1
    return added


def add_task(sid: str, title: str) -> str:
    title = " ".join(title.split())[:QUEUE_TITLE_MAX]
    with QueueLock(sid):
        rid = f"R{_next_id(load_queue(sid), ID_RE)}"
        queue_append(sid, {"op": "add", "id": rid, "kind": "task", "title": title,
                           "ts": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
                           "cwd": str(project_dir().resolve())})
    return rid


def claude_human(entry: dict) -> tuple[str, str, str] | None:
    """A message Michael typed, from a Claude transcript entry: (text, source, timestamp).
    Typed prompts are user entries with origin.kind "human"; messages typed mid-turn are
    queued_command attachments with the same origin. Peers, subagent hand-backs, task
    notifications, command expansions, compaction summaries and tool results never match."""
    if entry.get("isSidechain"):
        return None
    if entry.get("type") == "attachment":
        att = entry.get("attachment") or {}
        origin = att.get("origin")
        if att.get("type") != "queued_command" or not isinstance(origin, dict) or origin.get("kind") != "human":
            return None
        if att.get("commandMode") not in (None, "prompt"):
            return None
        text, src = capturable(att.get("prompt")), att.get("source_uuid") or entry.get("uuid")
        stamp = att.get("timestamp") or entry.get("timestamp")
    elif entry.get("type") == "user":
        origin = entry.get("origin")
        if not isinstance(origin, dict) or origin.get("kind") != "human":
            return None
        if entry.get("isMeta") or entry.get("isCompactSummary") or entry.get("isVisibleInTranscriptOnly"):
            return None
        content = (entry.get("message") or {}).get("content")
        if isinstance(content, list) and any(isinstance(x, dict) and x.get("type") == "tool_result" for x in content):
            return None
        text, src, stamp = capturable(entry_text(entry)), entry.get("promptId") or entry.get("uuid"), entry.get("timestamp")
    else:
        return None
    if not text:
        return None
    return (text, f"claude:{src}" if src else "", str(stamp or ""))


def codex_human(entry: dict) -> tuple[str, str, str] | None:
    """A message Michael typed, from a Codex rollout line (an event_msg of type user_message)."""
    payload = entry.get("payload") or {}
    if entry.get("type") != "event_msg" or payload.get("type") != "user_message":
        return None
    text = capturable(payload.get("message"))
    if not text:
        return None
    stamp = str(entry.get("timestamp") or "")
    src = payload.get("client_id") or hashlib.sha256(f"{stamp}|{text}".encode()).hexdigest()[:24]
    return (text, f"codex:{src}", stamp)


def codex_interactive(transcript: str) -> bool:
    """Only rollouts Michael types into: Codex's terminal UI or the Codex app, never `codex exec`
    (the cross-check skill) or Codex subagents."""
    try:
        with open(transcript, "rb") as handle:
            first = json.loads(handle.readline().decode("utf-8", errors="replace"))
    except (OSError, ValueError):
        return False
    source = (first.get("payload") or {}).get("source") if isinstance(first, dict) else None
    return source in CODEX_INTERACTIVE


def queue_sweep(sid: str, transcript: str | None) -> list[str]:
    """Capture what Michael typed since the last sweep of this transcript. Offsets are kept per
    transcript, so a clear's new transcript or a stray child never forces a re-read; the first
    sweep of a conversation reaches back QUEUE_LOOKBACK seconds and no further."""
    if not transcript or not os.path.isfile(transcript):
        return []
    codex = HOOK_AGENT == "codex"
    if codex and not codex_interactive(transcript):
        return []
    state_file = sweep_path(sid)
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        state = None
    size = os.path.getsize(transcript)
    if not isinstance(state, dict) or not isinstance(state.get("paths"), dict):
        state = {"since": time.time() - QUEUE_LOOKBACK, "paths": {}}
    offsets = state["paths"]
    offset = offsets.get(transcript)
    if not isinstance(offset, int) or offset > size:
        offset = max(0, size - QUEUE_FIRST_BYTES)
    since = float(state.get("since", 0))
    with open(transcript, "rb") as handle:
        handle.seek(offset)
        chunk = handle.read()
    end = chunk.rfind(b"\n") + 1  # whole lines only; a line still being written waits
    marker = b'"user_message"' if codex else b'"human"'
    parse = codex_human if codex else claude_human
    found: list[tuple[str, str, str]] = []
    for raw in chunk[:end].split(b"\n"):
        if marker not in raw:
            continue  # most lines are tool calls and output: skip them before parsing
        try:
            entry = json.loads(raw.decode("utf-8", errors="replace"))
        except ValueError:
            continue
        hit = parse(entry) if isinstance(entry, dict) else None
        if hit and (iso_epoch(hit[2]) or time.time()) >= since:
            found.append(hit)
    added = capture_messages(sid, found) if found else []
    offsets[transcript] = offset + end
    atomic_write(state_file, json.dumps(state))
    return added


def when(item: dict) -> str:
    epoch = iso_epoch(str(item.get("ts", "")))
    return fmt_time(epoch) if epoch else str(item.get("ts", ""))[:16]


def open_items(sid: str | None) -> list[dict]:
    return [i for i in load_queue(sid) if i["status"] == "open"]


def unreviewed(sid: str | None) -> list[dict]:
    return [m for m in load_state(sid)[1] if not m["reviewed"]]


def one_line(text: str, limit: int = QUEUE_TITLE_MAX) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[: limit - 3] + "..."


def queue_block(sid: str | None) -> str:
    """The checklist, for the start of a refreshed or resumed conversation: open tasks one line
    each, then any message not yet reviewed into the checklist."""
    tasks, inbox = open_items(sid), unreviewed(sid)
    if not tasks and not inbox:
        return ""
    out = [f"Checklist for this conversation ({len(tasks)} open; `{QUEUE_HELP}` to manage it):"]
    out += [f"- [ ] {t['id']} {t['title']}" for t in tasks] or ["- (no open tasks)"]
    if inbox:
        shown = inbox[-QUEUE_SHOW_INBOX:]
        out.append(f"Michael's messages not yet reviewed into the checklist ({len(inbox)}): add a task for each "
                   f"request (`{QUEUE_HELP} add \"<short title>\"`), then `{QUEUE_HELP} reviewed`.")
        out += [f"- {m['id']} ({when(m)}): {one_line(m['text'], 200)}" for m in shown]
        if len(inbox) > len(shown):
            out.append(f"  (+{len(inbox) - len(shown)} older: `{QUEUE_HELP} inbox`)")
    return "\n".join(out)


def prune_queues() -> None:
    cutoff = time.time() - QUEUE_PRUNE_DAYS * 86400
    for path in (STATE / "queue").glob("*.jsonl"):
        try:
            if path.stat().st_mtime < cutoff:
                for extra in (path, sweep_path(path.stem)):
                    extra.unlink(missing_ok=True)
        except OSError:
            pass


def cmd_queue(args: list[str]) -> int:
    """queue [list [--all|--project]] | add <title> | done|drop|reopen <ids> [--note ...] | title <id> <title>
    | inbox | reviewed [<m-id>] | show <id>"""
    sid = need_sid()
    sub = args[0] if args else "list"
    rest = args[1:]
    note = None
    if "--note" in rest:
        at = rest.index("--note")
        note = " ".join(rest[at + 1:]) or None
        rest = rest[:at]
    tasks, msgs = load_state(sid)
    by_id = {i["id"]: i for i in tasks + msgs}
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    if sub == "list":
        if "--project" in rest:
            here = str((repo_root(project_dir()) or project_dir()).resolve())
            shown = 0
            for path in sorted((STATE / "queue").glob("*.jsonl")):
                if path.stem == sid:
                    continue
                for task in open_items(path.stem):
                    if _under(Path(str(task.get("cwd", ""))), here):
                        print(f"[{path.stem}] [ ] {task['id']} {task['title']}")
                        shown += 1
            if not shown:
                print(f"No open tasks from other conversations under {here}.")
            return 0
        chosen = tasks if "--all" in rest else [t for t in tasks if t["status"] == "open"]
        for task in chosen:
            mark = "[ ]" if task["status"] == "open" else "[x]" if task["status"] == "done" else "[-]"
            tail = f"  ({task['note']})" if task.get("note") and task["status"] != "open" else ""
            print(f"{mark} {task['id']} {task['title']}{tail}")
        if not chosen:
            print("No open tasks." if tasks else "The checklist is empty.")
        inbox = [m for m in msgs if not m["reviewed"]]
        if inbox:
            print(f"Unreviewed messages: {len(inbox)} (`{QUEUE_HELP} inbox`)")
        return 0
    if sub == "inbox":
        inbox = [m for m in msgs if not m["reviewed"]]
        for m in inbox:
            print(f"{m['id']} ({when(m)}): {one_line(m['text'], 300)}")
        if not inbox:
            print("No unreviewed messages.")
        return 0
    if sub == "reviewed":
        target = rest[0] if rest else (msgs[-1]["id"] if msgs else "")
        if target and not MSG_RE.match(target):
            print(f"queue reviewed: {target} is not a message id (m<n>)", file=sys.stderr)
            return 1
        if target:
            with QueueLock(sid):
                queue_append(sid, {"op": "reviewed", "through": target, "ts": now})
        print(f"reviewed through {target or '(nothing captured)'}; {len(open_items(sid))} open task(s).")
        return 0
    if sub == "show":
        for rid in rest:
            item = by_id.get(rid if rid.startswith("m") else rid.upper())
            print(f"{rid}: {item.get('text') or item.get('title')}" if item else f"{rid}: not found")
        return 0
    if sub == "add":
        title = capturable(" ".join(rest))
        if not title:
            print("queue add: give a short task title", file=sys.stderr)
            return 1
        print(f"added {add_task(sid, title)}")
        return 0
    if sub == "title":
        rid = rest[0].upper() if rest else ""
        title = " ".join(rest[1:]).strip()
        if rid not in {t["id"] for t in tasks} or not title:
            print("queue title: give a task id and its new title", file=sys.stderr)
            return 1
        with QueueLock(sid):
            queue_append(sid, {"op": "title", "id": rid, "title": " ".join(title.split())[:QUEUE_TITLE_MAX], "ts": now})
        print(f"retitled {rid}")
        return 0
    if sub in ("done", "drop", "reopen"):
        ids = []
        task_ids = {t["id"] for t in tasks}
        for raw in rest:
            for part in raw.replace(",", " ").split():
                rid = part.upper()
                if rid not in task_ids:
                    print(f"queue {sub}: no task {part} in this conversation", file=sys.stderr)
                    return 1
                ids.append(rid)
        if not ids:
            print(f"queue {sub}: give one or more task ids (R3 R4)", file=sys.stderr)
            return 1
        rec = {"op": "reopen" if sub == "reopen" else "close", "ids": ids, "ts": now}
        if sub != "reopen":
            rec["status"] = "done" if sub == "done" else "dropped"
        if note:
            rec["note"] = note
        with QueueLock(sid):
            queue_append(sid, rec)
        left = open_items(sid)
        print(f"{sub}: {', '.join(ids)}. Open: {', '.join(t['id'] for t in left) or 'none'}.")
        return 0
    print(cmd_queue.__doc__, file=sys.stderr)
    return 1


def hook_request_capture(data: dict) -> int:
    """Stop (and Codex Stop): sweep this turn's messages into the inbox. When three or more sit
    unreviewed, ask the agent once (Claude only; never twice in a row) to update the checklist."""
    if quiet_lane():
        return 0
    sid = session_id()
    if not sid:
        return 0
    added = queue_sweep(sid, data.get("transcript_path"))
    inbox = unreviewed(sid)
    log("request-capture", f"sid={sid} agent={HOOK_AGENT} added={','.join(added) or '-'} unreviewed={len(inbox)}")
    if HOOK_AGENT == "claude" and len(inbox) >= QUEUE_NAG_UNREVIEWED and not data.get("stop_hook_active"):
        print(json.dumps({"decision": "block", "reason": (
            f"Checklist upkeep: {len(inbox)} of Michael's messages are not reviewed into the checklist "
            f"({', '.join(m['id'] for m in inbox[-5:])}). Add a task for each request "
            f"(`{QUEUE_HELP} add \"<short title>\"`), close finished ones (`{QUEUE_HELP} done <ids>`), "
            f"then run `{QUEUE_HELP} reviewed`. `{QUEUE_HELP} inbox` lists them.")}))
    return 0


# ---------------------------------------------------------------- hooks

def hook_session_start(data: dict) -> int:
    if quiet_lane():
        return 0
    status = session_start_card(data)
    sid = session_id()
    try:
        prune_queues()
        if sid:
            queue_sweep(sid, data.get("transcript_path"))
        block = queue_block(sid)
    except Exception as exc:  # the queue must never cost a session its card
        log("session-start", f"queue error: {type(exc).__name__}: {exc}")
        block = ""
    if block:
        print(("\n" if status else "") + block)
    return 0


def session_start_card(data: dict) -> bool:
    """The resume-card part of SessionStart. True when it printed something."""
    sid = session_id()
    prune_bindings()
    root = repo_root(project_dir())
    printed = False
    if sid and HOOK_AGENT == "claude" and data.get("source") == "startup" and not load_binding(sid) and not load_role(sid):
        try:
            activated = activate_builder(sid, root)
        except Exception as exc:  # never let activation cost a session its card reload
            log("orchestration", f"activation error: {type(exc).__name__}: {exc}")
            activated = None
        if activated:
            print(activated)
            printed = True
    elif HOOK_AGENT == "codex" and root and load_activation(root):
        print("This folder is a Builder worktree of an active orchestration; roles and guards apply only in Claude Code.")
        printed = True
    binding = load_binding(sid)
    if binding and sid:
        marker = STATE / "cleared" / sid
        refreshed = data.get("source") in ("compact", "clear") or marker.exists()
        try:
            marker.unlink()
        except OSError:
            pass
        touch_binding(sid)
        card = Path(binding["card"])
        if refreshed:
            print(f"This session was just refreshed. Its resume card ({card}), last updated {fmt_time(card_updated(binding))}, is the current state of the work:\n")
            print(show_card(binding))
            print()
        else:
            print(f"This session is bound to the resume card {card}; read it before continuing that work.")
        print(NOTES if binding.get("kind") != "file" else FILE_NOTES)
        role = load_role(sid)
        if role:
            print(f"Orchestration role for this session: {role_summary(role)}.")
        log("session-start", f"sid={sid} source={data.get('source')} refreshed={refreshed}")
        return True
    if root:
        folder = card_dir(root)
        names = sorted(folder.glob("*.md"), key=lambda p: p.stat().st_mtime, reverse=True) if folder.is_dir() else []
        if names:
            listed = ", ".join(p.stem for p in names[:6])
            print(f"Resume cards in this repo: {listed}. If Michael asks to continue one, bind it first: python3 ~/.claude/hooks/context-card.py bind <name>.")
            return True
    return printed


def hook_pre_compact(data: dict) -> int:
    if quiet_lane():
        return 0
    sid = session_id()
    try:
        if sid:
            queue_sweep(sid, data.get("transcript_path"))  # a mid-turn message lands before it can be summarized away
        waiting = open_items(sid)
        pending = unreviewed(sid)
    except Exception as exc:
        log("pre-compact", f"queue error: {type(exc).__name__}: {exc}")
        waiting, pending = [], []
    if waiting or pending:
        print(f"This conversation's checklist ({len(waiting)} open: {', '.join(i['id'] for i in waiting)}) and any "
              "unreviewed messages are restored right after this compaction. Refer to tasks by id and record "
              "progress on each; do not restate them.\n")
    binding = load_binding(sid)
    if not binding:
        return 0
    model = working_model(data.get("transcript_path"))
    profile = PROFILES / f"{model}.md" if model else None
    if not profile or not profile.is_file():
        profile = PROFILES / "default.md"
    since = card_updated(binding)
    stamp = fmt_time(since)
    print(
        "Resume-card compaction. This session works from the resume card "
        f"{binding['card']}, last updated {stamp}. The card and git history hold everything "
        "settled before then and are reloaded right after this compaction, so do not restate "
        f"them. Summarize only what happened after {stamp}."
    )
    later = commits_since(binding, since)
    if later:
        print(
            f"\nThe card is behind: {len(later)} commit(s) landed after it was last updated. "
            "Keep the work, decisions and discoveries behind them in the summary:"
        )
        for line in later[:20]:
            print(f"- {line}")
    print()
    if profile.is_file():
        print(profile.read_text(encoding="utf-8").strip())
    log("pre-compact", f"model={model} profile={profile.name} stale_commits={len(later)}")
    return 0


def block(reason: str, code: int = 2, label: str = "clear-guard") -> int:
    print(reason, file=sys.stderr)
    log(label, f"block: {reason}")
    return code


def role_block(reason: str) -> int:
    # Exit 3, mapped to 2 by the registered wrapper: an interpreter that cannot even open this
    # script exits 2 itself, and that must never block a session.
    return block(reason, code=3, label="role-guard")


def hook_clear_guard(data: dict) -> int:
    tool_input = data.get("tool_input")
    target = tool_input.get("session_id") if isinstance(tool_input, dict) else None
    if not isinstance(target, str) or not target:
        return block("clear guard: no target session in the hook input; not clearing.")
    host = os.environ.get("CLAUDE_CODE_HOST_SESSION_ID")
    if target != "self" and not (host and target == host):
        log("clear-guard", f"allow: target is another session ({target})")
        return 0
    kind, text, stamp = turn_start(data.get("transcript_path"))
    if kind != "typed" or not bare_wrap(text):
        return block(
            "This session does not clear itself: clearing needs Michael to type /wrap as his "
            "latest message. Leave the chat as it is and continue, or suggest /wrap."
        )
    sid = session_id()
    binding = load_binding(sid)
    if not binding or not sid:
        return block("No resume card is bound to this session; /wrap binds one and checkpoints it before clearing.")
    asked = iso_epoch(stamp)
    if asked is None or card_updated(binding) < asked - 5:
        return block("The card checkpoint after /wrap has not landed yet; update the card and run the commit step first.")
    if binding.get("mode") == "repo" and git(Path(binding["repo"]), "status", "--porcelain", "--", binding["card"]):
        return block("The card has uncommitted changes; run the /wrap commit step first.")
    marker = STATE / "cleared" / sid
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(stamp, encoding="utf-8")
    log("clear-guard", f"allow: typed /wrap sid={sid}")
    return 0


# ---------------------------------------------------------------- helpers for /wrap

def need_sid() -> str:
    sid = session_id()
    if not sid:
        raise SystemExit("No session identity (Desktop session id or CLAUDE_PID); cards need Claude Code.")
    return sid


def cmd_status(_args: list[str]) -> int:
    sid = session_id()
    binding = load_binding(sid)
    print(f"session: {sid or 'none'}")
    if binding:
        since = card_updated(binding)
        later = commits_since(binding, since)
        print(f"card: {binding['card']} ({binding.get('mode')}, kind {binding.get('kind', 'card')}), last updated {fmt_time(since)}, {len(later)} commit(s) since")
    else:
        print("card: none bound")
    root = repo_root(project_dir())
    if root:
        folder = card_dir(root)
        names = sorted(p.stem for p in folder.glob("*.md")) if folder.is_dir() else []
        print(f"repo: {root} ({'committed cards' if owned(root) else 'local cards, never committed'})")
        print(f"cards here: {', '.join(names) if names else 'none'}")
    settings = project_dir() / ".claude" / "settings.local.json"
    try:
        window = json.loads(settings.read_text(encoding="utf-8")).get("autoCompactWindow")
    except (OSError, ValueError, AttributeError):
        window = None
    print(f"compaction window here: {window or 'default'}")
    role = load_role(sid)
    print(f"role: {role['role'] + (' (' + role['orch_dir'] + ')' if role.get('orch_dir') else '') if role else 'none'}")
    return 0


def cmd_bind(args: list[str]) -> int:
    by_file = len(args) == 2 and args[0] == "--file"
    if not by_file and (len(args) != 1 or not NAME_RE.match(args[0])):
        raise SystemExit("usage: bind <name>  (lowercase letters, digits and dashes; up to 40)\n"
                         "       bind --file <path>  (an existing file, e.g. tasks/<orch>/RESUME.md)")
    sid = need_sid()
    root = repo_root(project_dir())
    if not root:
        raise SystemExit("Not inside a git repository; resume cards live with a repo.")
    if by_file:
        # The Orchestrator's card is its RESUME.md (skill `build-orchestration`): the protocol rewrites
        # it on every ledger write, so it is always the freshest statement of the work.
        card = Path(args[1]) if os.path.isabs(args[1]) else project_dir() / args[1]
        card = card.resolve()
        if not card.is_file():
            raise SystemExit(f"{card} does not exist; create it first.")
        try:
            card.relative_to(root.resolve())
        except ValueError:
            raise SystemExit(f"{card} is outside this repository ({root}).")
    else:
        card = card_dir(root) / f"{args[0]}.md"
        if not card.exists():
            atomic_write(card, TEMPLATE.format(name=args[0]))
            if owned(root):
                os.chmod(card, 0o644)
    for other in (STATE / "bind").glob("*.json"):
        try:
            data = json.loads(other.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if other.stem != sid and data.get("card") == str(card) and time.time() - other.stat().st_mtime < 12 * 3600:
            print(f"note: session {other.stem} was also working from this card within the last 12 hours.")
    if by_file:
        rel = card.relative_to(root.resolve()).as_posix()
        in_repo = owned(root) and git(root, "ls-files", "--error-unmatch", rel) is not None
    else:
        in_repo = owned(root) and card_dir(root) == root / ".claude" / "resume"
    binding = {"card": str(card), "repo": str(root), "mode": "repo" if in_repo else "local",
               "kind": "file" if by_file else "card", "bound_at": time.time()}
    atomic_write(binding_path(sid), json.dumps(binding, indent=2) + "\n")
    log("bind", f"sid={sid} card={card}")
    print(f"bound: {card} ({binding['mode']})\n")
    print(show_card(binding))
    return 0


def cmd_unbind(_args: list[str]) -> int:
    sid = need_sid()
    try:
        binding_path(sid).unlink()
        print("unbound; this session is back to normal compaction.")
    except OSError:
        print("no card was bound.")
    return 0


def in_progress(root: Path) -> str | None:
    for name in ("rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"):
        path = git(root, "rev-parse", "--git-path", name)
        if path and (root / path if not os.path.isabs(path) else Path(path)).exists():
            return name
    return None


def cmd_commit(args: list[str]) -> int:
    binding = load_binding(need_sid())
    if not binding:
        raise SystemExit("No card bound; run bind <name> first.")
    if binding.get("mode") != "repo":
        os.utime(binding["card"], None)  # marks the checkpoint: the clear guard checks the card is newer than /wrap
        print("local card (kept outside git: untracked, or not Michael's repo); marked current, nothing to commit.")
        return 0
    root, card = Path(binding["repo"]), binding["card"]
    busy = in_progress(root)
    if busy:
        raise SystemExit(f"git is in the middle of an operation ({busy}); finish it before checkpointing.")
    message = " ".join(args).strip().splitlines()[0] if args and " ".join(args).strip() else "checkpoint"
    if not message.startswith("checkpoint"):
        message = f"checkpoint: {message}"
    if git(root, "add", "--", card) is None:
        raise SystemExit("git add of the card failed.")
    if not git(root, "diff", "--cached", "--name-only", "--", card):
        print("card unchanged since its last commit; nothing to commit.")
        return 0
    done = subprocess.run(
        ["git", "-C", str(root), "commit", "-q", "-m", message, "--only", "--", card],
        capture_output=True, text=True, timeout=120, env=git_env(),
    )
    if done.returncode != 0:
        print(done.stdout + done.stderr, file=sys.stderr)
        raise SystemExit("git commit failed; the card is not checkpointed.")
    print(f"checkpoint committed: {git(root, 'log', '-1', '--format=%h %s')}")
    return 0


def set_project(folder: Path, on: bool, window: int = WINDOW) -> str:
    """The 350K auto-compaction window for sessions started in `folder` (local settings, excluded)."""
    settings = folder / ".claude" / "settings.local.json"
    try:
        data = json.loads(settings.read_text(encoding="utf-8")) if settings.exists() else {}
    except ValueError:
        raise SystemExit(f"{settings} is not valid JSON; fix it first.")
    if not isinstance(data, dict):
        raise SystemExit(f"{settings} must hold a JSON object.")
    if on:
        data["autoCompactWindow"] = window
    else:
        data.pop("autoCompactWindow", None)
    atomic_write(settings, json.dumps(data, indent=2) + "\n")
    root = repo_root(folder)
    warning = ""
    if root and on:
        rel = settings.resolve().relative_to(root.resolve()).as_posix()
        if git(root, "ls-files", "--error-unmatch", rel) is not None:
            warning = f" (warning: {rel} is tracked by git; this change will show up in commits)"
        else:
            exclude = git(root, "rev-parse", "--git-path", "info/exclude")
            if exclude:
                path = Path(exclude) if os.path.isabs(exclude) else root / exclude
                existing = path.read_text(encoding="utf-8") if path.exists() else ""
                if f"/{rel}" not in existing.splitlines():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with path.open("a", encoding="utf-8") as handle:
                        handle.write(("" if existing.endswith("\n") or not existing else "\n") + f"/{rel}\n")
    state = f"{window} tokens" if on else "Claude Code's default"
    return f"auto-compaction for sessions started in {folder}: {state}{warning}"


LIMIT_RE = re.compile(r"^(\d+(?:\.\d+)?)([km]?)$")


def parse_limit(raw: str) -> int:
    match = LIMIT_RE.match(raw.strip().lower().replace("_", "").replace(",", ""))
    if not match:
        raise SystemExit(f"not a token count: {raw} (for example 250k or 250000)")
    try:
        limit = int(float(match.group(1)) * {"": 1, "k": 1000, "m": 1000000}[match.group(2)])
    except (OverflowError, ValueError):
        raise SystemExit(f"not a token count: {raw}")
    if limit < WINDOW_MIN:
        raise SystemExit(f"limit must be at least {WINDOW_MIN // 1000}k: below that, the fixed load refills the chat right after each compaction.")
    if limit > WINDOW_MAX:
        raise SystemExit(f"limit must be at most {WINDOW_MAX // 1000}k.")
    return limit


def window_record_path(folder: Path) -> Path:
    return STATE / "windows" / f"{hashlib.sha1(str(folder.resolve()).encode('utf-8')).hexdigest()[:16]}.json"


def window_of(record: dict) -> int:
    holders = record.get("holders") or {}
    return int(holders.get("autowrap") or WINDOW)  # an explicit /autowrap limit wins over the default


def window_hold(folder: Path, holder: str, limit: int | None = None) -> str:
    """One record per folder: who holds its compaction window (autowrap, orch:<name>), and the
    folder's own setting from before the first holder, restored when the last one leaves."""
    path = window_record_path(folder)
    record = read_json(path) or {"folder": str(folder.resolve()), "prior": settings_snapshot(folder), "holders": {}}
    record.setdefault("holders", {})[holder] = limit or record["holders"].get(holder) or WINDOW
    atomic_write(path, json.dumps(record, indent=2) + "\n")
    return set_project(folder, True, window_of(record))


def window_release(folder: Path, holder: str) -> str:
    path = window_record_path(folder)
    record = read_json(path)
    if not record or holder not in (record.get("holders") or {}):
        return f"{folder}: nothing held by {holder}"
    del record["holders"][holder]
    if record["holders"]:
        atomic_write(path, json.dumps(record, indent=2) + "\n")
        return set_project(folder, True, window_of(record)) + f" (still held by {', '.join(record['holders'])})"
    remove(path)
    return restore_project(folder, record.get("prior") or {})


def cmd_autowrap(args: list[str]) -> int:
    """/autowrap: automatic refresh for this project (keyed by the repo root). `on`/`limit` hold the
    folder's compaction window; `off` releases autowrap's hold and unbinds only a card autowrap
    itself bound (`on --bound`), never a chat with a role."""
    usage = "usage: autowrap on [--bound] | off | status | limit <tokens, e.g. 250k> [--bound]"
    if not args or args[0] not in ("on", "off", "status", "limit"):
        raise SystemExit(usage)
    bound_now = "--bound" in args
    rest = [a for a in args[1:] if a != "--bound"]
    if (args[0] == "limit") != (len(rest) == 1) or len(rest) > 1:
        raise SystemExit(usage)
    folder = repo_root(project_dir()) or project_dir()
    record = read_json(window_record_path(folder)) or {}
    holders = record.get("holders") or {}
    sid = session_id()
    binding = load_binding(sid)
    if args[0] == "status":
        others = [h for h in holders if h != "autowrap"]
        print(f"autowrap for {folder}: {'on (limit ' + str(holders['autowrap']) + ')' if 'autowrap' in holders else 'off'}"
              f"{'; window also held by ' + ', '.join(others) if others else ''}; "
              f"compaction window {window_of(record) if holders else 'default'}; this chat's card: {binding['card'] if binding else 'none'}")
        return 0
    if args[0] in ("on", "limit"):
        limit = parse_limit(rest[0]) if args[0] == "limit" else None
        line = window_hold(folder, "autowrap", limit)
        record = read_json(window_record_path(folder)) or {}
        if bound_now and sid and binding:
            record.setdefault("autowrap_cards", {})[sid] = binding["card"]
            atomic_write(window_record_path(folder), json.dumps(record, indent=2) + "\n")
        print(line + ". Chats started here from now on use it; this one keeps its window until it restarts.")
        print(f"this chat's card: {binding['card'] if binding else 'none bound'}")
        return 0
    if "autowrap" not in holders:
        print(f"autowrap is not on for {folder}; nothing changed.")
        return 0
    cards = record.get("autowrap_cards") or {}
    line = window_release(folder, "autowrap")
    unbound = False
    if sid and binding and binding.get("kind") != "file" and cards.get(sid) == binding.get("card") and not load_role(sid):
        remove(binding_path(sid))
        unbound = True
    if cards:
        record = read_json(window_record_path(folder))
        if record:
            record.pop("autowrap_cards", None)
            atomic_write(window_record_path(folder), json.dumps(record, indent=2) + "\n")
    print(line + ("; this chat's card (bound by autowrap) is unbound" if unbound else "") + ".")
    return 0


ROLES = ("orchestrator", "builder")
GIT_GLOBAL_OPTS_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
BUILDER_GIT_BLOCKED = {"push", "merge", "rebase", "switch", "update-ref", "cherry-pick", "revert", "am", "pull"}
READ_ONLY_GIT = {"status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "grep", "cat-file",
                 "merge-base", "describe", "shortlog", "ls-tree", "for-each-ref", "name-rev"}


def role_path(sid: str) -> Path:
    return STATE / "role" / f"{sid}.json"


def process_start(sid: str) -> str | None:
    """For a terminal CLI identity (pid-N), the start time of that process: a later session that
    reuses the pid must not inherit the old role."""
    if not sid.startswith("pid-"):
        return None
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", sid[4:]], capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() or None


def load_role(sid: str | None) -> dict | None:
    if not sid:
        return None
    path = role_path(sid)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("role") not in ROLES:
        return None
    if data.get("process_start") and data["process_start"] != process_start(sid):
        try:
            path.unlink()  # a stale role from an earlier process that had the same pid
        except OSError:
            pass
        return None
    orch = data.get("orchestration") or {}
    if data["role"] == "builder" and orch and not load_activation(Path(orch.get("builder_worktree", "/nonexistent")), include_paused=True):
        return None  # its orchestration ended, expired or is orphaned: no rules apply
    return data


def resolve_arg(value: str) -> str:
    folder = Path(value) if os.path.isabs(value) else project_dir() / value
    return str(folder.resolve())


def cmd_role(args: list[str]) -> int:
    sid = need_sid()
    if sid.startswith("codex-"):
        raise SystemExit("Roles are enforced only in Claude Code; Codex has no role guard.")
    if args == ["off"]:
        try:
            role_path(sid).unlink()
        except OSError:
            pass
        log("role", f"sid={sid} role=off")
        print("role cleared; no orchestration rules apply to this session.")
        return 0
    if not args or args[0] not in ROLES:
        raise SystemExit("usage: role orchestrator --orch-dir <path> [--allow <path>]... | role builder [--worktree <path>] | role off")
    data: dict = {"role": args[0], "set_at": time.time()}
    rest = args[1:]
    allow: list[str] = []
    while rest:
        flag = rest.pop(0)
        if not rest:
            raise SystemExit(f"{flag} needs a path")
        value = resolve_arg(rest.pop(0))
        if flag == "--orch-dir" and args[0] == "orchestrator":
            data["orch_dir"] = value
        elif flag == "--allow" and args[0] == "orchestrator":
            allow.append(value)
        elif flag == "--worktree" and args[0] == "builder":
            data["worktree"] = value
        else:
            raise SystemExit(f"unknown option for {args[0]}: {flag}")
    if args[0] == "orchestrator":
        if not data.get("orch_dir") or not Path(data["orch_dir"]).is_dir():
            raise SystemExit("role orchestrator needs --orch-dir <existing tasks/<orchestration>/ directory>")
        data["allow"] = allow
    start = process_start(sid)
    if start:
        data["process_start"] = start
    atomic_write(role_path(sid), json.dumps(data, indent=2) + "\n")
    log("role", f"sid={sid} role={args[0]}")
    print(f"role: {role_summary(data)}.")
    return 0


def role_summary(role: dict) -> str:
    orch = role.get("orchestration") or {}
    if orch and (read_json(orch_state(Path(orch["builder_worktree"]))) or {}).get("paused"):
        return (f"{role['role']} of orchestration {orch.get('name')}, PAUSED: "
                + ("a normal chat agent until /orchestrate on" if role["role"] == "orchestrator" else "idle until the Orchestrator runs /orchestrate on"))
    if role["role"] == "orchestrator":
        return (f"orchestrator; Edit/Write are allowed in {role['orch_dir']}, any analysis_outputs/, "
                f"{', '.join(role.get('allow') or []) or 'no extra roots'} and outside git work trees; "
                "product files are blocked (Bash is not policed; custody is)")
    where = f"Edit/Write only inside {role['worktree']}" if role.get("worktree") else "Edit/Write unrestricted"
    return f"builder; {where}; git push/merge/rebase/switch/branch change/reset --hard/branch -D/update-ref and gh pr merge are blocked"


def _under(path: Path, root: str) -> bool:
    try:
        path.relative_to(Path(root))
        return True
    except ValueError:
        return False


def _in_git_tree(path: Path) -> bool:
    folder = path if path.is_dir() else path.parent
    while not folder.exists() and folder != folder.parent:
        folder = folder.parent
    return git(folder, "rev-parse", "--show-toplevel") is not None


def git_invocations(command: str) -> list[list[str]]:
    """The argument lists of every `git ...` / `gh ...` simple command in a shell string."""
    import shlex
    found = []
    for part in re.split(r"&&|\|\||[;|\n]", command):
        try:
            tokens = shlex.split(part)
        except ValueError:
            tokens = part.split()
        while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
            tokens = tokens[1:]  # leading VAR=value assignments
        if tokens and os.path.basename(tokens[0]) in ("git", "gh"):
            found.append([os.path.basename(tokens[0])] + tokens[1:])
    return found


def git_subcommand(tokens: list[str]) -> tuple[str | None, list[str]]:
    i = 1
    while i < len(tokens) and tokens[i].startswith("-"):
        i += 2 if tokens[i] in GIT_GLOBAL_OPTS_WITH_ARG else 1
    return (tokens[i], tokens[i + 1:]) if i < len(tokens) else (None, [])


def builder_git_violation(command: str) -> str | None:
    for tokens in git_invocations(command):
        if tokens[0] == "gh":
            if len(tokens) >= 3 and tokens[1] == "pr" and tokens[2] in ("merge", "create"):
                return "gh pr " + tokens[2]
            continue
        sub, rest = git_subcommand(tokens)
        if sub in BUILDER_GIT_BLOCKED:
            return f"git {sub}"
        if sub == "reset" and "--hard" in rest:
            return "git reset --hard"
        if sub == "branch" and any(flag in rest for flag in ("-D", "-f", "--force", "-M", "-C")):
            return "git branch " + next(f for f in rest if f in ("-D", "-f", "--force", "-M", "-C"))
        if sub == "checkout" and "--" not in rest and any(not a.startswith("-") or a in ("-b", "-B") for a in rest):
            return "git checkout (switching branches)"
    return None


def hook_role_guard(data: dict) -> int:
    if headless() or data.get("agent_type") == "challenger":
        return 0  # the challenger has its own agent-scoped guard
    role = load_role(session_id())
    if not role:
        return 0
    tool = data.get("tool_name")
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    orch = role.get("orchestration") or {}
    paused = bool(orch) and bool((read_json(orch_state(Path(orch["builder_worktree"]))) or {}).get("paused"))
    if role["role"] == "orchestrator" and paused:
        return 0  # /orchestrate off: a normal chat agent until /orchestrate on
    if role["role"] == "builder" and paused and tool in ("Edit", "Write", "NotebookEdit", "Bash", "PowerShell"):
        return role_block(f"Orchestration {orch.get('name')} is paused: this Builder is idle until the Orchestrator runs /orchestrate on.")
    if tool in ("Edit", "Write", "NotebookEdit"):
        target = Path(str(tool_input.get("file_path") or tool_input.get("notebook_path") or "")).resolve()
        if role["role"] == "orchestrator":
            allowed = (_under(target, role["orch_dir"]) or "analysis_outputs" in target.parts
                       or any(_under(target, root) for root in role.get("allow") or []) or not _in_git_tree(target))
            if not allowed:
                return role_block(f"The Orchestrator never edits the product: {target} is a product file. "
                                  "Put the change in the Builder's assignment.")
        if role["role"] == "builder" and role.get("worktree") and not _under(target, role["worktree"]):
            return role_block(f"This Builder edits only inside its worktree ({role['worktree']}): {target}")
    if role["role"] == "builder" and tool in ("Bash", "PowerShell"):
        hit = builder_git_violation(str(tool_input.get("command", "")))
        if hit:
            return role_block(f"The Builder commits locally but does not run `{hit}`; the Orchestrator relays "
                              "Michael's go for pushes, merges and branch changes.")
    return 0


def hook_challenger_guard(data: dict) -> int:
    """Agent-scoped (challenger.md frontmatter), so it runs only for the Challenger subagent."""
    tool = data.get("tool_name")
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    role = load_role(session_id())
    canonical = repo_root(Path(role["orch_dir"])) if role and role.get("orch_dir") else None
    if tool in ("Edit", "Write", "NotebookEdit"):
        target = Path(str(tool_input.get("file_path") or tool_input.get("notebook_path") or "")).resolve().as_posix().lower()
        if "/analysis_outputs/reviewer-evidence/" not in target or "/execution-copy/" in target:
            return role_block(f"The Challenger writes only its own evidence under analysis_outputs/reviewer-evidence/ "
                              f"and never inside execution-copy/: {target}")
    if tool in ("Read", "Glob", "Grep") and canonical:
        # Pass-1 isolation: the canonical checkout holds builder deliverables, earlier reviews and
        # the ledger. The Challenger works only from its inbox, which lives outside it.
        raw = tool_input.get("file_path") or tool_input.get("path") or ""
        target = Path(str(raw)).resolve() if raw else Path(os.getcwd()).resolve()
        if _under(target, str(canonical.resolve())):
            return role_block(f"The Challenger reads only its inbox and the handoff, not the Orchestrator's checkout ({canonical}).")
    if tool in ("Bash", "PowerShell"):
        for tokens in git_invocations(str(tool_input.get("command", ""))):
            sub, _ = git_subcommand(tokens) if tokens[0] == "git" else (tokens[1] if len(tokens) > 1 else None, [])
            if tokens[0] == "gh" or sub not in READ_ONLY_GIT:
                return role_block(f"The Challenger runs read-only git only (not `{' '.join(tokens[:3])}`).")
    return 0


SKILL_TEMPLATES = Path(__file__).resolve().parent.parent / "global-skills" / "build-orchestration" / "templates"
ORCH_TTL_DAYS = 30


def orch_key(builder_root: Path) -> str:
    return hashlib.sha1(str(builder_root.resolve()).encode("utf-8")).hexdigest()[:16]


def orch_state(builder_root: Path) -> Path:
    # Outside every repo: no custody noise in the Builder's tree, nothing to commit by accident.
    return STATE / "orchestrations" / f"{orch_key(builder_root)}.json"


def read_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def orchestrator_live(act: dict) -> bool:
    raw = read_json(role_path(str(act.get("orchestrator", ""))))
    orch = (raw or {}).get("orchestration") or {}
    return bool(raw and raw.get("role") == "orchestrator" and orch.get("name") == act.get("name")
                and orch.get("builder_worktree") == act.get("builder_worktree"))


def load_activation(builder_root: Path, include_paused: bool = False) -> dict | None:
    """A live activation for this Builder worktree: its own record, not expired, and its
    Orchestrator's role still set. Paused ones count only with include_paused (existing Builders
    stay loaded and are held idle); a paused orchestration never activates a new session."""
    act = read_json(orch_state(builder_root))
    if not act or act.get("builder_worktree") != str(builder_root.resolve()):
        return None
    if time.time() - float(act.get("set_at", 0)) > ORCH_TTL_DAYS * 86400:
        return None
    if act.get("paused") and not include_paused:
        return None
    return act if orchestrator_live(act) else None


def settings_snapshot(folder: Path) -> dict:
    """Preflight one folder's local settings; raises SystemExit on invalid JSON before any write."""
    settings = folder / ".claude" / "settings.local.json"
    if not settings.exists():
        return {"existed": False, "window": None}
    try:
        data = json.loads(settings.read_text(encoding="utf-8"))
    except ValueError:
        raise SystemExit(f"{settings} is not valid JSON; fix it first. Nothing was changed.")
    if not isinstance(data, dict):
        raise SystemExit(f"{settings} must hold a JSON object. Nothing was changed.")
    return {"existed": True, "window": data.get("autoCompactWindow")}


def restore_project(folder: Path, prior: dict) -> str:
    settings = folder / ".claude" / "settings.local.json"
    if not folder.is_dir():
        return f"{folder} no longer exists; nothing to restore there"
    data = read_json(settings) or {}
    if prior.get("window") is not None:
        data["autoCompactWindow"] = prior["window"]
    else:
        data.pop("autoCompactWindow", None)
    if not data and not prior.get("existed"):
        try:
            settings.unlink()
        except OSError:
            pass
        return f"auto-compaction for sessions started in {folder}: back to Claude Code's default"
    atomic_write(settings, json.dumps(data, indent=2) + "\n")
    return f"auto-compaction for sessions started in {folder}: restored ({prior.get('window') or 'default'})"


def write_role(sid: str, data: dict) -> None:
    start = process_start(sid)
    if start:
        data["process_start"] = start
    atomic_write(role_path(sid), json.dumps(data, indent=2) + "\n")


def remove(*paths: Path) -> None:
    for path in paths:
        try:
            path.unlink()
        except OSError:
            pass


def cmd_orchestration(args: list[str]) -> int:
    sid = need_sid()
    if sid.startswith("codex-"):
        raise SystemExit("Orchestration runs in Claude Code; Codex has no role guard.")
    role = load_role(sid) or {}
    mine = role.get("orchestration") or {}
    here = repo_root(project_dir())
    if not args or args[0] == "status":
        if mine:
            act = read_json(orch_state(Path(mine["builder_worktree"])))
            state_word = "record missing; /orchestrate end cleans up" if not act else ("paused" if act.get("paused") else "on")
            print(f"orchestration {mine.get('name')} ({state_word}): this session is the {role.get('role')} (builder worktree {mine.get('builder_worktree')}).")
            return 0
        found = [a for a in (read_json(f) for f in (STATE / "orchestrations").glob("*.json")) if a and here and a.get("canonical") == str(here)]
        for act in found:
            live = load_activation(Path(act["builder_worktree"]), include_paused=True)
            print(f"orchestration {act.get('name')}: {('paused' if act.get('paused') else 'live') if live else 'stale (its Orchestrator role is gone or expired; /orchestrate end cleans up)'}; "
                  f"Orchestrator session {act.get('orchestrator')}; builder worktree {act.get('builder_worktree')}.")
        if not found:
            print("orchestration: none for this checkout.")
        return 0
    if args[0] in ("on", "off"):
        if role.get("role") != "orchestrator" or not mine:
            raise SystemExit("Run /orchestrate on or off in the Orchestrator's chat of a live orchestration (see /orchestrate status).")
        state = orch_state(Path(mine["builder_worktree"]))
        act = read_json(state)
        if not act:
            raise SystemExit("This orchestration's record is missing; /orchestrate end cleans up.")
        if args[0] == "on" and time.time() - float(act.get("set_at", 0)) > ORCH_TTL_DAYS * 86400:
            raise SystemExit(f"Orchestration {act.get('name')} expired after {ORCH_TTL_DAYS} days; /orchestrate end, then /orchestrate new.")
        if bool(act.get("paused")) == (args[0] == "off"):
            print(f"orchestration {act.get('name')} is already {'paused' if args[0] == 'off' else 'on'}.")
            return 0
        act["paused"] = args[0] == "off"
        atomic_write(state, json.dumps(act, indent=2) + "\n")
        log("orchestration", f"{'pause' if act['paused'] else 'resume'} name={act.get('name')}")
        print(f"orchestration {act.get('name')} {'paused: this chat is a normal agent (guard lifted), Builders are idle and none activate' if act['paused'] else 'resumed: the Orchestrator guard is back and Builders activate again'}.")
        return 0
    if args[0] == "end":
        if role.get("role") == "builder":
            raise SystemExit("A Builder cannot end the orchestration; the Orchestrator does.")
        if mine:
            act = read_json(orch_state(Path(mine["builder_worktree"])))
        else:
            name = args[1] if len(args) > 1 else None
            stale = [a for a in (read_json(f) for f in (STATE / "orchestrations").glob("*.json"))
                     if a and here and a.get("canonical") == str(here) and (name is None or a.get("name") == name)]
            if any(orchestrator_live(a) for a in stale):
                raise SystemExit("That orchestration's Orchestrator session is still live; end it there.")
            act = stale[0] if len(stale) == 1 else None
            if len(stale) > 1:
                raise SystemExit("Several stale orchestrations here; name one: orchestration end <name>.")
        if not act:
            raise SystemExit("No orchestration to end here.")
        builder = Path(act["builder_worktree"])
        lines = [window_release(builder, f"orch:{act.get('name')}"),
                 window_release(Path(act["canonical"]), f"orch:{act.get('name')}")]
        cleaned = 0
        for path in (STATE / "role").glob("*.json"):
            data = read_json(path) or {}
            orch = data.get("orchestration") or {}
            if data.get("role") == "builder" and orch.get("name") == act.get("name") and orch.get("builder_worktree") == str(builder):
                other = path.stem
                binding = read_json(binding_path(other)) or {}
                if str(binding.get("card", "")).startswith(str(STATE / "orchestrations" / orch_key(builder))):
                    remove(binding_path(other))
                remove(path)
                cleaned += 1
        remove(orch_state(builder))
        orch_sid = act.get("orchestrator", "")
        binding = read_json(binding_path(orch_sid)) or {}
        if binding.get("card") == act.get("resume"):
            remove(binding_path(orch_sid))
        orole = read_json(role_path(orch_sid)) or {}
        if (orole.get("orchestration") or {}).get("name") == act.get("name"):
            remove(role_path(orch_sid))  # last: a failure above leaves off re-runnable
        log("orchestration", f"end name={act.get('name')} builders={cleaned}")
        print(f"orchestration {act.get('name')} ended: the Orchestrator and {cleaned} Builder session(s) are back to normal.")
        print("\n".join(f"- {line}" for line in lines))
        return 0
    if len(args) < 2 or args[0] != "new" or not NAME_RE.match(args[1]):
        raise SystemExit("usage: orchestration new <name> [--builder-worktree <path>] [--allow <path>]... | on | off | end [<name>] | status")
    name = args[1]
    extra = args[2:]
    allow: list[str] = []
    builder_arg = None
    while extra:
        flag = extra.pop(0)
        if flag not in ("--allow", "--builder-worktree") or not extra:
            raise SystemExit(f"unknown option: {flag}")
        value = extra.pop(0)
        if flag == "--allow":
            allow.append(resolve_arg(value))
        else:
            builder_arg = value
    if role.get("role") == "builder":
        raise SystemExit("This session is a Builder; run /orchestrate new in the Orchestrator's chat.")
    if mine and mine.get("name") != name:
        raise SystemExit(f"This session already runs orchestration {mine.get('name')}; /orchestrate end it first.")
    if not here:
        raise SystemExit("Run this from the Orchestrator's canonical checkout (a git repository).")
    worktrees = Path(os.environ.get("CONTEXT_CARD_WORKTREES") or Path.home() / ".worktrees")
    if builder_arg is None:
        # The handoff's section 9 layout, made for Michael: a Builder worktree on its own branch and
        # a plain Challenger folder, both under ~/.worktrees (dotfiles INV-8; ~/Documents/Worktrees
        # until 2026-10-02, when ADR-0007 left ~/Documents to his personal files).
        target = worktrees / f"{here.name}-{name}-builder"
        if not target.exists():
            branch = f"orchestration/{name}/builder"
            has_branch = git(here, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}") is not None
            made = git(here, "worktree", "add", "-q", *([str(target), branch] if has_branch else ["-b", branch, str(target)]))
            if made is None:
                raise SystemExit(f"Could not create the Builder worktree at {target}.")
        (worktrees / f"{here.name}-{name}-challenger" / "analysis_outputs" / "reviewer-evidence" / "inbox").mkdir(parents=True, exist_ok=True)
        builder_arg = str(target)
    builder = repo_root(Path(resolve_arg(builder_arg)))
    if not builder or builder.resolve() == here.resolve():
        raise SystemExit(f"{args[3]} must be the Builder's own git worktree, not this checkout.")
    common = [git(folder, "rev-parse", "--path-format=absolute", "--git-common-dir") for folder in (here, builder)]
    if not common[0] or common[0] != common[1]:
        raise SystemExit(f"{builder} is not a worktree of this repository.")
    existing = read_json(orch_state(builder))
    if existing and existing.get("orchestrator") != sid and orchestrator_live(existing):
        raise SystemExit(f"Orchestration {existing.get('name')} already owns {builder} (Orchestrator session "
                         f"{existing.get('orchestrator')}). One Orchestrator per Builder worktree.")
    same = existing if existing and existing.get("orchestrator") == sid and existing.get("name") == name else None
    if same and same.get("paused"):
        raise SystemExit(f"Orchestration {name} is paused; resume it with /orchestrate on.")
    settings_snapshot(here), settings_snapshot(builder)  # preflight both before any write
    orch_dir = here / "tasks" / name
    orch_dir.mkdir(parents=True, exist_ok=True)
    resume = orch_dir / "RESUME.md"
    if not resume.exists():
        kickoff = orch_dir / "KICKOFF.md"
        next_action = (f"phase 2 begins. Read {kickoff} (your kickoff prompt) and {orch_dir / 'brief.md'}, then follow the "
                       "build-orchestration skill: ledger skeleton, briefs, baseline manifests, first assignment."
                       if kickoff.is_file() else "write the brief and the ledger skeleton (build-orchestration skill).")
        atomic_write(resume, "\n".join([
            f"# RESUME: {name} (rewritten on every ledger write)", "",
            f"- Next action: {next_action}",
            "- Frozen / unfrozen / held: none yet",
            "- Waiting on Michael: nothing",
            "- Last custody check: none yet",
            "- Open questions (provisional answers): none",
            f"- Live Orchestrator: {sid}",
            f"- Builder worktree: {builder.resolve()}; Challenger inboxes: {worktrees / (here.name + '-' + name + '-challenger')}", ""]))
    act = {"name": name, "canonical": str(here), "builder_worktree": str(builder.resolve()), "orchestrator": sid,
           "resume": str(resume.resolve()),
           "set_at": time.time()}
    atomic_write(orch_state(builder), json.dumps(act, indent=2) + "\n")
    rel = resume.resolve().relative_to(here.resolve()).as_posix()
    tracked = git(here, "ls-files", "--error-unmatch", rel) is not None
    atomic_write(binding_path(sid), json.dumps({"card": str(resume.resolve()), "repo": str(here), "kind": "file",
                                               "mode": "repo" if owned(here) and tracked else "local",
                                               "bound_at": time.time()}, indent=2) + "\n")
    write_role(sid, {"role": "orchestrator", "orch_dir": str(orch_dir.resolve()), "allow": allow, "set_at": time.time(),
                     "orchestration": {"name": name, "canonical": str(here), "builder_worktree": str(builder.resolve())}})
    lines = [window_hold(here, f"orch:{name}"), window_hold(builder, f"orch:{name}")]
    log("orchestration", f"new name={name} sid={sid} builder={builder}")
    print(f"orchestration {name} set up and on.")
    print(f"- Orchestrator (this session): card {resume}, role orchestrator (product files blocked; allowed: tasks/{name}/, analysis_outputs/, non-git paths{', ' + ', '.join(allow) if allow else ''}).")
    print(f"- Builder: each new Claude session opened in {builder} becomes a Builder at start, with its own fresh card, the git guard and edits confined to the worktree.")
    print("- Challenger: a fresh `challenger` subagent per revision; nothing to set up.")
    print("\n".join(f"- {line}" for line in lines))
    print("Custody: .claude/settings.local.json in both checkouts is now expected; run the baseline snapshot after this, or list it as an audit exclusion.")
    return 0


def activate_builder(sid: str, root: Path | None) -> str | None:
    """SessionStart(startup) of a brand-new, role-less, unbound Claude session in a live Builder
    worktree: it becomes a Builder with its own fresh card. Never touches an existing session."""
    act = load_activation(root) if root else None
    if not act:
        return None
    card = STATE / "orchestrations" / orch_key(root) / f"builder-{sid}.md"
    atomic_write(card, TEMPLATE.format(name=f"Builder card: orchestration {act['name']}, session {sid}"))
    write_role(sid, {"role": "builder", "worktree": str(root.resolve()), "set_at": time.time(),
                     "orchestration": {"name": act["name"], "builder_worktree": act["builder_worktree"]}})
    try:
        atomic_write(binding_path(sid), json.dumps({"card": str(card), "repo": str(root), "mode": "local", "kind": "card",
                                                   "bound_at": time.time()}, indent=2) + "\n")
    except OSError:
        remove(role_path(sid))  # never leave a role without its card
        raise
    log("orchestration", f"builder activated sid={sid} name={act['name']}")
    return (f"This session is a Builder for orchestration {act['name']} (set up by the Orchestrator's /orchestrate new): "
            "git guard on, edits confined to this worktree, and its own fresh card. Confirm with context-card.py status.")


HOOKS = {"session-start": hook_session_start, "pre-compact": hook_pre_compact,
         "request-capture": hook_request_capture,
         "clear-guard": hook_clear_guard, "role-guard": hook_role_guard,
         "challenger-guard": hook_challenger_guard}
HELPERS = {"status": cmd_status, "bind": cmd_bind, "unbind": cmd_unbind, "commit": cmd_commit,
           "autowrap": cmd_autowrap, "role": cmd_role, "orchestration": cmd_orchestration,
           "queue": cmd_queue}


def main(argv: list[str]) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if not argv or argv[0] not in {**HOOKS, **HELPERS}:
        print(__doc__, file=sys.stderr)
        return 1
    name = argv[0]
    global HOOK_AGENT, CODEX_HOOK_SESSION, IN_HOOK
    IN_HOOK = name in HOOKS
    if "--agent" in argv[1:] and name in HOOKS:
        HOOK_AGENT = argv[argv.index("--agent") + 1] if argv.index("--agent") + 1 < len(argv) else "claude"
    if HOOK_AGENT == "codex":
        if name not in ("session-start", "request-capture"):
            return 0  # Codex ignores PreCompact output, and has no Desktop clear tool.
        data = read_stdin_json()
        CODEX_HOOK_SESSION = str(data.get("session_id") or "") or None
        try:
            return HOOKS[name](data)
        except BaseException as exc:
            log(name, f"codex error: {type(exc).__name__}: {exc}")
            return 0
    if name == "clear-guard":
        try:
            data = json.loads(sys.stdin.read())
            if not isinstance(data, dict):
                raise ValueError("hook input is not a JSON object")
            return hook_clear_guard(data)
        except BaseException as exc:  # fail closed: an error must never allow a clear
            return block(f"clear guard error ({type(exc).__name__}); not clearing.")
    if name in ("role-guard", "challenger-guard"):
        # Silent for sessions without a role, even when broken; fail closed (exit 3) for a
        # session with a role, and always for the Challenger.
        try:
            data = json.loads(sys.stdin.read())
            if not isinstance(data, dict):
                raise ValueError("hook input is not a JSON object")
            return HOOKS[name](data)
        except BaseException as exc:
            if name == "challenger-guard" or load_role(session_id()):
                return role_block(f"{name} error ({type(exc).__name__}); not running this tool.")
            return 0
    if name in HOOKS:
        try:
            return HOOKS[name](read_stdin_json())
        except BaseException as exc:  # never break a session start or a compaction
            log(name, f"error: {type(exc).__name__}: {exc}")
            return 0
    return HELPERS[name](argv[1:])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
