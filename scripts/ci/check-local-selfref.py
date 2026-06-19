#!/usr/bin/env python3
"""check-local-selfref.py  -  INV-9 enforcer: no `local`/`declare`/`typeset` statement
references a variable assigned EARLIER in the SAME statement.

Under `set -u`, bash expands the RHS of every assignment in a single `local` statement BEFORE
the just-declared locals become visible, so a reference to an earlier same-statement local is
UNBOUND and the script aborts. This is the class of bug that crashed `sync` mid-regen on
2026-06-18 (sync.sh materialize_gemini_project_skill):

    local src="$1" dst="$2" namespaced="$3" marker="$dst/.dotfiles-skill-source"
                                             ^^^^^^^^ $dst is UNBOUND here under set -u

It aborted regen and everything after it, and silently broke gemini skill refresh. The fix is
always to split the dependent assignment onto its own `local` line. This gate makes that
mechanical so the crash class cannot return. CI + pre-commit can run it (it is a static scan of
the tracked scripts - no machine state needed), so unlike the `--machine` skill check it is a
real green-in-CI enforcer.

Scans every tracked *.sh file. Exit 0 clean, 1 violation, 2 fail-closed.
"""
import re
import subprocess
import sys

KEYWORD_RE = re.compile(r'\b(?:local|declare|typeset)\b')
REF_RE = re.compile(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)')


def repo_root():
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def tracked_sh(root):
    out = subprocess.run(["git", "ls-files", "*.sh"], cwd=root,
                         capture_output=True, text=True)
    return [l for l in out.stdout.splitlines() if l.strip()]


def split_top_level(s, seps=";"):
    """Split s on separator chars that are NOT inside single/double quotes."""
    out, buf, q = [], [], None
    for c in s:
        if q:
            buf.append(c)
            if c == q:
                q = None
        elif c in ("'", '"'):
            q = c
            buf.append(c)
        elif c in seps:
            out.append("".join(buf))
            buf = []
        else:
            buf.append(c)
    out.append("".join(buf))
    return out


def read_words(body):
    """Whitespace-separated words of a declaration body, respecting quotes (a quoted region
    may contain spaces and stays in one word)."""
    words, buf, q = [], [], None
    for c in body:
        if q:
            buf.append(c)
            if c == q:
                q = None
        elif c in ("'", '"'):
            q = c
            buf.append(c)
        elif c.isspace():
            if buf:
                words.append("".join(buf)); buf = []
        else:
            buf.append(c)
    if buf:
        words.append("".join(buf))
    return words


def check_decl(body):
    """body = text after a local/declare/typeset keyword (one statement). Return list of
    (declared_name, referenced_name) where referenced was declared earlier in the same stmt.
    A reference to an OUTER var of the same name (e.g. `local PATH="$PATH"`) is NOT flagged -
    the name is only considered 'assigned' AFTER its own value is checked, so a self-value
    reference resolves to the bound outer var, which is safe."""
    assigned = []
    violations = []
    for w in read_words(body):
        if w.startswith("-"):
            continue                                  # a flag: -r, -a, -g ...
        if "=" not in w:
            assigned.append(w)                        # bare `local name` (declared, unset)
            continue
        name, _, value = w.partition("=")             # split at FIRST '=' (value may contain '=')
        name = name.strip()
        for ref in REF_RE.findall(value):
            if ref in assigned and ref != name:
                violations.append((name, ref))
        if name:
            assigned.append(name)
    return violations


def scan(text):
    """Return list of (lineno, snippet, decl_name, ref_name) violations for one file's text."""
    out = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip().rstrip("\\")              # ignore a trailing line-continuation
        for piece in split_top_level(line):
            m = KEYWORD_RE.search(piece)
            if not m:
                continue
            for decl_name, ref_name in check_decl(piece[m.end():]):
                out.append((lineno, piece.strip(), decl_name, ref_name))
    return out


def main():
    root = repo_root()
    if not root:
        sys.stderr.write("check-local-selfref: not a git repo - failing closed\n")
        return 2
    files = tracked_sh(root)
    failures = []
    for rel in files:
        try:
            with open(f"{root}/{rel}", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            sys.stderr.write(f"check-local-selfref: cannot read {rel} ({e}) - failing closed\n")
            return 2
        for lineno, snippet, decl, ref in scan(text):
            failures.append((rel, lineno, decl, ref, snippet))

    print(f"check-local-selfref: scanned {len(files)} shell script(s)")
    if failures:
        sys.stderr.write(
            "\nLOCAL self-reference (UNBOUND under `set -u`) - split the dependent assignment "
            "onto its own `local` line:\n")
        for rel, lineno, decl, ref, snippet in failures:
            sys.stderr.write(f"  - {rel}:{lineno}  `{decl}` references ${ref} assigned earlier in "
                             f"the SAME local statement:\n      {snippet}\n")
        return 1
    print("check-local-selfref OK - no `local` references a same-statement variable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
