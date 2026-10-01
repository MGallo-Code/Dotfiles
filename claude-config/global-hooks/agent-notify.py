#!/usr/bin/env python3
"""Explicit, per-turn completion email for Claude Code, Codex, and Gemini CLI.

The email path is deliberately inert unless this exact agent session was armed first.
One acknowledged send removes the durable pending record. A failed send stays pending
and is retried only when the same explicitly armed session completes again. When Codex
Desktop already owns the single native notify slot, its original callback receives the
same payload through an argument-safe passthrough independently of email state.

Commands:
  agent-notify.py arm [--agent AGENT] [--label TEXT] [--to ADDRESS]
  agent-notify.py disarm [--agent AGENT]
  agent-notify.py hook --agent AGENT [--codex-passthrough TOKEN] [CODEX_EVENT_JSON]

Gemini does not expose its session id to the shell tool. Its ``arm`` invocation emits
an opaque marker; the managed Gemini ``AfterTool(run_shell_command)`` hook validates
that marker and writes the real session-scoped arm record. ``AfterAgent`` then uses it.
"""

from __future__ import annotations

import argparse
import base64
import email.policy
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from email.message import EmailMessage
from pathlib import Path
from typing import Any


AGENTS = {"claude", "codex", "gemini"}
AGENT_NAMES = {"claude": "Claude", "codex": "Codex", "gemini": "Gemini"}
ARM_MARKER = "AGENT_NOTIFY_ARM_V1:"
STATE_VERSION = 1
MCP_PROTOCOL_VERSION = "2025-06-18"
ARM_TTL_SECONDS = 24 * 60 * 60
PENDING_TTL_SECONDS = 24 * 60 * 60
LOCK_TTL_SECONDS = 5 * 60
SEND_TIMEOUT_SECONDS = 20
MAX_LABEL_CHARS = 160
MAX_COURIER_RESPONSE_BYTES = 1024 * 1024
MAX_GEMINI_MARKER_SCAN_CHARS = 64 * 1024
MAX_CODEX_PASSTHROUGH_ARGS = 64
MAX_CODEX_PASSTHROUGH_ARG_CHARS = 4_096
MAX_CODEX_PASSTHROUGH_TOTAL_CHARS = 8_192
MAX_CODEX_PASSTHROUGH_TOKEN_CHARS = 12_000
CODEX_PASSTHROUGH_TIMEOUT_SECONDS = 10


class NotifyError(RuntimeError):
    """A safe, non-payload-bearing notification error."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keep the Courier bearer token on the configured endpoint only."""

    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> urllib.request.Request | None:
        return None


_HTTP_OPENER = urllib.request.build_opener(_NoRedirect)


def _state_root() -> Path:
    override = os.environ.get("AGENT_NOTIFY_STATE_DIR")
    return Path(override).expanduser() if override else Path.home() / ".config" / "agent-notify"


def _config_path() -> Path:
    override = os.environ.get("AGENT_NOTIFY_CONFIG")
    return Path(override).expanduser() if override else _state_root() / "config.json"


def _ensure_private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name == "posix":
        path.chmod(0o700)


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    _ensure_private_dir(path.parent)
    fd, raw_tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp = Path(raw_tmp)
    try:
        if os.name == "posix":
            os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        if os.name == "posix":
            path.chmod(0o600)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def _read_json_object(path: Path, error_code: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise NotifyError(error_code) from exc
    if not isinstance(value, dict):
        raise NotifyError(error_code)
    return value


def _load_config() -> dict[str, Any]:
    config = _read_json_object(_config_path(), "config_unreadable")
    required = ("default_to", "from_address", "account", "courier_url", "courier_token_file")
    if any(not isinstance(config.get(key), str) or not config[key].strip() for key in required):
        raise NotifyError("config_invalid")
    courier_url = urllib.parse.urlsplit(config["courier_url"])
    if (
        courier_url.scheme != "https"
        or not courier_url.hostname
        or courier_url.username is not None
        or courier_url.password is not None
    ):
        raise NotifyError("courier_url_invalid")
    return config


def _log(message: str) -> None:
    """Log only fixed status codes. Never pass payloads, addresses, paths, or labels."""
    root = _state_root()
    _ensure_private_dir(root)
    path = root / "notify.log"
    safe = re.sub(r"[^a-zA-Z0-9_.= -]", "_", message)[:240]
    try:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {safe}\n")
        if os.name == "posix":
            path.chmod(0o600)
    except OSError:
        pass


def _clean_label(value: str) -> str:
    label = " ".join(str(value or "").replace("\r", " ").replace("\n", " ").split())
    return label[:MAX_LABEL_CHARS]


def _valid_address(value: str) -> bool:
    return bool(re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value or ""))


