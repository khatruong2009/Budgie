import BudgieCore
import SwiftUI

/// The voice recording sheet (`_VoiceRecordingSheet`,
/// voice_recording_sheet.dart:261-514): LISTENING with the pulsing mic, the
/// countdown and Stop; THINKING while the recording is transcribed and
/// read; an error with Cancel and Try again. Records as soon as it appears.
///
/// It brings its own chrome, content-measured detent and dismissal lock
/// (not dismissible while THINKING), so the host only swaps it for the
/// prefilled form when `onDraft` fires and closes the flow on `onCancel`.
/// Any way of leaving (Cancel, drag, scrim, the host replacing it) stops the
/// recorder, drops a request in flight and deletes the recording.
struct VoiceRecordingSheet: View {
    let onDraft: (VoiceDraft) -> Void
    let onCancel: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        VoiceSheetBody(model: model, onDraft: onDraft, onCancel: onCancel)
    }
}

/// Builds the stage machine once (`@State`) from the app model.
private struct VoiceSheetBody: View {
    let onCancel: () -> Void

    @State private var entry: VoiceEntryModel
    @State private var contentHeight: CGFloat = 0

    init(model: AppModel, onDraft: @escaping (VoiceDraft) -> Void, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        let (apiKey, makeSession, maxSeconds) = Self.networking()
        // SwiftUI may run this init again and keep only the first `entry`,
        // so nothing here may hold a resource: the session is made on the
        // first request and released by `entry.cancel()`.
        let services = VoiceServices.openAI(
            apiKey: apiKey, session: makeSession(),
            today: { model.now },
            categoryNames: { type in model.categories(for: type).map(\.name) })
        _entry = State(
            initialValue: VoiceEntryModel(
                recorder: VoiceRecorder(), services: services, maxSeconds: maxSeconds, onDraft: onDraft))
    }

    /// The key from the bundle (nil when not configured), how to make an
    /// ephemeral session and the recording cap; Debug launch hooks replace
    /// them.
    private static func networking() -> (apiKey: String?, makeSession: @MainActor () -> URLSession, maxSeconds: Int) {
        #if DEBUG
        let maxSeconds = VoiceTestHooks.maxSeconds ?? VoiceEntryModel.defaultMaxSeconds
        if VoiceTestHooks.stubbing {
            return (VoiceTestHooks.fakeKey, { VoiceTestHooks.stubbedSession ?? URLSession(configuration: .ephemeral) }, maxSeconds)
        }
        #else
        let maxSeconds = VoiceEntryModel.defaultMaxSeconds
        #endif
        return (
            OpenAIVoiceClient.apiKey(fromInfoDictionary: Bundle.main.infoDictionary),
            { URLSession(configuration: .ephemeral) }, maxSeconds
        )
    }

    var body: some View {
        ScrollView {
            content
                .padding(
                    EdgeInsets(
                        top: Self.topPadding, leading: Metrics.spacingL, bottom: Self.bottomPadding,
                        trailing: Metrics.spacingL))
                .frame(maxWidth: .infinity)
                .onGeometryChangeCompat { contentHeight = $0.height }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollClipDisabled()
        .budgieSheetChrome()
        .presentationDetents([
            .height(BudgetSheetLayout.height(measured: contentHeight, estimate: estimatedHeight))
        ])
        .interactiveDismissDisabled(entry.isProcessing)
        .sensoryFeedback(.impact(weight: .medium), trigger: entry.recordingStarts)
        .sensoryFeedback(.impact(weight: .light), trigger: entry.stops)
        .sensoryFeedback(.error, trigger: entry.errors)
        .onAppear { entry.begin() }
        .onDisappear { entry.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            entry.appDidEnterBackground()
        }
        .onChange(of: entry.stage) { _, stage in announce(stage) }
        .onChange(of: entry.remainingSeconds) { _, seconds in
            if seconds == 10, entry.stage == .recording {
                AccessibilityNotification.Announcement("10 seconds left").post()
            }
        }
    }

    // MARK: Stages

    /// The chrome's handle block is 20pt; Flutter puts the first line 56pt
    /// below the top (24 + the 4pt handle + 28).
    private static let topPadding: CGFloat = 36

    /// Flutter leaves 24 under the buttons plus the safe area. The detent
    /// already includes the system's own allowance under the content, which
    /// measured 6pt more than Flutter's with a full 24 (QA, iPhone 17 Pro
    /// class), so the padding gives that much back.
    private static let bottomPadding = Metrics.spacingL - 6

    @ViewBuilder
    private var content: some View {
        switch entry.stage {
        case .recording: recording
        case .processing: processing
        case .error(let kind, let message): error(kind: kind, message: message)
        }
    }

    private var recording: some View {
        VStack(spacing: Metrics.sectionGap) {
            eyebrow("LISTENING")
            PulsingMic(pulsing: entry.isPulsing)
            Text(entry.countdownText)
                .textStyle(.numericMedium)
                .foregroundStyle(BudgieColor.textSecondary)
                .accessibilityLabel(
                    entry.remainingSeconds == 1 ? "1 second remaining" : "\(entry.remainingSeconds) seconds remaining")
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("voice.countdown")
            PillButton(
                title: "Stop", symbol: "stop", filled: true, minHeight: Metrics.pillButtonHeight
            ) { entry.stop() }
            .accessibilityIdentifier("voice.stop")
        }
    }

    private var processing: some View {
        VStack(spacing: Metrics.sectionGap) {
            eyebrow("THINKING")
            ThinkingSpinner()
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)
            Text("Making sense of it...")
                .textStyle(Self.blurbText)
                .foregroundStyle(BudgieColor.textSecondary)
        }
    }

