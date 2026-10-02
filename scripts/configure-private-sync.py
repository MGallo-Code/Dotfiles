#!/usr/bin/env python3
"""configure-private-sync.py - converge Syncthing for EA's private files (ADR-0009, INV-24).

    python3 scripts/configure-private-sync.py [--home DIR] [--check]

Off unless ~/.config/dotfiles/private-sync exists. Talks to the local Syncthing REST API (address
and key from its config.xml) and sets: a listen address on this machine's Tailscale IP only; no
global or local discovery, relays, NAT traversal, usage or crash reporting, or auto-upgrade; the
GUI on loopback; exactly the peers in private-sync.json; one folder, include-only (.stignore),
with staggered versioning; nothing else. A second run changes nothing. --check reports drift and
exits 1 without writing.

Bootstrap: a machine whose device ID is not in private-sync.json yet is found by its Tailscale IP;
it gets the lockdown and the folder with no peers, and its ID is printed to add to the file.

Python 3.9+, standard library only.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "private-sync.json"
GATE = Path(".config") / "dotfiles" / "private-sync"
STIGNORE_HEADER = "// Written by dotfiles (ADR-0009). Git carries EA; Syncthing carries only these. Edit private-sync.json, not this file."
LOCKDOWN = {
    "globalAnnounceEnabled": False,
    "localAnnounceEnabled": False,
    "relaysEnabled": False,
    "natEnabled": False,
    "stunKeepaliveStartS": 0,      # no STUN: never ask public servers for the external address
    "announceLANAddresses": False,
    "urAccepted": -1,
    "autoUpgradeIntervalH": 0,
    "crashReportingEnabled": False,
    "startBrowser": False,
}


class SyncError(RuntimeError):
    pass


def expand(path: str, home: Path) -> str:
    return str(home / path[2:]) if path.startswith("~/") else path


def stignore_text(include: list[str]) -> str:
    lines = [STIGNORE_HEADER]
    for path in include:
        clean = path.strip("/")
        if not clean or clean.startswith(".git") or "*" in clean:
            raise SyncError(f"include path {path!r} must name a plain folder, never .git or a glob")
        lines.append(f"!/{clean}")
    lines.append("*")
    return "\n".join(lines) + "\n"


def find_self(manifest: dict, my_id: str, local_ips: set[str]) -> dict | None:
    for peer in manifest["peers"]:
        if peer.get("device_id") == my_id:
            return peer
    for peer in manifest["peers"]:
        if peer.get("tailscale_ip") in local_ips:
            return peer
    return None


def desired(current: dict, manifest: dict, my_id: str, me: dict, home: Path) -> dict:
    """The config Syncthing should have. Pure: the same inputs always give the same output."""
    cfg = copy.deepcopy(current)
    port = int(manifest.get("port", 22000))
    cfg["options"].update(LOCKDOWN)
    cfg["options"]["listenAddresses"] = [f"tcp://{me['tailscale_ip']}:{port}"]
    host = str(cfg["gui"].get("address", "")).rsplit(":", 1)[0]
    if host not in ("127.0.0.1", "localhost", "[::1]"):
        cfg["gui"]["address"] = "127.0.0.1:8384"

    peers = [p for p in manifest["peers"] if p.get("device_id") and p["device_id"] != my_id]
    old = {d["deviceID"]: d for d in cfg["devices"]}
    template = cfg.get("defaults", {}).get("device", {})
    devices = [old.get(my_id, {**copy.deepcopy(template), "deviceID": my_id, "name": me["name"]})]
    for peer in peers:
        dev = copy.deepcopy(old.get(peer["device_id"], template))
        dev.update({"deviceID": peer["device_id"], "name": peer["name"],
                    "addresses": [f"tcp://{peer['tailscale_ip']}:{port}"],
                    "autoAcceptFolders": False, "introducer": False, "paused": False})
        devices.append(dev)
    devices.sort(key=lambda d: d["deviceID"])  # Syncthing stores devices sorted by ID; match it or every run rewrites
    cfg["devices"] = devices

    fid = manifest["folder_id"]
    folder = copy.deepcopy(next((f for f in cfg["folders"] if f["id"] == fid), cfg.get("defaults", {}).get("folder", {})))
    seconds = int(manifest.get("versioning_days", 30)) * 86400
    folder.update({
        "id": fid, "label": manifest.get("folder_label", fid), "path": expand(manifest["folder_path"], home),
        "type": "sendreceive", "paused": False, "fsWatcherEnabled": True,
        "devices": [{"deviceID": d["deviceID"], "introducedBy": "", "encryptionPassword": ""} for d in devices],
    })
    versioning = dict(folder.get("versioning") or {})
    versioning.update({"type": "staggered", "params": {"maxAge": str(seconds), "cleanInterval": "3600"},
                       "cleanupIntervalS": 3600})
    folder["versioning"] = versioning
    cfg["folders"] = [folder]
    return cfg


# ---------------------------------------------------------------- the live instance

def differences(a: object, b: object, path: str = "") -> list[str]:
    """Paths (never values: the config holds the API key) where two configs differ."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for key in sorted(set(a) | set(b)):
            out += differences(a.get(key), b.get(key), f"{path}/{key}") if key in a and key in b else [f"{path}/{key}"]
        return out
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        return [d for i, (x, y) in enumerate(zip(a, b)) for d in differences(x, y, f"{path}[{i}]")]
    return [] if a == b else [path or "/"]