def _detect_agent(explicit: str | None) -> str:
    if explicit:
        if explicit not in AGENTS:
            raise NotifyError("agent_invalid")
        return explicit
    if os.environ.get("CLAUDE_CODE_SESSION_ID"):
        return "claude"
    if os.environ.get("CODEX_THREAD_ID"):
        return "codex"
    if os.environ.get("GEMINI_SESSION_ID") or os.environ.get("GEMINI_CLI"):
        return "gemini"
    raise NotifyError("agent_unknown")


def _session_from_env(agent: str) -> str | None:
    names = {
        "claude": "CLAUDE_CODE_SESSION_ID",
        "codex": "CODEX_THREAD_ID",
        "gemini": "GEMINI_SESSION_ID",
    }
    value = os.environ.get(names[agent], "").strip()
    return value or None


def _session_key(agent: str, session_id: str) -> str:
    if not session_id or len(session_id) > 512 or any(ord(ch) < 32 for ch in session_id):
        raise NotifyError("session_invalid")
    return hashlib.sha256(f"{agent}\0{session_id}".encode("utf-8")).hexdigest()


def _paths(agent: str, session_id: str) -> tuple[Path, Path, Path]:
    key = _session_key(agent, session_id)
    root = _state_root()
    return root / "armed" / f"{key}.json", root / "pending" / f"{key}.json", root / "locks" / f"{key}.lock"


def _gc_stale() -> None:
    now = time.time()
    for dirname, ttl in (("armed", ARM_TTL_SECONDS), ("pending", PENDING_TTL_SECONDS), ("locks", LOCK_TTL_SECONDS)):
        directory = _state_root() / dirname
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            try:
                if path.is_file() and now - path.stat().st_mtime > ttl:
                    path.unlink()
            except OSError:
                continue


def _arm_record(agent: str, session_id: str, label: str, recipient: str) -> None:
    armed, pending, _lock = _paths(agent, session_id)
    if pending.exists():
        raise NotifyError("prior_notice_pending")
    record = {
        "version": STATE_VERSION,
        "agent": agent,
        "label": _clean_label(label),
        "to": recipient,
        "created_at": int(time.time()),
        "notification_id": str(uuid.uuid4()),
    }
    _atomic_json(armed, record)


def _gemini_marker(label: str, recipient: str | None, action: str = "arm") -> str:
    raw = json.dumps(
        {
            "version": STATE_VERSION,
            "action": action,
            "label": _clean_label(label),
            "to": recipient or "",
        },
        separators=(",", ":"),
    ).encode("utf-8")
    token = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
    return ARM_MARKER + token


def _decode_gemini_marker(text: str) -> dict[str, Any] | None:
    match = re.search(re.escape(ARM_MARKER) + r"([A-Za-z0-9_-]{4,1024})", text)
    if not match:
        return None
    token = match.group(1)
    try:
        raw = base64.urlsafe_b64decode(token + "=" * (-len(token) % 4))
        value = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict) or value.get("version") != STATE_VERSION:
        return None
    return value


def _cmd_arm(args: argparse.Namespace) -> int:
    agent = _detect_agent(args.agent)
    config = _load_config()
    recipient = args.to or config["default_to"]
    if not _valid_address(recipient):
        raise NotifyError("recipient_invalid")
    session_id = _session_from_env(agent)
    if agent == "gemini" and not session_id:
        # Gemini's AfterTool hook receives the real session id and this successful stdout.
        print(_gemini_marker(args.label, recipient))
        return 0
    if not session_id:
        raise NotifyError("session_unavailable")
    _gc_stale()
    _arm_record(agent, session_id, args.label, recipient)
    print(f"{AGENT_NAMES[agent]} completion email armed for this turn.")
    return 0


