#!/usr/bin/env python3
"""Generates a deterministic, now-relative 10,000-row Budgie store for the
performance tests (docs/PERFORMANCE.md) and installs it on a simulator.

Why not Fixtures/store/large_10k: its rows are all income, dated 2020-2027
(some in the future), App Lock is on and the recurring templates are stale,
so it is wrong for UI timing. This store:
  - 10,000 transactions over 60 months ending in the current month, none
    after today, about 70% expense; the current month has 500 rows (350 of
    them Groceries), each of the three months before it 250;
  - USD, App Lock off, no recurring templates (a launch generates nothing
    and writes nothing), 5 budget limits;
  - the base fixture's categories, tags, rules, goals and net worth
    entries, plus a net worth account "Perf History" with 500 weekly
    snapshots (the account history timeline builds every row eagerly).
The same bytes are written as the primary and the backup file (an intact
pair), with the header checksum computed as StoreFile.checksum does.

Usage:
  perf_seed.py <simulator-udid>            install on that simulator
  perf_seed.py --generate-only <dir>       write the two files into <dir>
  perf_seed.py --rows N ...                a smaller store of N rows (default
                                           10000) for the "is it the 10k?"
                                           comparison; 12 snapshots, not 500
The app must already be installed on the simulator. It is terminated first.
Nothing here reads or writes any other simulator or any real data.
"""
import datetime, json, random, subprocess, sys, uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from sim import reset_store

BUNDLE = "com.khatruong.budgetbuddy"
ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / "Fixtures/store/large_10k/input/financial_store_v2.json"
ROWS = 10_000
SNAPSHOTS = 500
MONTHS = 60
REVISION = 200

EXPENSE = [  # (category, weight)
    ("Groceries", 22), ("Eating Out", 18), ("Transportation", 12), ("Housing", 4), ("Entertainment", 9),
    ("Health", 6), ("Clothing", 6), ("General", 10), ("Travel", 3), ("Pets", 4), ("Family", 3), ("Gift", 2),
    ("Loan Payment", 1),
]
INCOME = [("Salary", 6), ("Investment", 2), ("Gift", 1), ("Other", 3)]
MERCHANTS = [
    "Corner Market", "Green Grocer", "Bus pass", "Metro top up", "Pharmacy", "Streaming", "Book store", "Hardware",
    "Gas station", "Bakery", "Farmers market", "Pizza night", "Lunch with Sam", "Parking", "Haircut", "Gym", "Cinema",
    "Phone bill", "Water bill", "Vet", "Toy shop", "Flowers", "Taxi", "Brunch", "Takeout", "Dry cleaning",
]


def checksum(data: bytes) -> str:
    """FNV-1a 64 as Dart's toRadixString(16).padLeft(16, '0') on a signed int."""
    h = 0xCBF29CE484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    signed = h - (1 << 64) if h >= (1 << 63) else h
    text = "-" + format(-signed, "x") if signed < 0 else format(signed, "x")
    return "0" * (16 - len(text)) + text if len(text) < 16 else text


