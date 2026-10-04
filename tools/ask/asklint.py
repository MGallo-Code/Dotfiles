"""Wording checks for questions to Michael, shared by ask.py (the questions page) and the
ask-guard hook (Claude's native card). ADR-0011.

A question has to make sense to someone who never saw the session, so agent-internal labels
are rejected: rule, decision and invariant ids, file paths and file names, code identifiers,
function calls and commit hashes. Links (URLs and bare domains) are his words too, so they are
left alone. Python 3.9 standard library only.
"""
from __future__ import annotations

import re

_LABELS = (
    (re.compile(r"\b(?:INV|ADR|PROC|UI|SOLO|APP|COMP|DESK|TOUCH|CHAT)-\d+\b"), "a rule or decision id"),
    (re.compile(r"(?:^|[\s(`'\"])(?:~|\.{1,2})?/[\w.-]+/[\w./-]*"), "a file path"),
    (re.compile(r"\b[A-Za-z]:\\[^\s`'\"]+|%\w+%\\[^\s`'\"]*"), "a file path"),
    (re.compile(r"\b[\w-]+/[\w.-]+\.[A-Za-z]{1,5}\b"), "a file path"),
    (re.compile(r"\b[\w-]+\.(?:py|sh|ps1|psm1|toml|json|ya?ml|md|tsx|jsx|css|html|sql|rs|go)\b"), "a file name"),
    (re.compile(r"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b"), "a code identifier"),
    (re.compile(r"\b[A-Za-z_][\w.]*\(\)"), "a function call"),
    (re.compile(r"\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b"), "a commit hash"),
)

_LINKS = re.compile(
    r"\b(?:https?|ftp)://\S+|\b(?:[\w-]+\.)+(?:com|org|net|io|dev|app|ai|co|us|uk|edu|gov|me|sh)\b(?:/\S*)?",
    re.IGNORECASE,
)

_TRIM = " (`'\""

# Phrases that promise a picture. The card can't show one, so these questions belong on the page.
# Bare "mock" or "image" are left alone ("mock the network", "Docker base image").
_VISUAL = re.compile(
    r"\b(?:screenshots?|mock-?ups?|(?:the|this|these|both|two|three|each|which) mocks?|pictures?"
    r"|(?:the|this|these) images? (?:above|below|on|in)|right(?:-hand)? (?:pane|panel)|side ?panel"
    r"|browser pane|preview pane|(?:shown|showing|open|opened) on the right)\b",
    re.IGNORECASE,
)


def _unlinked(text: str) -> str:
    return _LINKS.sub(lambda m: " " * len(m.group(0)), text or "")


def label_problems(text: str) -> list[str]:
    """Agent-internal labels in one piece of question text, as 'a file path: `x`' strings."""
    text = _unlinked(text)
    found: list[str] = []
    spans: list[tuple[int, int]] = []
    for pattern, kind in _LABELS:
        for match in pattern.finditer(text):
            start, end = match.span()
            if any(s <= start and end <= e for s, e in spans):
                continue  # part of a label already reported, e.g. the file name inside a path
            spans.append((start, end))
            item = f"{kind}: `{match.group(0).strip(_TRIM)}`"
            if item not in found:
                found.append(item)
    return found


def visual_problems(text: str) -> list[str]:
    return [f"a reference to a picture or pane: `{m.group(0)}`" for m in _VISUAL.finditer(text or "")]


def describe(problems: list[tuple[str, str]]) -> str:
    """One reason string for a list of (where, problem) pairs."""
    return "; ".join(f"{where} has {problem}" for where, problem in problems)
