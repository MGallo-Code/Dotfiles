#!/usr/bin/env python3
"""check-ask.py - INV-26 (ADR-0011): questions for Michael reach him as the questions page or a
clean question card, never as a list at the end of a reply.

Hermetic (throwaway ASK_HOME and HOME). Proves on real output:
  - asklint flags agent-internal labels and picture promises, and passes plain questions;
  - ask.py validates input, serves its page only on 127.0.0.1 behind the token and a Host check,
    escapes question text into the page, takes the first valid answer only, and reports answers,
    waits, closes, stops and prunes correctly; two asks never cross;
  - ask-guard denies a labeled or picture-promising card (with a one-shot audited override),
    blocks once on a reply ending in a question list (Claude transcript or Codex payload), stays
    silent in headless lanes and on bad input;
  - the three scripts parse as Python 3.9 (macOS /usr/bin/python3 runs them);
  - on POSIX with bash and jq: register_ask_guard + configure-agent-integrations twice leave
    settings.json byte-identical, ask-guard once per event, the completion hook last.

--revert-test  breaks each guarded behavior in a copy of the scripts; every break must FAIL.
--machine      the live machine: ask-guard registered once per event and the registered command
               really denies a labeled card; Codex has the Stop guard and the question-card flag.
"""
from __future__ import annotations

import argparse
import ast
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FILES = ("tools/ask/ask.py", "tools/ask/asklint.py", "tools/ask/page.html", "claude-config/global-hooks/ask-guard.py")


class Fail(Exception):
    pass


def expect(cond: bool, what: str) -> None:
    if not cond:
        raise Fail(what)


# ---- helpers ------------------------------------------------------------------------------

def http(url: str, data: bytes | None = None, ctype: str | None = None, host: str | None = None,
         method: str | None = None) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=data, method=method)
    if ctype:
        req.add_header("Content-Type", ctype)
    if host:
        req.add_header("Host", host)

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=5) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def answer(url: str, answers: list[dict]) -> int:
    return http(url + "answers", json.dumps({"answers": answers}).encode(), "application/json")[0]


class Tree:
    """A copy of the scripts under test, so revert mutations never touch the repo."""

    def __init__(self, base: Path, ask_home: Path):
        self.root, self.ask_home = base, ask_home
        for rel in FILES:
            (base / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / rel, base / rel)

    def env(self, **extra: str) -> dict:
        env = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "SSH_CONNECTION")}
        env.update({"ASK_HOME": str(self.ask_home), "ASK_GUARD_PRINT_MODE": "0", "CLAUDE_CODE_ENTRYPOINT": "cli",
                    "ASK_LIFETIME": "300", **extra})  # a server a failed fixture leaves behind dies soon
        return env

    def ask(self, *args: str, stdin: str | None = None, **env: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.root / "tools/ask/ask.py"), *args], input=stdin,
                              capture_output=True, text=True, env=self.env(**env), timeout=60)

    def hook(self, payload: object, **env: str) -> str:
        raw = payload if isinstance(payload, str) else json.dumps(payload)
        out = subprocess.run([sys.executable, str(self.root / "claude-config/global-hooks/ask-guard.py")], input=raw,
                             capture_output=True, text=True, env=self.env(**env), timeout=30)
        expect(out.returncode == 0, f"ask-guard exited {out.returncode} (it must always exit 0)")
        return out.stdout.strip()

    def open(self, questions: dict, *flags: str, **env: str) -> tuple[str, str]:
        path = self.root / f"q-{time.time_ns()}.json"
        path.write_text(json.dumps(questions), encoding="utf-8")
        out = self.ask("open", str(path), *flags, **env)
        expect(out.returncode == 0, f"ask.py open failed: {out.stderr.strip()}")
        lines = dict(line.split(": ", 1) for line in out.stdout.splitlines() if ": " in line)
        return lines["Questions page"], lines["Ask id"]


def q(question: str = "Which layout should the inbox list use?", multi: bool = False, n: int = 2, **opt) -> dict:
    options = [{"label": f"Option {i + 1}", "detail": f"What option {i + 1} gives you."} for i in range(n)]
    options[0].update(opt)
    return {"question": question, "context": "The inbox shows about 9 emails per screen today.", "multi": multi,
            "options": options}


