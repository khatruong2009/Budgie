import XCTest

/// Voice entry, end to end in the UI: Home mic (or a `budgetapp://voice-add`
/// link), the recording sheet, THINKING, the prefilled add form, and every
/// error the sheet can show. Never the real microphone or the network:
/// every launch points the Debug hooks (Budgie/Debug/VoiceTestHooks.swift)
/// at a few bytes this test writes to its own temporary directory
/// (`BUDGIE_VOICE_AUDIO_FILE`) and, where the OpenAI calls matter, at a
/// canned answer per call (`BUDGIE_VOICE_STUB`; any other URL answers 599).
/// Fresh install, no seeded data; a test that saves a row deletes it again.
@MainActor
final class VoiceUITests: XCTestCase {
    let app = XCUIApplication()
    private var audioURL: URL!

    static let transcript = "lunch at Chipotle twelve fifty"
    static let generic = "Something went wrong. Try again."

    override func setUp() async throws {
        continueAfterFailure = false
        audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-uitest-\(UUID().uuidString).m4a")
        try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]).write(to: audioURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: audioURL)
    }

    // MARK: Launch

    /// The model's reply as the assistant message content (a JSON string).
    private func reply(
        type: String = "expense", description: String = "Chipotle lunch", amount: Double = 12.5,
        category: String = "Eating Out", date: String? = nil
    ) -> String {
        var fields: [String: Any] = ["type": type, "description": description, "amount": amount, "category": category]
        if let date { fields["date"] = date }
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// A stub plan: each list is consumed in order and its last entry repeats.
    private func plan(
        transcribe: [[String: Any]] = [["text": VoiceUITests.transcript]], chat: [[String: Any]]? = nil
    ) -> String {
        let chat = chat ?? [["content": reply()]]
        let data = try! JSONSerialization.data(withJSONObject: ["transcribe": transcribe, "chat": chat])
        return String(decoding: data, as: UTF8.self)
    }

    /// Launches past the onboarding tour with the audio hook on (unless
    /// `audio` is false) and the given stub and extra hooks.
    private func launch(stub: String? = nil, audio: Bool = true, hooks: [String: String] = [:]) {
        if audio { app.launchEnvironment["BUDGIE_VOICE_AUDIO_FILE"] = audioURL.path }
        if let stub { app.launchEnvironment["BUDGIE_VOICE_STUB"] = stub }
        for (key, value) in hooks { app.launchEnvironment[key] = value }
        app.budgie()
    }

    // MARK: Helpers

    private var listening: XCUIElement { app.staticTexts["LISTENING"] }
    private var thinking: XCUIElement { app.staticTexts["THINKING"] }
    private var message: XCUIElement { app.staticTexts["voice.message"] }
    private var quoted: XCUIElement { app.staticTexts["voice.transcript"] }

    private func openVoiceFromHome(file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["home.voice"].tapSettled()
        XCTAssertTrue(listening.waitForExistence(timeout: 15), "LISTENING not shown", file: file, line: line)
    }

    private func stop(file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["voice.stop"].tapSettled()
    }

    /// Records, stops and lands on the error the stub produces.
    private func recordExpectingError(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        openVoiceFromHome(file: file, line: line)
        stop(file: file, line: line)
        expectError(text, file: file, line: line)
    }

    private func expectError(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(message.waitForExistence(timeout: 15), "no error shown, wanted \"\(text)\"", file: file, line: line)
        XCTAssertEqual(message.label, text, file: file, line: line)
    }

    private func expectForm(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 15), "\(title) form not shown", file: file, line: line)
        XCTAssertTrue(app.textFields["Amount"].waitForExistence(timeout: 5), file: file, line: line)
    }

    /// The form's selected category (the Category row's value).
    private var categoryWheel: String { app.formCategory.value as? String ?? "" }

    /// Drags the sheet (grabbed at `element`) to the bottom of the screen.
    private func dragSheetDown(from element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
    }

    // MARK: Happy path

    /// Home mic > LISTENING > Stop > THINKING > the prefilled Add Expense
    /// form (no "Make this recurring", cannot be swiped away) > Add > the
    /// row in Recent activity, which the test then deletes.
    func testExpenseFromTheHomeMic() throws {
        launch(stub: plan(transcribe: [["text": Self.transcript, "delayMs": 6000]]))
        openVoiceFromHome()
        XCTAssertTrue(app.staticTexts["voice.countdown"].waitForExistence(timeout: 5), "countdown shown")
        stop()
        XCTAssertTrue(thinking.waitForExistence(timeout: 5), "THINKING not shown")
        XCTAssertFalse(listening.exists)

        expectForm("Add Expense")
        XCTAssertEqual(app.textFields["Amount"].value as? String, "12.50")
        XCTAssertEqual(app.textFields["Description"].value as? String, "Chipotle lunch")
        XCTAssertEqual(categoryWheel, "Eating Out")
        XCTAssertFalse(app.buttons["Make this recurring"].exists, "a prefilled form offers no recurring")
        XCTAssertFalse(app.staticTexts["Make this recurring"].exists)

        // A swipe down does not dismiss the confirmation.
        dragSheetDown(from: app.staticTexts["Add Expense"])
        XCTAssertTrue(app.staticTexts["Add Expense"].exists, "the form was dismissed by a swipe")
        XCTAssertTrue(app.textFields["Amount"].exists)

        app.buttons["Add"].tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 10), "form did not close")
        let row = app.labelled(containing: "Chipotle lunch")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the saved row is in Recent activity")
        XCTAssertTrue((row.value as? String ?? "").contains("Eating Out"), "row value: \(String(describing: row.value))")

        // Control: the ordinary Add form does offer "Make this recurring",
        // so its absence above means something.
        app.buttons["Add transaction"].tapSettled()
        XCTAssertTrue(app.buttons["Make this recurring"].waitForExistence(timeout: 5), "control: the ordinary form has recurring")
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 5))

        // Leave no data: delete the row from SEE ALL.
        app.buttons["See all transactions"].firstMatch.tapSettled()
        let listed = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Chipotle lunch'")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 10))
        listed.swipeLeft()
        let confirm = app.alerts["Delete Transaction"].buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(listed.waitForNonExistence(timeout: 5), "the row was deleted")
    }

    /// The form's Cancel closes the whole voice flow back to Home.
    func testCancelOnTheFormClosesTheFlow() throws {
        launch(stub: plan())
        openVoiceFromHome()
        stop()
        expectForm("Add Expense")
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 5), "form did not close")
        XCTAssertTrue(app.buttons["home.voice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.voice"].isHittable, "Home is back in front")
        XCTAssertFalse(app.labelled(containing: "Chipotle lunch").exists, "Cancel saved nothing")
    }

    // MARK: Draft contents

    func testIncomeDraftOpensAddIncome() throws {
        launch(stub: plan(chat: [["content": reply(type: "income", description: "Paycheck", amount: 1500, category: "Salary")]]))
        openVoiceFromHome()
        stop()
        expectForm("Add Income")
        XCTAssertEqual(app.textFields["Amount"].value as? String, "1500.00")
        XCTAssertEqual(app.textFields["Description"].value as? String, "Paycheck")
        XCTAssertEqual(categoryWheel, "Salary")
        XCTAssertFalse(app.buttons["Make this recurring"].exists)
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Income"].waitForNonExistence(timeout: 5))
    }

    /// A spoken date three days back reaches the form's Date tile.
    func testSpokenDateReachesTheForm() throws {
        let past = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd"
        let shown = DateFormatter()
        shown.locale = Locale(identifier: "en_US_POSIX")
        shown.dateFormat = "MMM dd, yyyy"

        launch(stub: plan(chat: [["content": reply(date: iso.string(from: past))]]))
        openVoiceFromHome()
        stop()
        expectForm("Add Expense")
        let date = app.buttons["Date"]
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        XCTAssertEqual(date.value as? String, shown.string(from: past))
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 5))
    }

    // MARK: Errors

    /// A chat failure is a parse-stage error: the generic message with the
    /// transcript quoted; Try again re-reads the kept transcript.
    func testChatFailureThenRetry() throws {
        launch(stub: plan(chat: [["status": 500], ["content": reply()]]))
        recordExpectingError(Self.generic)
        XCTAssertTrue(quoted.exists, "a parse-stage error quotes the transcript")
        XCTAssertEqual(quoted.label, "\"\(Self.transcript)\"")
        app.buttons["voice.tryAgain"].tapSettled()
        expectForm("Add Expense")
        XCTAssertEqual(app.textFields["Description"].value as? String, "Chipotle lunch")
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 5))
    }

    /// A transcription failure has no transcript to quote; Try again
    /// transcribes the same recording again.
    func testTranscriptionFailureThenRetry() throws {
        launch(stub: plan(transcribe: [["status": 500], ["text": Self.transcript]]))
        recordExpectingError(Self.generic)
        XCTAssertFalse(quoted.exists, "no transcript exists yet")
        app.buttons["voice.tryAgain"].tapSettled()
        expectForm("Add Expense")
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 5))
    }

    /// Owner decision: a refused key (401) reads as the generic message.
    func testUnauthorizedIsGeneric() throws {
        launch(stub: plan(transcribe: [["status": 401]]))
        recordExpectingError(Self.generic)
        XCTAssertFalse(quoted.exists)
        XCTAssertTrue(app.buttons["voice.tryAgain"].exists)
        XCTAssertTrue(app.buttons["voice.cancel"].exists)
    }

    /// Owner decision: a rate limit (429) reads as the generic message too,
    /// here on the chat call, so the transcript is quoted.
    func testRateLimitedIsGeneric() throws {
        launch(stub: plan(chat: [["status": 429]]))
        recordExpectingError(Self.generic)
        XCTAssertEqual(quoted.label, "\"\(Self.transcript)\"")
    }

    func testUnreadableOutputQuotesTheTranscript() throws {
        launch(stub: plan(chat: [["content": "this is not json at all"]]))
        recordExpectingError("Couldn't read that as a transaction — try again")
        XCTAssertEqual(quoted.label, "\"\(Self.transcript)\"")
    }

    func testNotATransactionQuotesTheTranscript() throws {
        launch(stub: plan(chat: [["content": "{\"error\":\"not a transaction\"}"]]))
        recordExpectingError("That didn't sound like a transaction — try again")
        XCTAssertEqual(quoted.label, "\"\(Self.transcript)\"")
    }

    /// An empty transcript re-records on Try again.
    func testEmptyTranscriptThenRecordAgain() throws {
        launch(stub: plan(transcribe: [["text": ""], ["text": Self.transcript]]))
        recordExpectingError("Didn't catch anything — try again")
        XCTAssertFalse(quoted.exists)
        app.buttons["voice.tryAgain"].tapSettled()
        XCTAssertTrue(listening.waitForExistence(timeout: 10), "Try again did not record again")
        stop()
        expectForm("Add Expense")
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 5))
    }

    // MARK: Microphone, cap, key

    func testMicrophoneDenied() throws {
        launch(hooks: ["BUDGIE_VOICE_MIC_DENIED": "1"])
        app.buttons["home.voice"].tapSettled()
        expectError("Microphone access is off. Enable it in Settings > Budgie.")
        XCTAssertFalse(quoted.exists)
        // Try again asks again and is denied again.
        app.buttons["voice.tryAgain"].tapSettled()
        expectError("Microphone access is off. Enable it in Settings > Budgie.")
        app.buttons["voice.cancel"].tapSettled()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5), "the sheet did not close")
        XCTAssertTrue(app.buttons["home.voice"].isHittable, "back on Home")
    }

    /// With the cap at 2 s the sheet moves on to THINKING by itself. (No
    /// LISTENING or countdown assertions: the whole recording lasts about as
    /// long as one accessibility query takes.)
    func testRecordingCapMovesOnWithoutStop() throws {
        launch(
            stub: plan(transcribe: [["text": Self.transcript, "delayMs": 10000]]),
            hooks: ["BUDGIE_VOICE_MAX_SECONDS": "2"])
        app.buttons["home.voice"].tapSettled()
        XCTAssertTrue(thinking.waitForExistence(timeout: 20), "the cap did not stop the recording")
        XCTAssertFalse(app.buttons["voice.stop"].exists, "Stop is gone in THINKING")
        expectForm("Add Expense")
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 5))
    }

    /// A Debug build without a key shows "not configured" after Stop, and
    /// nothing is sent: a missing key never builds a request. Skipped when
    /// this tree has a Secrets.xcconfig, because then the app has a real
    /// key and would call OpenAI (with no stub installed).
    func testNotConfiguredWithoutAKey() throws {
        let secrets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Secrets.xcconfig")
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: secrets.path),
            "native/Config/Secrets.xcconfig exists, so this build has a real key and no stub would guard the network")
        launch()
        recordExpectingError("OpenAI is not configured. Add OPENAI_API_KEY to native/Config/Secrets.xcconfig.")
        XCTAssertFalse(quoted.exists)
    }

    // MARK: Routes

    /// `budgetapp://voice-add` opens the sheet; a second link while it is up
    /// does not stack another one.
    func testDeepLinkOpensOneVoiceSheet() throws {
        launch(stub: plan())
        app.route("budgetapp://voice-add")
        XCTAssertTrue(listening.waitForExistence(timeout: 15), "voice-add did not open the voice sheet")
        app.route("budgetapp://voice_add")
        XCTAssertTrue(listening.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "LISTENING").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "voice.stop").count, 1)

        // Closing the one sheet leaves Home, not a second sheet beneath.
        dragSheetDown(from: listening)
        XCTAssertTrue(listening.waitForNonExistence(timeout: 10), "the sheet did not close")
        sleep(2)
        XCTAssertFalse(listening.exists, "a second voice sheet was stacked")
        XCTAssertTrue(app.buttons["home.voice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.voice"].isHittable, "Home is in front")
    }

    /// A voice link opens over a sheet the user already has open, as the
    /// other routes do, and closing it leaves that sheet as it was.
    func testVoiceRouteOpensOverAHomeSheet() throws {
        launch(hooks: ["BUDGIE_VOICE_MIC_DENIED": "1"])
        app.buttons["Add transaction"].tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForExistence(timeout: 10))
        app.route("budgetapp://voice-add")
        expectError("Microphone access is off. Enable it in Settings > Budgie.")
        app.buttons["voice.cancel"].tapSettled()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5), "the voice sheet did not close")
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForExistence(timeout: 5), "the add form is still open")
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.isHittable, "the add form is in front again")
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 5))
    }
}
