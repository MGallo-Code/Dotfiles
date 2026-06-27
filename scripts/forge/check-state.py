#!/usr/bin/env python3
"""check-state.py - Forge tracker readiness checker.

Reads a Forge `tracker.json` and reports whether the workflow is ready for PR, still
in progress, blocked on human input, or invalid. Intended for Claude/Codex/Gemini
and hooks alike; it depends only on the tracker file.

Exit codes:
  0 READY       all required gates are satisfied
  1 INCOMPLETE  agent work remains before ready_for_pr
  2 BLOCKED     human decision/override/permission is required
  3 INVALID     tracker is missing, malformed, or schema-invalid
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


REQUIRED_FIELDS = {
    "schema_version",
    "task_slug",
    "repo",
    "risk_class",
    "phase",
    "open_questions",
    "approved_decisions",
    "assumptions_made",
    "assumption_risk",
    "plan_clean_streak",
    "build_clean_streak",
    "reviewers_required",
    "reviewers_completed",
    "degraded_reviewers",
    "open_findings_count",
    "gates_run",
    "visual_required",
    "visual_verified",
    "pr_allowed",
    "explicit_human_override",
    "last_evidence",
    "next_action",
}
REQUIRED_FIELDS_V2 = {"plan_path", "remaining_work"}
REQUIRED_FIELDS_V3 = {"approved_plan_paths"}

RISK_CLASSES = {"small", "non_trivial", "high_risk", "destructive"}
PHASES = {
    "clarify",
    "ground",
    "plan",
    "plan_crosscheck",
    "handoff",
    "implement",
    "build_verify",
    "visual_verify",
    "ready_for_pr",
}
ASSUMPTION_RISKS = {"low", "medium", "high"}
REQUIRED_LISTS = {
    "open_questions",
    "approved_decisions",
    "assumptions_made",
    "reviewers_required",
    "reviewers_completed",
    "degraded_reviewers",
    "gates_run",
    "last_evidence",
    "remaining_work",
    "approved_plan_paths",
}
REQUIRED_BOOLS = {"visual_required", "visual_verified", "pr_allowed", "explicit_human_override"}
REQUIRED_INTS = {"schema_version", "plan_clean_streak", "build_clean_streak", "open_findings_count"}
REQUIRED_STRS = {"plan_path"}
READY_PHASE = "ready_for_pr"
MIN_CLEAN_STREAK = 3


def norm(value: Any) -> str:
    return str(value).strip().lower().replace("-", "_").replace(" ", "_")


def item_name(item: Any) -> str:
    if isinstance(item, dict):
        for key in ("name", "reviewer", "id", "tool"):
            if key in item:
                return norm(item[key])
        return norm(json.dumps(item, sort_keys=True))
    return norm(item)


def item_reason(item: Any) -> str:
    if isinstance(item, dict):
        for key in ("reason", "why", "status"):
            if key in item and item[key]:
                return str(item[key])
    return str(item)


def is_done_item(item: Any) -> bool:
    if isinstance(item, dict):
        return norm(item.get("status", "")) in {"done", "complete", "completed"}
    return False


def item_label(item: Any) -> str:
    if isinstance(item, dict):
        for key in ("item", "name", "task", "description"):
            if item.get(key):
                return str(item[key])
        return json.dumps(item, sort_keys=True)
    return str(item)


def item_status(item: Any) -> str:
    if isinstance(item, dict) and item.get("status"):
        return norm(item["status"])
    return "pending"


def unfinished_work(data: dict[str, Any]) -> list[Any]:
    items = data.get("remaining_work", [])
    if not isinstance(items, list):
        return []
    return [item for item in items if not is_done_item(item)]


def open_question_blocks(item: Any) -> bool:
    if isinstance(item, dict):
        if item.get("blocking") is False:
            return False
        risk = norm(item.get("risk", item.get("assumption_risk", "high")))
        return risk in {"high", "destructive", "unknown", ""}
    return True


def has_override_for(item: Any) -> bool:
    if isinstance(item, dict):
        return bool(item.get("override") or item.get("approved") or item.get("human_override"))
    return False


def load_tracker(path: Path) -> tuple[dict[str, Any] | None, list[str]]:
    if not path.exists():
        return None, [f"tracker does not exist: {path}"]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return None, [f"tracker is not valid JSON: {exc}"]
    except OSError as exc:
        return None, [f"cannot read tracker: {exc}"]
    if not isinstance(data, dict):
        return None, ["tracker JSON must be an object"]
    return data, []


def validate_schema(data: dict[str, Any]) -> list[str]:
    invalid: list[str] = []
    required = set(REQUIRED_FIELDS)
    version = data.get("schema_version")
    if isinstance(version, int) and not isinstance(version, bool) and version >= 2:
        required |= REQUIRED_FIELDS_V2
    if isinstance(version, int) and not isinstance(version, bool) and version >= 3:
        required |= REQUIRED_FIELDS_V3

    missing = sorted(required - data.keys())
    if missing:
        invalid.append("missing required field(s): " + ", ".join(missing))

    risk = data.get("risk_class")
    if risk is not None and risk not in RISK_CLASSES:
        invalid.append(f"risk_class must be one of {sorted(RISK_CLASSES)}, got {risk!r}")
    phase = data.get("phase")
    if phase is not None and phase not in PHASES:
        invalid.append(f"phase must be one of {sorted(PHASES)}, got {phase!r}")
    arisk = data.get("assumption_risk")
    if arisk is not None and arisk not in ASSUMPTION_RISKS:
        invalid.append(f"assumption_risk must be one of {sorted(ASSUMPTION_RISKS)}, got {arisk!r}")

    for field in sorted(REQUIRED_LISTS & data.keys()):
        if not isinstance(data[field], list):
            invalid.append(f"{field} must be a list")
    for field in sorted(REQUIRED_BOOLS & data.keys()):
        if not isinstance(data[field], bool):
            invalid.append(f"{field} must be a boolean")
    for field in sorted(REQUIRED_INTS & data.keys()):
        if not isinstance(data[field], int) or isinstance(data[field], bool):
            invalid.append(f"{field} must be an integer")
        elif data[field] < 0:
            invalid.append(f"{field} must be non-negative")
    for field in sorted(REQUIRED_STRS & data.keys()):
        if not isinstance(data[field], str) or not data[field].strip():
            invalid.append(f"{field} must be a non-empty string")
    return invalid


def evaluate(data: dict[str, Any]) -> tuple[str, list[str], list[str]]:
    """Return (status, blockers, incomplete)."""
    blockers: list[str] = []
    incomplete: list[str] = []

    risk = data["risk_class"]
    phase = data["phase"]
    override = data["explicit_human_override"]

    blocking_questions = [q for q in data["open_questions"] if open_question_blocks(q)]
    if blocking_questions:
        blockers.append(f"{len(blocking_questions)} blocking open question(s) remain")

    if data["assumption_risk"] == "high" and not override:
        blockers.append("high-risk assumptions require explicit_human_override")

    degraded = data["degraded_reviewers"]
    degraded_without_override = [d for d in degraded if not (override or has_override_for(d))]
    if degraded_without_override:
        reasons = "; ".join(item_reason(d) for d in degraded_without_override[:3])
        blockers.append(f"degraded reviewer(s) require explicit override: {reasons}")

    if phase != READY_PHASE:
        incomplete.append(f"phase is {phase!r}, not {READY_PHASE!r}")

    if data["open_findings_count"] > 0:
        incomplete.append(f"{data['open_findings_count']} open finding(s) remain")

    if risk != "small":
        if data["plan_clean_streak"] < MIN_CLEAN_STREAK and not override:
            incomplete.append(
                f"plan_clean_streak is {data['plan_clean_streak']}, needs {MIN_CLEAN_STREAK}"
            )
        if data["build_clean_streak"] < MIN_CLEAN_STREAK and not override:
            incomplete.append(
                f"build_clean_streak is {data['build_clean_streak']}, needs {MIN_CLEAN_STREAK}"
            )

        required = {item_name(r) for r in data["reviewers_required"]}
        completed = {item_name(r) for r in data["reviewers_completed"]}
        degraded_names = {item_name(r) for r in degraded}
        missing_reviewers = sorted(required - completed - degraded_names)
        if missing_reviewers and not override:
            incomplete.append("required reviewer(s) missing: " + ", ".join(missing_reviewers))

        if not data["gates_run"]:
            incomplete.append("gates_run is empty")
        if not data["last_evidence"]:
            incomplete.append("last_evidence is empty")

    if data["visual_required"] and not data["visual_verified"]:
        incomplete.append("visual verification is required but not verified")

    if phase == READY_PHASE and not data["pr_allowed"]:
        blockers.append("pr_allowed is false; explicit PR permission is required")
    elif not data["pr_allowed"]:
        incomplete.append("pr_allowed is false")

    if risk == "destructive" and phase == READY_PHASE and not override:
        blockers.append("destructive risk requires explicit_human_override before ready_for_pr")

    if blockers:
        return "BLOCKED", blockers, incomplete
    if incomplete:
        return "INCOMPLETE", blockers, incomplete
    return "READY", blockers, incomplete


def find_latest_tracker(base: Path) -> Path | None:
    if not base.exists():
        return None
    trackers = [p for p in base.glob("*/tracker.json") if p.is_file()]
    if not trackers:
        return None
    return max(trackers, key=lambda p: p.stat().st_mtime)


def forge_home() -> Path:
    return Path(os.path.expanduser(os.environ.get("FORGE_HOME", "~/Documents/Agent-Forge")))


def resolve_tracker_arg(arg: str) -> Path:
    expanded = os.path.expanduser(arg)
    if os.sep in expanded or (os.altsep and os.altsep in expanded) or expanded.endswith(".json"):
        return Path(expanded).resolve()
    return (forge_home() / expanded / "tracker.json").resolve()


def print_text(status: str, path: Path, data: dict[str, Any] | None, invalid: list[str],
               blockers: list[str], incomplete: list[str]) -> None:
    if status == "INVALID":
        sys.stderr.write(f"forge-state: INVALID {path}\n")
        for item in invalid:
            sys.stderr.write(f"  - {item}\n")
        return

    assert data is not None
    out = sys.stdout if status == "READY" else sys.stderr
    out.write(f"forge-state: {status} {path}\n")
    out.write(f"  task: {data.get('task_slug')}  phase: {data.get('phase')}  risk: {data.get('risk_class')}\n")
    plan_path = data.get("plan_path")
    if plan_path:
        out.write(f"  plan_path: {plan_path}\n")
    approved_plan_paths = data.get("approved_plan_paths", [])
    if approved_plan_paths:
        out.write("  approved_plan_paths:\n")
        for item in approved_plan_paths:
            out.write(f"    - {item}\n")
    if blockers:
        out.write("  blockers:\n")
        for item in blockers:
            out.write(f"    - {item}\n")
    if incomplete:
        out.write("  missing:\n")
        for item in incomplete:
            out.write(f"    - {item}\n")
    next_action = data.get("next_action")
    if next_action:
        out.write(f"  next_action: {next_action}\n")
    remaining = unfinished_work(data)
    if remaining:
        out.write("  remaining_work:\n")
        for item in remaining:
            out.write(f"    - [{item_status(item)}] {item_label(item)}\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Check Forge tracker readiness.")
    parser.add_argument(
        "tracker",
        nargs="?",
        help="Tracker path or slug. Bare slug resolves to $FORGE_HOME/<slug>/tracker.json. "
             "Defaults to newest $FORGE_HOME/*/tracker.json (or ~/Documents/Agent-Forge).",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    args = parser.parse_args(argv)

    if args.tracker:
        tracker = resolve_tracker_arg(args.tracker)
    else:
        base = forge_home()
        latest = find_latest_tracker(base)
        if latest is None:
            invalid = [f"no tracker path supplied and no {base}/*/tracker.json found"]
            if args.json:
                print(json.dumps({"status": "INVALID", "invalid": invalid}, indent=2))
            else:
                print_text("INVALID", base, None, invalid, [], [])
            return 3
        tracker = latest.resolve()

    data, load_errors = load_tracker(tracker)
    if data is None:
        if args.json:
            print(json.dumps({"status": "INVALID", "tracker": str(tracker), "invalid": load_errors}, indent=2))
        else:
            print_text("INVALID", tracker, None, load_errors, [], [])
        return 3

    invalid = validate_schema(data)
    if invalid:
        if args.json:
            print(json.dumps({"status": "INVALID", "tracker": str(tracker), "invalid": invalid}, indent=2))
        else:
            print_text("INVALID", tracker, data, invalid, [], [])
        return 3

    status, blockers, incomplete = evaluate(data)
    if args.json:
        print(json.dumps({
            "status": status,
            "tracker": str(tracker),
            "task_slug": data.get("task_slug"),
            "phase": data.get("phase"),
            "risk_class": data.get("risk_class"),
            "blockers": blockers,
            "missing": incomplete,
            "next_action": data.get("next_action"),
            "plan_path": data.get("plan_path"),
            "approved_plan_paths": data.get("approved_plan_paths", []),
            "remaining_work": unfinished_work(data),
        }, indent=2))
    else:
        print_text(status, tracker, data, [], blockers, incomplete)

    return {"READY": 0, "INCOMPLETE": 1, "BLOCKED": 2}[status]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
