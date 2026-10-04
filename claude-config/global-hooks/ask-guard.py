#!/usr/bin/env python3
"""Questions for Michael reach him as the questions page or a clean card (ADR-0011, INV-26).

    PreToolUse AskUserQuestion (Claude): deny a card whose text carries agent-internal labels
        (rule ids, file paths, code names) or promises a picture the card can't show. The reason
        tells the model what to rewrite. `ask.py allow --reason ...` lets the next card through.
    Stop (Claude and Codex): when the turn's final reply ends in a list of questions for him,
        block once so the agent moves them to the page or the card. Skipped when
        stop_hook_active, so it can never loop.

Silent in headless lanes (the hub's `claude -p`, SDK runs), where nobody sees a page or card.
Fails open: bad input, a missing checker or any error prints nothing and exits 0. Python 3.9
standard library only. `card_problems` is also used by agent-notify.py, so a card this hook
denies never sends the "waiting on you" email.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


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


def _ask_home() -> Path:
    return Path(os.environ.get("ASK_HOME") or Path.home() / ".cache" / "ask")


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
    if not session:
        return False
    marker = _ask_home() / f"allow-{hashlib.sha256(session.encode('utf-8')).hexdigest()[:16]}.json"
    try:
        marker.unlink()
        return True
    except OSError:
        return False


def pre_tool_use(data: dict) -> dict | None:
    if data.get("tool_name") != "AskUserQuestion":
        return None
    problems = card_problems(data.get("tool_input") or {})
    if not problems or _consume_override(str(data.get("session_id") or "")):
        return None
    lint = _load_lint()
    reason = ("Michael reads this card cold, without this session's context. Fix: " + lint.describe(problems)
              + ". Say what each label means in plain words. A question that needs a picture goes on the questions page"
              " (global rule questions.md). If he truly needs a label itself, run `ask.py allow --reason ...` first.")
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}}


# ---- Stop ---------------------------------------------------------------------------------

_FENCE = re.compile(r"```.*?(?:```|\Z)", re.DOTALL)
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


def ends_in_question_list(text: str) -> bool:
    lines = [ln.strip() for ln in _FENCE.sub("", text).splitlines() if ln.strip()]
    tail = lines[-15:]
    questions = [ln for ln in tail if ln.rstrip("*_ ").endswith("?")]
    if len(questions) >= 2 and any(_ITEM.match(ln) for ln in questions):
        return True
    for index, line in enumerate(tail):
        heading = line.startswith("#") or line.startswith("**") or line.endswith(":")
        if heading and not _ITEM.match(line) and len(line) < 80 and _HEADING.search(line) \
                and any(_ITEM.match(ln) for ln in tail[index + 1:]):
            return True
    return False


def stop(data: dict) -> dict | None:
    if data.get("stop_hook_active") or not ends_in_question_list(final_reply(data)):
        return None
    return {"decision": "block", "reason": (
        "Your reply ends with questions for Michael as a list. Keep the report, but move what's waiting on him "
        "to the questions page (global rule questions.md), or to the question card if nothing more can be done "
        "without the answers and no picture is needed. Commands he must run stay as bash blocks. If these "
        "aren't open questions for him, end the turn as is.")}


def main() -> int:
    data = json.load(sys.stdin)
    if not isinstance(data, dict):
        return 0
    event = data.get("hook_event_name")
    if quiet_lane():
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
