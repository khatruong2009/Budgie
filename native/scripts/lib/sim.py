#!/usr/bin/env python3
"""The one simulator lookup rule for the scripts in native/scripts.

runtime_for(device_type) returns the identifier of the highest available iOS
runtime that offers the device type (default "iPhone 17 Pro"). The newest
installed runtime is not enough: a newer runtime may not carry the device
type (iOS 27.1 has no iPhone 17 Pro; creating one on it fails with
`Incompatible device`).

find_or_create(name) returns (udid, was_booted) of the named simulator,
creating it if missing. copy_store(container, source_dir) puts a store
directory into an app data container.

Shell: lib/sim.sh (`sim_runtime`). CLI: sim.py runtime [device type name]
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_DEVICE_TYPE = "iPhone 17 Pro"
BUNDLE = "com.khatruong.budgetbuddy"


def sh(*cmd, check=True):
    return subprocess.run(cmd, check=check, text=True, capture_output=True).stdout.strip()


def simctl_json(*args):
    return json.loads(sh("xcrun", "simctl", "list", *args, "-j"))


def runtime_for(device_type=DEFAULT_DEVICE_TYPE):
    type_ids = {t["identifier"] for t in simctl_json("devicetypes")["devicetypes"] if t["name"] == device_type}
    if not type_ids:
        raise RuntimeError(f"no simulator device type named {device_type!r}")
    candidates = [
        r for r in simctl_json("runtimes")["runtimes"]
        if r["platform"] == "iOS" and r["isAvailable"]
        and any(t["identifier"] in type_ids for t in r.get("supportedDeviceTypes", []))
    ]
    if not candidates:
        raise RuntimeError(f"no available iOS runtime offers {device_type!r}")
    return max(candidates, key=lambda r: tuple(int(p) for p in r["version"].split(".")))["identifier"]


def find_or_create(name):
    devices = simctl_json("devices")["devices"]
    found = next((d for items in devices.values() for d in items if d["name"] == name and d.get("isAvailable", True)), None)
    if found:
        return found["udid"], found["state"] == "Booted"
    return sh("xcrun", "simctl", "create", name, DEFAULT_DEVICE_TYPE, runtime_for()), False


def reset_store(container):
    """Empties the app's financial_store directory in a data container (the
    path `simctl get_app_container <udid> <bundle> data` prints) and returns
    it."""
    store = Path(container) / "Library" / "Application Support" / "financial_store"
    shutil.rmtree(store, ignore_errors=True)
    store.mkdir(parents=True)
    return store


def copy_store(container, source_dir):
    """Replaces the app's financial_store with the files of source_dir."""
    store = reset_store(container)
    for item in Path(source_dir).iterdir():
        if item.is_file():
            shutil.copy2(item, store / item.name)


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] != "runtime":
        sys.exit(__doc__)
    try:
        print(runtime_for(*sys.argv[2:3]))
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"sim.py: {error}", file=sys.stderr)
        sys.exit(1)