def _cmd_disarm(args: argparse.Namespace) -> int:
    agent = _detect_agent(args.agent)
    session_id = _session_from_env(agent)
    if agent == "gemini" and not session_id:
        print(_gemini_marker("", None, "disarm"))
        return 0
    if not session_id:
        raise NotifyError("session_unavailable")
    armed, pending, lock = _paths(agent, session_id)
    for path in (armed, pending, lock):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    print(f"{AGENT_NAMES[agent]} completion email disarmed.")
    return 0


def _read_hook_payload(agent: str, codex_json: str | None) -> dict[str, Any]:
    raw = codex_json if agent == "codex" else sys.stdin.read()
    if not raw:
        raise NotifyError("hook_payload_missing")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise NotifyError("hook_payload_invalid") from exc
    if not isinstance(value, dict):
        raise NotifyError("hook_payload_invalid")
    return value


def _forward_codex_notification(token: str | None, event_json: str | None) -> None:
    """Preserve a pre-existing Codex Desktop callback without involving email state."""
    if not token or not event_json or len(token) > MAX_CODEX_PASSTHROUGH_TOKEN_CHARS:
        return
    try:
        raw = base64.b64decode(
            token + "=" * (-len(token) % 4), altchars=b"-_", validate=True
        )
        argv = json.loads(raw.decode("utf-8"))
        if (
            not isinstance(argv, list)
            or not argv
            or len(argv) > MAX_CODEX_PASSTHROUGH_ARGS
            or not all(
                isinstance(item, str) and item and len(item) <= MAX_CODEX_PASSTHROUGH_ARG_CHARS
                for item in argv
            )
            or sum(len(item) for item in argv) > MAX_CODEX_PASSTHROUGH_TOTAL_CHARS
        ):
            return
        subprocess.run(
            [*argv, event_json],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=CODEX_PASSTHROUGH_TIMEOUT_SECONDS,
            check=False,
        )
    except Exception:
        # This compatibility callback must never block the managed completion hook.
        return


def _hook_session(agent: str, payload: dict[str, Any]) -> str:
    if agent == "codex":
        value = payload.get("thread-id")
    else:
        value = payload.get("session_id")
    if not isinstance(value, str) or not value:
        raise NotifyError("hook_session_missing")
    return value


def _gemini_after_tool(payload: dict[str, Any]) -> None:
    if payload.get("tool_name") != "run_shell_command":
        return
    response = payload.get("tool_response")
    if not isinstance(response, dict) or response.get("error"):
        return
    serialized = json.dumps(response, ensure_ascii=True)
    marker = _decode_gemini_marker(serialized[:MAX_GEMINI_MARKER_SCAN_CHARS])
    if marker is None:
        return
    action = marker.get("action", "arm")
    tool_input = payload.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if (
        action not in {"arm", "disarm"}
        or not isinstance(command, str)
        or "agent-notify.py" not in command
        or not re.search(rf"(?:^|\s){re.escape(action)}(?:\s|$)", command)
    ):
        return
    session_id = _hook_session("gemini", payload)
    if action == "disarm":
        for path in _paths("gemini", session_id):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        return
    config = _load_config()
    recipient = marker.get("to") or config["default_to"]
    if not isinstance(recipient, str) or not _valid_address(recipient):
        raise NotifyError("recipient_invalid")
    label = marker.get("label") if isinstance(marker.get("label"), str) else ""
    _gc_stale()
    _arm_record("gemini", session_id, label, recipient)


def _completion_event(agent: str, payload: dict[str, Any]) -> bool:
    if agent == "claude":
        return payload.get("hook_event_name") == "Stop" and not bool(payload.get("stop_hook_active"))
    if agent == "codex":
        return payload.get("type") == "agent-turn-complete"
    return payload.get("hook_event_name") == "AfterAgent" and not bool(payload.get("stop_hook_active"))


