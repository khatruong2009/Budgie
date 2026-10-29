#!/usr/bin/env python3
"""Installs an app build on a named simulator (created if missing, never any
other simulator), optionally seeds a fixture store, and launches it.

A simulator this script had to boot is shut down again before it exits,
whether it succeeded or not (the app and its seeded store stay installed).

Usage: sim_seed.py <simulator-name> <path/to/Budgie.app> [fixture-input-dir]
Example: sim_seed.py Budgie-UI-A build/Budgie.app native/Fixtures/store/typical/input
Prints the simulator UDID.
"""
import json, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from sim import copy_store, runtime_for

name, app = sys.argv[1], sys.argv[2]
fixture = Path(sys.argv[3]) if len(sys.argv) > 3 else None
BUNDLE = "com.khatruong.budgetbuddy"

def sh(*cmd):
    return subprocess.run(cmd, check=True, text=True, capture_output=True).stdout.strip()

devices = json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))["devices"]
found = next((d for items in devices.values() for d in items if d["name"] == name and d.get("isAvailable", True)), None)
if found:
    udid, was_booted = found["udid"], found["state"] == "Booted"
else:
    udid, was_booted = sh("xcrun", "simctl", "create", name, "iPhone 17 Pro", runtime_for("iPhone 17 Pro")), False
try:
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
    sh("xcrun", "simctl", "bootstatus", udid, "-b")
    sh("xcrun", "simctl", "install", udid, app)
    if fixture:
        subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE], capture_output=True)
        copy_store(sh("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"), fixture)
    sh("xcrun", "simctl", "launch", udid, BUNDLE)
    time.sleep(4)
    print(udid)
finally:
    if not was_booted:
        subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
