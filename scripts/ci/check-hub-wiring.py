#!/usr/bin/env python3
"""check-hub-wiring.py  -  INV-4 + INV-5 enforcers: hub MCP wiring discipline.

Generalized from check-courier-wiring.py (remote-hubs Phase A): the same two rules that guarded
courier now guard EVERY managed MCP hub (nexus/courier/docgen/calendar; future http hubs join via
hubs.json), so a new hub cannot silently skip the discipline.

INV-4 (no inlined token): a hub's bearer is NEVER inlined into agent wiring. Every
      `Authorization: Bearer <X>` in the script set must reference an ENV VAR - either the
      per-hub `${<HUB>_BEARER}` or the manifest's generic `${$token_env}` indirection - never a
      literal token (which would reach argv / a CLI's stored config). DISTINCT from INV-1
      (secret-scan over the git tree): the token legitimately lives OUTSIDE git
      (`~/.config/<hub>/auth-token`), so the secret scanner never sees the wiring risk - this gate does.

INV-5 (per-role via the shared fn): a hub's host-vs-client decision and EVERY hub `mcp add` live
      ONCE in `manifest.{sh,ps1}` (register_hub_mcp / register_all_hub_mcp / Register-HubMcp /
      Register-AllHubMcp). No setup/sync script may wire a hub directly. This encodes the blocking
      regression the ADR-0002 review caught: `sync` owned a duplicate stdio courier add that
      silently clobbered the http client wiring on every run.

COVERAGE gate (not POINT): scans the whole script set over the FULL hub-name set (managed stdio
servers + the http hubs in hubs.json), so a NEW hub `mcp add` on any surface is caught.

Exit 0: clean.  Exit 1: a violation.  Exit 2: fail-closed (internal error).

Escape hatch (audited override): append `# hub-wiring-allow` to a line to exempt it.
"""
import json
import os
import re
import subprocess
import sys

ALLOW = "hub-wiring-allow"
# INV-4 scans the full set (the allowed bearer refs live in manifest now).
ALL_SCRIPTS = ["manifest.sh", "manifest.ps1", "setup.sh", "setup.ps1", "sync.sh", "sync.ps1"]
# INV-5 scans the setup/sync subset - manifest is the ONE allowed home for a hub add.
WIRING_SCRIPTS = ["setup.sh", "setup.ps1", "sync.sh", "sync.ps1"]
# Managed local-stdio-ONLY servers (always wired host-stdio by register_all_hub_mcp, never
# http-served, so not in hubs.json). The http-served, role-aware hubs (courier, calendar) come from
# hubs.json and are UNIONed in at runtime - calendar joined them in remote-hubs Phase C.
MANAGED_STDIO = ["nexus", "docgen"]
# The manifest's generic indirection variable, always an allowed bearer reference.
GENERIC_TOKEN_REF = "${$token_env}"

_BEARER_RE = re.compile(r"Authorization:\s*Bearer\s+(\S+)")
_ADD_RE = re.compile(r"\bmcp\s+add\b")
# An env-var reference: ${VAR} or ${$var} (the generic indirection) - NEVER a literal token.
_ENVREF_RE = re.compile(r"^\$\{\$?[A-Za-z_][A-Za-z0-9_]*\}$")


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


def http_hub_names(root):
    """HTTP-served hubs from the hubs.json registry (the same file the host bootstrap reads).

    FAIL CLOSED on both a MISSING and an unparseable registry (caller -> exit 2). hubs.json is a
    required tracked file post-Phase-A; a missing one in CI / a fresh clone would silently strip
    courier from the hub set and pass green - the exact gap that let the untracked-registry blocker
    hide. (Treat absent like a missing manifest.sh: a hard error, never a silent degrade.)
    """
    path = os.path.join(root, "hubs.json")
    if not os.path.exists(path):
        raise FileNotFoundError(
            f"hubs.json registry missing at {path} - it is a required tracked file "
            "(stage/commit it). Refusing to run with courier silently dropped from coverage."
        )
    with open(path, encoding="utf-8") as f:
        data = json.load(f)  # JSONDecodeError -> caller turns it into exit 2
    return [h["name"] for h in data]


# --host scan targets: the GENERATED per-CLI configs that carry the materialized MCP wiring. These are
# machine-local (NOT in git), so neither the script-set scan below nor the CI secret-scan ever sees a
# literal token here - this is the host-side complement to INV-4.
GENERATED_CONFIGS = ["~/.gemini/settings.json", "~/.claude.json", "~/.codex/config.toml"]


