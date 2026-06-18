#!/usr/bin/env python3
"""gen-agent-allowlist.py  --  AGENT-ALLOWLIST-MIRROR

Mirror Michael's Claude Code permission allowlist into codex and gemini so all three
auto-approve the same things. Run from sync.sh / sync.ps1 (one shared generator -> no
bash/PowerShell TOML+JSON duplication; parity is "both call this script").

Claude is the SOURCE OF TRUTH. We read every `permissions.allow` entry from the user
settings and each project's settings, then translate into each tool's NATIVE mechanism:

  - codex  (~/.codex/config.toml):   per-MCP-tool  [mcp_servers.<s>.tools.<t>] approval_mode = "approve"
  - gemini (~/.gemini/settings.json): per-MCP-SERVER mcpServers.<s>.trust = true,
                                      plus tools.allowed += run_shell_command(<prefix>)

HONEST GAPS (printed every run, never silently pretended):
  * codex has NO per-shell-command allowlist (it uses sandbox + approval policy), so
    Claude's `Bash(...)` allows are NOT mirrored to codex.
  * gemini trust is per-SERVER, not per-tool: allowing any one tool of a server trusts
    the whole server (broader than Claude's per-tool grant, but they are your own servers).
  * Only servers that already EXIST in each tool's config are touched (no phantom servers);
    Claude-hosted (claude_ai_*) and plugin_* servers are skipped where absent.

Idempotent: re-running adds only what's missing. Backs up each target to
<file>.allowlist-bak before writing. Additive only; never removes your existing config.
"""
import glob
import json
import os
import re
import shutil
import sys

HOME = os.path.expanduser("~")


# ── 1. Collect Claude allow entries (user + every project) ───────────────────
def claude_allow_entries():
    paths = [os.path.join(HOME, ".claude/settings.json")]
    paths += glob.glob(os.path.join(HOME, "Documents/*/.claude/settings.json"))
    paths += glob.glob(os.path.join(HOME, "Documents/*/.claude/settings.local.json"))
    seen = set()
    for p in paths:
        if not os.path.exists(p):
            continue
        try:
            with open(p, encoding="utf-8") as f:
                d = json.load(f)
        except Exception as e:
            sys.stderr.write(f"  ! allowlist: skipping unreadable {p} ({e})\n")
            continue
        for e in d.get("permissions", {}).get("allow", []):
            seen.add(e)
    return seen


def parse_entries(entries):
    """Return (mcp_tools{(server,tool)}, mcp_servers{server}, bash_prefixes{str}, web{str})."""
    mcp_tools, mcp_servers, bash_prefixes, web = set(), set(), set(), set()
    for e in sorted(entries):
        e = e.strip()
        if e.startswith("mcp__"):
            rest = e[len("mcp__"):]
            if "__" in rest:
                server, tool = rest.split("__", 1)
                if tool == "*":                 # mcp__server__* = whole-server allow
                    mcp_servers.add(server)
                else:
                    mcp_tools.add((server, tool))
            else:
                mcp_servers.add(rest)
        elif e.startswith("Bash(") and e.endswith(")"):
            pfx = _bash_prefix(e[len("Bash("):-1])
            if pfx:
                bash_prefixes.add(pfx)
        elif e == "WebSearch":
            web.add("google_web_search")
        elif e.startswith("WebFetch"):
            web.add("web_fetch")
    return mcp_tools, mcp_servers, bash_prefixes, web


def _bash_prefix(spec):
    """Claude Bash() spec -> a reusable command PREFIX, or None for one-off exact commands.
    `git:*`->git, `notmuch search *`->'notmuch search', `open *`->open, exact paths->None."""
    spec = spec.strip()
    if ":*" in spec:                       # claude colon-prefix form
        spec = spec.split(":", 1)[0]
    elif spec.endswith(" *"):
        spec = spec[:-2]
    elif spec.endswith("*"):
        spec = spec[:-1]
    else:
        return None                        # exact one-off (full path / specific args): skip
    spec = spec.strip()
    # Skip anything that isn't a clean, portable command prefix: absolute/home paths,
    # shell metachars, quotes - project one-offs with ~zero reuse value in another agent.
    if not spec or spec.startswith(("/", "~", '"', "'")):
        return None
    if any(c in spec for c in "\"'$|&;<>()`\\{}") or "/" in spec or "~" in spec:
        return None
    return spec


# ── 2. codex: per-MCP-tool approval_mode = "approve" ─────────────────────────
def _toml_key(k):
    """A bare TOML key if safe, else a quoted basic-string key (handles dots/spaces)."""
    if re.fullmatch(r"[A-Za-z0-9_-]+", k):
        return k
    return '"' + k.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _load_toml():
    """A TOML parser if one exists, else None. tomllib is 3.11+ stdlib, but some pythons
    (e.g. an older python3 on the Windows box) lack it - so this is optional, used only for
    the strict pre-write validation; detection below is regex-based and parser-free."""
    try:
        import tomllib
        return tomllib
    except ModuleNotFoundError:
        try:
            import tomli
            return tomli
        except ModuleNotFoundError:
            return None


