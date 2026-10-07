#!/usr/bin/env python3
"""The questions page (ADR-0011): put questions for Michael on a local page and keep working.

    ask.py open QUESTIONS.json [--from LABEL] [--browser]   start a page, print its link and id
    ask.py wait ID [--timeout SECONDS]                      block until he sends (exit 0)
    ask.py poll ID                                          check once, never blocks
    ask.py close ID                                         stop a page he answered in chat
    ask.py list [--all]                                     this session's pages
    ask.py allow --reason TEXT                              let the next card (15 min) keep a flagged label

Exit codes for wait/poll/close: 0 answered (answers printed), 3 still waiting, 4 closed, expired
or stopped without answers, 2 bad input.

Each page is its own server on 127.0.0.1 with an OS-picked port and a 128-bit token in the
path, so several sessions never share one, and only this machine can reach it. Its state lives
in ~/.cache/ask/<id>/ (ASK_HOME overrides): questions.json, copied images, server.json and,
once he sends, answers.json. The server exits after the answers arrive, on close, or after 24 h.
Python 3.9 standard library only.
"""
from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asklint  # noqa: E402

HERE = Path(__file__).resolve().parent
PAGE = HERE / "page.html"
IMAGE_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
               ".webp": "image/webp"}
MAX_IMAGE = 10 * 1024 * 1024
MAX_IMAGES = 3  # per option: a 390 and a 1280 px shot, plus one spare
KEEP_DAYS = 7
MAX_BODY = 64 * 1024
LIFETIME = int(os.environ.get("ASK_LIFETIME") or 24 * 3600)
LIMITS = {"questions": (1, 10), "options": (2, 6), "question": 200, "context": 400, "label": 80,
          "detail": 240, "from": 80, "other": 2000}
EXIT_ANSWERED, EXIT_WAITING, EXIT_ENDED, EXIT_INPUT = 0, 3, 4, 2


class AskError(Exception):
    pass


def home() -> Path:
    return Path(os.environ.get("ASK_HOME") or Path.home() / ".cache" / "ask")


def session_key(raw: str | None = None) -> str:
    """The asking session, hashed like agent-notify's keys; empty outside an agent session."""
    raw = raw if raw is not None else (os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("CODEX_THREAD_ID") or "")
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16] if raw else ""