# ---- fixtures -----------------------------------------------------------------------------

def lint_fixtures(t: Tree) -> None:
    spec = importlib.util.spec_from_file_location("asklint_under_test", t.root / "tools/ask/asklint.py")
    lint = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lint)
    flagged = ["Adopt INV-14 region-ring semantics?", "Keep scripts/configure-codex-defaults.py as is?",
               "Should default_mode_request_user_input stay on?", "Revert f199c5f?", "Call render() twice?",
               "Edit ~/.codex/config.toml?", "Delete C:\\Users\\moses\\notes.txt?", "Edit setup.ps1?"]
    pictures = ["Which mock do you prefer?", "See the screenshot in the right pane", "Pick one of the two mocks"]
    plain = ["Am I on the right track?", "Should the tests mock the network?", "Which Docker base image?",
             "Next.js or Astro?", "Publish to example.com/blog.html?", "Open https://github.com/a/b/pull/3?",
             "Use Cloudflare R2 for backups?", "Is the 1/2 split okay, or 2/3?", "Switch Codex to gpt-5.6-terra?"]
    for text in flagged:
        expect(lint.label_problems(text), f"asklint missed a label in {text!r}")
    for text in pictures:
        expect(lint.visual_problems(text), f"asklint missed a picture promise in {text!r}")
    for text in plain:
        found = lint.label_problems(text) + lint.visual_problems(text)
        expect(not found, f"asklint flagged plain text {text!r}: {found}")


def validation_fixtures(t: Tree) -> None:
    bad = {
        "no context": {"questions": [{**q(), "context": ""}]},
        "one option": {"questions": [q(n=1)]},
        "seven options": {"questions": [q(n=7)]},
        "eleven questions": {"questions": [q() for _ in range(11)]},
        "an internal label": {"questions": [q("Adopt INV-14?")]},
        "a missing image": {"questions": [q(image=str(t.root / "nope.png"))]},
        "a non-image file": {"questions": [q(image=str(t.root / FILES[0]))]},
    }
    for name, questions in bad.items():
        path = t.root / "bad.json"
        path.write_text(json.dumps(questions), encoding="utf-8")
        out = t.ask("open", str(path))
        expect(out.returncode == 2 and not out.stdout, f"ask.py open accepted {name}")
    path = t.root / "allowed.json"
    path.write_text(json.dumps({"questions": [q("Delete ~/notes/old.md?")]}), encoding="utf-8")
    out = t.ask("open", str(path), "--allow-labels", "he asked about that file")
    expect(out.returncode == 0, "--allow-labels did not let a needed label through")
    t.ask("close", out.stdout.split("Ask id: ")[1].split()[0])


