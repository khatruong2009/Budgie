#!/usr/bin/env python3
"""Upgrade rehearsal on a dedicated iOS simulator (UPGRADE_TEST_PLAN.md).

Installs the Flutter build and the Swift build over each other (same bundle
ID, never uninstalling), seeds synthetic data produced by the real Flutter
code (native/Fixtures), and checks that nothing is lost in either direction.

Only the simulator named SIM_NAME is touched; it is created if missing.
No physical device, no real data.

Usage: native/scripts/upgrade_rehearsal.py [--skip-build] [scenario ...]
Writes native/docs/rehearsal/<timestamp>/ (report.json, screenshots, pulled state).
       native/scripts/upgrade_rehearsal.py --compare-pulled DIR [DIR ...]
Checks app containers pulled from a physical device (REAL_DEVICE_CHECKLISTS.md).
"""
import argparse
import datetime
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=Path(__file__).parent, text=True).strip())
NATIVE = REPO / "native"
FIXTURES = NATIVE / "Fixtures"
BUNDLE = "com.khatruong.budgetbuddy"
GROUP = "group.com.khatruong.budgetbuddy"
SIM_NAME = "Budgie-Rehearsal"
SCRATCH = Path(os.environ.get("BUDGIE_REHEARSAL_SCRATCH", tempfile.gettempdir())) / "budgie-rehearsal"
# The onboarding flag of a user who finished the tour. Without it both
# builds open on the tour, not the data the screenshots are for.
ONBOARDED = {"flutter.onboarding_completed": {"type": "bool", "value": True}}


def run(cmd, check=True, env=None, **kw):
    merged = dict(os.environ, **(env or {}))
    result = subprocess.run(cmd, text=True, capture_output=True, env=merged, **kw)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, cmd))} failed:\n{result.stdout[-3000:]}\n{result.stderr[-3000:]}")
    return result


# ---------------------------------------------------------------- simulator

class Simulator:
    def __init__(self):
        devices = json.loads(run(["xcrun", "simctl", "list", "devices", "-j"]).stdout)["devices"]
        self.udid = None
        for runtime, items in devices.items():
            for d in items:
                if d["name"] == SIM_NAME and d.get("isAvailable", True):
                    self.udid = d["udid"]
        if not self.udid:
            runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "-j"]).stdout)["runtimes"]
            ios = [r for r in runtimes if r["platform"] == "iOS" and r["isAvailable"]]
            runtime = sorted(ios, key=lambda r: r["version"])[-1]["identifier"]
            self.udid = run(["xcrun", "simctl", "create", SIM_NAME, "iPhone 17 Pro", runtime]).stdout.strip()

    def state(self):
        devices = json.loads(run(["xcrun", "simctl", "list", "devices", "-j"]).stdout)["devices"]
        for items in devices.values():
            for d in items:
                if d["udid"] == self.udid:
                    return d["state"]

    def boot(self):
        if self.state() != "Booted":
            run(["xcrun", "simctl", "boot", self.udid])
        run(["xcrun", "simctl", "bootstatus", self.udid, "-b"])

    def shutdown(self):
        if self.state() != "Shutdown":
            run(["xcrun", "simctl", "shutdown", self.udid])

    def erase(self):
        """Only ever called on the dedicated rehearsal simulator."""
        self.shutdown()
        run(["xcrun", "simctl", "erase", self.udid])

    def install(self, app):
        run(["xcrun", "simctl", "install", self.udid, str(app)])

    def enroll_face_id(self):
        # Simulated biometrics so App Lock screens can be passed.
        run(["xcrun", "simctl", "spawn", self.udid, "notifyutil", "-s", "com.apple.BiometricKit.enrollmentChanged", "1"], check=False)
        run(["xcrun", "simctl", "spawn", self.udid, "notifyutil", "-p", "com.apple.BiometricKit.enrollmentChanged"], check=False)

    def face_id_match(self):
        run(["xcrun", "simctl", "spawn", self.udid, "notifyutil", "-p", "com.apple.BiometricKit_Sim.pearl.match"], check=False)

    def launch(self, env=None, wait=6):
        child = {f"SIMCTL_CHILD_{k}": v for k, v in (env or {}).items()}
        run(["xcrun", "simctl", "terminate", self.udid, BUNDLE], check=False)
        # A summary left by an earlier Swift run must not be attributed to
        # this launch.
        try:
            (self.data_container() / "Library" / "Caches" / "budgie-rehearsal.json").unlink()
        except (FileNotFoundError, RuntimeError):
            pass
        run(["xcrun", "simctl", "launch", self.udid, BUNDLE], env=child)
        time.sleep(wait)
        self.face_id_match()
        time.sleep(3)

    def terminate(self):
        run(["xcrun", "simctl", "terminate", self.udid, BUNDLE], check=False)
        time.sleep(1)

    def data_container(self):
        return Path(run(["xcrun", "simctl", "get_app_container", self.udid, BUNDLE, "data"]).stdout.strip())

    def group_container(self):
        out = run(["xcrun", "simctl", "get_app_container", self.udid, BUNDLE, "groups"]).stdout
        for line in out.splitlines():
            if line.startswith(GROUP):
                return Path(line.split(None, 1)[1].strip())
        return None

    def screenshot(self, path):
        run(["xcrun", "simctl", "io", self.udid, "screenshot", str(path)], check=False)

    def open_url(self, url):
        run(["xcrun", "simctl", "openurl", self.udid, url], check=False)


