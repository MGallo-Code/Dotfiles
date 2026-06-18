#!/usr/bin/env python3
"""gen-agent-commands.py  --  AGENT-COMMAND-MIRROR

Regenerate per-tool copies of the tracked Claude slash-command `.md` files into the
formats codex and gemini expect, so the same commands are available in all three agents.
Run from sync.sh / sync.ps1 (one shared generator -> no bash/PowerShell duplication of
the markdown transform; parity is "both call this script").

Claude `.md` is the SOURCE OF TRUTH (never written here). Per source command we emit:
  - codex : ~/.codex/prompts/<name>.md       (plain markdown body; $ARGUMENTS / $1..$9)
  - gemini: ~/.gemini/commands/<name>.toml    (description + prompt; $ARGUMENTS->{{args}},
                                               claude !`cmd` shell-injection -> gemini !{cmd})

Sources + namespacing are passed as argv pairs "prefix:dir" (prefix "" = bare name,
"sbic" = sbic-<name>). Each generated file carries a provenance marker; on every run we
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


def to_gemini_prompt(body):
    """Convert claude-isms to gemini command syntax."""
    body = body.replace("$ARGUMENTS", "{{args}}")
    # claude inline shell-injection  !`cmd`  ->  gemini  !{cmd}
    body = re.sub(r"!`([^`]+)`", r"!{\1}", body)
    return body


def toml_escape_triple(s):
    # Safe inside a TOML triple-quoted basic string: only """ and trailing/backslash need care.
    return s.replace('\\', '\\\\').replace('"""', '\\"\\"\\"')


def emit(name, desc, body):
    os.makedirs(CODEX_DIR, exist_ok=True)
    os.makedirs(GEMINI_DIR, exist_ok=True)
    # codex: markdown body, provenance in an HTML comment (codex shows the body verbatim).
    with open(os.path.join(CODEX_DIR, f"{name}.md"), "w", encoding="utf-8") as f:
        f.write(f"<!-- {MARKER} -->\n")
        if desc:
            f.write(f"<!-- {desc} -->\n")
        f.write(body if body.endswith("\n") else body + "\n")
    # gemini: TOML with description + prompt; provenance in a leading comment.
    g = to_gemini_prompt(body)
    with open(os.path.join(GEMINI_DIR, f"{name}.toml"), "w", encoding="utf-8") as f:
        f.write(f"# {MARKER}\n")
        if desc:
            # TOML basic string: escape backslash and double-quote (a stray backslash in a
            # description otherwise produces invalid TOML).
            desc_esc = desc.replace("\\", "\\\\").replace('"', '\\"')
            f.write(f'description = "{desc_esc}"\n')
        f.write(f'prompt = """\n{toml_escape_triple(g)}\n"""\n')


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


def main(argv):
    if not argv:
        print("  ! commands: no sources passed (expected prefix:dir args)")
        return 0
    generated = 0
    keep = set()
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
            try:
                with open(os.path.join(d, fn), encoding="utf-8") as f:
                    desc, body = strip_frontmatter(f.read())
                emit(name, desc, body)
            except Exception as e:
                sys.stderr.write(f"  ! commands: skipping unreadable {fn} ({e})\n")
                continue
            keep.add(name)
            generated += 1
    clean_orphans(keep, CODEX_DIR, ".md")
    clean_orphans(keep, GEMINI_DIR, ".toml")
    print(f"  commands: generated {generated} command(s) -> codex prompts + gemini TOML")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
