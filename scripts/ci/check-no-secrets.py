#!/usr/bin/env python3
"""check-no-secrets.py  -  INV-1 enforcer: no live credentials in the tracked tree.

Guards the highest-stakes cross-cutting invariant: OAuth secrets, refresh/access
tokens, API keys, app passwords, private keys, keychain exports, and .env values must
never become tracked git content - across every MCP server (EA) or every paired script
(dotfiles). It is the ENFORCER; the .gitignore patterns are the advisor.

This is a VALUE-shaped scanner (it matches actual key material / token shapes), NOT a
mention scanner. It deliberately does NOT reuse dotfiles/skills-scan.py's `secrets`
regex: that one flags any *reference* (the word "openai", "nexus.db") because its job is
to triage untrusted upstream diffs. Here the job is "is this an actual live secret,"
so the bar is the secret's own shape - otherwise the intentionally-tracked nexus.db
would trip it on every commit.

Auto-detects per-repo surfaces:
  - if  nexus/nexus.db  exists: open it READ-ONLY and assert it carries DATA, not
    CREDENTIALS (no secret-named table/column; no key material in TEXT values).
  - if  ssh/config.template  exists (dotfiles): a tracked  ssh/config  (the populated,
    non-template copy) is itself a finding.

Modes:
  (default)   full scan of every tracked file (git ls-files). For CI. Fails CLOSED
              (exit 2) if git is unavailable or zero files are scanned - never passes
              vacuously.
  --staged    scan only files staged for commit. For the pre-commit hook. Zero staged
              files is a clean no-op (exit 0).

Escape hatch: .secret-scan-allowlist.txt at the repo root - one reviewed substring or
path per line (# comments allowed). A hit whose file path OR matched line contains an
allowlist entry is suppressed. The allowlist file itself is never scanned.

Exit 0: clean.  Exit 1: a secret was found (actionable list).  Exit 2: fail-closed
(git missing, nothing scanned, or an internal error).
"""
import os
import re
import subprocess
import sys


def repo_root():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except Exception:
        return None


