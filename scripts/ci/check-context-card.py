#!/usr/bin/env python3
"""INV-17: resume-card hooks behave as specified (design: EA docs/decisions/0004-self-refreshing-sessions.md;
moved here with claude-config by ADR-0006, where it was EA INV-11).

Hermetic: throwaway git repos, a throwaway state dir, and transcript lines shaped like
Claude Code 2.1.281's. Runs claude-config/global-hooks/context-card.py as a subprocess.

    python3 scripts/ci/check-context-card.py                 # the fixtures
    python3 scripts/ci/check-context-card.py --revert-test   # a guard that always allows must FAIL them
"""

from __future__ import annotations

import argparse
import ast
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "claude-config" / "global-hooks" / "context-card.py"
PROFILES = ROOT / "claude-config" / "model-profiles" / "compact"
HOST = "local_test-session"


def clean_env(extra: dict | None = None) -> dict:
    """os.environ without GIT_* (hooks export GIT_DIR/GIT_INDEX_FILE; in a linked worktree
    GIT_DIR is absolute, and an inherited one sends `git -C <tmp>` to the REAL repository).
    Only the explicit dates a fixture passes survive."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(extra or {})
    return env


def iso(offset_s: float = 0.0) -> str:
    stamp = dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=offset_s)
    return stamp.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def typed(text: str, offset_s: float = 0.0) -> dict:
    return {"type": "user", "message": {"role": "user", "content": text},
            "origin": {"kind": "human"}, "turnOrigin": "human", "timestamp": iso(offset_s)}


WRAP = "<command-message>wrap</command-message>\n<command-name>/wrap</command-name>"
WRAP_KEEP = WRAP + "\n<command-args>keep</command-args>"
EXPANSION = {"type": "user", "isMeta": True, "message": {"role": "user", "content": [{"type": "text", "text": "Resume cards keep long work accurate"}]}}
TOOL_RESULT = {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}
PEER = {"type": "user", "isMeta": True, "origin": {"kind": "peer"}, "turnOrigin": "peer",
        "message": {"role": "user", "content": "Another Claude session sent a message:\n<cross-session-message from=\"uds:x\">go</cross-session-message>"}}
QUEUED = {"type": "attachment", "attachment": {"type": "queued_command", "prompt": "wait, don't clear", "origin": {"kind": "human"}}}
SUMMARY = {"type": "user", "isCompactSummary": True, "isVisibleInTranscriptOnly": True, "turnOrigin": "human",
           "message": {"role": "user", "content": "This session is being continued from a previous conversation."}}


def assistant(model: str) -> dict:
    return {"type": "assistant", "message": {"model": model, "content": [{"type": "text", "text": "ok"}]}}


class Suite:
    def __init__(self, script: Path, quiet: bool) -> None:
        self.script, self.quiet, self.failures = script, quiet, []
        self.tmp = Path(tempfile.mkdtemp(prefix="context-card-check-"))
        self.state = self.tmp / "state"

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        if not ok:
            self.failures.append(f"{name}: {detail}")
        if not self.quiet:
            print(f"{'ok  ' if ok else 'FAIL'} {name}{'' if ok else ' - ' + detail}")

    def repo(self, name: str, origin: str | None) -> Path:
        path = self.tmp / name
        path.mkdir()
        env = clean_env()
        subprocess.run(["git", "-C", str(path), "init", "-q", "-b", "main"], check=True, env=env)
        git_dir = subprocess.run(["git", "-C", str(path), "rev-parse", "--absolute-git-dir"],
                                 capture_output=True, text=True, env=env).stdout.strip()
        if Path(git_dir).resolve() != (path / ".git").resolve():
            raise SystemExit(f"refusing to configure a fixture repo that resolves to {git_dir!r}")
        for args in (["config", "user.email", "t@example.com"], ["config", "user.name", "t"],
                     ["config", "commit.gpgsign", "false"]):
            subprocess.run(["git", "-C", str(path), *args], check=True, env=env)
        if origin:
            subprocess.run(["git", "-C", str(path), "remote", "add", "origin", origin], check=True, env=env)
        (path / "README.md").write_text("x\n")
        subprocess.run(["git", "-C", str(path), "add", "README.md"], check=True, env=env)
        subprocess.run(["git", "-C", str(path), "commit", "-q", "-m", "init"], check=True, env=env)
        return path

    def run(self, args: list[str], repo: Path, stdin: dict | str | None = None,
            entry: str = "claude-desktop", host: str | None = HOST, extra: dict | None = None):
        env = {k: v for k, v in clean_env().items() if not k.startswith(("CLAUDE", "CONTEXT_CARD"))}
        env.update({"HOME": str(self.tmp / "home"), "CONTEXT_CARD_STATE": str(self.state),
                    "CONTEXT_CARD_PROFILES": str(PROFILES), "CLAUDE_PROJECT_DIR": str(repo),
                    "CLAUDE_CODE_ENTRYPOINT": entry})
        if host:
            env["CLAUDE_CODE_HOST_SESSION_ID"] = host
        env.update(extra or {})
        text = stdin if isinstance(stdin, str) else json.dumps(stdin or {})
        return subprocess.run([sys.executable, str(self.script), *args], input=text, cwd=str(repo),
                              env=env, capture_output=True, text=True, timeout=60)

    def transcript(self, name: str, entries: list[dict]) -> str:
        path = self.tmp / f"{name}.jsonl"
        path.write_text("".join(json.dumps(e) + "\n" for e in entries))
        return str(path)

    def git(self, repo: Path, *args: str, env: dict | None = None) -> str:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                              env=clean_env(env)).stdout.strip()


def fixtures(s: Suite) -> None:
    src = s.script.read_text(encoding="utf-8")
    try:
        ast.parse(src, feature_version=(3, 9))
        s.check("script parses as Python 3.9", True)
    except SyntaxError as exc:
        s.check("script parses as Python 3.9", False, str(exc))

    mine = s.repo("mine", "git@github.com:MGallo-Code/demo.git")
    r = s.run(["session-start"], mine, {"source": "startup"})
    s.check("unbound, no cards: silent", r.returncode == 0 and r.stdout == "", r.stdout + r.stderr)

    r = s.run(["bind", "demo-work"], mine)
    card = mine / ".claude" / "resume" / "demo-work.md"
    s.check("bind creates an in-repo card", r.returncode == 0 and card.is_file(), r.stdout + r.stderr)
    card.write_text("# demo-work\n\n## Goal\nCODEWORD-HERON\n")

    r = s.run(["session-start"], mine, {"source": "startup"})
    s.check("bound startup: pointer and notes, no card body",
            "bound to the resume card" in r.stdout and "CODEWORD-HERON" not in r.stdout and "Working notes" in r.stdout, r.stdout)
    r = s.run(["session-start"], mine, {"source": "compact"})
    s.check("bound compact: full card", "CODEWORD-HERON" in r.stdout and "just refreshed" in r.stdout, r.stdout)
    r = s.run(["session-start"], mine, {"source": "compact"}, entry="sdk-cli")
    s.check("headless (sdk-cli): session-start silent", r.stdout == "", r.stdout)
    r = s.run(["session-start"], mine, {"source": "startup"}, host="local_other")
    s.check("other session in a repo with cards: one-line list", "Resume cards in this repo: demo-work" in r.stdout and "CODEWORD" not in r.stdout, r.stdout)

    fable = s.transcript("fable", [assistant("claude-fable-5-1"), assistant("<synthetic>")])
    r = s.run(["pre-compact"], mine, {"trigger": "auto", "transcript_path": fable})
    s.check("pre-compact: Fable profile, synthetic entry skipped",
            "Resume-card compaction" in r.stdout and "six" not in r.stdout and "inside <summary></summary>" in r.stdout, r.stdout[:300])
    haiku = s.transcript("haiku", [assistant("claude-haiku-4-5-20251001")])
    r = s.run(["pre-compact"], mine, {"trigger": "auto", "transcript_path": haiku})
    s.check("pre-compact: unknown model falls back to default", "four labeled sections" in r.stdout, r.stdout[:300])
    r = s.run(["pre-compact"], mine, {"trigger": "auto", "transcript_path": fable}, host="local_other")
    s.check("pre-compact: unbound session silent", r.stdout == "", r.stdout)
    r = s.run(["pre-compact"], mine, {"trigger": "auto", "transcript_path": fable}, entry="sdk-cli")
    s.check("pre-compact: headless silent", r.stdout == "", r.stdout)

    # Staleness: a commit after the card's last update must be named in the instructions.
    s.git(mine, "add", "--", str(card))
    s.git(mine, "commit", "-q", "-m", "checkpoint: card", env={"GIT_COMMITTER_DATE": "2026-01-01T10:00:00", "GIT_AUTHOR_DATE": "2026-01-01T10:00:00"})
    (mine / "work.txt").write_text("w\n")
    s.git(mine, "add", "work.txt")
    s.git(mine, "commit", "-q", "-m", "Add the parser fix", env={"GIT_COMMITTER_DATE": "2026-01-01T11:00:00", "GIT_AUTHOR_DATE": "2026-01-01T11:00:00"})
    r = s.run(["pre-compact"], mine, {"trigger": "auto", "transcript_path": fable})
    s.check("pre-compact: stale card lists later commits", "card is behind" in r.stdout and "Add the parser fix" in r.stdout, r.stdout[:500])

    # Clear guard.
    other = s.run(["clear-guard"], mine, {"tool_input": {"session_id": "local_child"}, "transcript_path": fable})
    s.check("guard: clearing another session is allowed", other.returncode == 0, other.stderr)
    plain = s.transcript("plain", [typed("please clear yourself"), EXPANSION, assistant("claude-opus-5-5")])
    r = s.run(["clear-guard"], mine, {"tool_input": {"session_id": "self"}, "transcript_path": plain})
    s.check("guard: self-clear without /wrap is blocked", r.returncode == 2 and "does not clear itself" in r.stderr, f"rc={r.returncode} {r.stderr}")
    r = s.run(["clear-guard"], mine, {"tool_input": {"session_id": HOST}, "transcript_path": plain})
    s.check("guard: own host id counts as self", r.returncode == 2, f"rc={r.returncode}")

    card.write_text("# demo-work\n\n## Goal\nCODEWORD-HERON\n\n## Next exact step\nship\n")
    r = s.run(["commit", "checkpoint: ship"], mine)
    s.check("commit: card checkpoint lands", r.returncode == 0 and "checkpoint committed" in r.stdout, r.stdout + r.stderr)
    wrapped = s.transcript("wrapped", [typed(WRAP, -60), EXPANSION, TOOL_RESULT, SUMMARY, TOOL_RESULT, assistant("claude-opus-5-5")])
    r = s.run(["clear-guard"], mine, {"tool_input": {"session_id": "self"}, "transcript_path": wrapped})
    s.check("guard: typed /wrap + committed card allows (compact summary and tool results skipped)", r.returncode == 0, f"rc={r.returncode} {r.stderr}")
    r = s.run(["session-start"], mine, {"source": "startup"})
    s.check("after an allowed clear, the next startup gets the full card", "CODEWORD-HERON" in r.stdout, r.stdout)
    r = s.run(["session-start"], mine, {"source": "startup"})
    s.check("the clear marker is consumed once", "CODEWORD-HERON" not in r.stdout, r.stdout)

    for name, entries in (
        ("/wrap keep", [typed(WRAP_KEEP, -60), EXPANSION]),
        ("peer message after /wrap", [typed(WRAP, -60), EXPANSION, TOOL_RESULT, PEER]),
        ("queued message after /wrap", [typed(WRAP, -60), EXPANSION, QUEUED, TOOL_RESULT]),
        ("later typed prompt", [typed(WRAP, -120), EXPANSION, typed("actually wait", -30)]),
    ):
        path = s.transcript(name.replace(" ", "-").replace("/", ""), entries)
        r = s.run(["clear-guard"], mine, {"tool_input": {"session_id": "self"}, "transcript_path": path})
        s.check(f"guard blocks: {name}", r.returncode == 2, f"rc={r.returncode}")

    future = s.transcript("future", [typed(WRAP, 3600)])
    r = s.run(["clear-guard"], mine, {"tool_input": {"session_id": "self"}, "transcript_path": future})
    s.check("guard blocks: card not updated since /wrap", r.returncode == 2 and "not landed" in r.stderr, f"rc={r.returncode} {r.stderr}")
    card.write_text(card.read_text() + "dirty\n")
    r = s.run(["clear-guard"], mine, {"tool_input": {"session_id": "self"}, "transcript_path": wrapped})
    s.check("guard blocks: uncommitted card", r.returncode == 2, f"rc={r.returncode} {r.stderr}")
    r = s.run(["clear-guard"], mine, {"tool_input": {"session_id": "self"}, "transcript_path": wrapped}, host="local_unbound")
    s.check("guard blocks: no card bound", r.returncode == 2, f"rc={r.returncode}")
    r = s.run(["clear-guard"], mine, {"tool_input": {"session_id": "self"}, "transcript_path": str(s.tmp / "missing.jsonl")})
    s.check("guard fails closed: unreadable transcript", r.returncode == 2, f"rc={r.returncode}")
    r = s.run(["clear-guard"], mine, "not json at all")
    s.check("guard fails closed: garbage input", r.returncode == 2, f"rc={r.returncode}")

    # commit: only the card, never other staged work; refuse mid-rebase.
    (mine / "other.txt").write_text("staged by someone else\n")
    s.git(mine, "add", "other.txt")
    r = s.run(["commit", "checkpoint: again"], mine)
    files = s.git(mine, "show", "--name-only", "--format=", "HEAD").splitlines()
    body = s.git(mine, "log", "-1", "--format=%B")
    s.check("commit: only the card, one line, no trailer",
            r.returncode == 0 and files == [".claude/resume/demo-work.md"] and body.strip() == "checkpoint: again"
            and "other.txt" in s.git(mine, "diff", "--cached", "--name-only"), f"{files} {body!r} {r.stderr}")
    (mine / ".git" / "rebase-merge").mkdir()
    card.write_text(card.read_text() + "more\n")
    r = s.run(["commit", "checkpoint: mid-rebase"], mine)
    s.check("commit: refuses during a rebase", r.returncode != 0 and "middle of an operation" in (r.stderr + r.stdout), r.stdout + r.stderr)
    (mine / ".git" / "rebase-merge").rmdir()

    # Michael's SSH alias (`git@github:MGallo-Code/...`, git.md) is his repo too.
    alias = s.repo("alias", "git@github:MGallo-Code/dotfiles.git")
    r = s.run(["bind", "alias-work"], alias, host="local_alias")
    s.check("owner alias git@github: counts as Michael's repo", (alias / ".claude" / "resume" / "alias-work.md").is_file(), r.stdout + r.stderr)

    # Orchestration: bind the Orchestrator's card to RESUME.md; roles and the role guard.
    orch = mine / "tasks" / "m2"
    orch.mkdir(parents=True)
    (orch / "RESUME.md").write_text("# RESUME\nCODEWORD-OSPREY\n")
    r = s.run(["bind", "--file", "tasks/m2/RESUME.md"], mine, host="local_orch")
    s.check("bind --file binds RESUME.md as the card", r.returncode == 0 and "CODEWORD-OSPREY" in r.stdout, r.stdout + r.stderr)
    binding = json.loads((s.state / "bind" / "local_orch.json").read_text())
    s.check("bind --file on an untracked file: kind file, local (no commits)", binding.get("kind") == "file" and binding.get("mode") == "local", str(binding))
    r = s.run(["commit", "checkpoint: x"], mine, host="local_orch")
    s.check("commit on an untracked RESUME.md is a no-op, not a failure", r.returncode == 0 and "nothing to commit" in r.stdout, r.stdout + r.stderr)
    r = s.run(["session-start"], mine, {"source": "compact"}, host="local_orch")
    s.check("the Orchestrator gets RESUME.md back after compaction, with file notes", "CODEWORD-OSPREY" in r.stdout and "Do not rewrite it into another format" in r.stdout, r.stdout)
    r = s.run(["bind", "--file", "/etc/hosts"], mine, host="local_orch")
    s.check("bind --file refuses a file outside the repo", r.returncode != 0, r.stdout)

    def guard(host: str, tool: str, tool_input: dict, name: str = "role-guard", **extra):
        return s.run([name], mine, {"tool_name": tool, "tool_input": tool_input, **extra}, host=host)

    r = guard("local_norole", "Edit", {"file_path": str(mine / "README.md")})
    s.check("role guard: a session without a role is untouched", r.returncode == 0 and r.stderr == "", r.stderr)
    builder_tree = s.tmp / "builder-wt"
    builder_tree.mkdir()
    r = s.run(["role", "orchestrator", "--orch-dir", "tasks/m2"], mine, host="local_orch")
    s.check("role orchestrator is set", r.returncode == 0, r.stdout + r.stderr)
    for path, want in ((mine / "README.md", 3), (orch / "ledger.json", 0), (orch / ".." / ".." / "README.md", 3),
                       (mine / "analysis_outputs" / "m2" / "S1" / "disposition.md", 0),
                       (builder_tree / "analysis_outputs" / "builder-notes" / "inbox" / "S1" / "ASSIGNMENT.md", 0),
                       (s.tmp / "scratch" / "verify_S1.py", 0)):
        r = guard("local_orch", "Write", {"file_path": str(path)})
        s.check(f"role guard: orchestrator writes {path.name} -> {want}", r.returncode == want, f"rc={r.returncode} {r.stderr[:120]}")
    r = s.run(["role", "builder", "--worktree", str(builder_tree)], mine, host="local_builder")
    for cmd, want in (("git push origin main", 3), ("git -C x merge main", 3), ("git reset --hard HEAD~1", 3),
                      ("git push --force-with-lease", 3), ("gh pr merge 12", 3), ("git branch -D main", 3),
                      ("git switch main", 3), ("git checkout main", 3), ("git checkout -b feat", 3),
                      ("git commit -m 'slice 3'", 0), ("git commit -m \"fix push notification\"", 0),
                      ("git merge-base HEAD main", 0), ("git log -- scripts/push.sh", 0), ("npm install --force", 0),
                      ("pip install --force-reinstall x", 0), ("git checkout -- app.py", 0), ("pytest -q && git status", 0)):
        r = guard("local_builder", "Bash", {"command": cmd})
        s.check(f"role guard: builder `{cmd}` -> {want}", r.returncode == want, f"rc={r.returncode}")
    r = guard("local_builder", "Edit", {"file_path": str(mine / "README.md")})
    s.check("role guard: a --worktree Builder cannot edit outside it", r.returncode == 3, f"rc={r.returncode}")
    r = guard("local_builder", "Edit", {"file_path": str(builder_tree / "app.py")})
    s.check("role guard: a --worktree Builder edits inside it", r.returncode == 0, f"rc={r.returncode}")
    r = s.run(["role-guard"], mine, {"tool_name": "Bash", "tool_input": {"command": "git push"}}, host="local_builder", entry="sdk-cli")
    s.check("role guard: headless lanes are untouched", r.returncode == 0, f"rc={r.returncode}")
    r = s.run(["role-guard"], mine, "garbage", host="local_builder")
    s.check("role guard: an error blocks a session that has a role (exit 3)", r.returncode == 3, f"rc={r.returncode}")
    r = s.run(["role-guard"], mine, "garbage", host="local_norole")
    s.check("role guard: an error never blocks a session without a role", r.returncode == 0, f"rc={r.returncode}")
    s.run(["role", "off"], mine, host="local_builder")
    r = guard("local_builder", "Bash", {"command": "git push"})
    s.check("role off: rules lifted", r.returncode == 0, f"rc={r.returncode}")

    # A terminal session's role is tied to its process start time: a reused pid starts clean.
    pid_env = {"CLAUDE_PID": str(os.getpid())}
    s.run(["role", "builder"], mine, host=None, extra=pid_env)
    role_file = s.state / "role" / f"pid-{os.getpid()}.json"
    r = s.run(["role-guard"], mine, {"tool_name": "Bash", "tool_input": {"command": "git push"}}, host=None, extra=pid_env)
    s.check("pid role: applies to the same process", r.returncode == 3, f"rc={r.returncode}")
    data = json.loads(role_file.read_text()); data["process_start"] = "Thu Jan  1 00:00:00 1970"; role_file.write_text(json.dumps(data))
    r = s.run(["role-guard"], mine, {"tool_name": "Bash", "tool_input": {"command": "git push"}}, host=None, extra=pid_env)
    s.check("pid role: a stale role (same pid, other process) is dropped", r.returncode == 0 and not role_file.exists(), f"rc={r.returncode}")

    # The Challenger's agent-scoped guard: evidence-only writes, pass-1 isolation, read-only git.
    inbox = s.tmp / "challenger" / "analysis_outputs" / "reviewer-evidence" / "inbox" / "S3"
    for tool, tool_input, want in (
        ("Write", {"file_path": str(inbox / "review" / "report.md")}, 0),
        ("Write", {"file_path": str(inbox / "execution-copy" / "app.py")}, 3),
        ("Write", {"file_path": str(inbox / "Execution-Copy" / "app.py")}, 3),
        ("Write", {"file_path": str(mine / "src.py")}, 3),
        ("Read", {"file_path": str(inbox / "ASSIGNMENT.md")}, 0),
        ("Read", {"file_path": str(orch / "ledger.json")}, 3),
        ("Grep", {"pattern": "x"}, 3),
        ("Glob", {"pattern": "*", "path": str(inbox)}, 0),
        ("Bash", {"command": "git -C x log --oneline"}, 0),
        ("Bash", {"command": "git commit -m x"}, 3),
        ("Bash", {"command": "gh pr view 3"}, 3),
    ):
        r = guard("local_orch", tool, tool_input, name="challenger-guard", agent_type="challenger")
        s.check(f"challenger guard: {tool} {str(tool_input)[-48:]} -> {want}", r.returncode == want, f"rc={r.returncode}")
    r1 = guard("local_orch", "Write", {"file_path": str(mine / "src.py")}, agent_type="challenger")
    r2 = guard("local_orch", "Write", {"file_path": str(inbox / "review" / "report.md")}, agent_type="challenger")
    s.check("the session role guard applies the Challenger's own rules, not the Orchestrator's", r1.returncode == 3 and r2.returncode == 0,
            f"rc={r1.returncode}/{r2.returncode}")

    # /orchestrate: one switch in the Orchestrator; new Builder sessions set themselves up.
    canon = s.repo("canon", "git@github:MGallo-Code/app.git")
    bwt = s.tmp / "canon-builder"
    s.git(canon, "worktree", "add", "-q", "-b", "builder", str(bwt))
    other_repo = s.repo("unrelated", "git@github:MGallo-Code/other.git")
    (bwt / ".claude").mkdir()
    (bwt / ".claude" / "settings.local.json").write_text(json.dumps({"autoCompactWindow": 200000, "permissions": {"allow": ["Bash(ls:*)"]}}))
    role_of = lambda sid: json.loads((s.state / "role" / f"{sid}.json").read_text()) if (s.state / "role" / f"{sid}.json").exists() else {}
    bind_of = lambda sid: json.loads((s.state / "bind" / f"{sid}.json").read_text()) if (s.state / "bind" / f"{sid}.json").exists() else {}
    win = lambda folder: json.loads((folder / ".claude" / "settings.local.json").read_text()) if (folder / ".claude" / "settings.local.json").exists() else None
    start = lambda folder, sid, source="startup", **kw: s.run(["session-start"], folder, {"source": source}, host=sid, **kw)
    r = s.run(["orchestration", "new", "m9", "--builder-worktree", str(canon)], canon, host="local_o9")
    s.check("orchestrate new refuses the Orchestrator's own checkout", r.returncode != 0, r.stdout)
    r = s.run(["orchestration", "new", "m9", "--builder-worktree", str(other_repo)], canon, host="local_o9")
    s.check("orchestrate new refuses a repo that is not a worktree of this one", r.returncode != 0 and "not a worktree" in r.stderr, r.stderr)
    (canon / ".claude").mkdir(exist_ok=True)
    (canon / ".claude" / "settings.local.json").write_text("{ broken")
    r = s.run(["orchestration", "new", "m9", "--builder-worktree", str(bwt)], canon, host="local_o9")
    s.check("orchestrate new with invalid settings JSON changes nothing", r.returncode != 0 and not role_of("local_o9") and not bind_of("local_o9")
            and not list((s.state / "orchestrations").glob("*.json")), r.stderr)
    (canon / ".claude" / "settings.local.json").unlink()
    s.run(["bind", "prior-work"], bwt, host="local_prior")  # a session already bound in the worktree
    r = s.run(["orchestration", "new", "m9", "--builder-worktree", str(bwt)], canon, host="local_o9")
    ob, orole = bind_of("local_o9"), role_of("local_o9")
    s.check("orchestrate new: RESUME.md card, orchestrator role, 350K both sides, state outside the repos",
            r.returncode == 0 and ob.get("kind") == "file" and ob.get("card", "").endswith("tasks/m9/RESUME.md") and orole.get("role") == "orchestrator"
            and win(canon).get("autoCompactWindow") == 350000 and win(bwt).get("autoCompactWindow") == 350000
            and len(list((s.state / "orchestrations").glob("*.json"))) == 1 and not (bwt / "analysis_outputs").exists(), r.stdout + r.stderr)
    r = s.run(["orchestration", "new", "m9", "--builder-worktree", str(bwt)], canon, host="local_o9")
    s.check("rerunning new in the same session is harmless", r.returncode == 0 and role_of("local_o9").get("role") == "orchestrator", r.stderr)
    r = s.run(["orchestration", "new", "m10", "--builder-worktree", str(bwt)], canon, host="local_o9")
    s.check("a second orchestration in the same session is refused", r.returncode != 0, r.stdout)
    r = s.run(["orchestration", "new", "m9", "--builder-worktree", str(bwt)], canon, host="local_o10")
    s.check("a second Orchestrator on a live Builder worktree is refused (one-orchestrator lock)", r.returncode != 0 and "One Orchestrator" in r.stderr, r.stderr)

    (bwt / "src").mkdir()
    r1, r2 = start(bwt, "local_b1"), start(bwt / "src", "local_b2")
    c1, c2 = bind_of("local_b1").get("card", ""), bind_of("local_b2").get("card", "")
    s.check("new sessions in the worktree (root and a subdirectory) each become a Builder with their own fresh card",
            "is a Builder for orchestration m9" in r1.stdout and "is a Builder" in r2.stdout and c1 and c2 and c1 != c2
            and role_of("local_b1").get("worktree") == str(bwt.resolve()), r1.stdout + r2.stdout)
    r = s.run(["role-guard"], bwt, {"tool_name": "Bash", "tool_input": {"command": "git push"}}, host="local_b1")
    s.check("an activated Builder's git guard works", r.returncode == 3, f"rc={r.returncode}")
    start(bwt, "local_prior", source="startup")
    s.check("a session already bound in the worktree keeps its own card and gets no role",
            bind_of("local_prior").get("card", "").endswith("prior-work.md") and not role_of("local_prior"), str(bind_of("local_prior")))
    for source in ("compact", "clear", "resume"):
        start(bwt, f"local_{source}", source=source)
    s.check("only a brand-new session (startup) activates; compact/clear/resume never do",
            not any(role_of(f"local_{x}") for x in ("compact", "clear", "resume")), "")
    r = start(bwt, "local_h9", entry="sdk-cli")
    s.check("a headless session in the worktree is not activated", not role_of("local_h9"), r.stdout)
    r = s.run(["session-start", "--agent", "codex"], bwt, {"source": "startup", "session_id": "t-9"}, host=None)
    s.check("Codex in the worktree gets a notice, no role", "roles and guards apply only in Claude Code" in r.stdout and not role_of("codex-t-9"), r.stdout)
    start(mine, "local_x9")
    s.check("sessions in other repos are untouched", not role_of("local_x9"), "")
    r = s.run(["orchestration", "end"], bwt, host="local_b1")
    s.check("a Builder cannot end the orchestration", r.returncode != 0 and role_of("local_b1"), r.stdout)
    r = s.run(["orchestration", "end"], canon, host="local_nobody")
    s.check("a role-less session cannot end a live orchestration", r.returncode != 0 and "still live" in r.stderr, r.stderr)

    r = s.run(["orchestration", "end"], canon, host="local_o9")
    gone = [p for p in (s.state / "role" / "local_b1.json", s.state / "role" / "local_b2.json", s.state / "bind" / "local_b1.json",
                        s.state / "role" / "local_o9.json", s.state / "bind" / "local_o9.json") if p.exists()]
    after = win(bwt) or {}
    s.check("end removes every Builder's and the Orchestrator's setup and restores the prior windows",
            r.returncode == 0 and not gone and after.get("autoCompactWindow") == 200000 and after.get("permissions")
            and win(canon) is None and not list((s.state / "orchestrations").glob("*.json"))
            and bind_of("local_prior").get("card", "").endswith("prior-work.md"), f"{r.stdout} left={gone} bwt={after}")

    # /orchestrate new with no worktree given: the transition creates the layout itself, RESUME.md
    # points at the kickoff, and /wrap's commit marks the file card current so the guard allows the clear.
    wt_base = s.tmp / "worktrees"
    (canon / "tasks" / "m11").mkdir(parents=True)
    (canon / "tasks" / "m11" / "KICKOFF.md").write_text("# kickoff\n")
    r = s.run(["orchestration", "new", "m11"], canon, host="local_o11", extra={"CONTEXT_CARD_WORKTREES": str(wt_base)})
    made = wt_base / "canon-m11-builder"
    resume11 = (canon / "tasks" / "m11" / "RESUME.md").read_text() if (canon / "tasks" / "m11" / "RESUME.md").exists() else ""
    s.check("new without a worktree creates the Builder worktree (own branch) and the Challenger folder",
            r.returncode == 0 and (made / ".git").exists() and (wt_base / "canon-m11-challenger" / "analysis_outputs" / "reviewer-evidence" / "inbox").is_dir()
            and s.git(made, "branch", "--show-current") == "orchestration/m11/builder", r.stdout + r.stderr)
    s.check("RESUME.md points phase 2 at the kickoff", "KICKOFF.md" in resume11 and "phase 2 begins" in resume11, resume11[:200])
    import time as _t
    aged = _t.time() - 600  # RESUME.md was written at the transition, before Michael typed /wrap
    os.utime(canon / "tasks" / "m11" / "RESUME.md", (aged, aged))
    wrap11 = s.transcript("wrap11", [typed(WRAP, -60), EXPANSION])
    r = s.run(["clear-guard"], canon, {"tool_input": {"session_id": "self"}, "transcript_path": wrap11}, host="local_o11")
    blocked_before = r.returncode == 2
    s.run(["commit", "checkpoint: transition"], canon, host="local_o11")
    r = s.run(["clear-guard"], canon, {"tool_input": {"session_id": "self"}, "transcript_path": wrap11}, host="local_o11")
    s.check("transition: /wrap's commit marks RESUME.md current, then the guard allows the clear", blocked_before and r.returncode == 0, f"rc={r.returncode}")
    r = s.run(["session-start"], canon, {"source": "startup"}, host="local_o11")
    s.check("the cleared Orchestrator chat starts with RESUME.md (kickoff pointer) loaded", "KICKOFF.md" in r.stdout and "just refreshed" in r.stdout, r.stdout[:200])
    s.run(["orchestration", "end"], canon, host="local_o11", extra={"CONTEXT_CARD_WORKTREES": str(wt_base)})
    s.check("end keeps the Builder worktree (it holds the work)", made.is_dir(), "")

    # /orchestrate off and on: pause and resume. Paused: the Orchestrator is a normal agent, running
    # Builders are held idle (blocked, not unguarded), and none activate.
    s.run(["orchestration", "new", "m9", "--builder-worktree", str(bwt)], canon, host="local_o9")
    start(bwt, "local_p1")
    r = s.run(["orchestration", "off"], canon, host="local_o9")
    e1 = s.run(["role-guard"], canon, {"tool_name": "Edit", "tool_input": {"file_path": str(canon / "README.md")}}, host="local_o9")
    g1 = s.run(["role-guard"], bwt, {"tool_name": "Bash", "tool_input": {"command": "pytest -q"}}, host="local_p1")
    w1 = s.run(["role-guard"], bwt, {"tool_name": "Edit", "tool_input": {"file_path": str(bwt / "app.py")}}, host="local_p1")
    start(bwt, "local_p2")
    st = s.run(["orchestration", "status"], canon, host="local_o9")
    bst = s.run(["orchestration", "status"], bwt, host="local_p1")
    reload = s.run(["session-start"], bwt, {"source": "compact"}, host="local_p1")
    s.check("off pauses: Orchestrator guard lifted; running Builders held idle (edits and shell blocked); none activate; status and reload say paused",
            r.returncode == 0 and e1.returncode == 0 and g1.returncode == 3 and w1.returncode == 3 and not role_of("local_p2")
            and "paused" in st.stdout and "paused" in bst.stdout and "PAUSED" in reload.stdout,
            f"{r.stdout}{st.stdout}{bst.stdout} e={e1.returncode} g={g1.returncode} w={w1.returncode}")
    r = s.run(["orchestration", "new", "m9", "--builder-worktree", str(bwt)], canon, host="local_o9")
    s.check("new while paused is refused (resume with on)", r.returncode != 0 and "paused" in r.stderr, r.stderr)
    r = s.run(["orchestration", "on"], canon, host="local_o9")
    e2 = s.run(["role-guard"], canon, {"tool_name": "Edit", "tool_input": {"file_path": str(canon / "README.md")}}, host="local_o9")
    g2 = s.run(["role-guard"], bwt, {"tool_name": "Bash", "tool_input": {"command": "git push"}}, host="local_p1")
    g3 = s.run(["role-guard"], bwt, {"tool_name": "Bash", "tool_input": {"command": "pytest -q"}}, host="local_p1")
    s.check("on resumes: guards back, the idle hold lifted", r.returncode == 0 and e2.returncode == 3 and g2.returncode == 3 and g3.returncode == 0,
            f"e={e2.returncode} g={g2.returncode} g3={g3.returncode}")
    r = s.run(["orchestration", "on"], canon, host="local_o9")
    s.check("on when already on says so", r.returncode == 0 and "already on" in r.stdout, r.stdout)
    r = s.run(["orchestration", "off"], bwt, host="local_p1")
    s.check("a Builder cannot pause the orchestration", r.returncode != 0, r.stdout)
    r = s.run(["orchestration", "off"], canon, host="local_nobody")
    s.check("a chat with no role cannot pause it", r.returncode != 0, r.stdout)

    # Builder subagents (ADR-0010): their calls carry the Orchestrator's session. role-guard routes them
    # to the Builder rules (as their own agent hook does), and an open Builder holds off the clear.
    def sub(tool: str, tool_input: dict, name: str = "role-guard", host: str = "local_o9"):
        return s.run([name], canon, {"tool_name": tool, "tool_input": tool_input, "agent_type": "builder", "agent_id": "a-b1"}, host=host)
    cdw = f"cd {bwt} && "
    for tool, tool_input, want in (
        ("Edit", {"file_path": str(bwt / "app.py")}, 0),
        ("Write", {"file_path": str(bwt / "src" / "new.py")}, 0),
        ("Edit", {"file_path": str(canon / "README.md")}, 3),
        ("Write", {"file_path": str(bwt / ".claude" / "agents" / "builder.md")}, 3),
        ("Write", {"file_path": str(bwt / ".git" / "hooks" / "pre-push")}, 3),
        ("Bash", {"command": cdw + "pytest -q"}, 0),
        ("Bash", {"command": f'cd "{bwt}/src"; ls'}, 0),
        ("Bash", {"command": "pytest -q"}, 3),
        ("Bash", {"command": f"cd {canon} && git status"}, 3),
        ("Bash", {"command": cdw + "git commit -qm wip"}, 0),
        ("Bash", {"command": cdw + "git push"}, 3),
        ("Bash", {"command": cdw + "python3 ~/.claude/hooks/context-card.py queue add x"}, 3),
        ("Bash", {"command": cdw + "python3 ~/.claude/hooks/context-card.py status"}, 0),
        ("PowerShell", {"command": f"Set-Location '{bwt}'; Get-ChildItem"}, 0),
    ):
        for name in ("role-guard", "builder-guard"):
            r = sub(tool, tool_input, name)
            shown = next(iter(tool_input.values())).replace(str(bwt), "<wt>").replace(str(canon), "<canon>")
            s.check(f"builder subagent ({name}): {tool} {shown} -> {want}", r.returncode == want, f"rc={r.returncode} {r.stderr[:160]}")
    r = sub("Edit", {"file_path": str(bwt / "app.py")}, "builder-guard", host="local_nobody")
    s.check("a Builder subagent outside a session that leads an orchestration does nothing", r.returncode == 3, f"rc={r.returncode}")
    agents = SCRIPT.parents[1] / "global-agents"
    bodies = {n: (agents / f"{n}.md").read_text(encoding="utf-8").split("\n---\n", 1) for n in ("builder", "builder-high")}
    s.check("both Builder agents: one body, a fail-closed builder-guard hook, no Agent or messaging tools",
            bodies["builder"][1] == bodies["builder-high"][1] and all(
                'builder-guard; rc=$?; [ "$rc" -eq 0 ] || exit 2' in head and "\ntools: " in head
                and not any(t in head.split("\ntools: ", 1)[1].split("\n", 1)[0] for t in ("Agent", "SendMessage"))
                for head, _ in bodies.values()), "")

    wrap9 = s.transcript("wrap9", [typed(WRAP, -60), EXPANSION])
    clear9 = lambda: s.run(["clear-guard"], canon, {"tool_input": {"session_id": "self"}, "transcript_path": wrap9}, host="local_o9")
    compact9 = lambda: s.run(["pre-compact"], canon, {"trigger": "auto", "transcript_path": fable}, host="local_o9")
    for agent, aid in (("builder", "a-b1"), ("builder-high", "a-b2"), ("Explore", "a-x"), ("builder", "a-b1")):
        s.run(["subagent-start"], canon, {"agent_type": agent, "agent_id": aid}, host="local_o9")
    listed = s.run(["builders"], canon, host="local_o9").stdout
    c1, p1 = clear9(), compact9()
    s.check("open Builders are recorded (not other subagents); /wrap refused while one is open; compaction asks for the full context",
            "a-b1" in listed and "a-b2" in listed and "a-x" not in listed and c1.returncode == 2 and "still open" in c1.stderr
            and "full working context" in p1.stdout and "Summarize only what happened after" not in p1.stdout, listed + c1.stderr + p1.stdout[:300])
    s.run(["builders", "retire", "a-b1"], canon, host="local_o9")
    listed, c2 = s.run(["builders"], canon, host="local_o9").stdout, clear9()
    s.check("retire closes one Builder; the clear still waits for the other", "a-b1" not in listed and "a-b2" in listed and "still open" in c2.stderr, listed + c2.stderr)
    s.run(["builders", "forget"], canon, host="local_o9")
    c3, p3 = clear9(), compact9()
    s.check("forget clears the records: the clear and compaction are back to normal",
            "still open" not in c3.stderr and "full working context" not in p3.stdout, c3.stderr + p3.stdout[:300])
    s.run(["subagent-start"], canon, {"agent_type": "builder", "agent_id": "a-b3"}, host="local_o9")

    s.run(["orchestration", "off"], canon, host="local_o9")
    r = sub("Edit", {"file_path": str(bwt / "app.py")}, "builder-guard")
    s.check("a paused orchestration holds its Builder subagents idle", r.returncode == 3 and "paused" in r.stderr, r.stderr)
    r = s.run(["orchestration", "end"], canon, host="local_o9")
    s.check("end works while paused", r.returncode == 0 and not role_of("local_p1") and not role_of("local_o9"), r.stdout + r.stderr)
    s.check("end drops the Orchestrator's open Builder records", not list((s.state / "open-builders").glob("*.json")), "")

    # One window record per folder: autowrap and an orchestration share it; the old limit returns last.
    for order in ("autowrap-first", "orchestration-first"):
        (bwt / ".claude" / "settings.local.json").write_text(json.dumps({"autoCompactWindow": 200000, "permissions": {"allow": ["Bash(ls:*)"]}}))
        (canon / ".claude").mkdir(exist_ok=True)
        (canon / ".claude" / "settings.local.json").write_text(json.dumps({"autoCompactWindow": 500000}))
        if order == "autowrap-first":
            s.run(["autowrap", "limit", "300k"], canon, host="local_aw3")
            s.run(["orchestration", "new", "m12", "--builder-worktree", str(bwt)], canon, host="local_o12")
            mid = (win(canon) or {}).get("autoCompactWindow")
            s.run(["autowrap", "off"], canon, host="local_aw3")
            still = (win(canon) or {}).get("autoCompactWindow")
            s.run(["orchestration", "end"], canon, host="local_o12")
        else:
            s.run(["orchestration", "new", "m12", "--builder-worktree", str(bwt)], canon, host="local_o12")
            s.run(["autowrap", "limit", "300k"], canon, host="local_aw3")
            mid = (win(canon) or {}).get("autoCompactWindow")
            s.run(["orchestration", "end"], canon, host="local_o12")
            still = (win(canon) or {}).get("autoCompactWindow")
            s.run(["autowrap", "off"], canon, host="local_aw3")
        final = (win(canon) or {}).get("autoCompactWindow")
        s.check(f"shared window ({order}): custom limit wins while held, stays until the last holder leaves, then the old 500k returns",
                mid == 300000 and still in (300000, 350000) and final == 500000 and (win(bwt) or {}).get("autoCompactWindow") == 200000,
                f"mid={mid} still={still} final={final} bwt={win(bwt)}")
    r = s.run(["autowrap", "off"], canon, host="local_aw3")
    s.check("autowrap off with nothing on changes nothing", r.returncode == 0 and "not on" in r.stdout and (win(canon) or {}).get("autoCompactWindow") == 500000, r.stdout)
    s.run(["orchestration", "new", "m13", "--builder-worktree", str(bwt)], canon, host="local_o13")
    start(bwt, "local_b13")
    r = s.run(["autowrap", "off"], bwt, host="local_b13")
    s.check("a Builder's autowrap off neither unbinds its card nor strips the orchestration's window",
            bind_of("local_b13") and role_of("local_b13") and (win(bwt) or {}).get("autoCompactWindow") == 350000, r.stdout)
    st = s.run(["autowrap", "status"], canon, host="local_o13")
    s.check("autowrap status names the orchestration holding the window", "orch:m13" in st.stdout, st.stdout)
    s.run(["orchestration", "end"], canon, host="local_o13")
    (canon / "tasks" / "m9" / "RESUME.md").write_text("# RESUME\n")
    s.run(["bind", "--file", "tasks/m9/RESUME.md"], canon, host="local_f1")
    s.run(["autowrap", "on", "--bound"], canon, host="local_f1")
    s.run(["autowrap", "off"], canon, host="local_f1")
    s.check("autowrap off never unbinds a file card (an Orchestrator's RESUME.md)", bind_of("local_f1").get("kind") == "file", str(bind_of("local_f1")))

    # /autowrap limit: a custom window per folder, bounded, restored by off.
    aw = s.repo("aw", "git@github:MGallo-Code/aw.git")
    (aw / ".claude").mkdir()
    (aw / ".claude" / "settings.local.json").write_text(json.dumps({"autoCompactWindow": 500000, "keep": 1}))
    r = s.run(["autowrap", "limit", "250k"], aw, host="local_aw2")
    lim = win(aw) or {}
    s.check("autowrap limit 250k sets this folder's window and keeps other keys", r.returncode == 0 and lim.get("autoCompactWindow") == 250000 and lim.get("keep") == 1, r.stdout + r.stderr)
    r = s.run(["autowrap", "limit", "100k"], aw, host="local_aw2")
    s.check("autowrap limit refuses a window that would thrash (< 150k)", r.returncode != 0 and (win(aw) or {}).get("autoCompactWindow") == 250000, r.stderr)
    bad = [s.run(["autowrap", "limit", v], aw, host="local_aw2") for v in ("250kk", "inf", "2000k", "abc")]
    s.check("autowrap limit rejects 250kk, inf, 2000k and abc cleanly (no traceback)",
            all(b.returncode != 0 and "Traceback" not in b.stderr for b in bad) and "at most" in bad[2].stderr, " | ".join(b.stderr.strip()[:60] for b in bad))
    s.run(["autowrap", "off"], aw, host="local_aw2")
    s.run(["autowrap", "on"], aw, host="local_aw2")
    s.check("autowrap on after off uses 350k", (win(aw) or {}).get("autoCompactWindow") == 350000, str(win(aw)))
    s.run(["autowrap", "off"], aw, host="local_aw2")
    s.check("autowrap off restores the folder's previous limit", (win(aw) or {}).get("autoCompactWindow") == 500000 and (win(aw) or {}).get("keep") == 1, str(win(aw)))

    # A stale orchestration (Orchestrator role gone) activates nobody, its Builders go inert, and it
    # can be cleaned up from the checkout.
    s.run(["orchestration", "new", "m9", "--builder-worktree", str(bwt)], canon, host="local_o9")
    start(bwt, "local_b3")
    (s.state / "role" / "local_o9.json").unlink()
    start(bwt, "local_b4")
    r = s.run(["role-guard"], bwt, {"tool_name": "Bash", "tool_input": {"command": "git push"}}, host="local_b3")
    s.check("stale: no new Builder, and existing Builder roles go inert", not role_of("local_b4") and r.returncode == 0, f"rc={r.returncode}")
    shutil.rmtree(bwt)
    r = s.run(["orchestration", "end"], canon, host="local_nobody")
    s.check("a stale orchestration is cleaned up from the checkout, even with its worktree gone (no ghost folders)",
            r.returncode == 0 and not (s.state / "role" / "local_b3.json").exists() and not bwt.exists(), r.stdout + r.stderr)

    # Codex: the model's shell has CODEX_THREAD_ID; its hooks get the same id as stdin session_id.
    codex_env = {"CODEX_THREAD_ID": "thread-123", "CLAUDE_CODE_HOST_SESSION_ID": "local_stale", "CONTEXT_CARD_NEAREST": "codex"}
    (mine / ".claude" / "resume" / "codex-work.md").write_text("# codex-work\nCODEWORD-PUFFIN\n")
    r = s.run(["bind", "codex-work"], mine, host=None, extra=codex_env)
    s.check("codex: the model's shell binds by CODEX_THREAD_ID", r.returncode == 0 and (s.state / "bind" / "codex-thread-123.json").is_file(), r.stdout + r.stderr)
    r = s.run(["session-start", "--agent", "codex"], mine, {"source": "compact", "session_id": "thread-123"}, host=None, extra={"CLAUDE_CODE_HOST_SESSION_ID": "local_stale"})
    s.check("codex: SessionStart(compact) reloads the card by stdin session_id, ignoring stale Claude env", "CODEWORD-PUFFIN" in r.stdout, r.stdout)
    r = s.run(["pre-compact", "--agent", "codex"], mine, {"trigger": "auto", "session_id": "thread-123"}, host=None)
    s.check("codex: pre-compact is silent (Codex ignores it)", r.returncode == 0 and r.stdout == "", r.stdout)
    r = s.run(["session-start"], mine, {"source": "compact"}, extra={"CODEX_THREAD_ID": "thread-123"})
    s.check("a Claude hook ignores an inherited CODEX_THREAD_ID", "CODEWORD-HERON" in r.stdout and "PUFFIN" not in r.stdout, r.stdout[:200])
    r = s.run(["status"], mine, host=None, extra={"CODEX_THREAD_ID": "thread-9", "CLAUDE_CODE_HOST_SESSION_ID": "local_near", "CONTEXT_CARD_NEAREST": "claude"})
    s.check("a helper under Claude uses the Claude id even with a stale CODEX_THREAD_ID", "session: local_near" in r.stdout, r.stdout[:80])
    r = s.run(["role", "builder"], mine, host=None, extra={"CODEX_THREAD_ID": "thread-123"})
    s.check("codex: role is refused (no Codex guard)", r.returncode != 0 and "only in Claude Code" in (r.stderr + r.stdout), r.stdout + r.stderr)

    # Someone else's repo: the card stays outside it and nothing is committed.
    theirs = s.repo("theirs", "git@github.com:some-org/app.git")
    r = s.run(["bind", "client-fix"], theirs, host="local_theirs")
    local_cards = list((s.state / "cards").glob("theirs-*/client-fix.md"))
    s.check("foreign repo: card kept outside the repo", r.returncode == 0 and len(local_cards) == 1 and not (theirs / ".claude").exists(), r.stdout + r.stderr)
    r = s.run(["commit", "checkpoint: x"], theirs, host="local_theirs")
    s.check("foreign repo: commit is a no-op", r.returncode == 0 and "nothing to commit" in r.stdout and s.git(theirs, "status", "--porcelain") == "", r.stdout)

    # /autowrap on/off: merged settings, excluded locally, removable.
    settings = mine / ".claude" / "settings.local.json"
    settings.write_text(json.dumps({"permissions": {"allow": ["Bash(ls:*)"]}}))
    s.run(["bind", "aw-work"], mine, host="local_aw")
    r = s.run(["autowrap", "on", "--bound"], mine, host="local_aw")
    data = json.loads(settings.read_text())
    exclude = (mine / ".git" / "info" / "exclude").read_text()
    s.check("autowrap on: window set, other keys kept, excluded locally",
            r.returncode == 0 and data.get("autoCompactWindow") == 350000 and data.get("permissions") and "/.claude/settings.local.json" in exclude, f"{data} {r.stderr}")
    r = s.run(["autowrap", "off"], mine, host="local_aw")
    s.check("autowrap off: window removed and this chat's card unbound", "autoCompactWindow" not in json.loads(settings.read_text())
            and not (s.state / "bind" / "local_aw.json").exists(), settings.read_text())
    queue_fixtures(s)


def queue_fixtures(s: Suite) -> None:  # called at the end of fixtures()
    """ADR-0008 (amended 2026-10-02): a checklist the agent keeps (tasks R<n>, one line each) plus an
    inbox the hooks fill with every message Michael types (m<n>), swept from the transcript at Stop,
    PreCompact and SessionStart. Restores show open tasks and unreviewed messages only."""
    work = s.repo("queue-work", None)
    host = "local_queue"
    q = s.state / "queue" / f"{host}.jsonl"

    def said(text: str, uid: str, offset_s: float = 0.0) -> dict:
        return {**typed(text, offset_s), "uuid": uid}

    def midturn(text: str, uid: str, offset_s: float = 0.0, **att) -> dict:
        stamp = iso(offset_s)
        return {"type": "attachment", "uuid": f"e-{uid}", "timestamp": stamp,
                "attachment": {"type": "queued_command", "prompt": text, "source_uuid": uid, "commandMode": "prompt",
                               "origin": {"kind": "human"}, "timestamp": stamp, **att}}

    tpath = s.transcript("queue", [said("an old request from before the queue existed", "old1", -3600),
                                   midturn("an old mid-turn message", "old2", -3500)])

    def append(path: str, *entries: dict, raw: str = "") -> None:
        with open(path, "a") as handle:
            handle.write("".join(json.dumps(e) + "\n" for e in entries) + raw)

    def stop(path: str = tpath, hook: str = "request-capture", **extra) -> subprocess.CompletedProcess:
        return s.run([hook], work, {"transcript_path": path, **extra}, host=host)

    def queue(*args: str, who: str = host) -> subprocess.CompletedProcess:
        return s.run(["queue", *args], work, host=who)

    def inbox() -> list[str]:
        try:
            return [json.loads(line)["text"] for line in q.read_text().splitlines() if '"op": "msg"' in line]
        except OSError:
            return []

    append(tpath, said("Sort the iCloud docs and CODEWORD-WREN", "u1"))
    r = stop()
    s.check("queue: the turn's typed message lands in the inbox verbatim, silently", r.returncode == 0 and r.stdout == ""
            and inbox() == ["Sort the iCloud docs and CODEWORD-WREN"], f"{inbox()} {r.stdout} {r.stderr}")
    s.check("queue: a captured message is not a task", "No open tasks" in queue("list").stdout or "empty" in queue("list").stdout,
            queue("list").stdout)

    append(tpath,
           midturn("mid-turn: CODEWORD-FINCH", "m1"),
           {"type": "attachment", "uuid": "p1", "timestamp": iso(), "turnOrigin": "human",  # gets past the byte filter
            "attachment": {"type": "queued_command", "prompt": "peer: CODEWORD-PEER", "origin": {"kind": "peer"}, "timestamp": iso()}},
           {"type": "attachment", "uuid": "n1", "timestamp": iso(),
            "attachment": {"type": "queued_command", "prompt": "<task-notification>CODEWORD-TASK", "commandMode": "task-notification", "timestamp": iso()}},
           {**midturn("subagent: CODEWORD-SIDE", "sc1"), "isSidechain": True},
           {**said("Another Claude session sent a message: CODEWORD-PEER2", "pu"), "origin": {"kind": "peer"}},
           {**said("<task-notification>CODEWORD-TASK2", "tn"), "origin": {"kind": "task-notification"}},
           {**said("Base directory for this skill: CODEWORD-META", "me"), "isMeta": True},
           said("<command-message>wrap</command-message>\n<command-name>/wrap</command-name>", "w1"),
           said("<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>check CI</command-args>", "l1"),
           said("<system-reminder>\nThe separate session for background task t1 has ended.\n</system-reminder>\n\nkeep only this: CODEWORD-CROW", "r1"),
           said("<system-reminder>\nCODEWORD-NOTICE only\n</system-reminder>", "r2"),
           PEER, SUMMARY, TOOL_RESULT, EXPANSION,
           raw='{"type": "attachment", "attachment": {"type": "queued_command", "prompt": "half-writ')
    r = stop()
    got = inbox()
    s.check("queue: mid-turn messages and slash commands with arguments are captured, harness notices stripped",
            got[1:] == ["mid-turn: CODEWORD-FINCH", "/loop check CI", "keep only this: CODEWORD-CROW"], str(got))
    s.check("queue: peers, task notifications, subagents, meta, summaries, tool results, bare commands and pure notices are never captured",
            not any(w in " ".join(got) for w in ("CODEWORD-PEER", "CODEWORD-TASK", "CODEWORD-SIDE", "CODEWORD-META",
                                                 "CODEWORD-NOTICE", "continued from", "Resume cards", "/wrap")), str(got))
    s.check("queue: the first sweep reaches back minutes, never to older history", not any("old" in x for x in got), str(got))
    nag = json.loads(r.stdout) if r.stdout.strip().startswith("{") else {}
    s.check("queue: three or more unreviewed messages make the Stop hook ask for a checklist update",
            nag.get("decision") == "block" and "queue add" in nag.get("reason", "") and "queue reviewed" in nag.get("reason", ""), r.stdout)
    r = stop(stop_hook_active=True)
    s.check("queue: the Stop hook never asks twice in a row", r.stdout == "", r.stdout)

    append(tpath, raw='ten", "origin": {"kind": "human"}, "commandMode": "prompt", "source_uuid": "half", "timestamp": "' + iso() + '"}}\n')
    append(tpath, midturn("mid-turn: CODEWORD-FINCH", "m1"))  # Claude Code re-writes a queued message later with the same id
    stop(stop_hook_active=True)
    stop(stop_hook_active=True)
    got = inbox()
    s.check("queue: a line finished after a sweep lands once; a re-written message and a second sweep add nothing",
            got.count("half-written") == 1 and got.count("mid-turn: CODEWORD-FINCH") == 1 and len(got) == 5, str(got))
    other = s.transcript("queue-after-clear", [said("after the clear: CODEWORD-HAWK", "c1")])
    stop(other, stop_hook_active=True)
    append(tpath, said("back on the first transcript: CODEWORD-KITE", "k1"))
    stop(stop_hook_active=True)
    got = inbox()
    s.check("queue: offsets are kept per transcript (a new one after a clear, then the old one again)",
            got[5:] == ["after the clear: CODEWORD-HAWK", "back on the first transcript: CODEWORD-KITE"], str(got))

    append(tpath, said("typed this turn, not yet swept: CODEWORD-HERON", "h1"))
    queue("reviewed")
    s.check("queue reviewed sweeps first, so the turn's own messages count as reviewed",
            "CODEWORD-HERON" in " ".join(inbox()) and "Unreviewed" not in queue("list").stdout, queue("list").stdout)
    r1, r2 = queue("add", "Sort iCloud Documents"), queue("add", "Loop CI checks")
    queue("title", "R2", "Watch CI until green")
    r = queue("reviewed")
    lst = queue("list").stdout
    s.check("queue: add and title make a one-line checklist; reviewed clears the inbox",
            r1.stdout.strip() == "added R1" and "[ ] R1 Sort iCloud Documents" in lst and "[ ] R2 Watch CI until green" in lst
            and "Unreviewed" not in lst and r.returncode == 0, lst + r.stderr)
    r = stop()
    s.check("queue: with the inbox reviewed the Stop hook stays quiet", r.stdout == "", r.stdout)
    r = queue("done", "R2", "--note", "green")
    lst, everything = queue("list").stdout, queue("list", "--all").stdout
    s.check("queue done checks a task off; --all shows it", "R2" not in lst and "[x] R2 Watch CI until green  (green)" in everything,
            lst + everything + r.stderr)
    s.check("queue done refuses an unknown or message id", queue("done", "R99").returncode == 1 and queue("done", "m1").returncode == 1)

    append(tpath, midturn("typed just before an auto-compaction: CODEWORD-LARK", "m2"))
    r = stop(hook="pre-compact", trigger="auto")
    s.check("queue: PreCompact sweeps first, so a mid-turn message is never summarized away",
            "CODEWORD-LARK" in " ".join(inbox()) and "restored" in r.stdout, r.stdout + r.stderr)
    r = stop(hook="session-start", source="compact")
    out = r.stdout
    s.check("queue: after a compaction the checklist comes back one line per open task",
            "- [ ] R1 Sort iCloud Documents" in out and "R2" not in out, out)
    s.check("queue: only unreviewed messages come back, never the reviewed ones",
            "CODEWORD-LARK" in out and "CODEWORD-WREN" not in out and "CODEWORD-FINCH" not in out, out)
    s.check("queue: the restore stays small", len(out) < 2500, len(out))

    q2 = s.state / "queue" / "local_queue-legacy.jsonl"
    q2.write_text(json.dumps({"op": "add", "id": "R1", "ts": iso(), "text": "an older free-text request\nwith a second line",
                              "src": "", "cwd": str(work)}) + "\n")
    r = queue("list", who="local_queue-legacy")
    s.check("queue: an item written before the checklist reads as a task titled by its text",
            "[ ] R1 an older free-text request with a second line" in r.stdout, r.stdout + r.stderr)

    r = s.run(["session-start"], work, {"source": "startup"}, host="local_queue-other")
    s.check("queue: another conversation starts empty", "CODEWORD" not in r.stdout and "Sort iCloud" not in r.stdout, r.stdout)
    r = queue("list", "--project", who="local_queue-other")
    s.check("queue list --project shows other conversations' open tasks here", "Sort iCloud Documents" in r.stdout, r.stdout + r.stderr)

    def rollout(name: str, source: object, *messages: str) -> str:
        lines = [{"type": "session_meta", "payload": {"id": name, "source": source, "originator": "Codex Desktop"}},
                 {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "# AGENTS.md CODEWORD-AGENTS"}]}}]
        lines += [{"type": "event_msg", "timestamp": iso(), "payload": {"type": "user_message", "client_id": f"{name}-{i}", "message": m}}
                  for i, m in enumerate(messages)]
        return s.transcript(name, lines)

    live = rollout("codex-live", "vscode", "codex: CODEWORD-OWL", "two", "three", "four")
    r = s.run(["request-capture", "--agent", "codex"], work, {"session_id": "th-1", "transcript_path": live}, host=None,
              extra={"CODEX_THREAD_ID": "stale"})
    cq = s.state / "queue" / "codex-th-1.jsonl"
    s.check("queue: Codex sweeps what Michael typed into its inbox, silently (no Stop nag)", r.returncode == 0 and r.stdout == ""
            and cq.is_file() and "CODEWORD-OWL" in cq.read_text() and "CODEWORD-AGENTS" not in cq.read_text(), r.stdout + r.stderr)
    for source in ("exec", {"subagent": {"other": "guardian"}}):
        scripted = rollout(f"codex-{'exec' if source == 'exec' else 'sub'}", source, "scripted: CODEWORD-BOT")
        s.run(["request-capture", "--agent", "codex"], work, {"session_id": "th-2", "transcript_path": scripted}, host=None)
    s.check("queue: codex exec runs and Codex subagents are never captured", not (s.state / "queue" / "codex-th-2.jsonl").exists(), "")

    bot = s.transcript("queue-bot", [said("headless: CODEWORD-BOT", "b1")])
    s.run(["request-capture"], work, {"transcript_path": bot}, entry="sdk-cli", host="local_queue-bot")
    s.run(["request-capture"], work, {"transcript_path": bot}, host="local_queue-bot", extra={"CONTEXT_CARD_PRINT_MODE": "1"})
    s.check("queue: headless runs and a nested `claude -p` are never captured", not (s.state / "queue" / "local_queue-bot.jsonl").exists(), "")
    r = s.run(["request-capture"], work, "not json", host=host)
    s.check("queue: a broken hook input never fails the hook", r.returncode == 0, r.stderr)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--script", type=Path, default=SCRIPT)
    parser.add_argument("--revert-test", action="store_true")
    args = parser.parse_args()
    if args.revert_test:
        work = Path(tempfile.mkdtemp(prefix="context-card-revert-"))
        mutant = work / "context-card.py"
        text = args.script.read_text(encoding="utf-8")
        ok = True
        plants = [(m, m + "    return 0  # REVERT-TEST: always allows\n") for m in (
            "def hook_clear_guard(data: dict) -> int:\n", "def hook_role_guard(data: dict) -> int:\n",
            "def hook_challenger_guard(data: dict) -> int:\n", "def hook_builder_guard(data: dict) -> int:\n")]
        plants += [('data.get("source") == "startup" and ', ""),  # activation on any source
                   ("                remove(path)\n                cleaned += 1", "                cleaned += 1"),  # end skips Builders
                   ('binding.get("kind") != "file" and cards.get(sid)', 'cards.get(sid)'),  # autowrap off unbinds file cards
                   ("    if limit > WINDOW_MAX:", "    if False:"),  # no upper bound
                   ('    elif entry.get("type") == "user":', '    elif False:'),  # typed prompts dropped
                   ('    if entry.get("type") == "attachment":', '    if False:'),  # mid-turn messages dropped
                   ('origin.get("kind") != "human"', 'origin.get("kind") == "nobody"'),  # peers captured
                   ("        print((\"\\n\" if status else \"\") + block)", "        pass"),  # nothing restored after compaction
                   ("    return source in CODEX_INTERACTIVE", "    return True"),  # codex exec captured
                   ("    return headless() or print_mode()", "    return headless()"),  # nested claude -p captured
                   ('len(inbox) >= QUEUE_NAG_UNREVIEWED and not data.get("stop_hook_active")', 'False'),  # the nag never fires
                   (' and not data.get("stop_hook_active"):', ':'),  # the nag repeats forever
                   ("            for transcript in known_transcripts(sid):", "            for transcript in []:"),  # reviewed does not sweep
                   ("    if agent in BUILDER_AGENTS:\n        return hook_builder_guard(data)", "    if False:\n        pass"),  # Orchestrator rules judge Builders
                   ("    running = open_builders(sid)\n", "    running = {}\n"),  # clear ignores open Builders
                   ("    if not sid or agent not in BUILDER_AGENTS", "    if True or agent not in BUILDER_AGENTS"),  # Builders never recorded
                   ('        return role_block("The orchestration is paused (/orchestrate on resumes it); the Builder is held idle.")',
                    "        pass"),  # a paused orchestration's Builder works
                   ("        if not where or not _under(", "        if False and not _under("),  # shell may start anywhere
                   ('        if _under(target, str(real_root / ".claude")) or', '        if False and _under(target, str(real_root / ".claude")) or'),
                   ('        if helper and helper.group(1) != "status":', "        if False:"),  # Builder runs Orchestrator helpers
                   ("    if open_builders(sid):\n        # This compaction", "    if False:\n        # This compaction"),  # narrowing kept
                   ("            remove(open_builders_path(orch_sid))", "            pass")]  # end keeps open Builders
        labels = ["clear guard always allows", "role guard always allows", "challenger guard always allows", "builder guard always allows",
                  "activation on any source", "end skips Builder cleanup", "autowrap off unbinds a file card",
                  "limit has no upper bound", "queue drops typed prompts", "queue drops mid-turn messages",
                  "queue captures peers", "queue not restored after compaction", "queue captures codex exec",
                  "queue captures a nested claude -p", "the checklist nag never fires", "the checklist nag repeats forever",
                  "queue reviewed does not sweep first",
                  "role guard judges Builders by the Orchestrator's rules", "clear ignores open Builders", "Builders never recorded",
                  "a paused orchestration's Builder works", "a Builder shell may start anywhere", "a Builder may edit .claude/",
                  "a Builder may run Orchestrator helpers", "compaction narrows while a Builder is open", "end keeps open Builder records"]
        for (marker, replacement), label in zip(plants, labels):
            if marker not in text:
                print(f"revert-test: plant anchor not found: {marker.strip()[:60]}", file=sys.stderr)
                return 1
            mutant.write_text(text.replace(marker, replacement, 1), encoding="utf-8")
            suite = Suite(mutant, quiet=True)
            try:
                fixtures(suite)
            finally:
                shutil.rmtree(suite.tmp, ignore_errors=True)
            if suite.failures:
                print(f"revert-test ok: '{label}' fails {len(suite.failures)} fixture(s)")
            else:
                print(f"revert-test FAILED: nothing caught '{label}'", file=sys.stderr)
                ok = False
        shutil.rmtree(work, ignore_errors=True)
        return 0 if ok else 1
    suite = Suite(args.script, quiet=False)
    # Run under the conditions of a hook in a linked worktree: an absolute GIT_DIR (and index)
    # pointing at a decoy repository. The decoy's config must come out byte-identical; the
    # 2026-09-29 incident rewrote the real EA config (core.bare, [user], [commit]) this way.
    decoy = suite.tmp / "decoy"
    subprocess.run(["git", "init", "-q", str(decoy)], check=True, env=clean_env())
    decoy_config = (decoy / ".git" / "config").read_bytes()
    saved = {k: os.environ.get(k) for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE")}
    os.environ.update({"GIT_DIR": str(decoy / ".git"), "GIT_INDEX_FILE": str(decoy / ".git" / "index"),
                       "GIT_WORK_TREE": str(decoy)})
    try:
        fixtures(suite)
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        suite.check("an inherited GIT_DIR (hook in a linked worktree) is never written to",
                    (decoy / ".git" / "config").read_bytes() == decoy_config,
                    (decoy / ".git" / "config").read_text(errors="replace"))
        shutil.rmtree(suite.tmp, ignore_errors=True)
    if suite.failures:
        print(f"\ncheck-context-card: {len(suite.failures)} failure(s)", file=sys.stderr)
        return 1
    print("\ncheck-context-card: all fixtures passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