def server_fixtures(t: Tree) -> None:
    src = (t.root / "tools/ask/ask.py").read_text(encoding="utf-8")
    expect('ThreadingHTTPServer(("127.0.0.1", 0)' in src, "the page server must bind 127.0.0.1 on an OS-picked port")
    png = t.root / "shot.png"
    png.write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 64)
    link = t.root / "link.png"
    try:
        link.symlink_to(png)
    except (OSError, NotImplementedError):
        link = png
    hostile = 'Pick one </script><script>document.title="pwned"</script><!-- of these'
    questions = {"from": "check", "questions": [q(hostile, image=str(link)), q("Which days?", multi=True, n=3)]}
    url, ask_id = t.open(questions)
    port = int(url.split(":")[2].split("/")[0])
    token = url.rstrip("/").rsplit("/", 1)[1]
    ask_dir = t.ask_home / ask_id

    status, page = http(url)
    expect(status == 200, f"page: HTTP {status}")
    expect(b"</script><script>" not in page and b"<!--" not in page.split(b"ask-data")[1],
           "question text broke out of the page's data script")
    expect(http(url.rstrip("/"))[0] == 301, "a link without its trailing slash must redirect")
    expect(http(f"http://127.0.0.1:{port}/not-the-token/")[0] == 404, "a wrong token must 404")
    expect(http(url, host=f"rebind.example:{port}")[0] == 403, "a foreign Host header must be refused")
    copied = sorted((ask_dir / "img").iterdir())
    expect(len(copied) == 1 and not copied[0].is_symlink(), "images must be copied in, not linked")
    expect(http(url + "img/0/0/0")[0] == 200, "a listed image must be served")
    shot = t.root / "wide.png"
    shot.write_bytes(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + (1280).to_bytes(4, "big") + (800).to_bytes(4, "big") + b"0" * 32)
    views = [{"path": str(png), "label": "Phone"}, {"path": str(shot), "label": "Desktop"}]
    _, views_id = t.open({"questions": [q(images=views)]})
    stored = json.loads((t.ask_home / views_id / "questions.json").read_text())["questions"][0]["options"][0]["images"]
    expect([(i["label"], i["width"]) for i in stored] == [("Phone", 0), ("Desktop", 1280)],
           f"labeled pictures and their widths were not recorded: {stored}")
    t.ask("close", views_id)
    expect(http(url + "img/0/1/0")[0] == 404 and http(url + "img/../server.json")[0] == 404,
           "only listed images may be served")
    expect(http(url + "answers", b"picks=1", "application/x-www-form-urlencoded")[0] == 415,
           "a plain form post must be refused")

    expect(t.ask("poll", ask_id).returncode == 3, "poll before answers must exit 3")
    expect(t.ask("wait", ask_id, "--timeout", "1").returncode == 3, "wait with a timeout must exit 3")
    expect(answer(url, [{"picks": [0, 1], "other": ""}, {"picks": [0], "other": ""}]) == 400,
           "two picks on a single-choice question must be refused")
    expect(answer(url, [{"picks": [], "other": ""}, {"picks": [], "other": ""}]) == 400,
           "an all-skipped answer must be refused")
    expect(answer(url, [{"picks": [9], "other": ""}, {"picks": [], "other": ""}]) == 400,
           "an out-of-range pick must be refused")
    expect(answer(url, [{"picks": [], "other": ""}, {"picks": [0, 2], "other": "Not on holidays"}]) == 200,
           "a valid answer with one skipped question was refused")
    expect(answer(url, [{"picks": [1], "other": ""}, {"picks": [1], "other": ""}]) == 409,
           "a second answer must not replace the first")
    out = t.ask("wait", ask_id)
    expect(out.returncode == 0 and "(skipped)" in out.stdout and "A. Option 1" in out.stdout
           and "C. Option 3" in out.stdout and "Other: Not on holidays" in out.stdout,
           f"wait did not print the answers: {out.stdout!r}")
    deadline = time.time() + 6
    while time.time() < deadline and http_alive(url):
        time.sleep(0.2)
    expect(not http_alive(url), "the server must stop after the answers arrive")
    expect(token not in json.dumps(json.loads((ask_dir / "answers.json").read_text())), "answers must not hold the token")
    server = json.loads((ask_dir / "server.json").read_text())
    expect(server.get("session") == "", "outside a session no session key is stored")

    try:  # the server must not be reachable on the machine's other addresses
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("10.255.255.255", 1))
        lan = probe.getsockname()[0]
        probe.close()
    except OSError:
        lan = ""
    if lan and not lan.startswith("127."):
        url2, id2 = t.open({"questions": [q()]})
        port2 = int(url2.split(":")[2].split("/")[0])
        with socket.socket() as s:
            s.settimeout(2)
            expect(s.connect_ex((lan, port2)) != 0, f"the page answered on {lan}: it must listen on 127.0.0.1 only")
        t.ask("close", id2)


def http_alive(url: str) -> bool:
    try:
        return http(url, method="HEAD")[0] == 200
    except (urllib.error.URLError, OSError):
        return False