def _claim_pending(agent: str, session_id: str) -> tuple[Path, Path, dict[str, Any]] | None:
    armed, pending, lock = _paths(agent, session_id)
    if not pending.exists():
        _ensure_private_dir(pending.parent)
        try:
            os.replace(armed, pending)
        except FileNotFoundError:
            return None
    _ensure_private_dir(lock.parent)
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return None
    os.close(fd)
    try:
        record = _read_json_object(pending, "pending_invalid")
        if record.get("version") != STATE_VERSION or record.get("agent") != agent:
            raise NotifyError("pending_invalid")
        return pending, lock, record
    except Exception:
        try:
            lock.unlink()
        except FileNotFoundError:
            pass
        raise


def _message(record: dict[str, Any]) -> tuple[str, str]:
    agent_name = AGENT_NAMES[str(record["agent"])]
    label = _clean_label(str(record.get("label") or ""))
    subject = f"{agent_name} is done"
    if label:
        subject += f" - {label}"
    body = f"{agent_name} completed the turn you explicitly asked to be emailed about."
    if label:
        body += f"\n\nStatus: {label}"
    body += "\n\nReturn to the terminal when convenient.\n"
    return subject, body


def _send_himalaya(config: dict[str, Any], recipient: str, subject: str, body: str) -> bool:
    binary = shutil.which("himalaya")
    if not binary:
        return False
    message = EmailMessage(policy=email.policy.SMTP)
    message["From"] = config["from_address"]
    message["To"] = recipient
    message["Subject"] = subject
    message.set_content(body)
    try:
        result = subprocess.run(
            [binary, "message", "send", "-a", config["account"], "--quiet"],
            input=message.as_bytes(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=SEND_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _token(config: dict[str, Any]) -> str:
    path = Path(config["courier_token_file"]).expanduser()
    try:
        info = path.stat()
        if path.is_symlink() or not stat.S_ISREG(info.st_mode):
            raise NotifyError("courier_token_invalid")
        if os.name == "posix" and stat.S_IMODE(info.st_mode) & 0o077:
            raise NotifyError("courier_token_permissions")
        value = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise NotifyError("courier_token_unreadable") from exc
    if len(value) < 16:
        raise NotifyError("courier_token_invalid")
    return value


def _http_post(
    url: str, token: str, body: dict[str, Any], session_id: str | None = None
) -> tuple[int, dict[str, str], str]:
    headers = {
        "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    request = urllib.request.Request(
        url,
        data=json.dumps(body, separators=(",", ":")).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with _HTTP_OPENER.open(request, timeout=SEND_TIMEOUT_SECONDS) as response:
            response_headers = {key.lower(): value for key, value in response.headers.items()}
            raw = response.read(MAX_COURIER_RESPONSE_BYTES + 1)
            if len(raw) > MAX_COURIER_RESPONSE_BYTES:
                raise NotifyError("courier_response_too_large")
            return response.status, response_headers, raw.decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, {key.lower(): value for key, value in exc.headers.items()}, ""
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise NotifyError("courier_request_failed") from exc


def _jsonrpc(text: str, content_type: str) -> dict[str, Any]:
    if "text/event-stream" in content_type:
        data_lines = [line.partition(":")[2].strip() for line in text.splitlines() if line.startswith("data:")]
        text = next((line for line in data_lines if line), "")
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise NotifyError("courier_response_invalid") from exc
    if not isinstance(value, dict) or value.get("error"):
        raise NotifyError("courier_response_invalid")
    return value


def _send_courier(
    config: dict[str, Any], recipient: str, subject: str, body: str
) -> bool:
    token = _token(config)
    url = config["courier_url"]
    status, headers, text = _http_post(
        url,
        token,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "agent-notify", "version": "1"},
            },
        },
    )
    if status >= 400:
        raise NotifyError("courier_initialize_rejected")
    _jsonrpc(text, headers.get("content-type", ""))
    session_id = headers.get("mcp-session-id")
    if session_id:
        ack_status, _ack_headers, _ack_text = _http_post(
            url, token, {"jsonrpc": "2.0", "method": "notifications/initialized"}, session_id
        )
        if ack_status >= 400:
            raise NotifyError("courier_initialize_rejected")
    status, headers, text = _http_post(
        url,
        token,
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "email_send",
                "arguments": {
                    "account": config["account"],
                    "to": [recipient],
                    "subject": subject,
                    "body": body,
                    "confirm": True,
                },
            },
        },
        session_id,
    )
    if status >= 400:
        raise NotifyError("courier_send_rejected")
    envelope = _jsonrpc(text, headers.get("content-type", ""))
    result = envelope.get("result")
    if not isinstance(result, dict) or result.get("isError"):
        raise NotifyError("courier_send_failed")
    content = result.get("content")
    if not isinstance(content, list) or len(content) != 1 or not isinstance(content[0], dict):
        raise NotifyError("courier_send_failed")
    try:
        payload = json.loads(str(content[0].get("text", "")))
    except json.JSONDecodeError as exc:
        raise NotifyError("courier_send_failed") from exc
    return isinstance(payload, dict) and payload.get("ok") is True


