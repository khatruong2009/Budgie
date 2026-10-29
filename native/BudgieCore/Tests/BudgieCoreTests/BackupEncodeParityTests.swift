import Foundation
import Testing

@testable import BudgieCore

@Suite("Backup: export matches Flutter's encodeBackup byte for byte (Fixtures/backup)")
struct BackupEncodeParityTests {
    @Test("every store and hand-made case, every backup zone", arguments: backupZones)
    func encode(_ zone: String) async throws {
        let timeZone = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: timeZone)
        let fixture = try backupFixture(zone, "encode.json")
        let launchNow = try DartDateTime.parse(fixture["launchNow"].string!, timeZone: timeZone)
        let exportedAt = try DartDateTime.parse(fixture["exportedAt"].string!, timeZone: timeZone)
        let appVersion = fixture["appVersion"].string!
        #expect(fixture["cases"].array.count >= 18)
        var counter = 0
        func newID() -> String {
            counter += 1
            return "swift-new-\(counter)"
        }
        for item in fixture["cases"].array {
            let name = item["name"].string!
            let snapshot: FinancialSnapshot
            let preferences: InMemoryPreferences
            if let store = item["store"].string {
                let scenario = try Scenario(Fixtures.url("store/\(store)"))
                preferences = scenario.preferences
                snapshot = try await FinancialStore(
                    fileSystem: scenario.fileSystem, preferences: preferences, protectedData: AlwaysAvailable(),
                    clock: { launchNow }
                ).read()
            } else {
                let sections = try JSONParser.parse(fixtureBytes(item["sections"])).objectValue!
                snapshot = FinancialSnapshot(revision: 1, sections: sections)
                preferences = InMemoryPreferences(typedPreferences(item["prefs"]))
            }
            let data = FinancialData.load(
                snapshot, preferences: preferences, calendar: calendar, now: { launchNow }, newID: newID, matchesPaddedCategoryNames: false
            ).data
            var bytes = try BackupEnvelope.encode(
                data: data, themeMode: item["themeMode"].string, appVersion: appVersion, now: exportedAt)
            let dartIDs = item["generatedIds"].array.map { $0.string! }
            var known = Set<[UInt16]>()
            allStrings(.object(snapshot.sections), into: &known)
            bytes = try substitutingGeneratedIDs(bytes, dart: dartIDs, known: known)
            if item["expected"].string != nil {
                #expect(bytes == fixtureBytes(item["expected"]), "\(zone) \(name)")
            } else {
                #expect(StoreFile.checksum(bytes) == item["expected"]["fnv"].string, "\(zone) \(name) fnv")
                #expect(bytes.count == item["expected"]["length"].int, "\(zone) \(name) length")
            }
        }
        for vector in fixture["fileNames"].array {
            let date = try DartDateTime.parse(vector["date"].string!, timeZone: timeZone)
            #expect(BackupEnvelope.fileName(now: date) == vector["fileName"].string, "\(zone)")
        }
    }

    @Test("the real Settings page's export: file name, bytes (Fixtures export_flow.json)", arguments: backupZones)
    func exportFlow(_ zone: String) async throws {
        let timeZone = TimeZone(identifier: zone)!
        let flow = try backupFixture(zone, "export_flow.json")
        #expect(flow["subject"].string == "Budgie Backup")
        #expect(flow["snackbar"].string == "Backup exported")
        #expect(flow["fileCount"].int == 1)
        let now = try DartDateTime.parse(flow["now"].string!, timeZone: timeZone)
        #expect(BackupEnvelope.fileName(now: now) == flow["fileName"].string)
        let scenario = try Scenario(Fixtures.url("store/typical"))
        let snapshot = try await FinancialStore(
            fileSystem: scenario.fileSystem, preferences: scenario.preferences, protectedData: AlwaysAvailable(), clock: { now }
        ).read()
        let data = FinancialData.load(
            snapshot, preferences: scenario.preferences, calendar: DartCalendar(timeZone: timeZone), now: { now },
            newID: { UUID().uuidString.lowercased() }, matchesPaddedCategoryNames: false
        ).data
        let bytes = try BackupEnvelope.encode(data: data, themeMode: flow["themeMode"].string, appVersion: "3.4.0", now: now)
        #expect(bytes == fixtureBytes(flow["bytes"]))
    }

    @Test("unreadable rows are left out, and a non-finite amount fails like Dart's encoder")
    func unreadableAndNonFinite() throws {
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let now = calendar.date(2026, 9, 28)
        let sections = try JSONParser.parse(#"""
            {"transactions":[
              {"id":"a","type":"expense","description":"ok","amount":1,"category":"General","date":"2026-09-01"},
              {"id":"b","type":"expense","amount":1.0,"category":"General","date":"2026-09-01"},
              {"id":"c","type":"expense","description":"inf","amount":1e999,"category":"General","date":"2026-09-01"}]}
            """#).objectValue!
        let data = FinancialData.load(
            FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences(), calendar: calendar,
            now: { now }, newID: { "new" }
        ).data
        #expect(data.transactionRows.count == 3 && data.transactions.count == 2)
        #expect(throws: BackupExportError.self) {
            try BackupEnvelope.encode(data: data, themeMode: "system", appVersion: "4.0.0", now: now)
        }
        do {
            _ = try BackupEnvelope.encode(data: data, themeMode: "system", appVersion: "4.0.0", now: now)
        } catch {
            #expect(error.message == "Converting object to an encodable object failed: Infinity")
        }
    }
}