def config_xml(home: Path) -> Path:
    for candidate in (home / "Library" / "Application Support" / "Syncthing" / "config.xml",
                      home / ".local" / "state" / "syncthing" / "config.xml",
                      home / ".config" / "syncthing" / "config.xml"):
        if candidate.is_file():
            return candidate
    raise SyncError("Syncthing has no config.xml yet (start it once: brew services start syncthing)")


def api_target(xml_path: Path) -> tuple[str, str]:
    gui = ET.parse(xml_path).getroot().find("gui")
    if gui is None:
        raise SyncError(f"no <gui> in {xml_path}")
    scheme = "https" if gui.get("tls") == "true" else "http"
    address, key = gui.findtext("address", ""), gui.findtext("apikey", "")
    if not address or not key:
        raise SyncError(f"no GUI address or API key in {xml_path}")
    return f"{scheme}://{address}", key


def call(base: str, key: str, method: str, path: str, body: object = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"X-API-Key": key, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read()
    return json.loads(raw) if raw.strip() else None


def local_ips() -> set[str]:
    try:
        out = subprocess.run(["ifconfig", "-a"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    return {tok.split("/")[0] for line in out.splitlines() for tok in line.split()[1:2] if line.strip().startswith("inet ")}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--config-xml", type=Path, help="Syncthing's config.xml (default: found under --home)")
    args = parser.parse_args(argv)
    home = args.home.expanduser()
    if not (home / GATE).exists():
        print("private sync: off on this machine (no ~/.config/dotfiles/private-sync)")
        return 0
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    folder = Path(expand(manifest["folder_path"], home))
    if not (folder / ".git").exists():
        raise SyncError(f"{folder} is not the EA checkout; nothing configured")
    deadline = time.time() + 30
    while True:  # a first `brew services start` writes config.xml a moment later
        try:
            base, key = api_target(args.config_xml or config_xml(home))
            break
        except (SyncError, ET.ParseError):
            if time.time() > deadline:
                raise
            time.sleep(1)
    while True:
        try:
            call(base, key, "GET", "/rest/system/ping")
            break
        except (urllib.error.URLError, OSError):
            if time.time() > deadline:
                raise SyncError(f"Syncthing is not answering at {base} (brew services start syncthing)")
            time.sleep(1)
    my_id = call(base, key, "GET", "/rest/system/status")["myID"]
    me = find_self(manifest, my_id, local_ips())
    if me is None:
        raise SyncError(f"this machine is not in private-sync.json (device {my_id}); add it to opt in")
    current = call(base, key, "GET", "/rest/config")
    want = desired(current, manifest, my_id, me, home)
    ignore = folder / ".stignore"
    text = stignore_text(manifest["include"])
    drift = []
    if want != current:
        drift.append("Syncthing config")
    if not ignore.is_file() or ignore.read_text(encoding="utf-8") != text:
        drift.append(".stignore")
    if args.check:
        print(f"private sync: {'drift in ' + ', '.join(drift) if drift else 'converged'}")
        for path in differences(current, want)[:20]:
            print(f"  {path}")
        return 1 if drift else 0
    if ".stignore" in drift:
        tmp = ignore.with_name(".stignore.tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, ignore)
    if "Syncthing config" in drift:
        call(base, key, "PUT", "/rest/config", want)
        if (call(base, key, "GET", "/rest/config/restart-required") or {}).get("requiresRestart"):
            call(base, key, "POST", "/rest/system/restart")
    peers = len(want["devices"]) - 1
    note = "" if me.get("device_id") == my_id else f"; add device_id {my_id} for {me['name']} to private-sync.json"
    print(f"private sync: {', '.join(drift) + ' updated' if drift else 'already converged'}; "
          f"{peers} peer(s) on Tailscale{note}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SyncError as exc:
        print(f"private sync: {exc}", file=sys.stderr)
        raise SystemExit(1)
