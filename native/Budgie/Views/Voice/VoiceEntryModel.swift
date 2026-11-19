import BudgieCore
import Foundation
import Observation

/// The microphone side of the sheet. `VoiceRecorder` is the real one; the
/// unit tests use a fake, so the stage machine runs without a device.
@MainActor
protocol VoiceCapturing: AnyObject {
    /// Deletes the previous recording, asks for permission when needed and
    /// starts a new one. Returns the file being written.
    func start() async throws(VoiceEntryError) -> URL
    /// Stops recording and finalises the file. Safe to call when idle.
    func stop()
    /// Deletes the current recording's file, if any.
    func discardFile()
    /// Called when the system takes the audio session away mid-recording (a
    /// phone call, Siri, an alarm). The recording is over; the file so far
    /// is kept.
    var onInterruption: (@MainActor () -> Void)? { get set }
}

/// The two network stages, injected so the stage machine never sees a
/// network. `openAI(...)` builds the real pair.
struct VoiceServices {
    var transcribe: @MainActor (URL) async throws(VoiceEntryError) -> String
    var draft: @MainActor (String) async throws(VoiceEntryError) -> VoiceDraft
    /// Releases what the stages hold (the URL session) once the flow is over.
    var finish: @MainActor () -> Void = {}

    /// A missing key (`apiKey` nil: empty, the example placeholder, or an
    /// unexpanded build setting) fails both stages with `.notConfigured`,
    /// which the sheet shows after recording, as Flutter does.
    ///
    /// `today` and `categoryNames` are read when the draft request starts
    /// (Flutter parses with `DateTime.now()` at that moment). `session` is
    /// built on the first request and `finish` invalidates it, so the sheet
    /// re-initialising leaves no session behind.
    @MainActor
    static func openAI(
        apiKey: String?, session: @autoclosure @escaping @MainActor () -> URLSession,
        today: @escaping @MainActor () -> DartDateTime,
        categoryNames: @escaping @MainActor (TransactionType) -> [String]
    ) -> VoiceServices {
        guard let apiKey else {
            return VoiceServices(
                transcribe: { _ throws(VoiceEntryError) in throw .notConfigured },
                draft: { _ throws(VoiceEntryError) in throw .notConfigured })
        }
        let connection = OpenAIConnection(apiKey: apiKey, makeSession: session)
        return VoiceServices(
            transcribe: { file throws(VoiceEntryError) in try await connection.client.transcribe(audioFile: file) },
            draft: { transcript throws(VoiceEntryError) in
                let client = connection.client
                let now = today()
                let expense = categoryNames(.expense)
                let income = categoryNames(.income)
                let output = try await client.draftJSON(
                    transcript: transcript, today: now, expenseCategories: expense, incomeCategories: income)
                return try VoiceDraftParser.parse(
                    modelOutput: output, transcript: transcript, today: now,
                    expenseCategories: expense, incomeCategories: income)
            },
            finish: { connection.invalidate() })
    }
}

/// The OpenAI client and its URL session, made on first use.
@MainActor
private final class OpenAIConnection {
    private let apiKey: String
    private let makeSession: @MainActor () -> URLSession
    private var session: URLSession?
    private var made: OpenAIVoiceClient?

    init(apiKey: String, makeSession: @escaping @MainActor () -> URLSession) {
        self.apiKey = apiKey
        self.makeSession = makeSession
    }

    var client: OpenAIVoiceClient {
        if let made { return made }
        let session = makeSession()
        self.session = session
        let client = OpenAIVoiceClient(apiKey: apiKey, session: session)
        made = client
        return client
    }

    /// Lets a request still in flight finish, then frees the session.
    func invalidate() {
        session?.finishTasksAndInvalidate()
        session = nil
        made = nil
    }
}

/// The recording sheet's stage machine (`_VoiceRecordingSheetState`,
/// voice_recording_sheet.dart:52-259): recording, processing, error, and
/// what "Try again" re-runs from the stage that failed.
///
/// One request at a time: the buttons that start work are only on screen in
/// the states that have no work in flight. `cancel()` (the sheet going away)
/// ends everything, and a request that finishes afterwards shows nothing.
@MainActor
@Observable
final class VoiceEntryModel {
    enum Stage: Equatable {
        case recording
        case processing
        case error(ErrorKind, message: String)
    }

    /// Flutter's `_ErrorKind`: what "Try again" re-runs.
    enum ErrorKind: Equatable {
        /// Record again (also: permission off, key missing, recorder failed).
        case noSpeech
        /// Transcribe the kept file again.
        case transcribeFailed
        /// Parse the kept transcript again.
        case parseFailed
    }

    /// Flutter's `_maxDuration`.
    static let defaultMaxSeconds = 30

    private(set) var stage = Stage.recording
    private(set) var secondsElapsed = 0
    /// True while the recorder is running: the mic's ping ring animates.
    private(set) var isPulsing = false
    /// The transcript kept for a parse retry; quoted under parse errors.
    private(set) var transcript: String?
    /// Haptic triggers (Flutter: medium after a recording starts, light on
    /// every stop path, `vibrate` on an error).
    private(set) var recordingStarts = 0
    private(set) var stops = 0
    private(set) var errors = 0

    let maxSeconds: Int

    @ObservationIgnored private let recorder: any VoiceCapturing
    @ObservationIgnored private let services: VoiceServices
    @ObservationIgnored private let onDraft: (VoiceDraft) -> Void
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var audioFile: URL?
    @ObservationIgnored private var didBegin = false
    @ObservationIgnored private var dismissed = false
    @ObservationIgnored private var delivered = false
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(
        recorder: any VoiceCapturing, services: VoiceServices, maxSeconds: Int = VoiceEntryModel.defaultMaxSeconds,
        tickInterval: Duration = .seconds(1), onDraft: @escaping (VoiceDraft) -> Void
    ) {
        self.recorder = recorder
        self.services = services
        self.maxSeconds = maxSeconds
        self.tickInterval = tickInterval
        self.onDraft = onDraft
        recorder.onInterruption = { [weak self] in self?.audioInterruptionBegan() }
    }

