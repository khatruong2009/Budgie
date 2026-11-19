import AVFoundation
import BudgieCore

/// Records one voice note at a time (the `record` package's `AudioRecorder`
/// as `voice_recording_sheet.dart` configures it): AAC-LC, 16 kHz, mono,
/// 32 kbps, to `<tmp>/voice_expense_<ms>.m4a`. The 30 s cap is the stage
/// machine's timer; this only records.
///
/// The file outlives `stop()` so a failed transcription can be retried on
/// it; the previous file goes when the next recording starts (along with any
/// left in the temporary directory by a process that was killed), and
/// `discardFile()` deletes the last one when the sheet goes away.
@MainActor
final class VoiceRecorder: VoiceCapturing {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var sessionActive = false
    private var interruptionObserver: (any NSObjectProtocol)?

    /// Set by the stage machine: the system took the audio session away
    /// (`AVAudioSession.interruptionNotification`, type `.began`).
    var onInterruption: (@MainActor () -> Void)?

    private static let filePrefix = "voice_expense_"

    /// `hasPermission()` with the request: shows the system prompt when the
    /// choice is still open. Denied and restricted both read as denied.
    func start() async throws(VoiceEntryError) -> URL {
        #if DEBUG
        if VoiceTestHooks.micDenied { throw .microphoneDenied }
        #endif
        stop()
        discardFile()
        Self.sweepStaleFiles()

        #if DEBUG
        if let fixture = VoiceTestHooks.audioFile {
            let url = Self.newFileURL()
            do {
                try FileManager.default.copyItem(at: fixture, to: url)
            } catch {
                throw .failed
            }
            fileURL = url
            return url
        }
        #endif

        switch AVAudioApplication.shared.recordPermission {
        case .granted: break
        case .denied: throw .microphoneDenied
        default:
            guard await AVAudioApplication.requestRecordPermission() else { throw .microphoneDenied }
        }
        // The sheet may have gone away while the prompt was up.
        guard !Task.isCancelled else { throw .failed }

        let url = Self.newFileURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            // Without this iOS mutes haptics while the mic is live, and the
            // start haptic (fired just after this) would be lost.
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
            sessionActive = true
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            fileURL = url
            guard recorder.record() else {
                releaseSession()
                throw VoiceEntryError.failed
            }
            self.recorder = recorder
            observeInterruptions()
        } catch let error as VoiceEntryError {
            throw error
        } catch {
            releaseSession()
            throw .failed
        }
        return url
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        releaseSession()
    }

    func discardFile() {
        guard let fileURL else { return }
        self.fileURL = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// A call, Siri or an alarm taking the session ends the recording; the
    /// stage machine stops and goes on with what there is.
    private func observeInterruptions() {
        removeInterruptionObserver()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.onInterruption?() }
        }
    }

    private func removeInterruptionObserver() {
        guard let interruptionObserver else { return }
        self.interruptionObserver = nil
        NotificationCenter.default.removeObserver(interruptionObserver)
    }

    /// Lets other audio (music, a call) come back once the mic is done.
    private func releaseSession() {
        removeInterruptionObserver()
        guard sessionActive else { return }
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Recordings a killed process left in the temporary directory.
    private static func sweepStaleFiles() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(filePrefix) && name.hasSuffix(".m4a") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// `voice_expense_<epoch ms>.m4a` in the temporary directory. The clock
    /// read only names a scratch file; nothing stored derives from it.
    private static func newFileURL() -> URL {
        let millis = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(filePrefix)\(millis).m4a")
    }
}
