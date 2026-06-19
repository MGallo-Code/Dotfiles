#!/usr/bin/env python3
"""check-skill-targets.py  -  INV enforcer: generated skill links track their source -
archived roots produce NO active affordance, every active source IS linked, and no two
sources collide on a name.

Scopes (deliberately different, so the gate is meaningful everywhere):

  1. MANIFEST consistency (repo-deterministic; pre-commit AND CI). An archived root must
     never leak back into an active list: an ARCHIVED_REPOS target must not appear in
     REPOS/EA_REPOS, and an ARCHIVED_PROJECT_SKILLS label must not appear in
     PROJECT_SKILLS. The mechanical guard that stops IT-Worker - or any future archive -
     from silently looking active again (which is how the stale it-worker-* links got
     generated in the first place).

  2. MACHINE state (only with --machine; on a dev machine where the generated skill dirs
     exist, NOT a bare CI runner). Three assertions over the live link tree:
       (a) DANGLING: no dotfiles-generated link is left dangling (source removed/archived).
       (b) COMPLETE: every source skill sync would link HAS its generated link in each
           intended target. This is the guard the dangling-only check lacked - an
           added-but-unlinked skill (the codex drift: 9 EA skills authored, never linked
           because no sync ran) is INVISIBLE to a dangling scan (the link is absent, not
           broken), but a completeness scan catches it.
       (c) COLLISION: no name in a target dir is claimed by two distinct source roots
           (the shadow risk - a vendor skill and a personal skill of the same name).
     Mirrors regen_agent_skills_links exactly: vendor + global skills -> AGENT_SKILLS_TARGETS
     un-namespaced; each PROJECT_SKILLS label|dir -> PROJECT_SKILLS_TARGETS (codex/gemini
     only, NEVER claude - claude reads each repo's .claude/skills natively) namespaced
     <label>-. A materialized gemini project skill is a real dir carrying
     .dotfiles-skill-source and counts as linked. Guarded: a target dir that does not exist
     yet (fresh machine, pre-first-sync) is skipped, never a false-fail. CI never runs this
     mode (dirs absent), so it never false-fails CI; the dev machine + `sync` own it.

Exit 0: clean.  Exit 1: a violation.  Exit 2: fail-closed (manifest unreadable).
"""
import os
import re
import sys
from collections import defaultdict


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


def extract_scalar(text, name):
    """Return the value of a bash scalar  NAME="value"  ('' if absent). The skill SOURCE
    dirs (AGENT_SKILLS_DIR, GLOBAL_SKILLS_DIR) are scalars, not arrays, so the completeness
    scan needs this - extract_array cannot see them."""
    m = re.search(rf'^{re.escape(name)}="([^"]*)"', text, re.MULTILINE)
    return m.group(1) if m else ""


def repo_target(entry):   # "remote|~/path" -> "~/path"
    return entry.rsplit("|", 1)[-1]


def skill_label(entry):   # "label|~/dir" -> "label"
    return entry.split("|", 1)[0]


def skill_dir(entry):     # "label|~/dir" -> "~/dir"
    return entry.split("|", 1)[-1]


def source_skill_names(src_dir):
    """Skill subdir names under src_dir, mirroring link_skill_dirs: real dirs only, skip
    dot-dirs (.system etc.). Empty if the source dir is absent."""
    d = os.path.expanduser(src_dir)
    if not os.path.isdir(d):
        return []
    return [n for n in sorted(os.listdir(d))
            if not n.startswith(".") and os.path.isdir(os.path.join(d, n))]


def is_linked(target_dir, entry_name):
    """True if target_dir/entry_name is a satisfied generated link: a symlink that
    resolves, OR a materialized gemini real-dir carrying .dotfiles-skill-source."""
    p = os.path.join(target_dir, entry_name)
    if os.path.islink(p):
        return os.path.exists(p)
    if os.path.isdir(p) and os.path.isfile(os.path.join(p, ".dotfiles-skill-source")):
        return True
    return False


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
    agent_skills_dir = extract_scalar(manifest, "AGENT_SKILLS_DIR")
    global_skills_dir = extract_scalar(manifest, "GLOBAL_SKILLS_DIR")

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

    # 2. MACHINE: dangling + completeness + collision (only where the dirs exist).
    scanned = 0
    if machine:
        agent_t = [os.path.expanduser(t) for t in agent_targets]
        project_t = [os.path.expanduser(t) for t in project_targets]

        # (a) DANGLING: a generated symlink whose target no longer resolves.
        seen = set()
        for d in agent_t + project_t:
            if d in seen:
                continue
            seen.add(d)
            if not os.path.isdir(d):
                continue
            scanned += 1
            for name in sorted(os.listdir(d)):
                p = os.path.join(d, name)
                if os.path.islink(p) and not os.path.exists(p):
                    failures.append(f"dangling skill link (source gone): {p}  - run `sync` to prune")

        # Source buckets, mirroring regen_agent_skills_links:
        #   bucket A: vendor + global skills -> agent_t (claude/codex/gemini), un-namespaced
        #   bucket B: each PROJECT_SKILLS label|dir -> project_t (codex/gemini), namespaced label-
        # claude is deliberately ABSENT from bucket B: it reads each repo's .claude/skills
        # natively, so project skills are never linked there - requiring them would false-fail.
        claims = defaultdict(lambda: defaultdict(set))   # target_dir -> entry_name -> {source roots}

        bucketA = []
        if agent_skills_dir:
            bucketA.append(("vendor", os.path.join(agent_skills_dir, "skills")))
        if global_skills_dir:
            bucketA.append(("global-skills", global_skills_dir))

        for root_label, src in bucketA:
            for name in source_skill_names(src):
                for td in agent_t:
                    if not os.path.isdir(td):
                        continue              # guard: fresh machine, target not yet created
                    claims[td][name].add(root_label)
                    if not is_linked(td, name):
                        failures.append(
                            f"missing skill link: {root_label} skill {name!r} is not linked "
                            f"into {td} - run `sync`")

        for entry in project_skills:
            label, pdir = skill_label(entry), skill_dir(entry)
            for name in source_skill_names(pdir):
                ns = f"{label}-{name}"
                for td in project_t:
                    if not os.path.isdir(td):
                        continue
                    claims[td][ns].add(f"project:{label}")
                    if not is_linked(td, ns):
                        failures.append(
                            f"missing skill link: project {label!r} skill {name!r} is not linked "
                            f"as {ns!r} into {td} - run `sync`")

        # (c) COLLISION: one name claimed by two distinct source roots in one target dir.
        for td, names in claims.items():
            for name, roots in names.items():
                if len(roots) > 1:
                    failures.append(
                        f"skill name collision in {td}: {name!r} claimed by {sorted(roots)} "
                        f"- two sources would shadow each other")

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
          + ("; every source skill linked, no dangling links, no name collisions." if machine else "."))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