# ---------------------------------------------------------------- builds

def build_flutter():
    """The Flutter app at the `flutter-final` tag (budget_app/ was removed
    from the tree after 4.0.0 shipped), built from an exported copy that gets
    a stub .env."""
    work = SCRATCH / "flutter"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    subprocess.run(f"git -C '{REPO}' archive --format=tar flutter-final budget_app | tar -x -C '{work}'", shell=True, check=True)
    (work / "budget_app" / ".env").write_text("OPENAI_API_KEY=rehearsal-dummy-key\n")
    app_dir = work / "budget_app"
    # `flutter build ios --simulator` also targets x86_64, which this Flutter
    # engine no longer ships for the simulator; build arm64 only.
    run(["flutter", "build", "ios", "--simulator", "--debug", "--config-only"], cwd=app_dir)
    derived = SCRATCH / "flutter-derived"
    run(["xcodebuild", "build", "-workspace", "ios/Runner.xcworkspace", "-scheme", "Runner", "-configuration", "Debug",
         "-sdk", "iphonesimulator", "-derivedDataPath", str(derived), "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES"], cwd=app_dir)
    return derived / "Build" / "Products" / "Debug-iphonesimulator" / "Runner.app"


def build_swift():
    derived = SCRATCH / "swift-derived"
    run(["xcodegen", "generate"], cwd=NATIVE)
    run(["xcodebuild", "build", "-project", "Budgie.xcodeproj", "-scheme", "Budgie", "-configuration", "Debug",
         "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(derived),
         "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual"], cwd=NATIVE)
    return derived / "Build" / "Products" / "Debug-iphonesimulator" / "Budgie.app"


# ---------------------------------------------------------------- state

def prefs_path(sim):
    return sim.data_container() / "Library" / "Preferences" / f"{BUNDLE}.plist"


def inject_prefs(sim, typed):
    """Writes Flutter-plugin-typed values into the app's defaults plist while
    the simulator is shut down (simctl spawn defaults cannot reach it)."""
    path = prefs_path(sim)
    sim.shutdown()
    domain = {}
    if path.exists():
        with open(path, "rb") as f:
            domain = plistlib.load(f)
    for key, entry in typed.items():
        value = entry["value"]
        if entry["type"] == "double":
            value = float(value)
        domain[key] = value
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        plistlib.dump(domain, f, fmt=plistlib.FMT_BINARY)
    sim.boot()


def inject_store(sim, source_dir):
    store = sim.data_container() / "Library" / "Application Support" / "financial_store"
    shutil.rmtree(store, ignore_errors=True)
    store.mkdir(parents=True)
    for item in Path(source_dir).iterdir():
        if item.is_file():
            shutil.copy2(item, store / item.name)


def read_prefs(sim):
    path = prefs_path(sim)
    if not path.exists():
        return {}
    with open(path, "rb") as f:
        return plistlib.load(f)