    var isProcessing: Bool { stage == .processing }

    /// `_formatElapsed`: "M:SS" of the time left, never below "0:00". Flutter
    /// always printed "0:" and the raw seconds, which only matches while the cap
    /// is under a minute (it is 30 s; `BUDGIE_VOICE_MAX_SECONDS` can raise it).
    var remainingSeconds: Int { max(0, maxSeconds - secondsElapsed) }
    var countdownText: String {
        let seconds = remainingSeconds % 60
        return String(remainingSeconds / 60) + ":" + (seconds < 10 ? "0" : "") + String(seconds)
    }

    // MARK: Lifecycle

    /// Starts recording once, when the sheet first appears.
    func begin() {
        guard !didBegin, !dismissed else { return }
        didBegin = true
        startRecording()
    }

    /// The sheet is going away (Cancel, drag, scrim, success): stop the
    /// recorder, drop any request in flight and delete the file.
    func cancel() {
        dismissed = true
        startTask?.cancel()
        work?.cancel()
        timer?.cancel()
        isPulsing = false
        recorder.stop()
        recorder.discardFile()
        audioFile = nil
        services.finish()
    }

    /// The app went to the background (`AppLifecycleState.paused`): stop and
    /// go on with what was recorded.
    func appDidEnterBackground() {
        if stage == .recording { stop() }
    }

    /// The system interrupted the audio session (a call, Siri): the same as
    /// going to the background. Flutter has no handling; the timer would
    /// keep counting over a paused recorder.
    func audioInterruptionBegan() {
        if stage == .recording { stop() }
    }

    /// Waits for the work in flight. For tests.
    func settle() async {
        await startTask?.value
        await work?.value
    }

    // MARK: Recording

    private func startRecording() {
        startTask = Task { await runStartRecording() }
    }

    /// `_startRecording`. A failure to record is shown as a no-speech error
    /// (Try again records again); Flutter lets the exception escape and
    /// leaves the sheet listening with no timer.
    private func runStartRecording() async {
        let file: URL
        do {
            file = try await recorder.start()
        } catch {
            guard isLive else { return }
            audioFile = nil
            showError(.noSpeech, error.message)
            return
        }
        guard isLive, stage == .recording else {
            // Stop (or dismissal) came in while permission or the recorder
            // was pending: nothing should keep running.
            recorder.stop()
            recorder.discardFile()
            return
        }
        audioFile = file
        recordingStarts += 1
        isPulsing = true
        secondsElapsed = 0
        startTimer()
    }

    private func startTimer() {
        timer?.cancel()
        let interval = tickInterval
        timer = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            var count: Int64 = 0
            while !Task.isCancelled {
                count += 1
                try? await clock.sleep(until: start + interval * count)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// One second of recording (the 1 s `Timer.periodic`): at the cap, stop
    /// and go on.
    func tick() {
        guard stage == .recording else { return }
        secondsElapsed += 1
        if secondsElapsed >= maxSeconds { stop() }
    }

    /// `_stopAndProcess`: the Stop button, the cap and the background all
    /// end up here.
    func stop() {
        guard stage == .recording else { return }
        stage = .processing
        timer?.cancel()
        isPulsing = false
        stops += 1
        work = Task {
            recorder.stop()
            guard isLive else { return }
            await transcribeAndParse()
        }
    }

    // MARK: Pipeline

    /// `_transcribeAndParse`. Empty speech and a missing key (Flutter's
    /// `VoiceExpenseException`) re-record; any other transcription failure
    /// re-transcribes the same file.
    private func transcribeAndParse() async {
        guard let file = audioFile else {
            showError(.noSpeech, VoiceEntryError.noSpeech.message)
            return
        }
        let text: String
        do {
            text = try await services.transcribe(file)
        } catch {
            guard isLive else { return }
            switch error {
            case .noSpeech, .notConfigured, .microphoneDenied: showError(.noSpeech, error.message)
            default: showError(.transcribeFailed, error.message)
            }
            return
        }
        guard isLive else { return }
        transcript = text
        await parse(text)
    }

    /// `_parseTranscript`: every failure here is a parse-stage error, which
    /// quotes the sheet's own transcript.
    private func parse(_ text: String) async {
        do {
            let draft = try await services.draft(text)
            guard isLive, !delivered else { return }
            delivered = true
            onDraft(draft)
        } catch {
            guard isLive else { return }
            showError(.parseFailed, error.message)
        }
    }

    private func showError(_ kind: ErrorKind, _ message: String) {
        errors += 1
        isPulsing = false
        stage = .error(kind, message: message)
    }

    // MARK: Retry

    /// `_retry`.
    func tryAgain() {
        guard case .error(let kind, _) = stage, isLive else { return }
        switch kind {
        case .noSpeech:
            restartRecording()
        case .transcribeFailed:
            stage = .processing
            work = Task { await transcribeAndParse() }
        case .parseFailed:
            guard let transcript else {
                restartRecording()
                return
            }
            stage = .processing
            work = Task { await parse(transcript) }
        }
    }

    private func restartRecording() {
        stage = .recording
        secondsElapsed = 0
        transcript = nil
        startRecording()
    }

    /// Not dismissed and not cancelled: safe to show what came back.
    private var isLive: Bool { !dismissed && !Task.isCancelled }
}
