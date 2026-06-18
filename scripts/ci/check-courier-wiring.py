#!/usr/bin/env python3
"""check-courier-wiring.py  -  INV-4 + INV-5 enforcers: courier MCP wiring discipline.

INV-4 (no inlined token): the courier bearer is NEVER inlined into agent wiring. The only
      token reference allowed in a courier `mcp add` is the env-var reference
      `${COURIER_BEARER}` (claude/gemini `--header`/`-H`) or `--bearer-token-env-var
      COURIER_BEARER` (codex). A literal token must never reach argv or a CLI's stored
      config. This is DISTINCT from INV-1 (secret-scan over the git tree): the token
      legitimately lives OUTSIDE git in `~/.config/courier/auth-token`, so the secret
      scanner never sees the wiring risk - this gate does.

INV-5 (per-role via the shared fn): courier's host-vs-client decision and EVERY courier
      `mcp add` live ONCE in `manifest.{sh,ps1}`'s `register_courier_mcp` /
      `Register-CourierMcp`. No setup/sync script may wire courier directly. This encodes
      the blocking regression the review caught: `sync` owned a duplicate stdio courier
      add that silently clobbered the http client wiring on every run.

COVERAGE gate (not POINT): scans the whole script set, so a NEW courier `mcp add` on any
surface is caught - a new site cannot silently skip the rule.

Exit 0: clean.  Exit 1: a violation.  Exit 2: fail-closed (internal error).

Escape hatch (audited override): append `# courier-wiring-allow` to a line to exempt it.
"""
import os
import re
import subprocess
import sys

ALLOW = "courier-wiring-allow"
# INV-4 scans the full set (the allowed ${COURIER_BEARER} lines live in manifest now).
ALL_SCRIPTS = ["manifest.sh", "manifest.ps1", "setup.sh", "setup.ps1", "sync.sh", "sync.ps1"]
# INV-5 scans the setup/sync subset - manifest is the ONE allowed home for a courier add.
WIRING_SCRIPTS = ["setup.sh", "setup.ps1", "sync.sh", "sync.ps1"]
# The only permitted bearer value, after stripping a leading sh `\` or ps1 backtick escape.
ALLOWED_BEARER = "${COURIER_BEARER}"

_BEARER_RE = re.compile(r"Authorization:\s*Bearer\s+(\S+)")
_ADD_RE = re.compile(r"\bmcp\s+add\b")
_COURIER_RE = re.compile(r"\bcourier\b")


def repo_root():
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except Exception:
        return None


def read_lines(root, fname):
    path = os.path.join(root, fname)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def main():
    root = repo_root()
    if not root:
        sys.stderr.write("check-courier-wiring: not a git repo - failing closed\n")
        return 2

    violations = []

    # INV-4: every `Authorization: Bearer <X>` must have X == ${COURIER_BEARER}.
    for fname in ALL_SCRIPTS:
        lines = read_lines(root, fname)
        if lines is None:
            continue
        for i, line in enumerate(lines, 1):
            if ALLOW in line:
                continue
            for m in _BEARER_RE.finditer(line):
                tok = m.group(1).lstrip("\\`").rstrip('"').rstrip("'")
                if tok != ALLOWED_BEARER:
                    violations.append(("INV-4", fname, i,
                        f"courier bearer is not the ${{COURIER_BEARER}} env ref: '{m.group(1)}'"))

    # INV-5: no courier `mcp add` outside manifest's shared register function.
    for fname in WIRING_SCRIPTS:
        lines = read_lines(root, fname)
        if lines is None:
            continue
        for i, line in enumerate(lines, 1):
            if ALLOW in line:
                continue
            if _ADD_RE.search(line) and _COURIER_RE.search(line):
                violations.append(("INV-5", fname, i,
                    "courier wired directly - must go through register_courier_mcp (manifest)"))

    print(f"check-courier-wiring: scanned {len(ALL_SCRIPTS)} script(s) for INV-4 + INV-5")
    if violations:
        sys.stderr.write("\nCOURIER WIRING VIOLATION:\n\n")
        for inv, fname, ln, msg in violations:
            sys.stderr.write(f"  [{inv}] {fname}:{ln}  {msg}\n")
        sys.stderr.write(
            "\nFix: wire courier ONLY via register_courier_mcp / Register-CourierMcp (manifest),\n"
            "and reference the token as ${COURIER_BEARER} - never a literal token. An audited\n"
            "exception may append '# courier-wiring-allow' to the line.\n")
        return 1

    print("check-courier-wiring OK - INV-4 (no inlined token) + INV-5 (per-role via shared fn) hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