def iso(d: datetime.datetime, micro: bool = False) -> str:
    base = d.strftime("%Y-%m-%dT%H:%M:%S")
    return base + (".%06d" % d.microsecond if micro else ".%03d" % (d.microsecond // 1000))


def month_add(first: datetime.date, delta: int) -> datetime.date:
    index = first.year * 12 + first.month - 1 + delta
    return datetime.date(index // 12, index % 12 + 1, 1)


def build(now: datetime.datetime) -> tuple[bytes, dict]:
    rng = random.Random(20260930)
    base = json.loads(BASE.read_bytes().split(b"\n", 1)[1])
    tags = [t["id"] for t in base["transactionTags"]]
    today = now.date()
    this_month = today.replace(day=1)

    def pick(table):
        return rng.choices([c for c, _ in table], [w for _, w in table])[0]

    counts = {}
    for back in range(MONTHS):
        counts[back] = ROWS // 20 if back == 0 else ROWS // 40 if back <= 3 else 0
    rest = ROWS - sum(counts.values())
    others = [b for b in range(4, MONTHS)]
    for i, back in enumerate(others):
        counts[back] = rest // len(others) + (1 if i < rest % len(others) else 0)

    transactions = []
    n = 0
    for back in range(MONTHS - 1, -1, -1):
        first = month_add(this_month, -back)
        last_day = (month_add(first, 1) - datetime.timedelta(days=1)).day
        if back == 0:
            last_day = today.day
        month_rows = []
        for i in range(counts[back]):
            n += 1
            day = rng.randint(1, last_day)
            stamp = datetime.datetime(first.year, first.month, day, rng.randint(0, 22), rng.randint(0, 59), rng.randint(0, 59))
            if back == 0 and i < counts[0] * 7 // 10:
                income, category = False, "Groceries"
            else:
                income = rng.random() < 0.30
                category = pick(INCOME if income else EXPENSE)
            if category == "Eating Out" and rng.random() < 0.25:
                text = rng.choice(["Coffee", "coffee beans", "Iced Coffee", "Coffee and cake"])
            elif income:
                text = {"Salary": "ACME PAYROLL", "Investment": "Dividend", "Gift": "Gift received"}.get(category, "Refund")
            else:
                text = f"{rng.choice(MERCHANTS)} #{rng.randint(1, 999)}"
            amount = round(rng.uniform(1, 900) if not income else rng.uniform(20, 4200), 2)
            created = stamp + datetime.timedelta(minutes=rng.randint(0, 600), microseconds=rng.randint(0, 999999))
            if created.date() > today:
                created = stamp
            month_rows.append({
                "id": str(uuid.UUID(int=rng.getrandbits(128), version=4)),
                "type": "income" if income else "expense",
                "description": text,
                "amount": amount,
                "category": category,
                "date": iso(stamp),
                "recurringTemplateId": None,
                "tagIds": [rng.choice(tags)] if rng.random() < 0.10 else [],
                "createdAt": iso(created, micro=True),
                "updatedAt": iso(created, micro=True),
            })
        rng.shuffle(month_rows)
        transactions.extend(month_rows)
    assert len(transactions) == ROWS, len(transactions)

    snapshots = []
    value = 12_000.0
    start = now - datetime.timedelta(weeks=SNAPSHOTS - 1)
    for i in range(SNAPSHOTS):
        value = round(max(500.0, value + rng.uniform(-400, 520)), 2)
        snapshots.append({"recordedAt": iso(start + datetime.timedelta(weeks=i)), "amount": value})
    worth = list(base["netWorthEntries"])
    worth.append({
        "id": str(uuid.UUID(int=rng.getrandbits(128), version=4)), "name": "Perf History", "type": "asset",
        "createdAt": iso(start, micro=True), "snapshots": snapshots,
    })

    sections = dict(base)
    sections["transactions"] = transactions
    sections["netWorthEntries"] = worth
    sections["recurringTransactions"] = []
    sections["appSettings"] = {
        "baseCurrencyCode": "USD", "localeOverride": None, "appLockEnabled": False, "autoLockTimeoutSeconds": 300,
        "hideBalances": False,
    }
    sections["categoryBudgetLimits"] = {
        "Groceries": 600.0, "Eating Out": 300.0, "Transportation": 200.0, "Entertainment": 150.0, "Health": 120.0,
    }
    payload = json.dumps(sections, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    header = json.dumps({
        "format": "budgie-financial-store", "schemaVersion": 2, "revision": REVISION, "payloadLength": len(payload),
        "payloadChecksum": checksum(payload), "writtenAt": iso(now),
    }, separators=(",", ":")).encode("utf-8")
    summary = {"rows": len(transactions), "bytes": len(header) + 1 + len(payload), "month": this_month.isoformat(),
               "currentMonthRows": counts[0], "snapshots": len(snapshots)}
    return header + b"\n" + payload, summary


def sh(*cmd, check=True):
    return subprocess.run(cmd, check=check, text=True, capture_output=True).stdout.strip()


def main():
    global ROWS, SNAPSHOTS
    args = sys.argv[1:]
    if args[:1] == ["--rows"]:
        ROWS = int(args[1])
        SNAPSHOTS = 500 if ROWS >= 10_000 else 12
        args = args[2:]
    if not args:
        sys.exit(__doc__)
    data, summary = build(datetime.datetime.now().replace(microsecond=0))
    if args[0] == "--generate-only":
        out = Path(args[1])
        store = out
    else:
        udid = args[0]
        sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
        container = Path(sh("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"))
        store = reset_store(container)
        # A leftover pre-native snapshot would hide the first-launch copy
        # (and its cost) from the launch measurements.
        subprocess.run(["rm", "-rf", str(container / "Library/Application Support/pre-native-migration")], check=True)
        # No onboarding flag is written here: `simctl spawn defaults write`
        # lands in the simulator's own preferences, not the app container's
        # plist, so the app never sees it (checked on iOS 27.0). The tests
        # start past the tour with the BUDGIE_SKIP_ONBOARDING launch hook.
    store.mkdir(parents=True, exist_ok=True)
    (store / "financial_store_v2.json").write_bytes(data)
    (store / "financial_store_v2.backup.json").write_bytes(data)
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