def write_json(path: Path, value: object) -> None:
    tmp = path.with_name(f".{path.name}.{secrets.token_hex(4)}.tmp")
    tmp.write_text(json.dumps(value, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


# ---- validation ---------------------------------------------------------------------------

def image_width(path: Path) -> int:
    """Pixel width from a PNG or GIF header (0 when unknown), so the page lays out wide shots
    in one column before they load."""
    with open(path, "rb") as handle:
        head = handle.read(32)
    if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
        return int.from_bytes(head[16:20], "big")
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return int.from_bytes(head[6:8], "little")
    return 0

def _text(obj: dict, key: str, where: str, required: bool = True) -> str:
    value = obj.get(key, "")
    if not isinstance(value, str):
        raise AskError(f"{where}: `{key}` must be text")
    value = " ".join(value.split())
    if required and not value:
        raise AskError(f"{where}: `{key}` is required")
    if len(value) > LIMITS[key]:
        raise AskError(f"{where}: `{key}` is longer than {LIMITS[key]} characters")
    return value


def validate(raw: object, label: str | None, allow_labels: bool) -> tuple[dict, list[tuple[Path, Path]]]:
    """Normalized questions plus (source, copy name) pairs for the images to copy."""
    if not isinstance(raw, dict) or not isinstance(raw.get("questions"), list):
        raise AskError('questions file must be an object with a "questions" list')
    low, high = LIMITS["questions"]
    if not low <= len(raw["questions"]) <= high:
        raise AskError(f"ask {low} to {high} questions per page")
    source = label if label is not None else raw.get("from", "")
    out = {"from": _text({"from": source}, "from", "page", required=False) or Path.cwd().name, "questions": []}
    images: list[tuple[Path, Path]] = []
    problems: list[tuple[str, str]] = []
    for qi, q in enumerate(raw["questions"]):
        where = f"question {qi + 1}"
        if not isinstance(q, dict):
            raise AskError(f"{where} must be an object")
        multi = q.get("multi", False)
        if not isinstance(multi, bool):
            raise AskError(f"{where}: `multi` must be true or false")
        item = {"question": _text(q, "question", where), "context": _text(q, "context", where),
                "multi": multi, "options": []}
        opts = q.get("options")
        low, high = LIMITS["options"]
        if not isinstance(opts, list) or not low <= len(opts) <= high:
            raise AskError(f"{where}: give {low} to {high} options")
        for oi, o in enumerate(opts):
            owhere = f"{where}, option {chr(65 + oi)}"
            if not isinstance(o, dict):
                raise AskError(f"{owhere} must be an object")
            opt = {"label": _text(o, "label", owhere), "detail": _text(o, "detail", owhere),
                   "recommended": bool(o.get("recommended", False))}
            given = o.get("images", [o["image"]] if o.get("image") else [])
            if not isinstance(given, list) or len(given) > MAX_IMAGES:
                raise AskError(f"{owhere}: give at most {MAX_IMAGES} images")
            opt["images"] = []
            for ii, image in enumerate(given):
                # "path" or {"path": ..., "label": "Phone"}: the label names the view switcher's button.
                spec = image if isinstance(image, dict) else {"path": image}
                label = " ".join(str(spec.get("label") or "").split())[:20]
                src = Path(str(spec.get("path") or "")).expanduser()
                try:
                    real = src.resolve(strict=True)
                except OSError:
                    raise AskError(f"{owhere}: image not found: {src}") from None
                suffix = real.suffix.lower()
                if suffix not in IMAGE_TYPES or not real.is_file():
                    raise AskError(f"{owhere}: image must be a {', '.join(sorted(IMAGE_TYPES))} file")
                if real.stat().st_size > MAX_IMAGE:
                    raise AskError(f"{owhere}: image is larger than 10 MB")
                name = Path("img") / f"{qi}-{oi}-{ii}{suffix}"
                images.append((real, name))
                opt["images"].append({"src": name.as_posix(), "label": label, "width": image_width(real)})
            item["options"].append(opt)
            for key in ("label", "detail"):
                problems += [(f"{owhere} {key}", p) for p in asklint.label_problems(opt[key])]
        for key in ("question", "context"):
            problems += [(f"{where} {key}", p) for p in asklint.label_problems(item[key])]
        out["questions"].append(item)
    if problems and not allow_labels:
        raise AskError("write these for someone who never saw this session: " + asklint.describe(problems)
                       + ". Say what they mean in plain words, or pass --allow-labels REASON if he needs the label itself.")
    return out, images


# ---- server -------------------------------------------------------------------------------

def page_html(questions: dict) -> bytes:
    data = json.dumps(questions).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    return PAGE.read_text(encoding="utf-8").replace("/*__ASK__*/", data, 1).encode("utf-8")


def valid_answers(body: object, questions: dict) -> list[dict] | None:
    if not isinstance(body, dict) or not isinstance(body.get("answers"), list):
        return None
    qs = questions["questions"]
    if len(body["answers"]) != len(qs):
        return None
    out = []
    if not any(isinstance(a, dict) and (a.get("picks") or str(a.get("other") or "").strip()) for a in body["answers"]):
        return None  # all skipped: nothing to send
    for q, a in zip(qs, body["answers"]):
        if not isinstance(a, dict):
            return None
        picks, other = a.get("picks", []), a.get("other", "")
        if not isinstance(picks, list) or not isinstance(other, str) or len(other) > LIMITS["other"]:
            return None
        if any(not isinstance(p, int) or isinstance(p, bool) or not 0 <= p < len(q["options"]) for p in picks):
            return None
        picks = sorted(set(picks))
        if not q["multi"] and len(picks) > 1:
            return None
        out.append({"picks": picks, "other": other.strip()})
    return out


def serve(ask_dir: Path) -> int:
    info = read_json(ask_dir / "server.json")
    questions = read_json(ask_dir / "questions.json")
    token = info.get("token")
    if not token or not questions:
        return EXIT_INPUT
    images = {f"img/{qi}/{oi}/{ii}": ask_dir / image["src"]
              for qi, q in enumerate(questions["questions"]) for oi, o in enumerate(q["options"])
              for ii, image in enumerate(o.get("images", []))}
    page = page_html(questions)
    lock = threading.Lock()
    done = threading.Event()
    prefix = f"/{token}/"

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "ask"
        sys_version = ""

        def log_message(self, *args):  # no request log: paths carry the token
            pass

        def host_ok(self) -> bool:
            # A page on another site can point a DNS name at 127.0.0.1 (DNS rebinding); it still
            # needs the token, and this refuses any Host but our own.
            port = self.server.server_address[1]
            return self.headers.get("Host", "") in (f"127.0.0.1:{port}", f"localhost:{port}")

        def reply(self, code: int, body: bytes = b"", ctype: str = "text/plain; charset=utf-8", extra=None,
                  cache: str = "no-store"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache)
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Content-Type-Options", "nosniff")
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_GET(self):
            if not self.host_ok():
                return self.reply(403)
            if self.path == prefix[:-1]:
                return self.reply(301, extra={"Location": prefix})
            if not self.path.startswith(prefix):
                return self.reply(404)
            rest = self.path[len(prefix):]
            if rest == "":
                csp = ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
                       "img-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'")
                return self.reply(200, page, "text/html; charset=utf-8", {"Content-Security-Policy": csp})
            if rest in images:
                path = images[rest]
                # A picture never changes for the life of the page, so switching views doesn't refetch it.
                return self.reply(200, path.read_bytes(), IMAGE_TYPES[path.suffix.lower()],
                                  cache="private, max-age=86400, immutable")
            return self.reply(404)

        def do_POST(self):
            if not self.host_ok():
                return self.reply(403)
            if self.path not in (prefix + "answers", prefix + "close"):
                return self.reply(404)
            if self.path.endswith("/close"):
                with lock:
                    if (ask_dir / "answers.json").exists():
                        return self.reply(409, b"answered")
                    write_json(ask_dir / "ended.json", {"state": "closed", "at": time.time()})
                self.reply(200, b"closed")
                done.set()
                return
            if not self.headers.get("Content-Type", "").startswith("application/json"):
                return self.reply(415)
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_BODY:
                return self.reply(413)
            try:
                body = json.loads(self.rfile.read(length).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return self.reply(400)
            answers = valid_answers(body, questions)
            if answers is None:
                return self.reply(400)
            with lock:
                if (ask_dir / "answers.json").exists() or (ask_dir / "ended.json").exists():
                    return self.reply(409)
                write_json(ask_dir / "answers.json", {"answers": answers, "at": time.time()})
            self.reply(200, b'{"ok":true}', "application/json")
            done.set()

        do_HEAD = do_GET

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    info.update(port=server.server_address[1], pid=os.getpid(), started=time.time())
    write_json(ask_dir / "server.json", info)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    if not done.wait(LIFETIME):
        with lock:
            if not (ask_dir / "answers.json").exists():
                write_json(ask_dir / "ended.json", {"state": "expired", "at": time.time()})
    time.sleep(1.5)  # let the page show its confirmation before the socket closes
    server.shutdown()
    return 0


# ---- commands -----------------------------------------------------------------------------

def ask_dir_for(ask_id: str) -> Path:
    if not ask_id or not all(c in "0123456789abcdef" for c in ask_id):
        raise AskError(f"unknown ask id: {ask_id!r}")
    path = home() / ask_id
    if not (path / "questions.json").exists():
        raise AskError(f"unknown ask id: {ask_id}")
    return path


def url_of(info: dict) -> str:
    return f"http://127.0.0.1:{info['port']}/{info['token']}/"


# Our own server is on 127.0.0.1: never send these requests through an http_proxy.
LOCAL = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def alive(info: dict, tries: int = 3) -> bool:
    """One slow answer is not a dead server: try a few times before saying so."""
    if not info.get("port"):
        return False
    for attempt in range(tries):
        try:
            with LOCAL.open(urllib.request.Request(url_of(info), method="HEAD"), timeout=2) as r:
                return r.status == 200
        except (urllib.error.URLError, OSError):
            if attempt + 1 < tries:
                time.sleep(0.5)
    return False


def state(ask_dir: Path) -> str:
    if (ask_dir / "answers.json").exists():
        return "answered"
    ended = read_json(ask_dir / "ended.json")
    if ended:
        return str(ended.get("state") or "ended")
    info = read_json(ask_dir / "server.json")
    if info.get("pid"):
        return "waiting" if alive(info) else "stopped"
    # No pid: the server never started (open reported it), or is starting right now.
    return "stopped" if time.time() - float(info.get("created") or 0) > 60 else "waiting"


def format_answers(ask_id: str, ask_dir: Path) -> str:
    questions = read_json(ask_dir / "questions.json")["questions"]
    answers = read_json(ask_dir / "answers.json").get("answers", [])
    lines = [f"Michael's answers (ask {ask_id}):"]
    for i, (q, a) in enumerate(zip(questions, answers), 1):
        lines.append(f"{i}. {q['question']}")
        for p in a["picks"]:
            lines.append(f"   {chr(65 + p)}. {q['options'][p]['label']}")
        if a["other"]:
            lines.append("   Other: " + a["other"].replace(chr(10), chr(10) + " " * 10))
        if not a["picks"] and not a["other"]:
            lines.append("   (skipped)")
    lines.append(f"Saved: {ask_dir / 'answers.json'}")
    return "\n".join(lines)


def report(ask_id: str, ask_dir: Path) -> int:
    current = state(ask_dir)
    if current == "answered":
        print(format_answers(ask_id, ask_dir))
        return EXIT_ANSWERED
    if current == "waiting":
        print(f"ask {ask_id}: waiting for Michael")
        return EXIT_WAITING
    print(f"ask {ask_id}: {current} without answers")
    return EXIT_ENDED


def spawn(ask_dir: Path) -> None:
    args = [sys.executable, str(Path(__file__).resolve()), "_serve", ask_dir.name]
    log = open(ask_dir / "server.log", "ab")
    kwargs: dict = {"stdin": subprocess.DEVNULL, "stdout": log, "stderr": log, "close_fds": True}
    try:
        if os.name == "nt":
            # Outlive the agent's command: leave its console, process group and (when the job
            # allows it) its kill-on-close job object.
            flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
            try:
                subprocess.Popen(args, creationflags=flags | 0x01000000, **kwargs)  # CREATE_BREAKAWAY_FROM_JOB
            except OSError:
                subprocess.Popen(args, creationflags=flags, **kwargs)
        else:
            subprocess.Popen(args, start_new_session=True, **kwargs)
    finally:
        log.close()


def prune(root: Path) -> None:
    """Drop pages older than KEEP_DAYS whose server is gone (screenshots and answers included)."""
    cutoff = time.time() - KEEP_DAYS * 86400
    for ask_dir in root.iterdir():
        try:
            if ask_dir.is_dir() and ask_dir.stat().st_mtime < cutoff and state(ask_dir) != "waiting":
                shutil.rmtree(ask_dir, ignore_errors=True)
        except OSError:
            continue


def cmd_open(args) -> int:
    try:
        text = sys.stdin.read() if args.questions == "-" else Path(args.questions).read_text(encoding="utf-8")
        raw = json.loads(text)
    except (OSError, ValueError) as exc:
        raise AskError(f"can't read questions: {exc}") from None
    questions, images = validate(raw, args.label, bool(args.allow_labels))
    if args.allow_labels:
        questions["allow_labels"] = args.allow_labels
        log_override({"session": session_key(), "page": True, "reason": args.allow_labels})
    if os.environ.get("SSH_CONNECTION"):
        print(f"ask: this session runs over SSH, so the page is on {socket.gethostname()}, which Michael's "
              "browser may not reach. Prefer the question card.", file=sys.stderr)
    root = home()
    root.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    prune(root)
    while True:
        ask_id = secrets.token_hex(4)
        ask_dir = root / ask_id
        try:
            ask_dir.mkdir(mode=0o700)
            break
        except FileExistsError:
            continue
    (ask_dir / "img").mkdir(mode=0o700)
    for src, name in images:
        shutil.copyfile(src, ask_dir / name)
    write_json(ask_dir / "questions.json", questions)
    write_json(ask_dir / "server.json", {"token": secrets.token_urlsafe(16), "session": session_key(),
                                         "created": time.time(), "from": questions["from"]})
    spawn(ask_dir)
    deadline = time.time() + 10
    while time.time() < deadline:
        info = read_json(ask_dir / "server.json")
        if info.get("port") and alive(info):
            break
        time.sleep(0.1)
    else:
        write_json(ask_dir / "ended.json", {"state": "failed", "at": time.time()})
        raise AskError(f"the page server didn't start; see {ask_dir / 'server.log'}")
    url = url_of(info)
    if args.browser:
        webbrowser.open(url)
    print(f"Questions page: {url}")
    print(f"Ask id: {ask_id}")
    print(f"Answers: ask.py wait {ask_id} (blocks) or ask.py poll {ask_id} (once)")
    return 0


def cmd_wait(args) -> int:
    ask_dir = ask_dir_for(args.id)
    deadline = time.time() + args.timeout if args.timeout else None
    while True:
        current = state(ask_dir)
        if current != "waiting" or (deadline and time.time() >= deadline):
            return report(args.id, ask_dir)
        time.sleep(1)


def cmd_poll(args) -> int:
    return report(args.id, ask_dir_for(args.id))


def cmd_close(args) -> int:
    ask_dir = ask_dir_for(args.id)
    info = read_json(ask_dir / "server.json")
    try:
        LOCAL.open(urllib.request.Request(url_of(info) + "close", data=b"", method="POST"), timeout=3)
    except urllib.error.HTTPError as exc:
        if exc.code != 409:
            raise AskError(f"close failed: HTTP {exc.code}") from None
    except (urllib.error.URLError, OSError, KeyError):
        if state(ask_dir) not in ("answered", "closed", "expired"):
            write_json(ask_dir / "ended.json", {"state": "closed", "at": time.time()})
    if (ask_dir / "answers.json").exists():
        print("He already sent answers on the page before it closed:")
    return report(args.id, ask_dir)


def cmd_list(args) -> int:
    root, me = home(), session_key()
    rows = []
    for ask_dir in sorted(root.glob("*/server.json"), key=lambda p: p.stat().st_mtime) if root.exists() else []:
        info = read_json(ask_dir)
        if not info:
            continue
        if not args.all and me and info.get("session") != me:
            continue
        questions = read_json(ask_dir.parent / "questions.json").get("questions") or [{}]
        rows.append(f"{ask_dir.parent.name}  {state(ask_dir.parent):9}  {questions[0].get('question', '')}")
    print("\n".join(rows) if rows else "No question pages.")
    return 0


def log_override(entry: dict) -> None:
    root = home()
    root.mkdir(parents=True, exist_ok=True)
    with open(root / "overrides.log", "a", encoding="utf-8") as log:
        log.write(json.dumps({**entry, "at": time.time()}) + "\n")


def cmd_allow(args) -> int:
    me = session_key()
    if not me:
        raise AskError("no session id in this environment")
    root = home()
    root.mkdir(parents=True, exist_ok=True)
    write_json(root / f"allow-{me}.json", {"reason": " ".join(args.reason.split()), "at": time.time()})
    log_override({"session": me, "reason": args.reason})
    print("The next question card in this session, within 15 minutes, may keep its flagged labels.")
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ask.py", description="The questions page (ADR-0011).")
    sub = p.add_subparsers(dest="cmd", required=True)
    o = sub.add_parser("open", help="start a questions page")
    o.add_argument("questions", help="questions JSON file, or - for stdin")
    o.add_argument("--from", dest="label", help="who is asking, shown in the page header")
    o.add_argument("--browser", action="store_true", help="also open it in the default browser")
    o.add_argument("--allow-labels", metavar="REASON", help="keep flagged labels he needs, with why")
    w = sub.add_parser("wait", help="block until answered")
    w.add_argument("id")
    w.add_argument("--timeout", type=float, default=0, help="seconds; 0 waits until the page ends")
    sub.add_parser("poll", help="check once").add_argument("id")
    sub.add_parser("close", help="stop a page he answered in chat").add_argument("id")
    sub.add_parser("list", help="this session's pages").add_argument("--all", action="store_true")
    sub.add_parser("allow", help="let the next card keep flagged labels").add_argument("--reason", required=True)
    sub.add_parser("_serve").add_argument("id")
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.cmd == "_serve":
            return serve(home() / args.id)
        return {"open": cmd_open, "wait": cmd_wait, "poll": cmd_poll, "close": cmd_close,
                "list": cmd_list, "allow": cmd_allow}[args.cmd](args)
    except AskError as exc:
        print(f"ask: {exc}", file=sys.stderr)
        return EXIT_INPUT


if __name__ == "__main__":
    sys.exit(main())
