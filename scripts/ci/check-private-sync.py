#!/usr/bin/env python3
"""INV-24: EA's private-file sync stays on Tailscale and never touches git (ADR-0009).

Hermetic: drives the pure `desired()` and `stignore_text()` of scripts/configure-private-sync.py
against a real Syncthing 2.1.5 default config (scripts/ci/fixtures/), no Syncthing needed.

    python3 scripts/ci/check-private-sync.py                 # the fixtures
    python3 scripts/ci/check-private-sync.py --revert-test   # each planted weakening must FAIL them
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "configure-private-sync.py"
FIXTURE = ROOT / "scripts" / "ci" / "fixtures" / "syncthing-2.1.5-default-config.json"
MANIFEST = ROOT / "private-sync.json"
ME, PEER, STRANGER = "AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA", \
    "BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB", \
    "CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC"


def load(script: Path):
    spec = importlib.util.spec_from_file_location("private_sync_check", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixtures(script: Path) -> list[str]:
    fails: list[str] = []

    def check(name: str, ok: bool, detail: object = "") -> None:
        if not ok:
            fails.append(f"{name}: {detail}")

    m = load(script)
    base = json.loads(FIXTURE.read_text(encoding="utf-8"))
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    manifest = {**manifest, "peers": [{"name": "mini", "tailscale_ip": "100.64.0.1", "device_id": ME},
                                      {"name": "laptop", "tailscale_ip": "100.64.0.2", "device_id": PEER}]}
    home = Path("/Users/someone")
    me = m.find_self(manifest, ME, set())
    check("self found by device id", me and me["name"] == "mini", me)
    check("self found by Tailscale IP when its id is not listed yet",
          (m.find_self({**manifest, "peers": [{"name": "mini", "tailscale_ip": "100.64.0.1", "device_id": ""}]},
                       ME, {"100.64.0.1"}) or {}).get("name") == "mini")
    check("an unlisted machine is refused", m.find_self(manifest, STRANGER, {"10.0.0.9"}) is None)

    current = copy.deepcopy(base)
    current["devices"][0]["deviceID"] = ME
    current["devices"].append({**copy.deepcopy(current["defaults"]["device"]), "deviceID": STRANGER, "name": "stranger"})
    current["folders"].append({**copy.deepcopy(current["defaults"]["folder"]), "id": "default", "path": "/Users/someone/Sync"})
    current["gui"]["address"] = "0.0.0.0:8384"
    want = m.desired(current, manifest, ME, me, home)
    o = want["options"]
    check("listens only on its Tailscale address", o["listenAddresses"] == ["tcp://100.64.0.1:22000"], o["listenAddresses"])
    for flag in ("globalAnnounceEnabled", "localAnnounceEnabled", "relaysEnabled", "natEnabled",
                 "crashReportingEnabled", "startBrowser"):
        check(f"{flag} is off", o[flag] is False, o[flag])
    check("usage reporting declined", o["urAccepted"] == -1, o["urAccepted"])
    check("STUN off (no external-address lookups)", o["stunKeepaliveStartS"] == 0, o["stunKeepaliveStartS"])
    check("LAN addresses not announced", o["announceLANAddresses"] is False, o["announceLANAddresses"])
    check("auto-upgrade off (Homebrew owns the version)", o["autoUpgradeIntervalH"] == 0, o["autoUpgradeIntervalH"])
    check("GUI forced back to loopback", want["gui"]["address"].startswith("127.0.0.1:"), want["gui"]["address"])
    ids = {d["deviceID"]: d for d in want["devices"]}
    check("devices are exactly this machine and its peer", set(ids) == {ME, PEER}, sorted(ids))
    check("the peer is reached only at its Tailscale address", ids.get(PEER, {}).get("addresses") == ["tcp://100.64.0.2:22000"],
          ids.get(PEER, {}).get("addresses"))
    check("the peer cannot introduce devices or push folders",
          ids.get(PEER, {}).get("introducer") is False and ids.get(PEER, {}).get("autoAcceptFolders") is False)
    check("exactly one folder (the default ~/Sync folder is dropped)", [f["id"] for f in want["folders"]] == ["ea-private"],
          [f["id"] for f in want["folders"]])
    folder = want["folders"][0]
    check("the folder is EA", folder["path"] == "/Users/someone/Workspace/EA", folder["path"])
    check("the folder is shared with exactly this machine and its peer",
          sorted(d["deviceID"] for d in folder["devices"]) == sorted([ME, PEER]))
    check("staggered versioning keeps 30 days", folder["versioning"]["type"] == "staggered"
          and folder["versioning"]["params"]["maxAge"] == str(30 * 86400), folder["versioning"])
    check("a second pass changes nothing", m.desired(want, manifest, ME, me, home) == want)
    check("the input config is not modified", current["devices"][-1]["deviceID"] == STRANGER)

    boot = m.desired(base, {**manifest, "peers": [{"name": "mini", "tailscale_ip": "100.64.0.1", "device_id": ""},
                                                  {"name": "laptop", "tailscale_ip": "100.64.0.2", "device_id": ""}]},
                     base["devices"][0]["deviceID"], {"name": "mini", "tailscale_ip": "100.64.0.1", "device_id": ""}, home)
    check("bootstrap: locked down with no peers until device ids are listed",
          len(boot["devices"]) == 1 and boot["options"]["relaysEnabled"] is False)

    text = m.stignore_text(manifest["include"])
    lines = [l for l in text.splitlines() if l and not l.startswith("//")]
    check(".stignore is include-only: each private folder, then everything else ignored",
          lines == [f"!/{p}" for p in manifest["include"]] + ["*"], lines)
    check("no include reaches .git", not any(".git" in l for l in lines), lines)
    for bad in (".git", "profile/*", "/"):
        try:
            m.stignore_text([bad])
            check(f"include {bad!r} is refused", False, "accepted")
        except m.SyncError:
            pass
    check("the manifest lists only the mini and the laptop", sorted(p["name"] for p in json.loads(MANIFEST.read_text())["peers"])
          == ["michaels-macbook-pro", "mikes-mac-mini"])
    return fails


PLANTS = [
    ('    "relaysEnabled": False,\n', '    "relaysEnabled": True,\n', "relays left on"),
    ('    "stunKeepaliveStartS": 0,', '    "stunKeepaliveStartS": 180,', "STUN left on"),
    ('    cfg["options"]["listenAddresses"] = [f"tcp://{me[\'tailscale_ip\']}:{port}"]\n',
     '    cfg["options"]["listenAddresses"] = ["default"]\n', "listening on every interface"),
    ('    lines.append("*")\n', '', "the ignore file is not include-only"),
    ('    cfg["devices"] = devices\n', '    cfg["devices"] = devices + [d for d in cfg["devices"] if d["deviceID"] not in {x["deviceID"] for x in devices}]\n',
     "unknown devices kept"),
    ('    cfg["folders"] = [folder]\n', '    cfg["folders"] = [folder] + [f for f in cfg["folders"] if f["id"] != fid]\n', "other folders kept"),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--revert-test", action="store_true")
    args = parser.parse_args()
    if not args.revert_test:
        fails = fixtures(SCRIPT)
        for f in fails:
            print(f"FAIL {f}")
        print("check-private-sync: " + (f"{len(fails)} failure(s)" if fails else "OK"))
        return 1 if fails else 0
    text, ok = SCRIPT.read_text(encoding="utf-8"), True
    with tempfile.TemporaryDirectory() as raw:
        for old, new, label in PLANTS:
            if old not in text:
                print(f"revert-test: plant anchor not found for '{label}'", file=sys.stderr)
                return 1
            mutant = Path(raw) / "configure-private-sync.py"
            mutant.write_text(text.replace(old, new, 1), encoding="utf-8")
            caught = len(fixtures(mutant))
            print(f"revert-test {'ok' if caught else 'FAILED'}: '{label}' fails {caught} fixture(s)")
            ok = ok and caught > 0
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