def _send(record: dict[str, Any]) -> str:
    config = _load_config()
    recipient = record.get("to")
    if not isinstance(recipient, str) or not _valid_address(recipient):
        raise NotifyError("pending_recipient_invalid")
    subject, body = _message(record)
    if _send_himalaya(config, recipient, subject, body):
        return "himalaya"
    if _send_courier(config, recipient, subject, body):
        return "courier"
    raise NotifyError("send_failed")


def _complete(agent: str, payload: dict[str, Any]) -> None:
    session_id = _hook_session(agent, payload)
    claimed = _claim_pending(agent, session_id)
    if claimed is None:
        return
    pending, lock, record = claimed
    try:
        transport = _send(record)
    except NotifyError as exc:
        _log(f"send_failed agent={agent} code={exc}")
        try:
            lock.unlink()
        except FileNotFoundError:
            pass
        return
    try:
        pending.unlink()
        lock.unlink()
    except FileNotFoundError:
        pass
    _log(f"send_ok agent={agent} transport={transport}")


def _cmd_hook(args: argparse.Namespace) -> int:
    agent = _detect_agent(args.agent)
    if agent == "codex":
        _forward_codex_notification(getattr(args, "codex_passthrough", None), args.event_json)
    try:
        payload = _read_hook_payload(agent, args.event_json)
        if agent == "gemini" and payload.get("hook_event_name") == "AfterTool":
            _gemini_after_tool(payload)
        elif _completion_event(agent, payload):
            _gc_stale()
            _complete(agent, payload)
    except NotifyError as exc:
        # Malformed/unarmed hook calls stay non-blocking. Log only after a managed
        # arm marker or pending record made this an active notification operation.
        if str(exc) not in {"hook_payload_missing", "hook_payload_invalid", "hook_session_missing"}:
            _log(f"hook_failed agent={agent} code={exc}")
    except Exception:
        # Native hooks must never block an agent turn or expose a traceback/payload.
        _log(f"hook_failed agent={agent} code=internal_error")
    if agent == "gemini":
        print("{}")
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    arm = sub.add_parser("arm")
    arm.add_argument("--agent", choices=sorted(AGENTS))
    arm.add_argument("--label", default="")
    arm.add_argument("--to")
    arm.set_defaults(func=_cmd_arm)

    disarm = sub.add_parser("disarm")
    disarm.add_argument("--agent", choices=sorted(AGENTS))
    disarm.set_defaults(func=_cmd_disarm)

    hook = sub.add_parser("hook")
    hook.add_argument("--agent", required=True, choices=sorted(AGENTS))
    hook.add_argument("--codex-passthrough")
    hook.add_argument("event_json", nargs="?")
    hook.set_defaults(func=_cmd_hook)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        return int(args.func(args))
    except NotifyError as exc:
        print(f"agent-notify: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