def lifecycle_fixtures(t: Tree) -> None:
    a_url, a_id = t.open({"questions": [q()]}, CLAUDE_CODE_SESSION_ID="session-a")
    b_url, b_id = t.open({"questions": [q()]}, CLAUDE_CODE_SESSION_ID="session-b")
    expect(a_url.split("/")[2] != b_url.split("/")[2], "two asks must get different ports")
    b_token = b_url.rstrip("/").rsplit("/", 1)[1]
    a_port = a_url.split("/")[2]
    expect(answer(f"http://{a_port}/{b_token}/", [{"picks": [1], "other": ""}]) == 404,
           "one ask's token must not work on another ask's server")
    expect(answer(a_url, [{"picks": [0], "other": ""}]) == 200, "answering ask A failed")
    expect(t.ask("poll", a_id).returncode == 0 and t.ask("poll", b_id).returncode == 3,
           "an answer to one ask showed up on the other")
    listed = t.ask("list", CLAUDE_CODE_SESSION_ID="session-b").stdout
    expect(b_id in listed and a_id not in listed, "list must show only this session's pages")
    raw = json.loads((t.ask_home / b_id / "server.json").read_text())["session"]
    expect(raw and "session-b" not in raw, "the session id must be stored hashed")

    out = t.ask("close", b_id)
    expect(out.returncode == 4 and "closed" in out.stdout, f"close of an open page: {out.stdout!r}")
    expect(answer(b_url, [{"picks": [0], "other": ""}]) != 200, "a closed page must not take answers")
    c_url, c_id = t.open({"questions": [q()]})
    answer(c_url, [{"picks": [1], "other": ""}])
    out = t.ask("close", c_id)
    expect(out.returncode == 0 and "B. Option 2" in out.stdout, "close after an answer must return that answer")

    d_url, d_id = t.open({"questions": [q()]})
    pid = json.loads((t.ask_home / d_id / "server.json").read_text())["pid"]
    try:
        os.kill(pid, 9)
    except (OSError, AttributeError):
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    time.sleep(0.5)
    out = t.ask("wait", d_id, "--timeout", "10")
    expect(out.returncode == 4 and "stopped" in out.stdout, f"wait on a dead server must end as stopped: {out.stdout!r}")

    old = t.ask_home / "0ld0ld00"
    old.mkdir()
    (old / "questions.json").write_text("{}")
    (old / "ended.json").write_text('{"state": "closed"}')
    stale = time.time() - 8 * 86400
    os.utime(old, (stale, stale))
    t.open({"questions": [q()]})
    expect(not old.exists(), "a page older than 7 days must be pruned")
    for ask_dir in t.ask_home.iterdir():
        if ask_dir.is_dir() and (ask_dir / "server.json").exists():
            t.ask("close", ask_dir.name)


def card(text: str, chip: str = "Layout", desc: str = "About 9 per screen") -> dict:
    return {"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "session_id": "s1",
            "tool_input": {"questions": [{"question": text, "header": chip, "multiSelect": False, "options": [
                {"label": "Two lines", "description": desc}, {"label": "One line", "description": "About 20"}]}]}}


def stop_msg(text: str, active: bool = False) -> dict:
    return {"hook_event_name": "Stop", "stop_hook_active": active, "last_assistant_message": text}