def pull(sim, dest):
    dest.mkdir(parents=True, exist_ok=True)
    container = sim.data_container()
    support = container / "Library" / "Application Support"
    store = support / "financial_store"
    if store.exists():
        shutil.copytree(store, dest / "financial_store", dirs_exist_ok=True)
    if (support / "pre-native-migration").exists():
        shutil.copytree(support / "pre-native-migration", dest / "pre-native-migration", dirs_exist_ok=True)
    prefs = read_prefs(sim)
    with open(dest / "preferences.plist", "wb") as f:
        plistlib.dump(prefs, f)
    group = sim.group_container()
    if group:
        plist = group / "Library" / "Preferences" / f"{GROUP}.plist"
        if plist.exists():
            shutil.copy2(plist, dest / "app-group.plist")
    summary = container / "Library" / "Caches" / "budgie-rehearsal.json"
    if summary.exists():
        shutil.copy2(summary, dest / "swift-summary.json")
    return {
        "sceneDelegateClasses": scene_delegate_classes(container),
        "files": sorted(p.name for p in (dest / "financial_store").iterdir()) if (dest / "financial_store").exists() else [],
        "preNativeSnapshots": sorted(p.name for p in (dest / "pre-native-migration").iterdir()) if (dest / "pre-native-migration").exists() else [],
        "flutterPrefKeys": sorted(k for k in prefs if k.startswith("flutter.")),
    }


def scene_delegate_classes(container):
    """Delegate class names iOS persisted for the app's scene sessions. They
    must exist in both binaries (Runner.SceneDelegate), or the other app
    restores a session it cannot instantiate and shows a black screen."""
    path = container / "Library" / "Saved Application State" / f"{BUNDLE}.savedState" / "KnownSceneSessions" / "data.data"
    found = set()

    def walk(value):
        if isinstance(value, dict):
            for v in value.values():
                walk(v)
        elif isinstance(value, list):
            for v in value:
                walk(v)
        elif isinstance(value, bytes):
            try:
                walk(plistlib.loads(value))
            except Exception:
                pass
        elif isinstance(value, str) and (value.endswith("SceneDelegate") or value.endswith("Configuration")):
            # A configuration resolved from Info.plist is stored by name
            # only ("Default Configuration"); an explicit one by class.
            found.add(value)

    if path.exists():
        with open(path, "rb") as f:
            walk(plistlib.load(f))
    return sorted(found)


def typed_prefs(prefs):
    out = {}
    for key, value in prefs.items():
        if not key.startswith("flutter."):
            continue
        if isinstance(value, bool):
            out[key] = {"type": "bool", "value": value}
        elif isinstance(value, int):
            out[key] = {"type": "int", "value": value}
        elif isinstance(value, float):
            out[key] = {"type": "double", "value": value}
        elif isinstance(value, str):
            out[key] = {"type": "string", "value": value}
        elif isinstance(value, list):
            out[key] = {"type": "stringList", "value": value}
    return out


def dart_view(cases):
    """Runs the real Flutter models over pulled states (verify mode) and
    returns {case: {problems, summary}}."""
    root = SCRATCH / "dart-view"
    shutil.rmtree(root, ignore_errors=True)
    for name, pulled in cases.items():
        target = root / name
        target.mkdir(parents=True)
        shutil.copytree(pulled / "financial_store", target / "financial_store")
        with open(pulled / "preferences.plist", "rb") as f:
            prefs = plistlib.load(f)
        (target / "prefs.json").write_text(json.dumps(typed_prefs(prefs)))
    result = run([str(NATIVE / "ParityHarness" / "run.sh"), "verify"], check=False,
                 env={"SWIFT_OUT": str(root), "PARITY_WORK_DIR": str(SCRATCH / "parity")})
    report_path = root / "dart-verification.json"
    if not report_path.exists():
        raise RuntimeError("Dart verification produced no report:\n" + result.stdout[-3000:] + result.stderr[-3000:])
    return json.loads(report_path.read_text())["cases"]


# ---------------------------------------------------------------- comparison

