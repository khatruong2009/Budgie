#!/usr/bin/env bash
# Puts the files BackupUITests and CSVImportUITests pick into a booted
# simulator's "On My iPhone" (the File Provider local storage). Every row
# is dated the 15th of last month; the CSV's new rows are later that day
# than the backup's, so they lead Home's recent activity after an import.
#
#   native/scripts/stage_import_fixtures.sh <simulator UDID>
#
# Run it after an erase and boot, before the UI tests. Only that simulator
# is touched. Those two suites replace the app's data, so they belong on an
# erased simulator only: they launch the app with BUDGIE_UITEST_DATA_GUARD=1,
# which refuses a store UI tests did not make (the tests then skip). Files: "Budgie UITest Backup.json" (schema 3, three
# transactions), "Budgie UITest Locked Backup.json" (the same with App Lock
# on), "Budgie UITest Corrupt.json", "Budgie UITest Import.csv"
# (two duplicates of the backup's rows, two new rows, one bad row),
# "Budgie UITest Duplicates.csv" and "Budgie UITest Bad Header.csv".
set -euo pipefail
UDID="${1:?usage: stage_import_fixtures.sh <simulator UDID>}"
# bootstatus -b boots a shut-down simulator; if that is what happens here,
# shut it down again on exit (a simulator that was already booted stays so).
if ! xcrun simctl list devices booted | grep -q "$UDID"; then
  trap 'xcrun simctl shutdown "$UDID" 2>/dev/null || true' EXIT
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null

GROUPS_DIR="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers/Shared/AppGroup"
STORAGE=""
for metadata in "$GROUPS_DIR"/*/.com.apple.mobile_container_manager.metadata.plist; do
  identifier=$(plutil -extract MCMMetadataIdentifier raw "$metadata" 2>/dev/null || true)
  if [ "$identifier" = "group.com.apple.FileProvider.LocalStorage" ]; then
    STORAGE="$(dirname "$metadata")/File Provider Storage"
    break
  fi
done
if [ -z "$STORAGE" ]; then
  echo "No File Provider local storage container on $UDID (boot it once first)." >&2
  exit 1
fi
mkdir -p "$STORAGE"
rm -f "$STORAGE"/Budgie\ UITest\ *

# The 15th of last month: in the past at any time of day (Home's recent
# activity is newest first, so a row the other UI tests add now still
# comes first), and outside the current month those tests total.
DAY="$(date -v1d -v-1m +%Y-%m)-15"

cat > "$STORAGE/Budgie UITest Backup.json" <<EOF
{
  "schemaVersion": 3,
  "app": "budgie",
  "appVersion": "3.4.0",
  "exportedAt": "${DAY}T08:00:00.000",
  "data": {
    "transactions": [
      {"id": "uitest-pay", "type": "income", "description": "UITest Paycheck", "amount": 3200.0, "category": "Salary",
       "date": "${DAY}T09:00:00.000", "recurringTemplateId": null, "tagIds": [],
       "createdAt": "${DAY}T09:00:00.000", "updatedAt": "${DAY}T09:00:00.000"},
      {"id": "uitest-rent", "type": "expense", "description": "UITest Rent", "amount": 1400.0, "category": "Housing",
       "date": "${DAY}T10:00:00.000", "recurringTemplateId": null, "tagIds": [],
       "createdAt": "${DAY}T10:00:00.000", "updatedAt": "${DAY}T10:00:00.000"},
      {"id": "uitest-groceries", "type": "expense", "description": "UITest Groceries", "amount": 86.4, "category": "Groceries",
       "date": "${DAY}T11:00:00.000", "recurringTemplateId": null, "tagIds": [],
       "createdAt": "${DAY}T11:00:00.000", "updatedAt": "${DAY}T11:00:00.000"}
    ],
    "netWorthEntries": [],
    "categoryBudgetLimits": {"Groceries": 400.0},
    "savingsGoals": [],
    "recurringTransactions": [],
    "themeMode": null,
    "categories": [],
    "transactionTags": [],
    "categorizationRules": [],
    "baseCurrencyCode": "USD",
    "localeOverride": null,
    "appLockEnabled": false,
    "autoLockTimeoutSeconds": 60,
    "hideBalances": false
  }
}
EOF

# The same backup with App Lock on (BackupUITests: a restore must not
# unlock the session it locks).
sed 's/"appLockEnabled": false/"appLockEnabled": true/' "$STORAGE/Budgie UITest Backup.json" > "$STORAGE/Budgie UITest Locked Backup.json"

printf '{ "schemaVersion": 3, "data": ' > "$STORAGE/Budgie UITest Corrupt.json"

printf 'Date,Type,Category,Description,Amount\r\n%s,Expense,Housing,UITest Rent,1400.00\r\n%s,Expense,Groceries,UITest Groceries,86.40\r\n%sT12:00,Expense,Eating Out,UITest Coffee,4.75\r\n%sT12:30,Income,Other,UITest Refund,25.00\r\nnot a date,Expense,Food,UITest Broken,1.00\r\n' \
  "$DAY" "$DAY" "$DAY" "$DAY" > "$STORAGE/Budgie UITest Import.csv"

printf 'Date,Type,Category,Description,Amount\r\n%s,Income,Salary,UITest Paycheck,3200.00\r\n%s,Expense,Housing,UITest Rent,1400.00\r\n' \
  "$DAY" "$DAY" > "$STORAGE/Budgie UITest Duplicates.csv"

printf 'Date;Type;Category;Description;Amount\r\n%s;Expense;Food;UITest Semicolon;1.00\r\n' "$DAY" > "$STORAGE/Budgie UITest Bad Header.csv"

echo "Staged into $STORAGE:"
ls -1 "$STORAGE" | grep "Budgie UITest"
