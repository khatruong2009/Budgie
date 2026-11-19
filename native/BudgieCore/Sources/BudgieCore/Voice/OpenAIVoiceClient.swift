import Foundation

/// The two OpenAI calls behind voice entry, ported from
/// `VoiceExpenseService.transcribe` / `parse` (voice_expense_service.dart).
/// Plain `URLSession`; one request at a time is the caller's job (the
/// recording sheet). Never logs the key, headers, audio or transcript.
///
/// What Flutter's `dart_openai` 4.1.4 actually sends, which this mirrors:
/// - Transcription: `POST /v1/audio/transcriptions`, multipart with the text
///   fields `model` and `prompt` first and the `file` part last (package:http
///   writes fields before files). No `response_format`, `language` or
///   `temperature`. The file part carries the file's base name and, like
///   dart_openai's `MultipartFile.fromPath`, `Content-Type:
///   application/octet-stream` before its `Content-Disposition` (pinned by
///   Fixtures/voicerequest). OpenAI identifies the format by the file name.
///   The response is the default JSON `{"text": ...}`.
/// - Chat: `POST /v1/chat/completions`, JSON `{model, messages,
///   response_format}`. Each message's `content` is an array of
///   `{"type":"text","text":...}` parts, not a bare string (system message,
///   then user message). Nothing else (no temperature, no max tokens).
///   The reply's `content` is a string or an array of parts, joined by their
///   `text`; a null content becomes "" and is left to the parser to reject.
/// - Timeout: one `OpenAIConfig.requestsTimeOut` of 30 seconds on every call.
///   dart_openai applies it to the whole send; `URLRequest.timeoutInterval`
///   is an idle timeout (no bytes for that long), so a stalled connection
///   still fails after 30 seconds.
/// - No retries, no organization header, `Authorization: Bearer <key>`.
public struct OpenAIVoiceClient: Sendable {
    static let transcriptionURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let chatURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let transcriptionModel = "gpt-4o-mini-transcribe"
    static let chatModel = "gpt-5.4-nano"
    static let transcriptionPrompt = "Personal expense phrases with dollar amounts like $12.50 and merchant names."
    static let requestTimeout: TimeInterval = 30
    /// The Info.plist key the build fills from Secrets.xcconfig.
    static let infoDictionaryKey = "OPENAI_API_KEY"
    /// The value in Secrets.example.xcconfig.
    static let placeholderKey = "REPLACE_WITH_OPENAI_API_KEY"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: Key

    /// The key from the app's Info dictionary, trimmed; nil when it is
    /// missing, empty, the example placeholder, or a build setting that was
    /// never expanded (`$(OPENAI_API_KEY)`, or any other `$(...)` text).
    public static func apiKey(fromInfoDictionary info: [String: Any]?) -> String? {
        guard let raw = info?[infoDictionaryKey] as? String else { return nil }
        let key = DartString.trim(raw)
        if key.isEmpty || key == placeholderKey || key.hasPrefix("$(") { return nil }
        return key
    }

    // MARK: Transcription

    /// Transcribes a recorded audio file. The text is trimmed like Flutter's
    /// `String.trim`; an empty result throws `.noSpeech`.
    public func transcribe(audioFile: URL) async throws(VoiceEntryError) -> String {
        guard let audio = try? Data(contentsOf: audioFile) else { throw .failed }

        let boundary = "BudgieBoundary-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in [("model", Self.transcriptionModel), ("prompt", Self.transcriptionPrompt)] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let filename = audioFile.lastPathComponent.replacingOccurrences(of: "\"", with: "%22")
        append(
            "--\(boundary)\r\nContent-Type: application/octet-stream\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")