def host_scan():
    """Host-side INV-4 complement: detect a LITERAL bearer materialized into a generated agent config.

    gemini materializes the ${<HUB>_BEARER} reference into ~/.gemini/settings.json at add-time on
    WSL/Linux (the real token lands at-rest in plaintext); claude/codex store the reference. The wiring
    (register_hub_mcp / Register-HubMcp) re-locks the gemini file 0600, but a materialized token still
    needs ROTATION. This scan flags any literal (redacted) + any loose perms. Detection only - the
    wiring owns the chmod. Host-side: configs are not in git, so this is NOT a CI gate.
    """
    import stat
    literals, loose = [], []
    for cfg in GENERATED_CONFIGS:
        path = os.path.expanduser(cfg)
        if not os.path.exists(path):
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in _BEARER_RE.finditer(text):
            tok = m.group(1).lstrip("\\`\"'").rstrip("\\`\"',")
            if not _ENVREF_RE.match(tok) and len(tok) >= 8:
                red = (tok[:3] + "..." + tok[-2:]) if len(tok) > 6 else "..."
                literals.append((cfg, red))
        if cfg.endswith("settings.json") and os.name == "posix":
            mode = stat.S_IMODE(os.stat(path).st_mode)
            if mode & 0o077:
                loose.append((cfg, oct(mode)))
    for cfg, mode in loose:
        sys.stderr.write(f"check-hub-wiring --host: {cfg} is {mode} (group/world-accessible) - re-run setup to re-lock 0600\n")
    if literals:
        sys.stderr.write("\nHUB BEARER EXPOSURE (a generated config holds a LITERAL token):\n")
        for cfg, red in literals:
            sys.stderr.write(f"  {cfg}: Authorization: Bearer {red}\n")
        sys.stderr.write(
            "\nA CLI materialized the bearer into its stored config (gemini does this on WSL/Linux).\n"
            "ROTATE the token: delete ~/.config/<hub>/auth-token on the host, re-run the host bootstrap\n"
            "to mint a new one, then re-run setup on each client to re-paste. (Host-side check; the\n"
            "configs are machine-local, not in git, so this never runs in CI.)\n")
        return 1
    print("check-hub-wiring --host OK - no literal bearer in the generated agent configs.")
    return 0


def main():
    if "--host" in sys.argv:
        return host_scan()

    root = repo_root()
    if not root:
        sys.stderr.write("check-hub-wiring: not a git repo - failing closed\n")
        return 2

    try:
        http_hubs = http_hub_names(root)
    except Exception as e:
        sys.stderr.write(f"check-hub-wiring: hubs.json unreadable/unparseable ({e}) - failing closed\n")
        return 2

    all_hubs = sorted(set(MANAGED_STDIO) | set(http_hubs))
    allowed_bearers = {GENERIC_TOKEN_REF} | {"${%s_BEARER}" % h.upper() for h in http_hubs}
    hub_name_re = re.compile(r"\b(%s)\b" % "|".join(re.escape(h) for h in all_hubs))

    violations = []

    # INV-4: every `Authorization: Bearer <X>` must be an env-var reference, not a literal token.
    for fname in ALL_SCRIPTS:
        lines = read_lines(root, fname)
        if lines is None:
            continue
        for i, line in enumerate(lines, 1):
            if ALLOW in line:
                continue
            for m in _BEARER_RE.finditer(line):
                tok = m.group(1).lstrip("\\`").rstrip('"').rstrip("'")
                if tok not in allowed_bearers and not _ENVREF_RE.match(tok):
                    violations.append(("INV-4", fname, i,
                        f"hub bearer is not an env-var reference: '{m.group(1)}'"))

    # INV-5: no hub `mcp add` outside manifest's shared register function.
    for fname in WIRING_SCRIPTS:
        lines = read_lines(root, fname)
        if lines is None:
            continue
        for i, line in enumerate(lines, 1):
            if ALLOW in line:
                continue
            if _ADD_RE.search(line) and hub_name_re.search(line):
                violations.append(("INV-5", fname, i,
                    "hub wired directly - must go through register_hub_mcp / register_all_hub_mcp (manifest)"))

    print(f"check-hub-wiring: scanned {len(ALL_SCRIPTS)} script(s) for INV-4 + INV-5 "
          f"over hubs {all_hubs} (http: {http_hubs})")
    if violations:
        sys.stderr.write("\nHUB WIRING VIOLATION:\n\n")
        for inv, fname, ln, msg in violations:
            sys.stderr.write(f"  [{inv}] {fname}:{ln}  {msg}\n")
        sys.stderr.write(
            "\nFix: wire hubs ONLY via register_hub_mcp / register_all_hub_mcp (manifest.sh) and\n"
            "Register-HubMcp / Register-AllHubMcp (manifest.ps1), and reference the token as an env\n"
            "var (${<HUB>_BEARER}) - never a literal token. An audited exception may append\n"
            "'# hub-wiring-allow' to the line.\n")
        return 1

    print("check-hub-wiring OK - INV-4 (no inlined token) + INV-5 (per-role via shared fn) hold for all hubs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