def update_codex(mcp_tools, mcp_servers):
    path = os.path.join(HOME, ".codex/config.toml")
    if not os.path.exists(path):
        return "codex: no ~/.codex/config.toml - skipped", 0
    with open(path, encoding="utf-8") as f:
        original = f.read()
    # Detect present servers + already-approved tools by regex (no TOML parser required).
    # codex server/tool names here are simple bare keys, so this is reliable.
    present_servers = set(re.findall(r'(?m)^\[mcp_servers\.([A-Za-z0-9_-]+)\]\s*$', original))
    already = set(re.findall(r'(?m)^\[mcp_servers\.([A-Za-z0-9_-]+)\.tools\.([A-Za-z0-9_-]+)\]', original))
    # Tools to approve = explicit (server,tool) allows whose server exists in codex.
    want = {(s, t) for (s, t) in mcp_tools if s in present_servers}
    missing = sorted(want - already)
    if not missing:
        return f"codex: {len(want & already)} MCP tool approvals already present", 0
    block = "\n# --- auto-approved MCP tools (mirrored from Claude allowlist) ---\n"
    for s, t in missing:
        block += f'[mcp_servers.{_toml_key(s)}.tools.{_toml_key(t)}]\napproval_mode = "approve"\n'
    new_content = original + block
    # Strict pre-write validation IF a TOML parser is available - never leave a half-broken
    # config.toml. (A raise propagates to main()'s handler; the original file is untouched.)
    toml = _load_toml()
    if toml is not None:
        toml.loads(new_content)
    shutil.copy2(path, path + ".allowlist-bak")
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_content)
    note = "" if toml is not None else " (no tomllib: validation skipped)"
    return f"codex: +{len(missing)} MCP tool approvals{note} " + \
           ", ".join(f"{s}.{t}" for s, t in missing[:6]) + ("..." if len(missing) > 6 else ""), len(missing)


# ── 3. gemini: per-server trust + shell/web allowlist ────────────────────────
def update_gemini(mcp_tools, mcp_servers, bash_prefixes, web):
    path = os.path.join(HOME, ".gemini/settings.json")
    if not os.path.exists(path):
        return "gemini: no ~/.gemini/settings.json - skipped", 0
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    changed = 0
    servers_cfg = d.get("mcpServers", {})
    referenced = {s for (s, _t) in mcp_tools} | set(mcp_servers)
    for s in sorted(referenced):
        if s in servers_cfg and not servers_cfg[s].get("trust"):
            servers_cfg[s]["trust"] = True
            changed += 1
    # tools.allowed: run_shell_command(<prefix>) + web tools
    tools = d.setdefault("tools", {})
    allowed = tools.setdefault("allowed", [])
    allowset = set(allowed)
    for pfx in sorted(bash_prefixes):
        entry = f"run_shell_command({pfx})"
        if entry not in allowset:
            allowed.append(entry); allowset.add(entry); changed += 1
    for w in sorted(web):
        if w not in allowset:
            allowed.append(w); allowset.add(w); changed += 1
    if not changed:
        return "gemini: trust + allowlist already current", 0
    shutil.copy2(path, path + ".allowlist-bak")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    json.load(open(path, encoding="utf-8"))  # re-validate
    return f"gemini: +{changed} change(s) (server trust + {len(bash_prefixes)} shell prefixes)", changed


def main():
    entries = claude_allow_entries()
    if not entries:
        print("  ! allowlist: no Claude allow entries found - nothing to mirror")
        return 0
    mcp_tools, mcp_servers, bash_prefixes, web = parse_entries(entries)
    print(f"  allowlist source: {len(entries)} Claude allow entries "
          f"({len(mcp_tools)} mcp-tool, {len(mcp_servers)} mcp-server, {len(bash_prefixes)} bash-prefix)")
    for fn in (lambda: update_codex(mcp_tools, mcp_servers),
               lambda: update_gemini(mcp_tools, mcp_servers, bash_prefixes, web)):
        try:
            msg, _n = fn()
            print(f"  {msg}")
        except Exception as e:
            sys.stderr.write(f"  ! allowlist: {e}\n")
    # Honest gaps (never silent):
    skipped_codex_bash = len(bash_prefixes)
    if skipped_codex_bash:
        print(f"  note: codex has no per-command shell allowlist - {skipped_codex_bash} Bash() "
              "prefixes NOT mirrored to codex (it uses sandbox + approval policy).")
    print("  note: gemini trust is per-SERVER (allowing one tool trusts that whole server).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
