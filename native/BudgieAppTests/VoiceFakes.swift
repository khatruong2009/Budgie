import BudgieCore
import XCTest

@testable import Runner

/// A recorder that records nothing: it hands out a file URL per `start()`
/// and counts what the stage machine asks of it.
@MainActor
final class FakeRecorder: VoiceCapturing {
    var startResults: [Result<URL, VoiceEntryError>] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var discardCount = 0
    private(set) var files: [URL] = []
    var onInterruption: (@MainActor () -> Void)?

    func start() async throws(VoiceEntryError) -> URL {
        startCount += 1
        if !startResults.isEmpty {
            switch startResults.removeFirst() {
            case .success(let url):
                files.append(url)
                return url
            case .failure(let error): throw error
            }
        }
        let url = URL(fileURLWithPath: "/tmp/voice_expense_\(startCount).m4a")
        files.append(url)
        return url
    }

    func stop() { stopCount += 1 }
    func discardFile() { discardCount += 1 }
}

/// Fake network stages: each call takes the next scripted outcome (the last
/// repeats) and records its argument.
@MainActor
final class Gate {
    private(set) var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

    func hold() { isHeld = true }

    func wait() async {
        guard isHeld else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseOne() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

@MainActor
final class FakeServices {
    var transcripts: [Result<String, VoiceEntryError>] = [.success("lunch at Chipotle twelve fifty")]
    var drafts: [Result<VoiceDraft, VoiceEntryError>] = [.success(FakeServices.draft)]
    private(set) var transcribedFiles: [URL] = []
    private(set) var draftedTranscripts: [String] = []
    /// While held, both stages wait for `releaseOne()` before answering.
    let gate = Gate()

    static let draft = VoiceDraft(
        type: .expense, description: "Chipotle", amount: 12.5, category: "Eating Out",
        date: DartCalendar(timeZone: .current).date(2026, 9, 30))

    var services: VoiceServices {
        VoiceServices(
            transcribe: { [self] file throws(VoiceEntryError) in
                transcribedFiles.append(file)
                await gate.wait()
                return try next(&transcripts).get()
            },
            draft: { [self] transcript throws(VoiceEntryError) in
                draftedTranscripts.append(transcript)
                await gate.wait()
                return try next(&drafts).get()
            })
    }

    private func next<T>(_ list: inout [Result<T, VoiceEntryError>]) -> Result<T, VoiceEntryError> {
        list.count > 1 ? list.removeFirst() : list[0]
    }
}