        let data = try await send(
            url: Self.transcriptionURL,
            contentType: "multipart/form-data; boundary=\(boundary)",
            body: body)
        guard let text = Self.decodeObject(data)?["text"]?.stringValue else { throw .failed }
        let transcript = DartString.trim(text)
        if transcript.isEmpty { throw .noSpeech }
        return transcript
    }

    // MARK: Chat

    /// Asks the model for the transaction JSON and returns the assistant
    /// message content for `VoiceDraftParser`. A null content is "" (the
    /// parser then reports `.unreadable`); a reply with no choices throws
    /// `.failed`.
    public func draftJSON(
        transcript: String, today: DartDateTime, expenseCategories: [String], incomeCategories: [String]
    ) async throws(VoiceEntryError) -> String {
        let system = Self.systemPrompt(
            today: today, expenseCategories: expenseCategories, incomeCategories: incomeCategories)
        func message(_ role: String, _ text: String) -> JSONValue {
            .object(JSONObject([
                "role": .string(role),
                "content": .array([.object(JSONObject(["type": .string("text"), "text": .string(text)]))]),
            ]))
        }
        let request = JSONValue.object(JSONObject([
            "model": .string(Self.chatModel),
            "messages": .array([message("system", system), message("user", transcript)]),
            "response_format": .object(JSONObject(["type": .string("json_object")])),
        ]))

        let data = try await send(
            url: Self.chatURL, contentType: "application/json", body: Data(DartJSON.encode(request)))
        guard
            let envelope = Self.decodeObject(data),
            let first = envelope["choices"]?.arrayValue?.first,
            let content = first.objectValue?["message"]?.objectValue?["content"]
        else { throw .failed }

        switch content {
        case .null:
            return ""
        case .string(let text):
            return text.value
        case .array(let parts):
            var joined = ""
            for part in parts {
                guard let object = part.objectValue else { throw .failed }
                joined += object["text"]?.stringValue ?? ""
            }
            return joined
        default:
            throw .failed
        }
    }

    /// The system prompt, word for word from voice_expense_service.dart. The
    /// date label is `DateFormat('yyyy-MM-dd')`, the weekday `DateFormat('EEEE')`
    /// (en_US), both read from `today`'s local fields.
    public static func systemPrompt(
        today: DartDateTime, expenseCategories: [String], incomeCategories: [String]
    ) -> String {
        let dateLabel = DartDateFormat.yyyyMMdd(today)
        let weekday = DartDateFormat.EEEE(today)
        let expenseVocab = expenseCategories.joined(separator: ", ")
        let incomeVocab = incomeCategories.joined(separator: ", ")
        return """
            You extract a single personal-finance transaction from a spoken phrase and return JSON only.

            Today is \(dateLabel) (\(weekday)), the device's local date. Resolve relative dates like "yesterday", "last Tuesday", or "two days ago" against it.

            Return exactly this JSON shape:
            {"type","description","amount","category","date"}

            Fields:
            - "type": either "expense" or "income". Default to "expense" unless the phrase clearly describes money coming in (for example "got paid", "salary", "received", "refund", "deposit"), in which case use "income".
            - "description": a short merchant or purpose label from the phrase.
            - "amount": a number. Spoken amounts map to decimals — "twelve fifty" means 12.50, "three thousand" means 3000. If no amount is stated, use 0.
            - "category": for expenses pick exactly one of: \(expenseVocab). For income pick exactly one of: \(incomeVocab). Choose the closest match.
            - "date": an ISO-8601 date (YYYY-MM-DD). Default to today (\(dateLabel)). Use a different date only when the phrase explicitly says when the money was spent (for example "yesterday", "last Friday", "on the 3rd"). When the phrase mentions the date of an upcoming trip, stay, or event ("flights for next month", "hotel for our trip in September"), that is NOT the transaction date — the payment is happening now, so use today. Never return a date in the future, and never replace a future reference with the same date in an earlier year.

            If the phrase is not describing a transaction at all, return {"error":"not_a_transaction"}.
            """
    }

    // MARK: Transport

    /// POSTs `body` and returns the response body for a 2xx status.
    ///
    /// Cancellation: the typed error has no cancellation case and the sheet
    /// discards the result of work it cancelled, so a cancelled task ends as
    /// `.failed` (URLSession surfaces `URLError.cancelled`), the same as any
    /// other transport failure. Callers that cancel must check
    /// `Task.isCancelled` before showing the error.
    private func send(url: URL, contentType: String, body: Data) async throws(VoiceEntryError) -> Data {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        guard let (data, response) = try? await session.upload(for: request, from: body),
            let http = response as? HTTPURLResponse
        else { throw .failed }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw .unauthorized
        case 429: throw .rateLimited
        default: throw .failed
        }
    }

    private static func decodeObject(_ data: Data) -> JSONObject? {
        (try? JSONParser.parse(Array(data)))?.objectValue
    }
}
