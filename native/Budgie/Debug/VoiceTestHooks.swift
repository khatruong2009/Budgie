#if DEBUG
import Foundation
import os

/// Debug-only launch hooks for voice entry, so UI tests and screenshots
/// never use the real microphone or the network. Read from the launch
/// environment (`XCUIApplication.launchEnvironment`):
///
/// - `BUDGIE_VOICE_AUDIO_FILE=<absolute path>`: no permission prompt and no
///   `AVAudioRecorder`; a copy of that file is the recording. Countdown,
///   Stop and the cap still run.
/// - `BUDGIE_VOICE_MIC_DENIED=1`: the microphone is denied, without a
///   system alert.
/// - `BUDGIE_VOICE_MAX_SECONDS=<n>`: replaces the 30 s cap.
/// - `BUDGIE_VOICE_STUB=<json>`: the OpenAI calls are answered from the
///   JSON (see `VoiceStubPlan`) with the fake key `ui-test-key`, and nothing
///   else reaches the network: any other URL answers 599.
///
/// Release builds contain none of this.
enum VoiceTestHooks {
    static let fakeKey = "ui-test-key"

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var audioFile: URL? {
        guard let path = environment["BUDGIE_VOICE_AUDIO_FILE"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var micDenied: Bool { environment["BUDGIE_VOICE_MIC_DENIED"] == "1" }

    static var maxSeconds: Int? {
        guard let text = environment["BUDGIE_VOICE_MAX_SECONDS"], let seconds = Int(text), seconds > 0 else { return nil }
        return seconds
    }

    static var stubbing: Bool { environment["BUDGIE_VOICE_STUB"] != nil }

    /// The stubbed session when `BUDGIE_VOICE_STUB` is set. The plan is
    /// installed once per process, so its response lists keep being consumed
    /// across sheets. A stub that is not valid JSON answers everything 599.
    static var stubbedSession: URLSession? {
        guard let json = environment["BUDGIE_VOICE_STUB"] else { return nil }
        installOnce(json)
        return VoiceStubProtocol.session()
    }

    private static let installedJSON = OSAllocatedUnfairLock<String?>(initialState: nil)

    private static func installOnce(_ json: String) {
        installedJSON.withLock { current in
            guard current == nil else { return }
            current = json
            VoiceStubProtocol.install(VoiceStubPlan.parse(json) ?? .empty)
        }
    }
}

/// Which of the two OpenAI calls a request is.
enum VoiceStubEndpoint: Hashable, Sendable {
    case transcribe, chat

    /// Matches `OpenAIVoiceClient`'s two URLs; anything else is nil.
    init?(url: URL?) {
        guard let url, url.host == "api.openai.com" else { return nil }
        switch url.path {
        case "/v1/audio/transcriptions": self = .transcribe
        case "/v1/chat/completions": self = .chat
        default: return nil
        }
    }
}

/// One canned answer.
struct VoiceStubResponse: Equatable, Sendable {
    enum Failure: String, Sendable {
        /// `URLError.timedOut`.
        case timeout
        /// `URLError.notConnectedToInternet`.
        case offline
    }

    var status = 200
    /// The transcription text (`{"text": ...}`).
    var text: String?
    /// The assistant message content of a chat reply.
    var content: String?
    /// The whole body as is, in place of the envelope (a malformed reply).
    var body: String?
    /// A transport failure in place of any reply.
    var failure: Failure?
    /// Waits this long before answering (holds the THINKING state).
    var delayMs = 0

    /// The 2xx envelope the real API sends and `OpenAIVoiceClient` reads:
    /// `{"text": ...}` for a transcription, `{"choices":[{"message":
    /// {"role":"assistant","content": ...}}]}` for a chat completion. A
    /// non-2xx status carries an OpenAI-style error object.
    func data(for endpoint: VoiceStubEndpoint) -> Data {
        if let body { return Data(body.utf8) }
        let object: [String: Any]
        if !(200..<300).contains(status) {
            object = ["error": ["message": "stubbed \(status)"]]
        } else {
            switch endpoint {
            case .transcribe:
                object = ["text": text ?? ""]
            case .chat:
                let message: [String: Any] = ["role": "assistant", "content": content ?? NSNull()]
                object = ["choices": [["index": 0, "message": message]]]
            }
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

/// The parsed `BUDGIE_VOICE_STUB`:
///
///     {"transcribe":[{"status":200,"text":"lunch at Chipotle twelve fifty"}],
///      "chat":[{"status":500},{"status":200,"content":"{\"type\":\"expense\",...}"}]}
///
/// Each list is consumed in order and its last entry repeats. An entry takes
/// `status` (default 200), `text`, `content`, `body`, `error`
/// ("timeout" or "offline") and `delayMs`. An endpoint with no list answers 599.
struct VoiceStubPlan: Equatable, Sendable {
    var transcribe: [VoiceStubResponse] = []
    var chat: [VoiceStubResponse] = []

    static let empty = VoiceStubPlan()

    /// nil when the text is not a JSON object or an entry is malformed.
    static func parse(_ json: String) -> VoiceStubPlan? {
        guard
            let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return nil }
        var plan = VoiceStubPlan()
        for (key, keyPath) in [("transcribe", \VoiceStubPlan.transcribe), ("chat", \VoiceStubPlan.chat)] {
            guard let raw = root[key] else { continue }
            guard let entries = raw as? [[String: Any]] else { return nil }
            var responses: [VoiceStubResponse] = []
            for entry in entries {
                guard let response = response(from: entry) else { return nil }
                responses.append(response)
            }
            plan[keyPath: keyPath] = responses
        }
        return plan
    }

    private static func response(from entry: [String: Any]) -> VoiceStubResponse? {
        var response = VoiceStubResponse()
        if let status = entry["status"] {
            guard let status = status as? Int else { return nil }
            response.status = status
        }
        response.text = entry["text"] as? String
        response.content = entry["content"] as? String
        response.body = entry["body"] as? String
        if let name = entry["error"] {
            guard let name = name as? String, let failure = VoiceStubResponse.Failure(rawValue: name) else { return nil }
            response.failure = failure
        }
        if let delay = entry["delayMs"] {
            guard let delay = delay as? Int, delay >= 0 else { return nil }
            response.delayMs = delay
        }
        return response
    }
}

/// A plan being consumed: the next answer per endpoint, the last repeating.
struct VoiceStubQueue: Sendable {
    let plan: VoiceStubPlan
    private var counts: [VoiceStubEndpoint: Int] = [:]

    init(plan: VoiceStubPlan) { self.plan = plan }

    mutating func next(for endpoint: VoiceStubEndpoint) -> VoiceStubResponse? {
        let list = endpoint == .transcribe ? plan.transcribe : plan.chat
        defer { counts[endpoint, default: 0] += 1 }
        return list.isEmpty ? nil : list[min(counts[endpoint, default: 0], list.count - 1)]
    }
}

/// Answers every request of a session from the installed plan. Requests
/// that are not one of the two OpenAI calls get a 599, so a leak shows up
/// as a failure instead of traffic.
final class VoiceStubProtocol: URLProtocol, @unchecked Sendable {
    private static let queue = OSAllocatedUnfairLock(initialState: VoiceStubQueue(plan: .empty))
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    /// Replaces the plan and restarts its lists.
    static func install(_ plan: VoiceStubPlan) {
        queue.withLock { $0 = VoiceStubQueue(plan: plan) }
    }

    /// An ephemeral session that this protocol answers.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url
        let response = VoiceStubEndpoint(url: url).flatMap { endpoint in
            Self.queue.withLock { $0.next(for: endpoint) }.map { (endpoint, $0) }
        }
        guard let (endpoint, answer) = response else {
            deliver(url: url, status: 599, data: Data(), failure: nil)
            return
        }
        let send: @Sendable () -> Void = { self.deliver(url: url, status: answer.status, data: answer.data(for: endpoint), failure: answer.failure) }
        if answer.delayMs > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(answer.delayMs), execute: send)
        } else {
            send()
        }
    }

    override func stopLoading() {
        cancelled.withLock { $0 = true }
    }

    private func deliver(url: URL?, status: Int, data: Data, failure: VoiceStubResponse.Failure?) {
        guard !cancelled.withLock({ $0 }) else { return }
        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure == .timeout ? .timedOut : .notConnectedToInternet))
            return
        }
        let http = HTTPURLResponse(
            url: url ?? URL(fileURLWithPath: "/"), statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])
        if let http { client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
