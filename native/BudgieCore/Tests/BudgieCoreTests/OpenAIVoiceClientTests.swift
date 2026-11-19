import Foundation
import Testing

@testable import BudgieCore

/// A URLProtocol that answers from a per-test script and records what it saw.
/// Tests run in parallel, so each test's session carries its own token in a
/// session-level header and the stub looks the script up by that token. No
/// request ever leaves the process.
final class VoiceStubProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case respond(status: Int, body: Data)
        case fail(URLError.Code)
        /// Never answers; the request ends only when the task is cancelled.
        case hang
    }

    struct Recorded {
        let method: String?
        let url: URL?
        let headers: [String: String]
        let body: Data
    }

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [Recorded] = []
        let outcome: Outcome
        init(_ outcome: Outcome) { self.outcome = outcome }
        func record(_ request: Recorded) { lock.withLock { _requests.append(request) } }
        var requests: [Recorded] { lock.withLock { _requests } }
    }

    static let tokenHeader = "X-Stub-Token"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]

    static func makeSession(_ outcome: Outcome) -> (URLSession, Script) {
        let token = UUID().uuidString
        let script = Script(outcome)
        lock.withLock { scripts[token] = script }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceStubProtocol.self]
        configuration.httpAdditionalHeaders = [tokenHeader: token]
        return (URLSession(configuration: configuration), script)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let headers = request.allHTTPHeaderFields ?? [:]
        guard let token = headers[Self.tokenHeader],
            let script = Self.lock.withLock({ Self.scripts[token] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        script.record(Recorded(method: request.httpMethod, url: request.url, headers: headers, body: body))

        switch script.outcome {
        case .respond(let status, let data):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}
}

/// Wednesday 2026-09-30, 14:05 in New York.
private let wednesday = DartDateTime(2026, 9, 30, 14, 5, timeZone: newYorkZone)!

private func json(_ text: String) -> Data { Data(text.utf8) }

private func chatReply(content: String) -> Data {
    let escaped = String(data: try! JSONSerialization.data(withJSONObject: [content]), encoding: .utf8)!
    let quoted = String(escaped.dropFirst().dropLast())
    return json(#"{"choices":[{"index":0,"message":{"role":"assistant","content":\#(quoted)}}]}"#)
}

private func voiceError<T>(_ operation: () async throws(VoiceEntryError) -> T) async -> VoiceEntryError? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}

/// A recorded clip on disk, removed by the caller.
private func makeAudioFile(_ bytes: [UInt8] = [0x00, 0x01, 0xFE, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D, 0x80]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
    try Data(bytes).write(to: url)
    return url
}

@Suite("OpenAIVoiceClient")
struct OpenAIVoiceClientTests {
    // MARK: System prompt

    @Test("system prompt is byte-identical to Flutter's for the built-in categories")
    func systemPromptPinned() {
        let expected = """
            You extract a single personal-finance transaction from a spoken phrase and return JSON only.

            Today is 2026-09-30 (Wednesday), the device's local date. Resolve relative dates like "yesterday", "last Tuesday", or "two days ago" against it.

            Return exactly this JSON shape:
            {"type","description","amount","category","date"}

            Fields:
            - "type": either "expense" or "income". Default to "expense" unless the phrase clearly describes money coming in (for example "got paid", "salary", "received", "refund", "deposit"), in which case use "income".
            - "description": a short merchant or purpose label from the phrase.
            - "amount": a number. Spoken amounts map to decimals — "twelve fifty" means 12.50, "three thousand" means 3000. If no amount is stated, use 0.
            - "category": for expenses pick exactly one of: General, Eating Out, Groceries, Housing, Transportation, Travel, Clothing, Gift, Health, Entertainment, Pets, Family, Loan Payment. For income pick exactly one of: Salary, Investment, Gift, Other. Choose the closest match.
            - "date": an ISO-8601 date (YYYY-MM-DD). Default to today (2026-09-30). Use a different date only when the phrase explicitly says when the money was spent (for example "yesterday", "last Friday", "on the 3rd"). When the phrase mentions the date of an upcoming trip, stay, or event ("flights for next month", "hotel for our trip in September"), that is NOT the transaction date — the payment is happening now, so use today. Never return a date in the future, and never replace a future reference with the same date in an earlier year.

            If the phrase is not describing a transaction at all, return {"error":"not_a_transaction"}.
            """
        let actual = OpenAIVoiceClient.systemPrompt(
            today: wednesday, expenseCategories: flutterExpenseNames, incomeCategories: flutterIncomeNames)
        #expect(actual == expected)
        // No trailing newline, em dashes intact.
        #expect(!actual.hasSuffix("\n"))
        #expect(actual.contains("\u{2014}"))
    }

    @Test("system prompt uses the passed category lists and the date's weekday")
    func systemPromptCustomLists() {
        let friday = DartDateTime(2026, 1, 2, timeZone: TimeZone(identifier: "UTC")!)!
        let prompt = OpenAIVoiceClient.systemPrompt(
            today: friday, expenseCategories: ["Coffee", "Rent"], incomeCategories: ["Bonus"])
        #expect(prompt.contains("Today is 2026-01-02 (Friday), the device's local date."))
        #expect(prompt.contains("pick exactly one of: Coffee, Rent. For income pick exactly one of: Bonus. Choose"))
    }

    // MARK: Transcription

    @Test("transcribe posts the multipart request and returns the trimmed text")
    func transcribeRequest() async throws {
        let (session, script) = VoiceStubProtocol.makeSession(
            .respond(status: 200, body: json(#"{"text":"  spent twelve fifty at Blue Bottle \n"}"#)))
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let bytes = try Data(contentsOf: audio)

        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        let transcript = try await client.transcribe(audioFile: audio)
        #expect(transcript == "spent twelve fifty at Blue Bottle")

        let recorded = try #require(script.requests.first)
        #expect(script.requests.count == 1)
        #expect(recorded.method == "POST")
        #expect(recorded.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(recorded.headers["Authorization"] == "Bearer test-key")

        let contentType = try #require(recorded.headers["Content-Type"])
        let prefix = "multipart/form-data; boundary="
        #expect(contentType.hasPrefix(prefix))
        let boundary = String(contentType.dropFirst(prefix.count))
        #expect(boundary.hasPrefix("BudgieBoundary-"))

        var expected = Data()
        expected.append(
            Data(
                ("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n"
                    + "--\(boundary)\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n"
                    + "Personal expense phrases with dollar amounts like $12.50 and merchant names.\r\n"
                    + "--\(boundary)\r\nContent-Type: application/octet-stream\r\n"
                    + "Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\n\r\n").utf8))
        expected.append(bytes)
        expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
        #expect(recorded.body == expected)
    }

    @Test("transcribe sends no retry: one request per call, even on failure")
    func transcribeSingleAttempt() async throws {
        let (session, script) = VoiceStubProtocol.makeSession(.respond(status: 500, body: json("{}")))
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        #expect(await voiceError { () async throws(VoiceEntryError) in try await client.transcribe(audioFile: audio) } == .failed)
        #expect(script.requests.count == 1)
    }

    @Test("empty transcript is .noSpeech", arguments: [#"{"text":""}"#, #"{"text":"   \n\t "}"#, "{\"text\":\"\u{FEFF} \u{A0}\"}"])
    func noSpeech(body: String) async throws {
        let (session, _) = VoiceStubProtocol.makeSession(.respond(status: 200, body: json(body)))
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        #expect(await voiceError { () async throws(VoiceEntryError) in try await client.transcribe(audioFile: audio) } == .noSpeech)
    }

    @Test("transcribe: malformed or wrong-shaped body is .failed", arguments: ["not json", "", "[]", #"{"nope":1}"#, #"{"text":5}"#])
    func transcribeMalformed(body: String) async throws {
        let (session, _) = VoiceStubProtocol.makeSession(.respond(status: 200, body: json(body)))
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        #expect(await voiceError { () async throws(VoiceEntryError) in try await client.transcribe(audioFile: audio) } == .failed)
    }

    @Test("transcribe: a missing audio file is .failed and sends nothing")
    func missingAudioFile() async {
        let (session, script) = VoiceStubProtocol.makeSession(.respond(status: 200, body: json(#"{"text":"hi"}"#)))
        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).m4a")
        #expect(await voiceError { () async throws(VoiceEntryError) in try await client.transcribe(audioFile: missing) } == .failed)
        #expect(script.requests.isEmpty)
    }

    // MARK: Chat

    @Test("draftJSON posts the chat request and returns the message content")
    func chatRequest() async throws {
        let output = #"{"type":"expense","description":"Blue Bottle","amount":12.5,"category":"Eating Out","date":"2026-09-30"}"#
        let (session, script) = VoiceStubProtocol.makeSession(.respond(status: 200, body: chatReply(content: output)))
        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        let result = try await client.draftJSON(
            transcript: "twelve fifty at \"Blue Bottle\" — coffee", today: wednesday,
            expenseCategories: flutterExpenseNames, incomeCategories: flutterIncomeNames)
        #expect(result == output)

        let recorded = try #require(script.requests.first)
        #expect(script.requests.count == 1)
        #expect(recorded.method == "POST")
        #expect(recorded.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(recorded.headers["Authorization"] == "Bearer test-key")
        #expect(recorded.headers["Content-Type"] == "application/json")

        let root = try #require(try JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
        #expect(Set(root.keys) == ["model", "messages", "response_format"])
        #expect(root["model"] as? String == "gpt-5.4-nano")
        #expect(root["response_format"] as? [String: String] == ["type": "json_object"])

        let messages = try #require(root["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        // Flutter sends content as an array of text parts, not a bare string.
        let systemParts = try #require(messages[0]["content"] as? [[String: String]])
        #expect(systemParts.count == 1)
        #expect(systemParts[0]["type"] == "text")
        #expect(
            systemParts[0]["text"]
                == OpenAIVoiceClient.systemPrompt(
                    today: wednesday, expenseCategories: flutterExpenseNames, incomeCategories: flutterIncomeNames))
        let userParts = try #require(messages[1]["content"] as? [[String: String]])
        #expect(userParts == [["type": "text", "text": "twelve fifty at \"Blue Bottle\" — coffee"]])
    }

    @Test("content given as an array of parts is joined")
    func contentArrayJoined() async throws {
        let body = json(
            #"{"choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"{\"amount\":"},{"type":"text"},{"type":"text","text":"3}"}]}}]}"#)
        let (session, _) = VoiceStubProtocol.makeSession(.respond(status: 200, body: body))
        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        let result = try await client.draftJSON(
            transcript: "x", today: wednesday, expenseCategories: [], incomeCategories: [])
        #expect(result == #"{"amount":3}"#)
    }

    @Test("null content is an empty string for the parser to reject")
    func nullContent() async throws {
        let body = json(#"{"choices":[{"message":{"role":"assistant","content":null}}]}"#)
        let (session, _) = VoiceStubProtocol.makeSession(.respond(status: 200, body: body))
        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        let result = try await client.draftJSON(
            transcript: "x", today: wednesday, expenseCategories: [], incomeCategories: [])
        #expect(result == "")
    }

    @Test(
        "draftJSON: malformed envelope is .failed",
        arguments: ["not json", "", "[]", "{}", #"{"choices":[]}"#, #"{"choices":[{}]}"#, #"{"choices":[{"message":{}}]}"#,
            #"{"choices":[{"message":{"content":5}}]}"#, #"{"choices":[{"message":{"content":["x"]}}]}"#])
    func chatMalformed(body: String) async {
        let (session, _) = VoiceStubProtocol.makeSession(.respond(status: 200, body: json(body)))
        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        let error = await voiceError { () async throws(VoiceEntryError) in
            try await client.draftJSON(transcript: "x", today: wednesday, expenseCategories: [], incomeCategories: [])
        }
        #expect(error == .failed)
    }

    // MARK: Status and transport mapping (both calls)

    @Test(
        "HTTP status maps to the voice error",
        arguments: [
            (401, VoiceEntryError.unauthorized), (403, .unauthorized), (429, .rateLimited), (400, .failed),
            (404, .failed), (408, .failed), (500, .failed), (503, .failed), (302, .failed),
        ])
    func statusMapping(status: Int, expected: VoiceEntryError) async throws {
        let body = json(#"{"error":{"message":"nope"}}"#)
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let (transcribeSession, _) = VoiceStubProtocol.makeSession(.respond(status: status, body: body))
        let transcribeClient = OpenAIVoiceClient(apiKey: "test-key", session: transcribeSession)
        #expect(await voiceError { () async throws(VoiceEntryError) in try await transcribeClient.transcribe(audioFile: audio) } == expected)

        let (chatSession, _) = VoiceStubProtocol.makeSession(.respond(status: status, body: body))
        let chatClient = OpenAIVoiceClient(apiKey: "test-key", session: chatSession)
        let chatError = await voiceError { () async throws(VoiceEntryError) in
            try await chatClient.draftJSON(transcript: "x", today: wednesday, expenseCategories: [], incomeCategories: [])
        }
        #expect(chatError == expected)
    }

    @Test("a 2xx status other than 200 still succeeds")
    func status201() async throws {
        let (session, _) = VoiceStubProtocol.makeSession(.respond(status: 201, body: json(#"{"text":"ok"}"#)))
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        #expect(try await client.transcribe(audioFile: audio) == "ok")
    }

    @Test("network errors are .failed", arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost, .cancelled])
    func networkErrors(code: URLError.Code) async throws {
        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let (transcribeSession, _) = VoiceStubProtocol.makeSession(.fail(code))
        let transcribeClient = OpenAIVoiceClient(apiKey: "test-key", session: transcribeSession)
        #expect(await voiceError { () async throws(VoiceEntryError) in try await transcribeClient.transcribe(audioFile: audio) } == .failed)

        let (chatSession, _) = VoiceStubProtocol.makeSession(.fail(code))
        let chatClient = OpenAIVoiceClient(apiKey: "test-key", session: chatSession)
        let chatError = await voiceError { () async throws(VoiceEntryError) in
            try await chatClient.draftJSON(transcript: "x", today: wednesday, expenseCategories: [], incomeCategories: [])
        }
        #expect(chatError == .failed)
    }

    @Test("cancelling the task while a request is in flight ends as .failed")
    func cancellation() async throws {
        let (session, script) = VoiceStubProtocol.makeSession(.hang)
        let client = OpenAIVoiceClient(apiKey: "test-key", session: session)
        let task = Task {
            await voiceError { () async throws(VoiceEntryError) in
                try await client.draftJSON(transcript: "x", today: wednesday, expenseCategories: [], incomeCategories: [])
            }
        }
        // Wait until the request has reached the stub, then cancel.
        for _ in 0..<500 where script.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(script.requests.count == 1)
        task.cancel()
        #expect(await task.value == .failed)
    }

    @Test("the request timeout is 30 seconds")
    func timeoutInterval() {
        #expect(OpenAIVoiceClient.requestTimeout == 30)
    }

    // MARK: Key

    @Test("apiKey(fromInfoDictionary:) returns a trimmed key")
    func apiKeyValid() {
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: ["OPENAI_API_KEY": "sk-abc"]) == "sk-abc")
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: ["OPENAI_API_KEY": "  sk-abc\n"]) == "sk-abc")
    }

    @Test("apiKey(fromInfoDictionary:) rejects missing, empty, placeholder and unexpanded values")
    func apiKeyRejected() {
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: nil) == nil)
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: [:]) == nil)
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: ["OTHER": "sk-abc"]) == nil)
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: ["OPENAI_API_KEY": ""]) == nil)
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: ["OPENAI_API_KEY": "  \n"]) == nil)
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: ["OPENAI_API_KEY": "REPLACE_WITH_OPENAI_API_KEY"]) == nil)
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: ["OPENAI_API_KEY": " REPLACE_WITH_OPENAI_API_KEY "]) == nil)
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: ["OPENAI_API_KEY": "$(OPENAI_API_KEY)"]) == nil)
        #expect(OpenAIVoiceClient.apiKey(fromInfoDictionary: ["OPENAI_API_KEY": 5]) == nil)
    }
}
