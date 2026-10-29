import BudgieCore
import XCTest

@testable import Runner

@MainActor
final class VoiceEntryModelTests: XCTestCase {
    private var recorder = FakeRecorder()
    private var fake = FakeServices()
    private var delivered: [VoiceDraft] = []

    override func setUp() async throws { reset() }

    private func reset() {
        recorder = FakeRecorder()
        fake = FakeServices()
        delivered = []
    }

    /// A machine whose own timer never fires (tests call `tick()`).
    private func makeModel(maxSeconds: Int = 30, services: VoiceServices? = nil) -> VoiceEntryModel {
        VoiceEntryModel(
            recorder: recorder, services: services ?? fake.services, maxSeconds: maxSeconds, tickInterval: .seconds(3600)
        ) { [self] in delivered.append($0) }
    }

    private func recording(maxSeconds: Int = 30, services: VoiceServices? = nil) async -> VoiceEntryModel {
        let model = makeModel(maxSeconds: maxSeconds, services: services)
        model.begin()
        await model.settle()
        return model
    }

    /// Lets queued work run until `condition` holds.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func stopped(_ model: VoiceEntryModel) async {
        model.stop()
        await model.settle()
    }

    private func assertError(
        _ model: VoiceEntryModel, _ kind: VoiceEntryModel.ErrorKind, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(model.stage, .error(kind, message: message), file: file, line: line)
    }

    // MARK: Happy path

    func testRecordingStartsThenStopTranscribesParsesAndDeliversOnce() async {
        let model = await recording()
        XCTAssertEqual(model.stage, .recording)
        XCTAssertTrue(model.isPulsing)
        XCTAssertEqual(model.recordingStarts, 1)
        XCTAssertEqual(model.countdownText, "0:30")

        model.stop()
        XCTAssertEqual(model.stage, .processing)
        XCTAssertFalse(model.isPulsing)
        XCTAssertEqual(model.stops, 1)
        await model.settle()

        XCTAssertEqual(delivered, [FakeServices.draft])
        XCTAssertEqual(fake.transcribedFiles, recorder.files)
        XCTAssertEqual(fake.draftedTranscripts, ["lunch at Chipotle twelve fifty"])
        XCTAssertEqual(model.errors, 0)
        XCTAssertEqual(recorder.stopCount, 1, "the recorder is stopped before transcribing")

        model.stop()
        await model.settle()
        XCTAssertEqual(delivered.count, 1, "a second stop does nothing")
    }

    func testCountdownRunsFromThirtyToZeroAndTheCapStopsRecording() async {
        let model = await recording()
        model.tick()
        XCTAssertEqual(model.countdownText, "0:29")
        for _ in 0..<19 { model.tick() }
        XCTAssertEqual(model.countdownText, "0:10")
        XCTAssertEqual(model.remainingSeconds, 10)
        for _ in 0..<9 { model.tick() }
        XCTAssertEqual(model.countdownText, "0:01")
        XCTAssertEqual(model.stage, .recording)
        model.tick()
        XCTAssertEqual(model.countdownText, "0:00")
        XCTAssertEqual(model.stage, .processing, "at the cap it stops and goes on")
        await model.settle()
        XCTAssertEqual(delivered.count, 1)
    }

    func testBackgroundingWhileRecordingStopsAndGoesOn() async {
        let model = await recording()
        model.appDidEnterBackground()
        XCTAssertEqual(model.stage, .processing)
        await model.settle()
        XCTAssertEqual(delivered.count, 1)
    }

    func testBackgroundingOutsideRecordingDoesNothing() async {
        fake.transcripts = [.failure(.failed)]
        let model = await recording()
        await stopped(model)
        let stage = model.stage
        model.appDidEnterBackground()
        XCTAssertEqual(model.stage, stage)
        XCTAssertEqual(model.stops, 1)
    }

    func testAudioInterruptionWhileRecordingStopsAndGoesOn() async {
        let model = await recording()
        XCTAssertNotNil(recorder.onInterruption, "the model listens for the recorder's interruption")
        recorder.onInterruption?()
        XCTAssertEqual(model.stage, .processing)
        XCTAssertEqual(model.stops, 1)
        await model.settle()
        XCTAssertEqual(delivered.count, 1)
    }

    func testAudioInterruptionOutsideRecordingDoesNothing() async {
        fake.transcripts = [.failure(.failed)]
        let model = await recording()
        await stopped(model)
        let stage = model.stage
        recorder.onInterruption?()
        XCTAssertEqual(model.stage, stage)
        XCTAssertEqual(model.stops, 1)
    }

    func testCancelReleasesTheServices() async {
        var finished = 0
        var services = fake.services
        services.finish = { finished += 1 }
        let model = await recording(services: services)
        XCTAssertEqual(finished, 0)
        model.cancel()
        XCTAssertEqual(finished, 1)
    }

    // MARK: Error kinds

    func testMicrophoneDeniedShowsFlutterMessageAndRecordsAgainOnRetry() async {
        recorder.startResults = [.failure(.microphoneDenied)]
        let model = await recording()
        assertError(model, .noSpeech, "Microphone access is off. Enable it in Settings > Budgie.")
        XCTAssertNil(model.transcript)
        XCTAssertEqual(model.errors, 1)

        model.tryAgain()
        XCTAssertEqual(model.stage, .recording)
        await model.settle()
        XCTAssertEqual(recorder.startCount, 2)
        XCTAssertEqual(model.stage, .recording)
        XCTAssertTrue(model.isPulsing)
    }

    func testTranscriptionErrorsMapToTheirKindsAndMessages() async {
        let cases: [(VoiceEntryError, VoiceEntryModel.ErrorKind, String)] = [
            (.noSpeech, .noSpeech, "Didn't catch anything — try again"),
            (.notConfigured, .noSpeech, VoiceEntryError.notConfigured.message),
            (.unauthorized, .transcribeFailed, "Something went wrong. Try again."),
            (.rateLimited, .transcribeFailed, "Something went wrong. Try again."),
            (.failed, .transcribeFailed, "Something went wrong. Try again."),
        ]
        for (error, kind, message) in cases {
            reset()
            fake.transcripts = [.failure(error)]
            let model = await recording()
            await stopped(model)
            assertError(model, kind, message)
            XCTAssertNil(model.transcript, "\(error)")
            XCTAssertEqual(model.errors, 1)
            XCTAssertTrue(delivered.isEmpty)
        }
    }

    func testParseErrorsAreParseFailedAndKeepTheTranscriptToQuote() async {
        let transcript = "lunch at Chipotle twelve fifty"
        let cases: [(VoiceEntryError, String)] = [
            (.unreadable(transcript: transcript), "Couldn't read that as a transaction — try again"),
            (.notATransaction(transcript: transcript), "That didn't sound like a transaction — try again"),
            (.unauthorized, "Something went wrong. Try again."),
            (.rateLimited, "Something went wrong. Try again."),
            (.failed, "Something went wrong. Try again."),
        ]
        for (error, message) in cases {
            reset()
            fake.drafts = [.failure(error)]
            let model = await recording()
            await stopped(model)
            assertError(model, .parseFailed, message)
            XCTAssertEqual(model.transcript, transcript, "the sheet's own transcript is quoted, also for \(error)")
            XCTAssertTrue(delivered.isEmpty)
        }
    }

    func testStopBeforeAnyRecordingExistsIsNoSpeech() async {
        let model = makeModel()
        model.begin()
        model.stop()
        await model.settle()
        assertError(model, .noSpeech, "Didn't catch anything — try again")
        XCTAssertTrue(fake.transcribedFiles.isEmpty)
        XCTAssertEqual(recorder.stopCount, 2, "the recorder that started late is stopped, not left running")
    }

    // MARK: Try again

    func testTryAgainAfterNoSpeechRecordsAgain() async {
        fake.transcripts = [.failure(.noSpeech), .success("coffee four dollars")]
        let model = await recording()
        await stopped(model)
        assertError(model, .noSpeech, "Didn't catch anything — try again")

        model.tryAgain()
        XCTAssertEqual(model.stage, .recording)
        XCTAssertEqual(model.countdownText, "0:30")
        await model.settle()
        XCTAssertEqual(recorder.startCount, 2, "a new recording, not the old file")
        XCTAssertEqual(model.recordingStarts, 2)

        await stopped(model)
        XCTAssertEqual(fake.transcribedFiles, recorder.files, "each stop transcribes the file recorded for it")
        XCTAssertEqual(fake.transcribedFiles.count, 2)
        XCTAssertNotEqual(fake.transcribedFiles[0], fake.transcribedFiles[1])
        XCTAssertEqual(fake.draftedTranscripts, ["coffee four dollars"])
        XCTAssertEqual(delivered.count, 1)
    }

    func testTryAgainAfterNotConfiguredRecordsAgain() async {
        let unconfigured = VoiceServices.openAI(
            apiKey: nil, session: .shared, today: { DartCalendar(timeZone: .current).date(2026, 9, 30) }, categoryNames: { _ in [] })
        let model = await recording(services: unconfigured)
        await stopped(model)
        assertError(model, .noSpeech, VoiceEntryError.notConfigured.message)
        XCTAssertTrue(delivered.isEmpty)

        model.tryAgain()
        await model.settle()
        XCTAssertEqual(model.stage, .recording)
        XCTAssertEqual(recorder.startCount, 2)
    }

    func testTryAgainAfterTranscribeFailureTranscribesTheSameFile() async {
        fake.transcripts = [.failure(.failed), .success("groceries forty")]
        let model = await recording()
        await stopped(model)
        assertError(model, .transcribeFailed, "Something went wrong. Try again.")

        model.tryAgain()
        XCTAssertEqual(model.stage, .processing)
        await model.settle()

        XCTAssertEqual(recorder.startCount, 1, "no re-record")
        XCTAssertEqual(fake.transcribedFiles.count, 2)
        XCTAssertEqual(fake.transcribedFiles[0], fake.transcribedFiles[1])
        XCTAssertEqual(recorder.discardCount, 0, "the file is kept for the retry")
        XCTAssertEqual(fake.draftedTranscripts, ["groceries forty"])
        XCTAssertEqual(delivered.count, 1)
    }

    func testTryAgainAfterParseFailureParsesTheSameTranscriptWithoutTranscribing() async {
        fake.drafts = [.failure(.failed), .success(FakeServices.draft)]
        let model = await recording()
        await stopped(model)
        assertError(model, .parseFailed, "Something went wrong. Try again.")

        model.tryAgain()
        XCTAssertEqual(model.stage, .processing)
        await model.settle()

        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(fake.transcribedFiles.count, 1, "not transcribed again")
        XCTAssertEqual(fake.draftedTranscripts, ["lunch at Chipotle twelve fifty", "lunch at Chipotle twelve fifty"])
        XCTAssertEqual(delivered, [FakeServices.draft])
    }

    func testRepeatedFailuresKeepShowingErrorsAndCountThem() async {
        fake.drafts = [.failure(.notATransaction(transcript: "hello"))]
        let model = await recording()
        await stopped(model)
        model.tryAgain()
        await model.settle()
        assertError(model, .parseFailed, "That didn't sound like a transaction — try again")
        XCTAssertEqual(model.errors, 2)
    }

    // MARK: Cancellation

    func testCancellingWhileTranscribingShowsNothingAndDeliversNothing() async {
        fake.gate.hold()
        let model = await recording()
        model.stop()
        await waitUntil { fake.gate.waiterCount == 1 }
        XCTAssertEqual(fake.transcribedFiles.count, 1, "the request is in flight")

        model.cancel()
        fake.transcripts = [.failure(.failed)]
        fake.gate.releaseOne()
        await model.settle()

        XCTAssertEqual(model.stage, .processing, "no error state after the sheet is gone")
        XCTAssertEqual(model.errors, 0)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(fake.draftedTranscripts.isEmpty, "a cancelled transcription does not go on to parse")
        XCTAssertGreaterThanOrEqual(recorder.discardCount, 1, "the recording is deleted")
    }

    func testCancellingWhileParsingNeverDeliversTheDraft() async {
        let model = await recording()
        fake.gate.hold()
        model.stop()
        await waitUntil { fake.gate.waiterCount == 1 }
        // The transcription is held at the gate; let it finish, then parsing waits there too.
        fake.gate.releaseOne()
        await waitUntil { fake.draftedTranscripts.count == 1 && fake.gate.waiterCount == 1 }

        model.cancel()
        fake.gate.releaseOne()
        await model.settle()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(model.errors, 0)
    }

    func testCancellingWhileRecordingStopsTheRecorderAndDeletesTheFile() async {
        let model = await recording()
        model.cancel()
        XCTAssertGreaterThanOrEqual(recorder.stopCount, 1)
        XCTAssertGreaterThanOrEqual(recorder.discardCount, 1)
        XCTAssertFalse(model.isPulsing)
        model.tick()
        XCTAssertEqual(model.stage, .recording, "cancel is final")
        model.begin()
        await model.settle()
        XCTAssertEqual(recorder.startCount, 1, "a cancelled sheet does not record")
    }

    func testCancelledRequestFailingDoesNotShowAnError() async {
        fake.gate.hold()
        fake.transcripts = [.failure(.failed)]
        let model = await recording()
        model.stop()
        await waitUntil { fake.gate.waiterCount == 1 }
        model.cancel()
        fake.gate.releaseOne()
        await model.settle()
        XCTAssertEqual(model.errors, 0)
        XCTAssertEqual(model.stage, .processing)
    }

    // MARK: Services

    func testNoKeyFailsBothStagesWithNotConfigured() async {
        let services = VoiceServices.openAI(
            apiKey: nil, session: .shared, today: { DartCalendar(timeZone: .current).date(2026, 9, 30) }, categoryNames: { _ in [] })
        do {
            _ = try await services.transcribe(URL(fileURLWithPath: "/tmp/none.m4a"))
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error, .notConfigured)
        }
        do {
            _ = try await services.draft("anything")
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error, .notConfigured)
        }
    }

    #if DEBUG
    // MARK: VoiceTestHooks

    func testStubPlanParsesAndConsumesInOrderRepeatingTheLast() {
        let json = """
            {"transcribe":[{"status":200,"text":"hello"}],
             "chat":[{"status":500},{"content":"{\\"a\\":1}","delayMs":5},{"status":429}]}
            """
        let plan = VoiceStubPlan.parse(json)
        XCTAssertEqual(plan?.transcribe, [VoiceStubResponse(status: 200, text: "hello")])
        XCTAssertEqual(plan?.chat.map(\.status), [500, 200, 429])
        XCTAssertEqual(plan?.chat[1].content, "{\"a\":1}")
        XCTAssertEqual(plan?.chat[1].delayMs, 5)

        var queue = VoiceStubQueue(plan: plan ?? .empty)
        XCTAssertEqual(queue.next(for: .chat)?.status, 500)
        XCTAssertEqual(queue.next(for: .chat)?.status, 200)
        XCTAssertEqual(queue.next(for: .chat)?.status, 429)
        XCTAssertEqual(queue.next(for: .chat)?.status, 429, "the last entry repeats")
        XCTAssertEqual(queue.next(for: .transcribe)?.text, "hello", "endpoints count separately")
        var empty = VoiceStubQueue(plan: .empty)
        XCTAssertNil(empty.next(for: .chat))
    }

    func testStubPlanRejectsMalformedJSON() {
        XCTAssertNil(VoiceStubPlan.parse("not json"))
        XCTAssertNil(VoiceStubPlan.parse("[1]"))
        XCTAssertNil(VoiceStubPlan.parse(#"{"chat":{"status":200}}"#))
        XCTAssertNil(VoiceStubPlan.parse(#"{"chat":[{"error":"meteor"}]}"#))
        XCTAssertNil(VoiceStubPlan.parse(#"{"chat":[{"status":"ok"}]}"#))
        XCTAssertEqual(VoiceStubPlan.parse("{}"), .empty)
        XCTAssertEqual(VoiceStubPlan.parse(#"{"chat":[{"error":"timeout"},{"error":"offline"}]}"#)?.chat.map(\.failure), [.timeout, .offline])
    }

    func testStubEndpointsMatchTheRealClientsURLsOnly() {
        XCTAssertEqual(VoiceStubEndpoint(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")), .transcribe)
        XCTAssertEqual(VoiceStubEndpoint(url: URL(string: "https://api.openai.com/v1/chat/completions")), .chat)
        XCTAssertNil(VoiceStubEndpoint(url: URL(string: "https://example.com/v1/chat/completions")))
        XCTAssertNil(VoiceStubEndpoint(url: URL(string: "https://api.openai.com/v1/models")))
        XCTAssertNil(VoiceStubEndpoint(url: nil))
    }

    /// The whole chain against the stub with the real `OpenAIVoiceClient`
    /// and `VoiceDraftParser`: the stub's envelope must be what the client
    /// reads, and a retry sees the next answer.
    func testStubbedSessionDrivesTheRealClientEndToEnd() async throws {
        let calendar = DartCalendar(timeZone: .current)
        let today = calendar.date(2026, 9, 30)
        let content = #"{"type":"expense","description":"Chipotle","amount":12.5,"category":"Eating Out"}"#
        let plan = VoiceStubPlan(
            transcribe: [VoiceStubResponse(text: "lunch at Chipotle twelve fifty")],
            chat: [VoiceStubResponse(status: 500), VoiceStubResponse(content: content)])
        VoiceStubProtocol.install(plan)
        defer { VoiceStubProtocol.install(.empty) }
        let services = VoiceServices.openAI(
            apiKey: VoiceTestHooks.fakeKey, session: VoiceStubProtocol.session(), today: { today },
            categoryNames: { $0 == .expense ? ["General", "Eating Out"] : ["Salary", "Other"] })

        let audio = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice_stub_\(UUID().uuidString).m4a")
        try Data([0, 1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        recorder.startResults = [.success(audio)]
        let model = VoiceEntryModel(recorder: recorder, services: services, tickInterval: .seconds(3600)) { [self] in delivered.append($0) }
        model.begin()
        await model.settle()
        await stopped(model)
        assertError(model, .parseFailed, "Something went wrong. Try again.")
        XCTAssertEqual(model.transcript, "lunch at Chipotle twelve fifty")

        model.tryAgain()
        await model.settle()
        let draft = try XCTUnwrap(delivered.first)
        XCTAssertEqual(draft.description, "Chipotle")
        XCTAssertEqual(draft.amount, 12.5)
        XCTAssertEqual(draft.category, "Eating Out")
        XCTAssertEqual(draft.type, .expense)
    }

    func testStubbedSessionAnswersOtherURLsWith599AndInjectsTimeouts() async throws {
        VoiceStubProtocol.install(VoiceStubPlan(chat: [VoiceStubResponse(failure: .timeout)]))
        defer { VoiceStubProtocol.install(.empty) }
        let session = VoiceStubProtocol.session()

        let (_, other) = try await session.data(from: XCTUnwrap(URL(string: "https://example.com/anything")))
        XCTAssertEqual((other as? HTTPURLResponse)?.statusCode, 599)

        let client = OpenAIVoiceClient(apiKey: VoiceTestHooks.fakeKey, session: session)
        do {
            _ = try await client.draftJSON(
                transcript: "x", today: DartCalendar(timeZone: .current).date(2026, 9, 30), expenseCategories: [], incomeCategories: [])
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error, .failed, "a timeout is a transport failure")
        }
    }

    func testStubAuthAndRateLimitStatusesReachTheClientAsTheirCases() async {
        VoiceStubProtocol.install(VoiceStubPlan(transcribe: [VoiceStubResponse(status: 401), VoiceStubResponse(status: 429)]))
        defer { VoiceStubProtocol.install(.empty) }
        let client = OpenAIVoiceClient(apiKey: VoiceTestHooks.fakeKey, session: VoiceStubProtocol.session())
        let audio = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice_stub_\(UUID().uuidString).m4a")
        try? Data([0]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        for expected in [VoiceEntryError.unauthorized, .rateLimited] {
            do {
                _ = try await client.transcribe(audioFile: audio)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error, expected)
            }
        }
    }
    #endif
}
