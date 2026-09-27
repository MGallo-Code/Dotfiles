#!/usr/bin/env python3
"""gen-agent-commands.py  --  AGENT-COMMAND-MIRROR

Regenerate Codex copies of the tracked Claude slash-command `.md` files, so the same
commands are available in Claude and Codex.
Run from sync.sh / sync.ps1 (one shared generator -> no bash/PowerShell duplication of
the markdown transform; parity is "both call this script").

Claude `.md` is the SOURCE OF TRUTH (never written here). Per source command we emit
~/.codex/prompts/<name>.md (plain markdown body; $ARGUMENTS / $1..$9).

Gemini was retired as an interactive agent (ADR-0004): the TOML mirrors this script used to
write into ~/.gemini/commands are removed on every run (only files carrying our marker).

Sources + namespacing are passed as argv pairs "prefix:dir" (prefix "" = bare name,
"x" = x-<name>). Each generated file carries a provenance marker; on every run we
remove ONLY previously-generated files (by marker) that no longer have a source, so
renames/removals don't leave orphans. User-authored prompts (no marker) are never touched.
"""
import os
import re
import sys

HOME = os.path.expanduser("~")
MARKER = "generated-by: dotfiles gen-agent-commands"
CODEX_DIR = os.path.join(HOME, ".codex/prompts")
GEMINI_DIR = os.path.join(HOME, ".gemini/commands")


def strip_frontmatter(text):
    """Return (description, body). Pulls `description:` out of a leading --- YAML block."""
    desc = ""
    if text.startswith("---"):
        m = re.match(r"^---\s*\n(.*?)\n---\s*\n?", text, re.DOTALL)
        if m:
            fm, text = m.group(1), text[m.end():]
            dm = re.search(r'^description:\s*(.+?)\s*$', fm, re.MULTILINE)
            if dm:
                desc = dm.group(1).strip().strip('"').strip("'")
    return desc, text.lstrip("\n")


def emit(name, desc, body):
    os.makedirs(CODEX_DIR, exist_ok=True)
    # codex: markdown body, provenance in an HTML comment (codex shows the body verbatim).
    with open(os.path.join(CODEX_DIR, f"{name}.md"), "w", encoding="utf-8") as f:
        f.write(f"<!-- {MARKER} -->\n")
        if desc:
            f.write(f"<!-- {desc} -->\n")
        f.write(body if body.endswith("\n") else body + "\n")


def clean_orphans(keep, directory, ext):
    """Remove only files WE generated (marker present) whose name isn't in `keep`."""
    if not os.path.isdir(directory):
        return
    for fn in os.listdir(directory):
        if not fn.endswith(ext):
            continue
        name = fn[:-len(ext)]
        if name in keep:
            continue
        path = os.path.join(directory, fn)
        try:
            with open(path, encoding="utf-8") as f:
                head = f.read(200)
        except Exception:
            continue
        if MARKER in head:
            os.remove(path)
            print(f"  commands: removed orphan {fn}")


def iter_sources(argv):
    """Yield (name, dir, filename) for every source .md across the prefix:dir specs.
    Shared by generate + --verify so the name computation can never drift between them."""
    for spec in argv:
        prefix, _, d = spec.partition(":")
        d = os.path.expanduser(d)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".md"):
                continue
            base = fn[:-3]
            name = f"{prefix}-{base}" if prefix else base
            yield name, d, fn


# How each tool surfaces these generated files, for the discoverability index.
INDEX = {
    "codex":  ("Codex TUI",  "~/.codex/prompts",  "*.md",
               "Type `/` to list custom prompts, or run one by name, e.g. `/handoff`."),
}


def write_index(directory, names, kind):
    """Write a generated README.md (how to invoke + the command list) into a target dir.
    Solves the discoverability gap: the commands mirror fine, but the user can't tell HOW
    to invoke them in codex. Regenerated each run; protected from clean_orphans."""
    os.makedirs(directory, exist_ok=True)
    where, path, glob, how = INDEX[kind]
    lines = [
        f"<!-- {MARKER} -->",
        f"# {where} commands (generated from Claude slash-commands)",
        "",
        "Mirrors of Michael's Claude Code slash-commands, REGENERATED on every `sync` from",
        "the Claude `.md` sources - do not hand-edit (changes are overwritten). Source of",
        "truth: `EA/claude-config/global-commands`.",
        "",
        "## How to invoke",
        how,
        f"{where} loads every `{glob}` in `{path}/` as a command.",
        "",
        "## Available commands",
    ]
    lines += [f"- `/{n}`" for n in sorted(names)] or ["- (none)"]
    lines.append("")
    with open(os.path.join(directory, "README.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def retire_gemini_mirrors():
    """Remove the Gemini command mirrors and index this script used to generate."""
    clean_orphans(set(), GEMINI_DIR, ".toml")
    index = os.path.join(GEMINI_DIR, "README.md")
    try:
        with open(index, encoding="utf-8") as f:
            generated = MARKER in f.read(200)
    except OSError:
        generated = False
    if generated:
        os.remove(index)
        print("  commands: removed retired Gemini index README.md")
    if os.path.isdir(GEMINI_DIR) and not os.listdir(GEMINI_DIR):
        os.rmdir(GEMINI_DIR)


def verify(argv):
    """Assert every source command has a generated codex prompt.
    The 'missing generated command fails a local check' gate (run during sync)."""
    missing, n = [], 0
    for name, _d, _fn in iter_sources(argv):
        n += 1
        if not os.path.isfile(os.path.join(CODEX_DIR, f"{name}.md")):
            missing.append(f"codex prompt {name}.md")
    if missing:
        sys.stderr.write("  command-mirror verify FAILED - missing generated outputs:\n")
        for m in missing:
            sys.stderr.write(f"    - {m}\n")
        return 1
    print(f"  command-mirror verify OK - all {n} source command(s) mirror to codex")
    return 0


def main(argv):
    if argv and argv[0] == "--verify":
        return verify(argv[1:])
    if not argv:
        print("  ! commands: no sources passed (expected prefix:dir args)")
        return 0
    generated = 0
    keep = set()
    for name, d, fn in iter_sources(argv):
        try:
            with open(os.path.join(d, fn), encoding="utf-8") as f:
                desc, body = strip_frontmatter(f.read())
            emit(name, desc, body)
        except Exception as e:
            sys.stderr.write(f"  ! commands: skipping unreadable {fn} ({e})\n")
            continue
        keep.add(name)
        generated += 1
    # Discoverability index in each dir (regenerated; kept across the orphan-clean below).
    write_index(CODEX_DIR, keep, "codex")
    keep.add("README")   # protect the codex index (.md) from clean_orphans
    clean_orphans(keep, CODEX_DIR, ".md")
    retire_gemini_mirrors()
    print(f"  commands: generated {generated} command(s) -> codex prompts (+ index)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