# --- VALUE-shaped credential patterns (high signal, low false-positive) ----------
# Each is (name, compiled regex). Designed so this file's own pattern SOURCE does not
# self-match (the bracketed character classes are not themselves valid secrets).
CONTENT_PATTERNS = [
    ("private key block", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----")),
    ("AWS access key id", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("AWS secret access key", re.compile(r"aws_secret_access_key\s*[=:]\s*['\"]?[A-Za-z0-9/+]{40}")),
    ("Slack token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{10,}")),
    ("GitHub token", re.compile(r"\bgh[pousr]_[0-9A-Za-z]{36,}")),
    ("Anthropic key", re.compile(r"\bsk-ant-[0-9A-Za-z_-]{20,}")),
    ("OpenAI key", re.compile(r"\bsk-(?:proj-)?[0-9A-Za-z]{20,}")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("Google OAuth client secret", re.compile(r"\bGOCSPX-[0-9A-Za-z_-]{20,}")),
    ("JWT", re.compile(r"\beyJ[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}")),
    ("generic token assignment",
     re.compile(r"(?i)(refresh_token|access_token|client_secret|api[_-]?key|app[_-]?password)"
                r"\s*[:=]\s*['\"][^'\"]{16,}['\"]")),
]

# Tracked PATHS that are themselves secrets (basename match unless noted).
FILENAME_PATTERNS = [
    re.compile(r"(^|/)id_(rsa|ed25519|ecdsa|dsa)$"),   # private keys (NOT *.pub)
    re.compile(r"\.pem$"), re.compile(r"\.key$"), re.compile(r"\.ppk$"),
    re.compile(r"\.p12$"), re.compile(r"\.pfx$"),
    re.compile(r"(^|/)credentials\.json$"),
    re.compile(r"(^|/)client_secret.*\.json$"),
    re.compile(r"(^|/)token\.json$"), re.compile(r"\.token\.json$"),
    re.compile(r"(^|/)service[-_]account.*\.json$"),
]
# .env is a finding UNLESS it's an example/template.
ENV_RE = re.compile(r"(^|/)\.env(\.[A-Za-z0-9]+)?$")
ENV_OK = re.compile(r"\.(example|sample|template|dist)$")

FORBIDDEN_DB_NAME = re.compile(r"(?i)(credential|secret|password|oauth|refresh_token|access_token|api[_-]?key)")
# For nexus.db TEXT values: only the unambiguous shapes (PII like notes must NOT trip).
DB_VALUE_PATTERNS = [p for (n, p) in CONTENT_PATTERNS
                     if n in ("private key block", "Slack token", "GitHub token",
                              "Anthropic key", "OpenAI key", "Google OAuth client secret", "JWT")]

SQLITE_REL = os.path.join("nexus", "nexus.db")
ALLOWLIST_REL = ".secret-scan-allowlist.txt"
SELF_REL = os.path.join("scripts", "ci", "check-no-secrets.py")


def load_allowlist(root):
    path = os.path.join(root, ALLOWLIST_REL)
    entries = []
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                s = line.strip()
                if s and not s.startswith("#"):
                    entries.append(s)
    return entries


def allowed(rel, line, allowlist):
    return any(a in rel or a in line for a in allowlist)


def is_binary(data):
    return b"\x00" in data[:8192]


def tracked_files(root, staged):
    if staged:
        cmd = ["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"]
    else:
        cmd = ["git", "ls-files"]
    out = subprocess.run(cmd, cwd=root, capture_output=True, text=True, check=True)
    return [f for f in out.stdout.splitlines() if f]


def scan_file(root, rel, allowlist, findings):
    abspath = os.path.join(root, rel)
    base = rel.replace("\\", "/")
    # Filename-based findings.
    if any(p.search(base) for p in FILENAME_PATTERNS) or (ENV_RE.search(base) and not ENV_OK.search(base)):
        if not allowed(base, "", allowlist):
            findings.append((base, 0, "secret-bearing filename"))
    # SSH template rule (dotfiles): a populated ssh/config (not the template) is a finding.
    if base == "ssh/config" and not allowed(base, "", allowlist):
        findings.append((base, 0, "populated ssh/config tracked (commit ssh/config.template only)"))
    # Content scan (skip binaries and the allowlist/self files).
    if base in (ALLOWLIST_REL,):
        return
    try:
        with open(abspath, "rb") as f:
            data = f.read()
    except (OSError, FileNotFoundError):
        return
    if is_binary(data):
        return
    text = data.decode("utf-8", errors="replace")
    for i, line in enumerate(text.splitlines(), 1):
        for name, pat in CONTENT_PATTERNS:
            if pat.search(line) and not allowed(base, line, allowlist):
                findings.append((base, i, name))


def scan_sqlite(root, findings):
    import sqlite3
    db = os.path.join(root, SQLITE_REL)
    uri = "file:" + db.replace("\\", "/") + "?mode=ro"
    try:
        con = sqlite3.connect(uri, uri=True)
    except Exception as e:
        # Fail closed: we were asked to vet the DB and could not.
        findings.append((SQLITE_REL, 0, f"could not open read-only for vetting ({e})"))
        return
    try:
        cur = con.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = [r[0] for r in cur.fetchall()]
        for t in tables:
            if FORBIDDEN_DB_NAME.search(t):
                findings.append((SQLITE_REL, 0, f"secret-named table '{t}'"))
            try:
                cur.execute(f"PRAGMA table_info('{t}')")
                cols = [r[1] for r in cur.fetchall()]
            except Exception:
                cols = []
            for c in cols:
                if FORBIDDEN_DB_NAME.search(c):
                    findings.append((SQLITE_REL, 0, f"secret-named column '{t}.{c}'"))
            # Scan TEXT values for unambiguous key material only.
            text_cols = [c for c in cols]
            if not text_cols:
                continue
            try:
                collist = ", ".join('"' + c + '"' for c in text_cols)
                cur.execute(f"SELECT {collist} FROM '{t}'")
                for row in cur.fetchall():
                    for val in row:
                        if isinstance(val, str):
                            for pat in DB_VALUE_PATTERNS:
                                if pat.search(val):
                                    findings.append((SQLITE_REL, 0, f"key material in table '{t}'"))
            except Exception:
                continue
    finally:
        con.close()


def main():
    staged = "--staged" in sys.argv[1:]
    root = repo_root()
    if not root:
        sys.stderr.write("check-no-secrets: not a git repo / git unavailable - failing closed\n")
        return 2
    allowlist = load_allowlist(root)
    findings = []
    try:
        files = tracked_files(root, staged)
    except Exception as e:
        sys.stderr.write(f"check-no-secrets: git listing failed ({e}) - failing closed\n")
        return 2

    if not staged and not files:
        sys.stderr.write("check-no-secrets: zero tracked files - refusing to pass vacuously\n")
        return 2

    for rel in files:
        if rel.replace("\\", "/") == SQLITE_REL.replace("\\", "/"):
            continue  # handled by scan_sqlite
        scan_file(root, rel, allowlist, findings)

    # nexus.db: in full mode always vet if present; in staged mode only if staged.
    db_present = os.path.exists(os.path.join(root, SQLITE_REL))
    db_relevant = db_present and (not staged or SQLITE_REL.replace("\\", "/") in
                                  [f.replace("\\", "/") for f in files])
    if db_relevant:
        print(f"check-no-secrets: vetting {SQLITE_REL} read-only (data-not-credentials)")
        scan_sqlite(root, findings)

    scanned = len(files) + (1 if db_relevant else 0)
    print(f"check-no-secrets: scanned {scanned} path(s), {len(CONTENT_PATTERNS)} value pattern(s)"
          + (" [staged]" if staged else " [full]"))

    if not findings:
        print("check-no-secrets OK - no live credential material in the tracked tree.")
        return 0

    sys.stderr.write("\nPOSSIBLE SECRET(S) IN THE TRACKED TREE:\n\n")
    for rel, ln, what in findings:
        loc = f"{rel}:{ln}" if ln else rel
        sys.stderr.write(f"  {loc}\n      {what}\n")
    sys.stderr.write(
        "\nRemove the secret (and rotate it), or - if this is a confirmed false positive -\n"
        f"add a reviewed substring/path to {ALLOWLIST_REL} with a justification.\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