def guard_fixtures(t: Tree) -> None:
    def denied(out: str) -> bool:
        return bool(out) and json.loads(out)["hookSpecificOutput"]["permissionDecision"] == "deny"

    expect(denied(t.hook(card("Adopt INV-14 region-ring semantics?"))), "a card with a rule id must be denied")
    expect(denied(t.hook(card("Which layout?", desc="Edit scripts/check.py"))), "a label in an option must be denied")
    expect(denied(t.hook(card("Which of the two mocks do you prefer?"))), "a card promising a picture must be denied")
    expect(t.hook(card("Which layout should the inbox use?")) == "", "a plain card must pass")
    expect(t.hook({**card("Adopt INV-14?"), "tool_name": "Bash"}) == "", "other tools must pass")
    t.ask("allow", "--reason", "he asked about that exact file", CLAUDE_CODE_SESSION_ID="s1")
    expect(t.hook(card("Delete ~/notes/old.md?")) == "", "the audited override must let one card through")
    expect(denied(t.hook(card("Delete ~/notes/old.md?"))), "the override must be used up by one card")
    expect("he asked about that exact file" in (t.ask_home / "overrides.log").read_text(), "overrides must be logged")

    blocked = ["Done: built the page.\n\n**Needs your decision**\n- Should I push this?\n- Do you want Gemini too?",
               "Report.\n\n## Waiting on you\n1. Pick a model for Codex\n2. Approve the hooks",
               "Built it.\n\n1. Should the page open on the right?\n2. Keep the old rule?"]
    passed = ["Fixed the typo in the README. Want me to commit it?",
              "Example:\n```\n- Why?\n- How?\n```\nDone.",
              "Done.\n\n- R9 Build the page: done\n- R11 Codex flag: waiting on Michael\n- R12 Docs: not done",
              "Why did it fail? The disk was asleep. Could we wake it? Yes, now it does."]
    for text in blocked:
        out = t.hook(stop_msg(text))
        expect(out and json.loads(out).get("decision") == "block", f"a reply ending in questions must block: {text!r}")
        expect(t.hook(stop_msg(text, active=True)) == "", "stop_hook_active must never block again")
        expect(t.hook(stop_msg(text), CLAUDE_CODE_ENTRYPOINT="sdk-cli") == "", "headless (SDK) must stay silent")
        expect(t.hook(stop_msg(text), ASK_GUARD_PRINT_MODE="1") == "", "a nested claude -p must stay silent")
    for text in passed:
        expect(t.hook(stop_msg(text)) == "", f"must not block: {text!r}")
    expect(denied(t.hook(card("Adopt INV-14?"))) and t.hook(card("Adopt INV-14?"), CLAUDE_CODE_ENTRYPOINT="sdk-py") == "",
           "headless lanes must not get card denials")

    transcript = t.root / "transcript.jsonl"
    entries = [
        {"type": "user", "message": {"role": "user", "content": "build it"}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working."}]}},
        {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": blocked[0]}]}},
        {"type": "assistant", "isSidechain": True, "message": {"content": [{"type": "text", "text": "subagent"}]}},
    ]
    transcript.write_text("\n".join(json.dumps(e) for e in entries) + "\n", encoding="utf-8")
    out = t.hook({"hook_event_name": "Stop", "transcript_path": str(transcript)})
    expect(out and json.loads(out).get("decision") == "block", "the Claude transcript's final reply must be read")
    transcript.write_text("\n".join(json.dumps(e) for e in entries[:4]) + "\n", encoding="utf-8")
    expect(t.hook({"hook_event_name": "Stop", "transcript_path": str(transcript)}) == "",
           "a final reply not yet written must never block")
    for junk in ("not json", "[]", "{}", '{"hook_event_name":"Stop","transcript_path":"/nope"}'):
        expect(t.hook(junk) == "", f"bad input must be silent: {junk!r}")


def grammar_fixture(t: Tree) -> None:
    for rel in FILES:
        if rel.endswith(".py"):
            try:
                ast.parse((t.root / rel).read_text(encoding="utf-8"), feature_version=(3, 9))
            except SyntaxError as exc:
                raise Fail(f"{rel} is not Python 3.9 grammar (macOS /usr/bin/python3): {exc}") from None


def registration_fixture(t: Tree) -> None:
    if os.name != "posix" or not shutil.which("bash") or not shutil.which("jq"):
        print("  skip  registration order (needs POSIX bash and jq; Windows: check-ask.ps1)")
        return
    spec = importlib.util.spec_from_file_location("cai", ROOT / "scripts/ci/check-agent-integrations.py")
    cai = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cai)
    home = t.root / "home"
    (home / ".claude").mkdir(parents=True)
    settings = home / ".claude" / "settings.json"
    settings.write_text(json.dumps({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "keep"}]}]}}))
    hooks = t.root / "hooks"
    hooks.mkdir()
    for name in ("agent-notify.py", "context-card.py", "python"):
        (hooks / name).write_text("# fixture\n")
    script = (f'ok() {{ :; }}; warn() {{ :; }}; expand() {{ echo "${{1/#\\~/$HOME}}"; }}; '
              f'source "{ROOT / "manifest.sh"}"; register_ask_guard')
    snapshots = []
    for _ in range(2):
        out = subprocess.run(["bash", "-c", script], env={**os.environ, "HOME": str(home)}, capture_output=True, text=True)
        expect(out.returncode == 0, f"register_ask_guard failed: {out.stderr.strip()}")
        result = cai.run_configurator(home, hooks / "agent-notify.py", hooks / "python", [])
        expect(result.returncode == 0, f"configure-agent-integrations failed: {result.stderr.strip()}")
        snapshots.append(settings.read_bytes())
    expect(snapshots[0] == snapshots[1], "setup/sync is not idempotent: a second run changed settings.json")
    data = json.loads(snapshots[1])
    def ours(event: str) -> list:
        return [(i, e) for i, e in enumerate(data["hooks"].get(event, [])) for h in e["hooks"] if "ask-guard.py" in h["command"]]
    expect(len(ours("PreToolUse")) == 1 and ours("PreToolUse")[0][1]["matcher"] == "AskUserQuestion",
           "ask-guard must be registered once on the question card")
    expect(len(ours("Stop")) == 1, "ask-guard must be registered once on Stop")
    last = data["hooks"]["Stop"][-1]["hooks"][-1]["command"]
    expect("agent-notify.py" in last, "the completion-email Stop hook must stay last")
    expect(data["hooks"]["PreToolUse"][0]["hooks"][0]["command"] == "keep", "an unrelated hook was disturbed")


