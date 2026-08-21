#!/usr/bin/env python3
"""Bounded, privacy-preserving Michael Workspace access diagnostics."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any


ACCESS_FAILURE = 74
DIAGNOSTIC_FAILURE = 70
REPORT_LIMIT = 25
KNOWN_CLIENTS = (
    "com.apple.Terminal",
    "com.mitchellh.ghostty",
    "com.anthropic.claude-code",
    "com.anthropic.claudefordesktop",
    "com.openai.codex",
)
TCC_SERVICES = (
    "kTCCServiceSystemPolicyAllFiles",
    "kTCCServiceSystemPolicyDocumentsFolder",
    "kTCCServiceSystemPolicyDesktopFolder",
    "kTCCServiceSystemPolicyDownloadsFolder",
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def errno_name(value: int | None) -> str | None:
    return errno.errorcode.get(value, f"ERRNO_{value}") if value is not None else None


def probe_child(
    path: Path,
    mode: str,
    *,
    probe_token: str | None = None,
    test_hold_after_create: float = 0,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "ok": False,
        "mode": mode,
        "operation": "stat",
        "errno": None,
        "timed_out": False,
        "mount_read_only": None,
    }
    probe_path: Path | None = None
    try:
        try:
            os.stat(path)
        except FileNotFoundError:
            if mode != "history":
                raise
            os.stat(path.parent)
            result["operation"] = "history_missing_optional"
            result["ok"] = True
            return result
        if hasattr(os, "statvfs"):
            result["operation"] = "statvfs"
            flags = os.statvfs(path).f_flag
            readonly_flag = getattr(os, "ST_RDONLY", 1)
            result["mount_read_only"] = bool(flags & readonly_flag)

        if mode == "history":
            # Opening proves access to the configured file without reading, appending, truncating,
            # or creating it. A missing history file is valid and handled above.
            result["operation"] = "history_open_read"
            descriptor = os.open(path, os.O_RDONLY)
            os.close(descriptor)
            result["operation"] = "history_open_append"
            descriptor = os.open(path, os.O_WRONLY | os.O_APPEND)
            os.close(descriptor)
        else:
            result["operation"] = "enumerate"
            with os.scandir(path) as entries:
                for index, _entry in enumerate(entries):
                    if index >= 255:
                        break

        if mode == "full":
            result["operation"] = "write_create"
            token = probe_token or f"{os.getpid()}-{secrets.token_hex(5)}"
            probe_path = path / f".workspace-access-probe-{token}"
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            flags |= getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(probe_path, flags, 0o600)
            try:
                payload = b"workspace-access-probe\n"
                os.write(descriptor, payload)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            if test_hold_after_create:
                time.sleep(test_hold_after_create)
            result["operation"] = "write_readback"
            with probe_path.open("rb") as handle:
                if handle.read() != payload:
                    raise OSError(errno.EIO, "probe readback mismatch")
            result["operation"] = "write_remove"
            probe_path.unlink()
            probe_path = None

        result["operation"] = "complete"
        result["ok"] = True
    except OSError as exc:
        result["errno"] = errno_name(exc.errno)
    finally:
        if probe_path is not None:
            try:
                probe_path.unlink()
            except OSError:
                pass
    return result


def combine_history_probes(parent: dict[str, Any], history_file: dict[str, Any]) -> dict[str, Any]:
    """Summarize history access for classification while retaining both raw probes in reports."""
    failed = next((item for item in (parent, history_file) if not item.get("ok")), None)
    return {
        "ok": failed is None,
        "errno": failed.get("errno") if failed else None,
        "mount_read_only": any(item.get("mount_read_only") is True for item in (parent, history_file)),
    }


def skipped_history_probe() -> dict[str, Any]:
    return {
        "ok": True,
        "mode": "history",
        "operation": "skipped_outside_safe_history_location",
        "errno": None,
        "timed_out": False,
        "mount_read_only": None,
        "skipped": True,
    }


def history_probes(
    history_path: Path, home_path: Path, timeout: float
) -> tuple[dict[str, Any], dict[str, Any]]:
    absolute = Path(os.path.abspath(str(history_path)))
    home = Path(os.path.abspath(str(home_path)))
    # Automatic diagnostics may inspect a direct HOME history file, but never follow a history
    # symlink or enter Documents/project descendants merely because HISTFILE points there.
    if absolute.parent != home or absolute.is_symlink():
        skipped = skipped_history_probe()
        return dict(skipped), dict(skipped)
    return bounded_probe(absolute.parent, "enumerate", timeout), bounded_probe(
        absolute, "history", timeout
    )


def bounded_probe(
    path: Path,
    mode: str = "full",
    timeout: float = 3.0,
    *,
    test_delay: float = 0,
    test_hold_after_create: float = 0,
) -> dict[str, Any]:
    probe_token = f"{os.getpid()}-{secrets.token_hex(5)}" if mode == "full" else None
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "_probe-child",
        "--path",
        str(path),
        "--mode",
        mode,
    ]
    if test_delay:
        command.extend(("--test-delay", str(test_delay)))
    if probe_token:
        command.extend(("--probe-token", probe_token))
    if test_hold_after_create:
        command.extend(("--test-hold-after-create", str(test_hold_after_create)))
    try:
        completed = subprocess.run(
            command,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        cleanup_errno = None
        if probe_token:
            try:
                (path / f".workspace-access-probe-{probe_token}").unlink()
            except FileNotFoundError:
                pass
            except OSError as exc:
                cleanup_errno = errno_name(exc.errno)
        return {
            "ok": False,
            "mode": mode,
            "operation": "bounded_probe",
            "errno": "ETIMEDOUT",
            "timed_out": True,
            "mount_read_only": None,
            "cleanup_errno": cleanup_errno,
        }
    try:
        result = json.loads(completed.stdout)
    except (json.JSONDecodeError, TypeError):
        return {
            "ok": False,
            "mode": mode,
            "operation": "diagnostic_child",
            "errno": None,
            "timed_out": False,
            "mount_read_only": None,
        }
    if completed.returncode not in (0, ACCESS_FAILURE) or not isinstance(result, dict):
        result["ok"] = False
        result["operation"] = "diagnostic_child"
    return result


def safe_state_dir(home: Path) -> Path:
    directory = home / ".local/state/michael-workspace-access"
    if directory.exists() and directory.is_symlink():
        raise RuntimeError("diagnostic state directory is a symlink")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.stat()
    wrong_owner = hasattr(os, "getuid") and info.st_uid != os.getuid()
    if wrong_owner or not stat.S_ISDIR(info.st_mode):
        raise RuntimeError("diagnostic state directory is not owned by the current user")
    os.chmod(directory, 0o700)
    return directory


def path_identity(path: Path, home: Path) -> dict[str, Any]:
    absolute = os.path.abspath(str(path))
    documents = os.path.abspath(str(home / "Documents"))
    known = {
        os.path.abspath(str(home)): "HOME",
        os.path.abspath(str(home / ".dotfiles")): "dotfiles",
        os.path.abspath(str(home / "Documents/EA")): "EA",
        os.path.abspath(str(home / "Documents/Wiki")): "Wiki",
        os.path.abspath(str(home / "Documents/SBIC")): "SBIC",
    }
    return {
        "label": known.get(absolute, "workspace"),
        "path_hash": hashlib.sha256(absolute.encode("utf-8")).hexdigest()[:16],
        "under_documents": absolute == documents or absolute.startswith(documents + os.sep),
    }


def responsible_process_chain() -> list[str]:
    labels: list[str] = []
    pid = os.getppid()
    aliases = {
        "terminal": "terminal",
        "ghostty": "ghostty",
        "claude": "claude-cli",
        "codex": "codex-cli",
        "chatgpt": "codex-desktop",
        "zsh": "zsh",
        "bash": "bash",
        "pwsh": "powershell",
        "powershell": "powershell",
        "python": "python",
        "python3": "python",
    }
    for _ in range(7):
        if pid <= 1:
            break
        try:
            output = subprocess.run(
                ["ps", "-p", str(pid), "-o", "ppid=", "-o", "comm="],
                text=True,
                capture_output=True,
                timeout=1,
                check=False,
            ).stdout.strip()
            parent_text, command = output.split(None, 1)
            pid = int(parent_text)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            break
        basename = Path(command).name.lower()
        command_lower = command.lower()
        if "/claude.app/" in command_lower:
            label = "claude-desktop"
        elif "/chatgpt.app/" in command_lower:
            label = "codex-desktop"
        else:
            label = aliases.get(basename, "other")
        if not labels or labels[-1] != label:
            labels.append(label)
    return labels


def tcc_inventory(home: Path) -> dict[str, Any]:
    if platform.system() != "Darwin":
        return {"status": "not_applicable", "sources": [], "grants": []}
    placeholders_clients = ",".join("?" for _ in KNOWN_CLIENTS)
    placeholders_services = ",".join("?" for _ in TCC_SERVICES)
    query = (
        "SELECT client, service, auth_value FROM access "
        f"WHERE client IN ({placeholders_clients}) AND service IN ({placeholders_services}) "
        "ORDER BY client, service"
    )
    grants: list[dict[str, Any]] = []
    sources: list[dict[str, Any]] = []
    for scope, database in (
        ("user", home / "Library/Application Support/com.apple.TCC/TCC.db"),
        ("system", Path("/Library/Application Support/com.apple.TCC/TCC.db")),
    ):
        try:
            connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=1)
            try:
                rows = connection.execute(query, KNOWN_CLIENTS + TCC_SERVICES).fetchall()
            finally:
                connection.close()
        except (OSError, sqlite3.Error) as exc:
            sources.append(
                {
                    "scope": scope,
                    "status": "unavailable",
                    "error": getattr(exc, "sqlite_errorname", None)
                    or errno_name(getattr(exc, "errno", None)),
                }
            )
            continue
        sources.append({"scope": scope, "status": "read", "grant_count": len(rows)})
        grants.extend(
            {
                "scope": scope,
                "client": str(client),
                "service": str(service),
                "auth_value": int(value),
            }
            for client, service, value in rows
        )
    readable = sum(source["status"] == "read" for source in sources)
    return {
        "status": "read" if readable == len(sources) else "partial" if readable else "unavailable",
        "sources": sources,
        "grants": grants,
    }


def cause(category: str, confidence: str, *evidence: str) -> dict[str, Any]:
    return {"category": category, "confidence": confidence, "evidence": list(evidence)}


def classify(
    target: dict[str, Any],
    home: dict[str, Any],
    history: dict[str, Any],
    *,
    under_documents: bool,
    system: str,
    symptom: str,
    tcc: dict[str, Any],
    caller_cwd_restore_failed: bool = False,
) -> list[dict[str, Any]]:
    causes: list[dict[str, Any]] = []
    target_errno = target.get("errno")

    if caller_cwd_restore_failed:
        causes.append(
            cause(
                "inaccessible_cwd_or_file_provider",
                "high",
                "the parent shell could not restore its original cwd after the agent exited",
            )
        )
    if symptom == "agent-read-only" and target.get("ok") and home.get("ok"):
        causes.append(
            cause(
                "agent_sandbox_envelope",
                "medium",
                "agent-reported denial is consistent with an agent sandbox mismatch while parent target and HOME probes succeeded",
                "parent process cannot override or prove an embedding host's effective task envelope",
            )
        )
    if target.get("mount_read_only") or target_errno == "EROFS":
        causes.append(
            cause(
                "read_only_mount",
                "high",
                "statvfs reported ST_RDONLY or the write probe returned EROFS",
            )
        )
    if (
        system == "Darwin"
        and under_documents
        and target_errno == "EPERM"
        and not target.get("mount_read_only")
    ):
        denied = any(item.get("auth_value") == 0 for item in tcc.get("grants", []))
        causes.append(
            cause(
                "macos_tcc_system_policy",
                "medium",
                "a protected Documents path returned EPERM on a writable mount",
                "a known client has a TCC denial, but attribution is unverified" if denied else "TCC grant inventory does not prove responsible-process authorization",
            )
        )
    if target_errno in {"ENOENT", "ESTALE", "EIO", "ETIMEDOUT"} and home.get("ok"):
        causes.append(
            cause(
                "inaccessible_cwd_or_file_provider",
                "high" if target_errno in {"ENOENT", "ESTALE"} else "medium",
                f"workspace probe failed with {target_errno} while HOME remained accessible",
            )
        )
    if target_errno == "EACCES":
        causes.append(
            cause(
                "unix_permissions_or_acl",
                "high",
                "workspace probe returned EACCES rather than EPERM or EROFS",
            )
        )
    if target.get("ok") and not history.get("ok"):
        causes.append(
            cause(
                "zsh_history_or_prompt_hook",
                "high",
                "workspace probe succeeded while the history directory or file access probe failed",
            )
        )
    elif symptom == "shell-message" and target.get("ok"):
        causes.append(
            cause(
                "zsh_history_or_prompt_hook",
                "low",
                "shell reported an error while workspace and HOME probes succeeded",
                "inspect the recorded shell/hook context; no filesystem denial was reproduced",
            )
        )
    if not causes and (not target.get("ok") or not home.get("ok") or not history.get("ok")):
        causes.append(
            cause(
                "unknown",
                "low",
                "a workspace, HOME, or history probe failed without evidence meeting a more specific classifier",
            )
        )
    if not causes:
        causes.append(
            cause(
                "no_failure_observed",
                "high",
                "workspace, HOME, history-directory, and history-file probes succeeded",
            )
        )
    causes.sort(key=lambda item: {"high": 0, "medium": 1, "low": 2}.get(item["confidence"], 3))
    return causes


def write_report(directory: Path, report: dict[str, Any]) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    name = f"report-{timestamp}-{os.getpid()}-{secrets.token_hex(3)}.json"
    destination = directory / name
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(destination, flags, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(destination, 0o600)

    latest_temporary = directory / f".latest-{os.getpid()}-{secrets.token_hex(3)}.tmp"
    descriptor = os.open(latest_temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(latest_temporary, directory / "latest.json")
    finally:
        try:
            latest_temporary.unlink()
        except FileNotFoundError:
            pass

    reports = sorted(directory.glob("report-*.json"), key=lambda item: item.name, reverse=True)
    for old in reports[REPORT_LIMIT:]:
        try:
            old.unlink()
        except OSError:
            pass
    return destination


def capture(args: argparse.Namespace) -> int:
    home_path = Path(args.home)
    target_path = Path(args.path)
    history_path = Path(args.history_file) if args.history_file else home_path / ".zsh_history"
    target_identity = path_identity(target_path, home_path)
    target_probe = bounded_probe(target_path, "full", args.timeout)
    home_probe = bounded_probe(home_path, "full", args.timeout)
    history_parent_probe, history_file_probe = history_probes(
        history_path, home_path, args.timeout
    )
    history_probe = combine_history_probes(history_parent_probe, history_file_probe)
    tcc = tcc_inventory(home_path)
    causes = classify(
        target_probe,
        home_probe,
        history_probe,
        under_documents=target_identity["under_documents"],
        system=platform.system(),
        symptom=args.symptom,
        tcc=tcc,
        caller_cwd_restore_failed=args.caller_cwd_restore_failed,
    )
    report = {
        "schema_version": 1,
        "captured_at": utc_now(),
        "phase": args.phase,
        "symptom": args.symptom,
        "agent": args.agent,
        "requested_policy": args.requested_policy,
        "agent_status": args.agent_status,
        "caller_cwd_restore_failed": args.caller_cwd_restore_failed,
        "platform": platform.system(),
        "process_context": responsible_process_chain(),
        "target": target_identity,
        "probes": {
            "target": target_probe,
            "home_control": home_probe,
            "history_parent": history_parent_probe,
            "history_file": history_file_probe,
        },
        "tcc": tcc,
        "causes": causes,
        "primary_category": causes[0]["category"],
        "privacy": {
            "raw_paths": False,
            "raw_logs": False,
            "command_or_transcript_content": False,
        },
    }
    try:
        directory = safe_state_dir(home_path)
        destination = write_report(directory, report)
    except (OSError, RuntimeError) as exc:
        print(f"workspace-access: could not write diagnostic report: {exc}", file=sys.stderr)
        return DIAGNOSTIC_FAILURE
    print(f"workspace-access: {report['primary_category']} ({destination})")
    return 0


def show_latest(home: Path, as_json: bool) -> int:
    try:
        path = safe_state_dir(home) / "latest.json"
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"workspace-access: no readable latest report: {exc}", file=sys.stderr)
        return 1
    if as_json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    print(f"Latest: {report.get('captured_at')} ({report.get('phase')})")
    print(f"Primary: {report.get('primary_category')}")
    for item in report.get("causes", []):
        print(f"- {item.get('category')} [{item.get('confidence')}]")
        for evidence in item.get("evidence", []):
            print(f"  {evidence}")
    target = report.get("probes", {}).get("target", {})
    print(
        "Target probe: "
        f"ok={target.get('ok')} operation={target.get('operation')} errno={target.get('errno')} "
        f"mount_read_only={target.get('mount_read_only')}"
    )
    return 0


def self_test() -> int:
    healthy = {"ok": True, "errno": None, "mount_read_only": False}
    home = dict(healthy)
    history = dict(healthy)
    empty_tcc = {"status": "read", "grants": []}
    fixtures = {
        "agent_sandbox_envelope": (
            healthy,
            home,
            history,
            dict(under_documents=True, system="Darwin", symptom="agent-read-only", tcc=empty_tcc),
        ),
        "read_only_mount": (
            {"ok": False, "errno": "EROFS", "mount_read_only": True},
            home,
            history,
            dict(under_documents=True, system="Darwin", symptom="filesystem", tcc=empty_tcc),
        ),
        "macos_tcc_system_policy": (
            {"ok": False, "errno": "EPERM", "mount_read_only": False},
            home,
            history,
            dict(under_documents=True, system="Darwin", symptom="filesystem", tcc=empty_tcc),
        ),
        "inaccessible_cwd_or_file_provider": (
            {"ok": False, "errno": "ESTALE", "mount_read_only": False},
            home,
            history,
            dict(under_documents=True, system="Darwin", symptom="filesystem", tcc=empty_tcc),
        ),
        "zsh_history_or_prompt_hook": (
            healthy,
            home,
            {"ok": False, "errno": "EACCES", "mount_read_only": False},
            dict(under_documents=True, system="Darwin", symptom="shell-message", tcc=empty_tcc),
        ),
        "unix_permissions_or_acl": (
            {"ok": False, "errno": "EACCES", "mount_read_only": False},
            home,
            history,
            dict(under_documents=False, system="Linux", symptom="filesystem", tcc=empty_tcc),
        ),
        "unknown": (
            {"ok": False, "errno": None, "mount_read_only": False},
            home,
            history,
            dict(under_documents=False, system="Linux", symptom="filesystem", tcc=empty_tcc),
        ),
    }
    for expected, (target, home_probe, history_probe, kwargs) in fixtures.items():
        actual = classify(target, home_probe, history_probe, **kwargs)[0]["category"]
        if actual != expected:
            print(f"self-test: expected {expected}, got {actual}", file=sys.stderr)
            return 1
    mixed = classify(
        healthy,
        home,
        {"ok": False, "errno": "EACCES", "mount_read_only": False},
        under_documents=True,
        system="Darwin",
        symptom="agent-read-only",
        tcc=empty_tcc,
    )
    if [item["category"] for item in mixed[:2]] != [
        "zsh_history_or_prompt_hook",
        "agent_sandbox_envelope",
    ]:
        print("self-test: direct history evidence did not outrank inferred sandbox evidence", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="workspace-access-selftest-") as raw:
        root = Path(raw)
        probe = bounded_probe(root, "full", 2)
        if not probe.get("ok") or any(root.glob(".workspace-access-probe-*")):
            print("self-test: reversible write probe failed or left residue", file=sys.stderr)
            return 1
        timed_out = bounded_probe(root, "enumerate", 0.02, test_delay=0.2)
        if not timed_out.get("timed_out") or timed_out.get("errno") != "ETIMEDOUT":
            print("self-test: bounded probe timeout did not fire", file=sys.stderr)
            return 1
        write_timed_out = bounded_probe(root, "full", 0.02, test_hold_after_create=0.2)
        if not write_timed_out.get("timed_out") or any(root.glob(".workspace-access-probe-*")):
            print("self-test: timed-out write probe left residue", file=sys.stderr)
            return 1
        history_file = root / ".zsh_history"
        history_file.write_text("private-history-content\n", encoding="utf-8")
        history_probe = bounded_probe(history_file, "history", 2)
        if not history_probe.get("ok") or history_file.read_text(encoding="utf-8") != "private-history-content\n":
            print("self-test: history access probe changed file content", file=sys.stderr)
            return 1
        missing_history = bounded_probe(root / ".missing-history", "history", 2)
        if not missing_history.get("ok") or missing_history.get("operation") != "history_missing_optional":
            print("self-test: missing optional history file was treated as a failure", file=sys.stderr)
            return 1
        combined_history = combine_history_probes(probe, history_probe)
        if not combined_history.get("ok"):
            print("self-test: healthy history probes did not combine as healthy", file=sys.stderr)
            return 1
        unsafe_history = root / "Documents/KeepTheCall/.zsh_history"
        unsafe_parent, unsafe_file = history_probes(unsafe_history, root, 2)
        if not unsafe_parent.get("skipped") or not unsafe_file.get("skipped"):
            print("self-test: history probe entered an unsafe project location", file=sys.stderr)
            return 1
        state = safe_state_dir(root)
        sample = {
            "captured_at": utc_now(),
            "phase": "self-test",
            "primary_category": "no_failure_observed",
            "causes": [],
            "target": path_identity(root, root),
            "probes": {"target": probe},
        }
        destination = write_report(state, sample)
        if os.name == "posix" and (
            stat.S_IMODE(state.stat().st_mode) != 0o700
            or stat.S_IMODE(destination.stat().st_mode) != 0o600
        ):
            print("self-test: report permissions are not private", file=sys.stderr)
            return 1
        report_text = destination.read_text(encoding="utf-8")
        if str(root) in report_text or "/Users/" in report_text:
            print("self-test: report unexpectedly contains a raw user path", file=sys.stderr)
            return 1
    print("workspace-access diagnostics self-test OK")
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    root.add_argument("--self-test", action="store_true")
    subparsers = root.add_subparsers(dest="command")

    probe_parser = subparsers.add_parser("probe")
    probe_parser.add_argument("--path", required=True)
    probe_parser.add_argument("--mode", choices=("enumerate", "full"), default="full")
    probe_parser.add_argument("--timeout", type=float, default=3.0)
    probe_parser.add_argument("--json", action="store_true")

    child_parser = subparsers.add_parser("_probe-child")
    child_parser.add_argument("--path", required=True)
    child_parser.add_argument("--mode", choices=("enumerate", "full", "history"), required=True)
    child_parser.add_argument("--test-delay", type=float, default=0, help=argparse.SUPPRESS)
    child_parser.add_argument("--probe-token", help=argparse.SUPPRESS)
    child_parser.add_argument("--test-hold-after-create", type=float, default=0, help=argparse.SUPPRESS)

    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--path", required=True)
    capture_parser.add_argument("--home", default=str(Path.home()))
    capture_parser.add_argument("--history-file")
    capture_parser.add_argument("--timeout", type=float, default=3.0)
    capture_parser.add_argument("--phase", choices=("preflight", "exit", "prompt", "manual"), required=True)
    capture_parser.add_argument("--agent", choices=("claude", "codex", "gemini", "shell", "desktop", "unknown"), default="unknown")
    capture_parser.add_argument("--requested-policy", default="unverified")
    capture_parser.add_argument("--agent-status", type=int)
    capture_parser.add_argument("--symptom", choices=("filesystem", "agent-read-only", "shell-message"), default="filesystem")
    capture_parser.add_argument("--caller-cwd-restore-failed", action="store_true")

    latest_parser = subparsers.add_parser("latest")
    latest_parser.add_argument("--home", default=str(Path.home()))
    latest_parser.add_argument("--json", action="store_true")
    return root


def main() -> int:
    args = parser().parse_args()
    if args.self_test:
        return self_test()
    if args.command == "_probe-child":
        if args.test_delay:
            time.sleep(args.test_delay)
        result = probe_child(
            Path(args.path),
            args.mode,
            probe_token=args.probe_token,
            test_hold_after_create=args.test_hold_after_create,
        )
        print(json.dumps(result, sort_keys=True))
        return 0 if result["ok"] else ACCESS_FAILURE
    if args.command == "probe":
        result = bounded_probe(Path(args.path), args.mode, args.timeout)
        if args.json or not result.get("ok"):
            print(json.dumps(result, sort_keys=True))
        return 0 if result.get("ok") else ACCESS_FAILURE
    if args.command == "capture":
        return capture(args)
    if args.command == "latest":
        return show_latest(Path(args.home), args.json)
    parser().print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
