#!/usr/bin/env bash
# PreToolUse(Bash) guard: the journal is denied to file-reading tools; this closes the
# shell route to the same files.
#
# WHY IT EXISTS. Michael, 2026-09-05: "my journaling IS something I want locked away from
# any LLM. I would be okay with asking an LLM to add something write-only, but never read."
# The Read/Glob/Grep deny rules in settings.json enforce that for the file tools. They do
# nothing about Bash, because a Bash rule matches COMMAND TEXT and not a resolved path, so
# `cat /Volumes/Media/Journal/2015/.../entry.md` was still open inside his own sessions.
# That gap was written down as known and open for four days; this is it closed.
#
# IT DERIVES ITS PATHS FROM HIS OWN DENY RULES rather than hardcoding them. One place to
# maintain, and the hook cannot disagree with the tool rules it is backing up. Today that
# means three paths, all the same corpus: the journal root, the Day One library, and the
# export zips (which are the second copy of every imported entry).
#
# WHAT IT CANNOT DO, stated because a guard that overstates its reach is worse than one
# that names its gap: a command is text. This stops every ordinary way of naming those
# places. It does not stop a path built from a variable, reached through a symlink made
# earlier, or assembled at runtime. Closing THAT needs the read to be blocked at the
# filesystem, which is a different mechanism.
set -uo pipefail

input="$(cat)"
command -v python3 >/dev/null 2>&1 || exit 0

HOOK_INPUT="$input" python3 - <<'PY'
import json
import os
import re
from pathlib import Path

GLOB = re.compile(r"[*?\[]")
# The hub's own journal tools. They are BUILT to print counts, filenames and uuids and
# never a line of what he wrote, which is why naming one is a question rather than a
# refusal -- he runs these himself and they are the only sanctioned way to touch the root.
SANCTIONED = ("journal_import.py", "journal_reindex.py", "journal_unescape.py")
# Any of these and the sanctioned exception is off: one command that runs an approved
# script and then cats a file is not an approved script run.
CHAINING = (";", "&&", "||", "|", "`", "$(", "\n")


def decide(kind, reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": kind,
        "permissionDecisionReason": reason,
    }}))
    raise SystemExit(0)


try:
    payload = json.loads(os.environ["HOOK_INPUT"])
except Exception:
    # "I could not evaluate this" must not look like "this is fine". Ask, do not pass.
    decide("ask", "The journal read guard could not read the tool input, so it could not "
                  "check this command. Approve only if it does not read his journal.")

if payload.get("tool_name") != "Bash":
    raise SystemExit(0)
command = str(payload.get("tool_input", {}).get("command", ""))
if not command:
    raise SystemExit(0)

settings = Path.home() / ".claude" / "settings.json"
try:
    rules = json.loads(settings.read_text()).get("permissions", {}).get("deny", [])
except Exception:
    decide("ask", f"The journal read guard could not read {settings}, so it does not know "
                  "which paths are protected. Approve only if this reads nothing of his.")

protected = []
for rule in rules:
    if not (isinstance(rule, str) and rule.startswith("Read(")):
        continue
    raw = rule[len("Read("):].rstrip(")").lstrip("/")
    stem = GLOB.split("/" + raw)[0].rstrip("/")
    if len(stem) > 1:
        protected.append(stem)

hit = next((p for p in protected if p in command), None)
if hit is None:
    raise SystemExit(0)

if any(token in command for token in CHAINING):
    decide("deny", f"This command names {hit}, which is read-denied, and chains several "
                   "commands together. Run the journal script on its own if that is what "
                   "you meant.")
if any(script in command for script in SANCTIONED):
    decide("ask", f"This runs one of the hub's own journal scripts against {hit}. Those "
                  "print counts and filenames, never entry text. Approve only if Michael "
                  "asked for this run.")
decide("deny", f"This command reads {hit}. Michael's journal is denied to every model "
               "(INV-GALLOGRID-40); Read/Glob/Grep are blocked by settings.json and this "
               "closes the shell route to the same files. There is no agent-side override: "
               "if he wants something from it, he runs it himself.")
PY
exit 0
