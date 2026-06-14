#!/usr/bin/env python3
"""P0 content scanner for the agent-skills sync gate.

Reads the ADDED lines of a git diff on stdin (lines may keep their leading '+').
Prints a short, semicolon-joined reason string ending in '| ' if ANY risk signal
is found, and nothing at all if the content is clean. A non-empty result forces
human review regardless of any LLM verdict. Bias is toward flagging: a false
flag costs a glance; a false pass auto-merges into every future AI session.
"""
import re
import sys

# Force UTF-8 stdin so hidden-unicode detection is reliable on Windows too
# (Python's default stdin encoding there is the locale codepage, e.g. cp1252).
try:
    sys.stdin.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

raw = sys.stdin.read()
# Strip a single leading '+' (diff add marker) from each line.
body = "\n".join(l[1:] if l.startswith("+") else l for l in raw.splitlines())

reasons = []

net_exec = re.compile(
    r"(curl|wget|fetch\s*\(|https?://|ftp://|/dev/tcp/|\bnc\b|ncat|\bssh\b|\bscp\b|"
    r"rsync|\beval\b|exec\s*\(|base64|atob\s*\(|os\.system|subprocess|child_process|"
    r"spawn\s*\(|Function\s*\(|require\s*\(|import\s+os|popen|launchctl|crontab|"
    r"\bsudo\b|chmod\s|rm\s+-rf)", re.I)
secrets = re.compile(
    r"(\.ssh|id_rsa|id_ed25519|\.env\b|keychain|security\s+find-|nexus\.db|_api_key|"
    r"\banthropic\b|\bopenai\b|aws_secret|aws_access|authorization:\s*bearer)", re.I)
inject = re.compile(
    r"(ignore (all |the )?(above|previous)|disregard (the|all|previous|above)|"
    r"you are now|new system prompt|</?system>|begin system|VERDICT:\s*SAFE)", re.I)

if net_exec.search(body):
    reasons.append("network/exec/obfuscation token")
if secrets.search(body):
    reasons.append("credential or secret-path reference")
if inject.search(body):
    reasons.append("possible prompt-injection text")

# Hidden / dangerous unicode: bidi overrides, isolates, zero-width, BOM.
bad = set()
for ch in body:
    o = ord(ch)
    if (0x202A <= o <= 0x202E) or (0x2066 <= o <= 0x2069) or o in (0x200B, 0x200C, 0x200D, 0xFEFF):
        bad.add(hex(o))
if bad:
    reasons.append("hidden/bidi unicode " + ",".join(sorted(bad)[:5]))

if reasons:
    sys.stdout.write("; ".join(reasons) + "| ")
