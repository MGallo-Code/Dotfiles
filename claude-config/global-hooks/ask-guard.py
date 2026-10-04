#!/usr/bin/env python3
"""Questions for Michael reach him as the questions page or a clean card (ADR-0011, INV-26).

    PreToolUse AskUserQuestion (Claude): deny a card whose text carries agent-internal labels
        (rule ids, file paths, code names) or points at a picture the card can't show. The reason
        tells the model what to rewrite. `ask.py allow --reason ...` lets the next card through
        (within 15 minutes); a third denial in a row within 10 minutes is let through and logged,
        so a false positive can't loop.
    Stop (Claude and Codex): when the turn's final reply ends in a list of open questions for
        him, block once so the agent moves them to the page or the card. Skipped when
        stop_hook_active, so it never blocks twice.

Silent in headless lanes (the hub's `claude -p`, SDK runs, `codex exec`, Codex subagents), where
nobody sees a page or card, and on a machine with ~/.config/dotfiles/ask-guard-off (sync keeps
the registration; this keeps it quiet). Fails open: bad input, a missing checker or any error
prints nothing and exits 0. Python 3.9 standard library only.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

OVERRIDE_TTL = 15 * 60
DENY_WINDOW = 10 * 60
DENY_LIMIT = 2  # the third denial in a row is let through


def _load_lint():
    here = Path(__file__).resolve()
    for root in (here.parents[2], Path(os.environ.get("DOTFILES_DIR") or Path.home() / ".dotfiles")):
        tools = root / "tools" / "ask"
        if (tools / "asklint.py").is_file():
            sys.path.insert(0, str(tools))
            import asklint  # noqa: PLC0415
            return asklint
    return None


def quiet_lane() -> bool:
    """Headless: an SDK entrypoint, or a `claude -p` nested in a session (it inherits the session's
    environment, so read the nearest claude ancestor's arguments, as context-card.py does).
    ASK_GUARD_PRINT_MODE=1/0 overrides (fixtures)."""
    if os.environ.get("CLAUDE_CODE_ENTRYPOINT", "").startswith("sdk"):
        return True
    forced = os.environ.get("ASK_GUARD_PRINT_MODE")
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


def switched_off() -> bool:
    return (Path.home() / ".config" / "dotfiles" / "ask-guard-off").exists()


def codex_headless(data: dict) -> bool:
    """A Codex Stop (it carries last_assistant_message) from `codex exec` or a Codex subagent:
    only rollouts Michael types into (session_meta source cli or vscode) count, as context-card.py."""
    if "last_assistant_message" not in data:
        return False
    try:
        with open(str(data.get("transcript_path") or ""), "rb") as handle:
            first = json.loads(handle.readline().decode("utf-8", "replace"))
    except (OSError, ValueError):
        return True
    source = (first.get("payload") or {}).get("source") if isinstance(first, dict) else None
    return source not in ("cli", "vscode")


def _ask_home() -> Path:
    return Path(os.environ.get("ASK_HOME") or Path.home() / ".cache" / "ask")


def _session_key(session: str) -> str:
    return hashlib.sha256(session.encode("utf-8")).hexdigest()[:16]


def _log(entry: dict) -> None:
    try:
        _ask_home().mkdir(parents=True, exist_ok=True)
        with open(_ask_home() / "overrides.log", "a", encoding="utf-8") as log:
            log.write(json.dumps({**entry, "at": time.time()}) + "\n")
    except OSError:
        pass


def card_problems(tool_input: dict) -> list[tuple[str, str]]:
    """(where, problem) pairs for an AskUserQuestion call; empty when the card is fine."""
    lint = _load_lint()
    if lint is None:
        return []
    problems: list[tuple[str, str]] = []
    for qi, q in enumerate(tool_input.get("questions") or [], 1):
        if not isinstance(q, dict):
            continue
        texts = [(f"question {qi}", str(q.get("question") or "")), (f"question {qi} chip", str(q.get("header") or ""))]
        for oi, o in enumerate(q.get("options") or []):
            if isinstance(o, dict):
                where = f"question {qi}, option {chr(65 + oi)}"
                texts += [(where, str(o.get("label") or "")), (where, str(o.get("description") or ""))]
        for where, text in texts:
            problems += [(where, p) for p in lint.label_problems(text) + lint.visual_problems(text)]
    return problems


def _consume_override(session: str) -> bool:
    """One audited `ask.py allow` lets the next flagged card through, if it is fresh."""
    if not session:
        return False
    marker = _ask_home() / f"allow-{_session_key(session)}.json"
    try:
        at = float(json.loads(marker.read_text(encoding="utf-8")).get("at") or 0)
        marker.unlink()
    except (OSError, ValueError, AttributeError):
        return False
    return time.time() - at <= OVERRIDE_TTL


def _deny_streak(session: str, denied: bool) -> int:
    """Denials in a row for this session within DENY_WINDOW; reset by any card that passes."""
    path = _ask_home() / f"denies-{_session_key(session or 'none')}.json"
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
        count = int(state.get("count", 0)) if time.time() - float(state.get("at", 0)) <= DENY_WINDOW else 0
    except (OSError, ValueError, AttributeError):
        count = 0
    count = count + 1 if denied else 0
    try:
        _ask_home().mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"count": count, "at": time.time()}), encoding="utf-8")
    except OSError:
        pass
    return count


def pre_tool_use(data: dict) -> dict | None:
    if data.get("tool_name") != "AskUserQuestion":
        return None
    session = str(data.get("session_id") or "")
    problems = card_problems(data.get("tool_input") or {})
    if not problems or _consume_override(session):
        _deny_streak(session, denied=False)
        return None
    if _deny_streak(session, denied=True) > DENY_LIMIT:
        _deny_streak(session, denied=False)
        _log({"session": _session_key(session), "reason": "let through after repeated denials",
              "problems": [p for _w, p in problems]})
        return None
    lint = _load_lint()
    reason = ("Michael reads this card cold, without this session's context. Fix: " + lint.describe(problems)
              + ". Say what each label means in plain words. A question that needs a picture goes on the questions page"
              " (global rule questions.md). If he truly needs a label itself, run `ask.py allow --reason ...` first.")
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}}


# ---- Stop ---------------------------------------------------------------------------------

_FENCE = re.compile(r"(```|~~~).*?(?:\1|\Z)", re.DOTALL)
_NONE = re.compile(r"^(?:none|nothing|n/a|no open questions?)\b", re.IGNORECASE)
_ITEM = re.compile(r"^\s*(?:[-*+•]|\d+[.)]|[A-Za-z][.)])\s+")
_HEADING = re.compile(
    r"needs? (?:your|his|michael'?s) (?:decision|input|answer|call)s?|questions? for (?:you|michael)|open questions"
    r"|waiting on (?:you|michael|him)|decisions? (?:needed|for you)|for you to (?:decide|answer|pick)"
    r"|what i need from you|your call",
    re.IGNORECASE,
)


def final_reply(data: dict) -> str:
    """The text of the turn's last reply: Codex passes it; Claude's comes from the transcript tail."""
    if isinstance(data.get("last_assistant_message"), str):
        return data["last_assistant_message"]
    path = data.get("transcript_path")
    if not path:
        return ""
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        handle.seek(max(0, handle.tell() - 512 * 1024))
        lines = handle.read().decode("utf-8", "replace").splitlines()
    texts: list[str] = []
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("isSidechain"):
            continue
        kind = entry.get("type")
        if kind == "user":
            break
        if kind != "assistant":
            continue
        content = (entry.get("message") or {}).get("content")
        blocks = content if isinstance(content, list) else [{"type": "text", "text": content or ""}]
        if any(isinstance(b, dict) and b.get("type") == "tool_use" for b in blocks):
            break
        texts.extend(b.get("text", "") for b in reversed(blocks) if isinstance(b, dict) and b.get("type") == "text")
    return "\n".join(reversed(texts))


def _is_question(line: str) -> bool:
    return line.rstrip("*_ ").endswith("?")


def ends_in_question_list(text: str) -> bool:
    lines = [ln.strip() for ln in _FENCE.sub("", text).splitlines() if ln.strip()]
    tail = lines[-15:]
    # An open question is a question line not followed by its answer (a plain line that is
    # neither a list item nor another question): "1. **Does it run on Windows?**" then "Yes, ..."
    # is a Q&A, not something waiting on him.
    open_items = [ln for i, ln in enumerate(tail) if _is_question(ln) and _ITEM.match(ln)
                  and not (i + 1 < len(tail) and not _ITEM.match(tail[i + 1]) and not _is_question(tail[i + 1]))]
    if len(open_items) >= 2:
        return True
    for index, line in enumerate(tail):
        heading = line.startswith("#") or line.startswith("**") or line.endswith(":")
        items = [ln for ln in tail[index + 1:] if _ITEM.match(ln)]
        if heading and not _ITEM.match(line) and len(line) < 80 and _HEADING.search(line) \
                and any(not _NONE.match(_ITEM.sub("", ln).strip("*_ ")) for ln in items):
            return True
    return False


def stop(data: dict) -> dict | None:
    if data.get("stop_hook_active") or not ends_in_question_list(final_reply(data)):
        return None
    return {"decision": "block", "reason": (
        "Your reply ends with questions for Michael as a list. Keep the report, but move what's waiting on him "
        "(global rule questions.md): approvals to publish or do anything irreversible go in the question card, "
        "never the page; other questions go on the questions page while you have work left, or in the card if "
        "nothing more can be done without them and no picture is needed. Commands he must run stay as bash "
        "blocks. If these aren't open questions for him, end the turn as is.")}


def main() -> int:
    data = json.load(sys.stdin)
    if not isinstance(data, dict):
        return 0
    event = data.get("hook_event_name")
    if switched_off() or codex_headless(data) or quiet_lane():
        return 0
    result = pre_tool_use(data) if event == "PreToolUse" else stop(data) if event == "Stop" else None
    if result:
        print(json.dumps(result))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