FIXTURES = (("asklint", lint_fixtures), ("validation", validation_fixtures), ("page server", server_fixtures),
            ("lifecycle", lifecycle_fixtures), ("ask-guard", guard_fixtures), ("python 3.9", grammar_fixture),
            ("registration", registration_fixture))


def run_all(mutate=None, quiet: bool = False) -> list[str]:
    failures = []
    with tempfile.TemporaryDirectory(prefix="check-ask-") as raw:
        t = Tree(Path(raw) / "tree", Path(raw) / "ask-home")
        if mutate:
            mutate(t.root)
        for name, fixture in FIXTURES:
            try:
                fixture(t)
                if not quiet:
                    print(f"  ok    {name}")
            except Fail as exc:
                failures.append(f"{name}: {exc}")
                if not quiet:
                    print(f"  FAIL  {name}: {exc}")
        for ask_dir in t.ask_home.glob("*/server.json"):  # never leave a server behind
            info = json.loads(ask_dir.read_text())
            if not info.get("port"):
                continue
            url = f"http://127.0.0.1:{info['port']}/{info['token']}/"
            try:
                http(url + "close", b"", method="POST")
            except (urllib.error.URLError, OSError):
                pass
            time.sleep(0.2)
            if http_alive(url) and info.get("pid"):  # a mutated server that ignores close
                try:
                    os.kill(info["pid"], 9)
                except (OSError, AttributeError):
                    subprocess.run(["taskkill", "/F", "/PID", str(info["pid"])], capture_output=True)
    return failures


def edit(rel: str, old: str, new: str):
    def apply(root: Path) -> None:
        path = root / rel
        text = path.read_text(encoding="utf-8")
        if old not in text:
            raise SystemExit(f"revert-test: mutation anchor missing in {rel}: {old!r}")
        path.write_text(text.replace(old, new, 1), encoding="utf-8")
    return apply


def override(rel: str, line: str):
    """Rebind a module-level name, before the script's entry point runs."""
    def apply(root: Path) -> None:
        path = root / rel
        text = path.read_text(encoding="utf-8")
        anchor = '\nif __name__ == "__main__":'
        text = text.replace(anchor, f"\n{line}\n{anchor}", 1) if anchor in text else text + f"\n{line}\n"
        path.write_text(text, encoding="utf-8")
    return apply