def compare(swift, dart):
    """Numbers the user sees: per-month totals and counts, net worth per
    month, recurring cursors, settings. Exact equality (same doubles)."""
    issues = []
    ds = dart["summary"]
    if swift["transactionCount"] != ds["transactionCount"]:
        issues.append(f"transactionCount swift {swift['transactionCount']} dart {ds['transactionCount']}")
    for key, month in ds["monthly"].items():
        s = swift["monthly"].get(key)
        if not s:
            issues.append(f"month {key} missing in Swift")
            continue
        for field, dfield in [("totalIncome", "totalIncome"), ("totalExpenses", "totalExpenses")]:
            if s[field] != month[dfield]:
                issues.append(f"{key} {field} swift {s[field]} dart {month[dfield]}")
        if s["count"] != len(month["transactionIds"]):
            issues.append(f"{key} count swift {s['count']} dart {len(month['transactionIds'])}")
    for key in swift["monthly"]:
        if key not in ds["monthly"]:
            issues.append(f"month {key} only in Swift")
    for key, nw in ds["netWorth"].items():
        s = swift["netWorth"].get(key)
        if not s or s["assets"] != nw["assets"] or s["liabilities"] != nw["liabilities"]:
            issues.append(f"net worth {key} swift {s} dart {nw['assets']}/{nw['liabilities']}")
    dr = [(r["id"], r["nextOccurrence"], r["isActive"]) for r in ds["recurring"]]
    sr = [(r["id"], r["nextOccurrence"], r["isActive"]) for r in swift["recurring"]]
    if dr != sr:
        issues.append(f"recurring swift {sr} dart {dr}")
    for field in ["baseCurrencyCode", "localeOverride", "appLockEnabled", "autoLockTimeoutSeconds", "hideBalances"]:
        if swift["appSettings"].get(field) != ds["appSettings"].get(field):
            issues.append(f"setting {field} swift {swift['appSettings'].get(field)} dart {ds['appSettings'].get(field)}")
    return issues


# ---------------------------------------------------------------- scenarios

