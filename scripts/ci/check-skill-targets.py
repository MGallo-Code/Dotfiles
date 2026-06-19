#!/usr/bin/env python3
"""check-skill-targets.py  -  INV enforcer: generated skills have a live source, and an
archived root produces NO active generated affordance.

Two assertions, with deliberately different scope so the gate is meaningful everywhere:

  1. MANIFEST consistency (repo-deterministic; runs in pre-commit AND CI). An archived
     root must never leak back into an active list: an ARCHIVED_REPOS target must not
     appear in REPOS/EA_REPOS, and an ARCHIVED_PROJECT_SKILLS label must not appear in
     PROJECT_SKILLS. This is the mechanical guard that stops IT-Worker - or any future
     archive - from silently looking active again (which is exactly how the stale
     it-worker-* skill links got generated in the first place).

  2. MACHINE state (only with --machine; runs on a dev machine where the generated skill
     dirs exist, NOT on a bare CI runner). No dotfiles-generated skill link may be left
     DANGLING (its source removed/archived). A dangling link is a dead affordance; the fix
     is `sync` (regen_agent_skills_links -> clean_stale_skill_symlinks prunes them). Real
     user-authored dirs and materialized gemini skills (real dirs, not links) are never
     flagged. CI does not run this mode (the dirs are absent), so it never false-fails CI.

Exit 0: clean.  Exit 1: a violation.  Exit 2: fail-closed (manifest unreadable).
"""
import os
import re
import sys


def repo_root():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", ".."))


def extract_array(text, name):
    """Return the quoted string items of a bash array  NAME=( "a" "b" ... ).
    Uses [^)]* so it stops at the FIRST ')': handles an empty single-line array (NAME=())
    without greedily swallowing the next array's contents, and multi-line arrays alike.
    (Safe because none of these arrays' values contain a ')'.)"""
    m = re.search(rf'^{re.escape(name)}=\(([^)]*)\)', text, re.MULTILINE)
    if not m:
        return []
    return re.findall(r'"([^"]+)"', m.group(1))


def repo_target(entry):   # "remote|~/path" -> "~/path"
    return entry.rsplit("|", 1)[-1]


def skill_label(entry):   # "label|~/dir" -> "label"
    return entry.split("|", 1)[0]


def main(argv):
    machine = "--machine" in argv
    root = repo_root()
    manifest_path = os.path.join(root, "manifest.sh")
    try:
        with open(manifest_path, encoding="utf-8") as f:
            manifest = f.read()
    except OSError as e:
        sys.stderr.write(f"check-skill-targets: cannot read manifest.sh ({e}) - failing closed\n")
        return 2

    repos = extract_array(manifest, "REPOS")
    ea_repos = extract_array(manifest, "EA_REPOS")
    project_skills = extract_array(manifest, "PROJECT_SKILLS")
    archived_repos = extract_array(manifest, "ARCHIVED_REPOS")
    archived_skills = extract_array(manifest, "ARCHIVED_PROJECT_SKILLS")
    agent_targets = extract_array(manifest, "AGENT_SKILLS_TARGETS")
    project_targets = extract_array(manifest, "PROJECT_SKILLS_TARGETS")

    failures = []

    # 1. MANIFEST: no archived root in an active list.
    archived_repo_targets = {repo_target(e) for e in archived_repos}
    for e in repos + ea_repos:
        if repo_target(e) in archived_repo_targets:
            failures.append(
                f"archived repo target {repo_target(e)!r} appears in an ACTIVE repo list "
                f"(REPOS/EA_REPOS) - archived roots must not be synced")
    archived_labels = {skill_label(e) for e in archived_skills}
    for e in project_skills:
        if skill_label(e) in archived_labels:
            failures.append(
                f"archived project-skill label {skill_label(e)!r} appears in ACTIVE "
                f"PROJECT_SKILLS - it would regenerate stale {skill_label(e)}-* links")

    # 2. MACHINE: no dangling generated skill link (only where the dirs exist).
    scanned, dangling = 0, []
    if machine:
        seen = set()
        for t in agent_targets + project_targets:
            d = os.path.expanduser(t)
            if d in seen:
                continue
            seen.add(d)
            if not os.path.isdir(d):
                continue
            scanned += 1
            for name in sorted(os.listdir(d)):
                p = os.path.join(d, name)
                # islink + not exists == a symlink whose target does not resolve.
                if os.path.islink(p) and not os.path.exists(p):
                    dangling.append(p)
        for p in dangling:
            failures.append(f"dangling skill link (source gone): {p}  - run `sync` to prune")

    mode = "manifest + machine" if machine else "manifest"
    print(f"check-skill-targets [{mode}]: {len(repos)} active repo(s), "
          f"{len(project_skills)} active project-skill(s), {len(archived_repos)} archived repo(s)"
          + (f", scanned {scanned} target dir(s)" if machine else ""))

    if failures:
        sys.stderr.write("\nSKILL-TARGET violation:\n")
        for f in failures:
            sys.stderr.write(f"  - {f}\n")
        return 1

    print("check-skill-targets OK - no archived root in an active list"
          + ("; no dangling generated skill links." if machine else "."))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