    private func error(kind: VoiceEntryModel.ErrorKind, message: String) -> some View {
        VStack(spacing: 0) {
            // Flutter's 48pt `error_rounded` draws about 40pt inside its box;
            // an SF symbol at 48 fills the box, so draw it smaller.
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 40, weight: .regular))
                .frame(width: Metrics.iconXL, height: Metrics.iconXL)
                .foregroundStyle(BudgieColor.danger)
                .accessibilityHidden(true)
            Text(message)
                .textStyle(.sheetTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
                .accessibilityIdentifier("voice.message")
            if kind == .parseFailed, let transcript = entry.transcript {
                Text("\"\(transcript)\"")
                    .textStyle(Self.blurbText)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .accessibilityIdentifier("voice.transcript")
            }
            // The sheet pattern: the main action as a full-width filled
            // pill, the secondary one outlined under it.
            VStack(spacing: 12) {
                PillButton(
                    title: "Try again", filled: true, minHeight: Metrics.pillButtonHeight
                ) { entry.tryAgain() }
                .accessibilityIdentifier("voice.tryAgain")
                PillButton(
                    title: "Cancel", color: BudgieColor.textPrimary, minHeight: Metrics.pillButtonHeight
                ) { onCancel() }
                .accessibilityIdentifier("voice.cancel")
            }
            .padding(.top, Metrics.sectionGap)
        }
    }

    /// The 14pt secondary blurb of the sheet pattern.
    private static let blurbText = TextSpec(face: .gabaritoRegular, size: 14, relativeTo: .subheadline)

    private func eyebrow(_ title: String) -> some View {
        Text(title)
            .textStyle(.eyebrow)
            .foregroundStyle(BudgieColor.accent)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Height

    /// The content's height at the default text size, so the sheet opens at
    /// its final height instead of resizing once measured. Every line is
    /// `round(size * height)` (`textStyle`): eyebrow 13, countdown 29, note
    /// 17, message 29 a line (about 26 characters). Recording: 36, 13, 28,
    /// the 120 mic, 28, 29, 28, Stop 52, the bottom padding. Thinking: 36,
    /// 13, 28, 120, 28, 17, bottom. Error: 36, the 48 icon, 20, the message,
    /// 28, the two 52 pills 12 apart, bottom.
    private var estimatedHeight: CGFloat {
        switch entry.stage {
        case .recording: 36 + 13 + 28 + 120 + 28 + 29 + 28 + 52 + Self.bottomPadding
        case .processing: 36 + 13 + 28 + 120 + 28 + 17 + Self.bottomPadding
        case .error(_, let message): 36 + 48 + 20 + CGFloat((message.count + 25) / 26) * 29 + 28 + 52 + 12 + 52 + Self.bottomPadding
        }
    }

    // MARK: VoiceOver

    /// Flutter says nothing on a state change; VoiceOver users lose the
    /// button they were on, so say where they are.
    private func announce(_ stage: VoiceEntryModel.Stage) {
        switch stage {
        case .recording: AccessibilityNotification.Announcement("Listening").post()
        case .processing: AccessibilityNotification.Announcement("Making sense of it").post()
        case .error(_, let message): AccessibilityNotification.Announcement(message).post()
        }
    }
}

/// The 88pt accent mic in a 120pt box (`_buildPulsingMic`) and, while
/// recording, a 2pt ring that grows to 1.7x and fades over 1.4 s, repeating.
/// Reduce Motion keeps the mic and drops the ring.
private struct PulsingMic: View {
    let pulsing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var origin = Date.now

    /// `_pulse`: 1400 ms, `.repeat()`.
    private static let period = 1.4

    var body: some View {
        ZStack {
            if !reduceMotion {
                // Before the recorder runs the ring rests at scale 1, alpha
                // 0.55, hugging the circle (Flutter's stopped controller).
                TimelineView(.animation(paused: !pulsing)) { context in
                    let elapsed = context.date.timeIntervalSince(origin)
                    let phase = pulsing ? elapsed.truncatingRemainder(dividingBy: Self.period) / Self.period : 0
                    let ping = FlutterCurve.easeOut(phase)
                    Circle()
                        .strokeBorder(BudgieColor.accent.opacity(0.55 * (1 - ping)), lineWidth: Metrics.borderThick)
                        .frame(width: 88, height: 88)
                        .scaleEffect(1 + 0.7 * ping)
                }
                .allowsHitTesting(false)
            }
            Circle()
                .fill(BudgieColor.accent)
                .frame(width: 88, height: 88)
            Image(systemName: "mic.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(BudgieColor.onAccent)
        }
        .frame(width: 120, height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
        .onChange(of: pulsing) { _, isPulsing in
            if isPulsing { origin = .now }
        }
    }
}

/// `CircularProgressIndicator(strokeWidth: 3)` at 56pt in the accent: an
/// arc that turns and breathes. Under Reduce Motion the arc keeps a steady
/// length and turns slowly; it is the only sign that work is going on.
private struct ThinkingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let turns = time / (reduceMotion ? 2.4 : 1.4)
            let sweep = reduceMotion ? 0.7 : 0.1 + 0.65 * (0.5 - 0.5 * cos(2 * .pi * time / 1.333))
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(BudgieColor.accent, lineWidth: 3)
                .rotationEffect(.degrees(turns.truncatingRemainder(dividingBy: 1) * 360 - 90))
                .frame(width: 56, height: 56)
        }
    }
}
