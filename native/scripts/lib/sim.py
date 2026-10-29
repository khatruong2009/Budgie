#!/usr/bin/env python3
"""The one simulator lookup rule for the scripts in native/scripts.

runtime_for(device_type) returns the identifier of the highest available iOS
runtime that offers the device type (default "iPhone 17 Pro"). The newest
installed runtime is not enough: a newer runtime may not carry the device
type (iOS 27.1 has no iPhone 17 Pro; creating one on it fails with
`Incompatible device`).

Shell: lib/sim.sh (`sim_runtime`). CLI: sim.py runtime [device type name]
"""
import json
import subprocess
import sys

DEFAULT_DEVICE_TYPE = "iPhone 17 Pro"


def _simctl_json(*args):
    out = subprocess.run(["xcrun", "simctl", "list", *args, "-j"], check=True, text=True, capture_output=True).stdout
    return json.loads(out)


def runtime_for(device_type=DEFAULT_DEVICE_TYPE):
    type_ids = {t["identifier"] for t in _simctl_json("devicetypes")["devicetypes"] if t["name"] == device_type}
    if not type_ids:
        raise RuntimeError(f"no simulator device type named {device_type!r}")
    candidates = [
        r for r in _simctl_json("runtimes")["runtimes"]
        if r["platform"] == "iOS" and r["isAvailable"]
        and any(t["identifier"] in type_ids for t in r.get("supportedDeviceTypes", []))
    ]
    if not candidates:
        raise RuntimeError(f"no available iOS runtime offers {device_type!r}")
    return max(candidates, key=lambda r: tuple(int(p) for p in r["version"].split(".")))["identifier"]


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] != "runtime":
        sys.exit(__doc__)
    try:
        print(runtime_for(*sys.argv[2:3]))
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"sim.py: {error}", file=sys.stderr)
        sys.exit(1)