class Rehearsal:
    def __init__(self, out, flutter_app, swift_app):
        self.out = out
        self.flutter_app = flutter_app
        self.swift_app = swift_app
        self.sim = Simulator()
        self.results = {}

    def fresh(self):
        self.sim.erase()
        self.sim.boot()
        self.sim.enroll_face_id()

    def shot(self, scenario, name):
        self.sim.screenshot(self.out / scenario / f"{name}.png")

    def record(self, scenario, **fields):
        self.results.setdefault(scenario, {}).update(fields)

    def swift_launch(self, scenario, label, extra=None, wait=8):
        env = {"BUDGIE_REHEARSAL_SUMMARY": "1", **(extra or {})}
        self.sim.launch(env, wait=wait)
        self.shot(scenario, label)

    # S1 + S2: upgrade from a typical Flutter store, then back to Flutter.
    def s1_typical_roundtrip(self):
        name = "s1_typical_roundtrip"
        (self.out / name).mkdir(parents=True, exist_ok=True)
        self.fresh()
        self.sim.install(self.flutter_app)
        inject_store(self.sim, FIXTURES / "store" / "typical" / "input")
        inject_prefs(self.sim, {"flutter.themeMode": {"type": "string", "value": "dark"},
                                "flutter.onboarding_completed": {"type": "bool", "value": True}})
        self.sim.launch(wait=20)
        self.shot(name, "1-flutter-before")
        self.sim.terminate()
        before = pull(self.sim, self.out / name / "1-flutter")

        self.sim.install(self.swift_app)  # over the Flutter app, no uninstall
        self.swift_launch(name, "2-swift-after-upgrade")
        self.sim.terminate()
        after = pull(self.sim, self.out / name / "2-swift")
        self.record(name, flutterState=before, swiftState=after)

        # Edit in Swift, then reinstall Flutter over it.
        self.swift_launch(name, "3-swift-edited", {"BUDGIE_REHEARSAL_EDIT": "1"}, wait=10)
        self.sim.terminate()
        edited = pull(self.sim, self.out / name / "3-swift-edited")
        self.sim.install(self.flutter_app)
        self.sim.launch(wait=25)
        self.shot(name, "4-flutter-after-downgrade")
        self.sim.terminate()
        back = pull(self.sim, self.out / name / "4-flutter-back")
        self.record(name, swiftEditedState=edited, flutterBackState=back)
        return {"1-flutter": self.out / name / "1-flutter", "2-swift": self.out / name / "2-swift",
                "3-swift-edited": self.out / name / "3-swift-edited", "4-flutter-back": self.out / name / "4-flutter-back"}

    # S3: legacy-only SharedPreferences, never opened by the Flutter build.
    def s3_legacy_only(self):
        name = "s3_legacy_only"
        (self.out / name).mkdir(parents=True, exist_ok=True)
        self.fresh()
        self.sim.install(self.flutter_app)  # creates the container; not launched
        prefs = json.loads((FIXTURES / "legacy" / "bare_only" / "prefs.json").read_text())
        envelope = json.loads((FIXTURES / "legacy" / "v1_only" / "prefs.json").read_text())
        prefs.update({k: v for k, v in envelope.items() if "financial_store_v1" in k})
        inject_prefs(self.sim, prefs)
        before = {"flutterPrefKeys": sorted(prefs)}
        self.sim.install(self.swift_app)
        self.swift_launch(name, "1-swift-first-launch")
        self.sim.terminate()
        after = pull(self.sim, self.out / name / "1-swift")
        backup_prefs = {}
        snapshots = sorted((self.out / name / "1-swift" / "pre-native-migration").glob("*/preferences.plist"))
        if snapshots:
            with open(snapshots[0], "rb") as f:
                backup_prefs = plistlib.load(f)
        self.record(name, injectedKeys=before["flutterPrefKeys"], swiftState=after,
                    legacyKeysInBackup=sorted(k for k in backup_prefs if k.startswith("flutter.")))
        # Then the Flutter build over it.
        self.sim.install(self.flutter_app)
        self.sim.launch(wait=25)
        self.shot(name, "2-flutter-after")
        self.sim.terminate()
        back = pull(self.sim, self.out / name / "2-flutter-back")
        self.record(name, flutterBackState=back)
        return {"s3-swift": self.out / name / "1-swift", "s3-flutter-back": self.out / name / "2-flutter-back"}

    # S4: locked / prewarmed launch (simulated in the Debug build).
    def s4_locked_launch(self):
        name = "s4_locked_launch"
        (self.out / name).mkdir(parents=True, exist_ok=True)
        self.fresh()
        self.sim.install(self.flutter_app)
        inject_store(self.sim, FIXTURES / "store" / "typical" / "input")
        # A user who finished the tour, so "2-after-unlock" shows the data.
        inject_prefs(self.sim, ONBOARDED)
        self.sim.install(self.swift_app)
        # Reinstalling moves the data container; resolve paths afterwards.
        support = self.sim.data_container() / "Library" / "Application Support"
        store = support / "financial_store"
        stamps = {p.name: (p.stat().st_mtime_ns, p.stat().st_size) for p in store.iterdir()}
        lock_seconds = 15
        env = {"BUDGIE_REHEARSAL_SUMMARY": "1", "BUDGIE_SIMULATE_LOCKED_SECONDS": str(lock_seconds)}
        child = {f"SIMCTL_CHILD_{k}": v for k, v in env.items()}
        summary = self.sim.data_container() / "Library" / "Caches" / "budgie-rehearsal.json"
        started = time.time()
        run(["xcrun", "simctl", "launch", self.sim.udid, BUNDLE], env=child)
        # Poll the whole window (screenshots can return late, so none are
        # taken until the first write is seen).
        first_write = {}
        shot = None
        while time.time() - started < lock_seconds + 10:
            elapsed = round(time.time() - started, 1)
            if shot is None and elapsed >= 5:
                # Non-blocking, so a slow screenshot cannot delay the checks.
                shot = subprocess.Popen(["xcrun", "simctl", "io", self.sim.udid, "screenshot",
                                         str(self.out / name / "1-while-locked.png")],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            state = {
                "store": {p.name: (p.stat().st_mtime_ns, p.stat().st_size) for p in store.iterdir()} != stamps,
                "preNative": (support / "pre-native-migration").exists(),
                "summary": summary.exists(),
            }
            for key, happened in state.items():
                if happened and key not in first_write:
                    first_write[key] = elapsed
            if len(first_write) == 3:
                break
            time.sleep(0.5)
        if shot:
            shot.wait()
        during = {
            "lockSeconds": lock_seconds,
            "firstWriteSecondsAfterLaunch": first_write,
            "nothingWrittenWhileLocked": all(t >= lock_seconds for t in first_write.values()),
        }
        self.shot(name, "2-after-unlock")
        self.sim.terminate()
        after = pull(self.sim, self.out / name / "after")
        self.record(name, whileLocked=during, afterUnlock=after)
        return {"s4-after": self.out / name / "after"}

    # S5: damaged primary (restored from backup) and both damaged (blocked).
    def s5_corruption(self):
        name = "s5_corruption"
        (self.out / name).mkdir(parents=True, exist_ok=True)
        self.fresh()
        self.sim.install(self.flutter_app)
        inject_store(self.sim, FIXTURES / "store" / "primary_truncated" / "input")
        # A user who finished the tour, so the shot shows the restored data.
        inject_prefs(self.sim, ONBOARDED)
        self.sim.install(self.swift_app)
        self.swift_launch(name, "1-truncated-primary")
        self.sim.terminate()
        restored = pull(self.sim, self.out / name / "1-restored")
        summary = json.loads((self.out / name / "1-restored" / "swift-summary.json").read_text())
        self.record(name, truncatedPrimary=restored, restoredTransactionCount=summary["transactionCount"],
                    loadReport=summary["loadReport"])

        self.fresh()
        self.sim.install(self.flutter_app)
        inject_store(self.sim, FIXTURES / "store" / "both_corrupt" / "input")
        # Real installs commonly retain these settings. They must not be
        # mistaken for recovery data and produce an empty financial store.
        inject_prefs(self.sim, {**ONBOARDED, "flutter.base_currency_code": {"type": "string", "value": "GBP"}})
        self.sim.install(self.swift_app)
        self.swift_launch(name, "2-both-corrupt")
        self.sim.terminate()
        blocked = pull(self.sim, self.out / name / "2-blocked")
        self.record(name, bothCorrupt=blocked,
                    blockedSummaryWritten=(self.out / name / "2-blocked" / "swift-summary.json").exists())
        files = self.out / name / "2-blocked" / "financial_store"
        assert not (files / "financial_store_v2.json").exists(), "Damaged files opened an empty budget"
        assert not (self.out / name / "2-blocked" / "swift-summary.json").exists(), "Damaged files reached ready state"
        return {"s5-restored": self.out / name / "1-restored"}

    def s6_malformed_legacy(self):
        """Malformed preference data must block before any migration write."""
        name = "s6_malformed_legacy"
        for label, key in [("ledger", "flutter.transactions"), ("envelope", "flutter.financial_store_v1")]:
            self.fresh()
            self.sim.install(self.flutter_app)
            injected = {
                **ONBOARDED,
                key: {"type": "string", "value": "truncated JSON"},
                "flutter.base_currency_code": {"type": "string", "value": "GBP"},
            }
            inject_prefs(self.sim, injected)
            self.sim.install(self.swift_app)
            (self.out / name / label).mkdir(parents=True, exist_ok=True)
            self.swift_launch(name, label)
            self.sim.terminate()
            dest = self.out / name / label
            state = pull(self.sim, dest)
            with open(dest / "preferences.plist", "rb") as file:
                prefs = plistlib.load(file)
            assert prefs.get(key) == injected[key]["value"], "Malformed legacy data was removed"
            assert not (dest / "financial_store/financial_store_v2.json").exists(), "Partial migration was committed"
            assert not (dest / "swift-summary.json").exists(), "Malformed legacy data reached ready state"
            assert state["preNativeSnapshots"], "Original legacy data received no safety copy"
            self.record(name, **{label: state})
        return {}


def compare_pulled(dirs):
    """Real-device mode (REAL_DEVICE_CHECKLISTS.md): each dir is a
    `devicectl device copy from ... --source Library` destination. Runs the
    Flutter models over its store and preferences, and compares them with
    the Swift rehearsal summary when the Swift app wrote one."""
    staged = {}
    for raw in dirs:
        library = Path(raw) / "Library"
        store = library / "Application Support" / "financial_store"
        if not store.exists():
            raise SystemExit(f"{raw}: no Library/Application Support/financial_store")
        case = SCRATCH / "device-pulls" / Path(raw).name
        shutil.rmtree(case, ignore_errors=True)
        case.mkdir(parents=True)
        shutil.copytree(store, case / "financial_store")
        prefs = library / "Preferences" / f"{BUNDLE}.plist"
        if prefs.exists():
            shutil.copy2(prefs, case / "preferences.plist")
        else:
            with open(case / "preferences.plist", "wb") as f:
                plistlib.dump({}, f)
        summary = library / "Caches" / "budgie-rehearsal.json"
        if summary.exists():
            shutil.copy2(summary, case / "swift-summary.json")
        staged[Path(raw).name] = case
    dart = dart_view(staged)
    report = {}
    for name, case in staged.items():
        entry = {"dartProblems": dart[name]["problems"]}
        if (case / "swift-summary.json").exists():
            entry["swiftVsDart"] = compare(json.loads((case / "swift-summary.json").read_text()), dart[name])
        report[name] = entry
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    return 1 if any(e["dartProblems"] or e.get("swiftVsDart") for e in report.values()) else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--compare-pulled", nargs="+", metavar="DIR",
                        help="check containers pulled from a device (REAL_DEVICE_CHECKLISTS.md); no simulator is used")
    parser.add_argument("scenarios", nargs="*", default=["s1", "s3", "s4", "s5", "s6"])
    args = parser.parse_args()
    SCRATCH.mkdir(parents=True, exist_ok=True)
    if args.compare_pulled:
        return compare_pulled(args.compare_pulled)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = NATIVE / "docs" / "rehearsal" / stamp
    out.mkdir(parents=True)

    flutter_app = SCRATCH / "flutter-derived" / "Build" / "Products" / "Debug-iphonesimulator" / "Runner.app"
    swift_app = SCRATCH / "swift-derived" / "Build" / "Products" / "Debug-iphonesimulator" / "Budgie.app"
    if not args.skip_build or not flutter_app.exists():
        flutter_app = build_flutter()
    if not args.skip_build or not swift_app.exists():
        swift_app = build_swift()

    rehearsal = Rehearsal(out, flutter_app, swift_app)
    pulled = {}
    runners = {"s1": rehearsal.s1_typical_roundtrip, "s3": rehearsal.s3_legacy_only,
               "s4": rehearsal.s4_locked_launch, "s5": rehearsal.s5_corruption,
               "s6": rehearsal.s6_malformed_legacy}
    for key in args.scenarios:
        try:
            pulled.update(runners[key]())
        except Exception as error:  # record and continue; the report says so
            rehearsal.record(key, error=str(error)[-4000:])

    readable_pulls = {k: v for k, v in pulled.items() if (v / "financial_store").exists()}
    dart = dart_view(readable_pulls) if readable_pulls else {}
    comparisons = {}
    for case, pulled_dir in pulled.items():
        swift_summary = pulled_dir / "swift-summary.json"
        if swift_summary.exists() and case in dart:
            comparisons[f"{case}: Swift vs Flutter models on the same files"] = compare(json.loads(swift_summary.read_text()), dart[case])
    # What the user saw in Flutter before the upgrade vs what Swift shows after.
    pairs = [("2-swift", "1-flutter"), ("3-swift-edited", "4-flutter-back"), ("s3-swift", "s3-flutter-back")]
    for swift_case, flutter_case in pairs:
        swift_summary = pulled.get(swift_case, Path("/nonexistent")) / "swift-summary.json"
        if swift_summary.exists() and flutter_case in dart:
            comparisons[f"{swift_case} (Swift) vs {flutter_case} (Flutter)"] = compare(json.loads(swift_summary.read_text()), dart[flutter_case])
    report = {
        "simulator": {"name": SIM_NAME, "udid": rehearsal.sim.udid},
        "commit": run(["git", "rev-parse", "HEAD"], cwd=REPO).stdout.strip(),
        "scenarios": rehearsal.results,
        "dartProblems": {k: v["problems"] for k, v in dart.items()},
        "swiftVsDart": comparisons,
    }
    (out / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True, default=str))
    rehearsal.sim.shutdown()
    print(out / "report.json")
    return 1 if any("error" in result for result in rehearsal.results.values()) or any(
        result for result in comparisons.values()
    ) or any(result["problems"] for result in dart.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