GUARD, ASK, LINT = "claude-config/global-hooks/ask-guard.py", "tools/ask/ask.py", "tools/ask/asklint.py"
MUTATIONS = {
    "labels not checked": override(LINT, "label_problems = lambda text: []"),
    "pictures not checked": override(LINT, "visual_problems = lambda text: []"),
    "bound to every interface": edit(ASK, 'ThreadingHTTPServer(("127.0.0.1", 0)', 'ThreadingHTTPServer(("0.0.0.0", 0)'),
    "no Host check": edit(ASK, 'return self.headers.get("Host", "") in (', 'return True or self.headers.get("Host", "") in ('),
    "no token check": edit(ASK, "if not self.path.startswith(prefix):\n                return self.reply(404)",
                           "if False:\n                return self.reply(404)"),
    "page data not escaped": edit(ASK, '.replace("<", "\\\\u003c")', ""),
    "later answers overwrite": edit(ASK, 'if (ask_dir / "answers.json").exists() or (ask_dir / "ended.json").exists():\n                    return self.reply(409)',
                                    "if False:\n                    return self.reply(409)"),
    "answers not validated": edit(ASK, 'if not q["multi"] and len(picks) > 1:\n            return None', "pass"),
    "images linked, not copied": edit(ASK, "shutil.copyfile(src, ask_dir / name)", "os.symlink(src, ask_dir / name)"),
    "card never denied": override(GUARD, "card_problems = lambda tool_input: []"),
    "question lists never caught": override(GUARD, "ends_in_question_list = lambda text: False"),
    "loops on stop_hook_active": edit(GUARD, 'if data.get("stop_hook_active") or', "if"),
    "loud in headless lanes": override(GUARD, "quiet_lane = lambda: False"),
    "override never used up": edit(GUARD, "        marker.unlink()\n        return True", "        return marker.exists()"),
}


def machine() -> list[str]:
    failures = []
    settings = Path.home() / ".claude" / "settings.json"
    data = json.loads(settings.read_text(encoding="utf-8")) if settings.exists() else {}
    for event, matcher in (("PreToolUse", "AskUserQuestion"), ("Stop", None)):
        found = [(e, h) for e in data.get("hooks", {}).get(event, []) for h in e.get("hooks", [])
                 if "ask-guard.py" in str(h.get("command"))]
        if len(found) != 1 or (matcher and found[0][0].get("matcher") != matcher):
            failures.append(f"{event}: expected one ask-guard hook{' on ' + matcher if matcher else ''}, found {len(found)}")
            continue
        payload = card("Adopt INV-14 region-ring semantics?") if event == "PreToolUse" else stop_msg("- Push it?\n- Deploy it?")
        env = {**os.environ, "ASK_GUARD_PRINT_MODE": "0", "CLAUDE_CODE_ENTRYPOINT": "cli"}
        out = subprocess.run(found[0][1]["command"], shell=True, input=json.dumps(payload), capture_output=True,
                             text=True, env=env, timeout=30)
        if '"deny"' not in out.stdout and '"block"' not in out.stdout:
            failures.append(f"{event}: the registered ask-guard command did not act (python, path or import broken)")
    stops = data.get("hooks", {}).get("Stop", [])
    if stops and "agent-notify.py" not in str(stops[-1]):
        failures.append("Stop: the completion-email hook is not last")
    codex_cfg = Path.home() / ".codex" / "config.toml"
    if os.name == "posix" and codex_cfg.exists() and shutil.which("codex"):
        text = codex_cfg.read_text(encoding="utf-8")
        if "ask-guard.py" not in text:
            failures.append("Codex: no ask-guard Stop hook in config.toml")
        listed = subprocess.run(["codex", "features", "list"], capture_output=True, text=True).stdout
        if not any(line.split()[:1] == ["default_mode_request_user_input"] and line.split()[-1] == "true"
                   for line in listed.splitlines() if line.strip()):
            failures.append("Codex: the question card (default_mode_request_user_input) is not enabled")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--revert-test", action="store_true")
    parser.add_argument("--machine", action="store_true")
    args = parser.parse_args()
    if args.machine:
        failures = machine()
        for failure in failures:
            print(f"  FAIL  {failure}")
        print("check-ask [machine] " + ("FAILED" if failures else "OK"))
        return 1 if failures else 0
    if args.revert_test:
        survivors = [name for name, mutate in MUTATIONS.items() if not run_all(mutate, quiet=True)]
        if survivors:
            print("revert-test FAILED: these breaks still pass: " + ", ".join(survivors))
            return 1
        print(f"revert-test ok: all {len(MUTATIONS)} breaks fail the fixtures")
        return 0
    print("check-ask: fixtures")
    failures = run_all()
    print("check-ask " + ("FAILED" if failures else "OK"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
