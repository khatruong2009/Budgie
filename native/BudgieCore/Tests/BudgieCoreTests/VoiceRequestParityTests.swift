import Foundation
import Testing

@testable import BudgieCore

/// Zones of Fixtures/voicerequest: a DST change at 02:00 (New York) and at
/// midnight (Santiago).
private let voiceRequestZones = ["America/New_York", "America/Santiago"]

private func fixture(_ zone: String) throws -> J {
    try Fixtures.json("\(Fixtures.zonePath("voicerequest", zone))/request.json")
}

private struct Part {
    let name: String?
    let filename: String?
    let contentType: String?
    let headers: [String]
    let bytes: [UInt8]
}

/// The parts of a multipart body, found on the bytes (a "\r\n" is one
/// Character in a Swift String, so the text cannot be indexed by offset).
private func parseMultipart(_ body: Data, boundary: String) -> [Part] {
    let bytes = [UInt8](body)
    let delimiter = Array("--\(boundary)".utf8)
    let crlf: [UInt8] = [13, 10]
    func find(_ needle: [UInt8], from: Int) -> Int? {
        guard needle.count <= bytes.count - from, from >= 0 else { return nil }
        var i = from
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0] && Array(bytes[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }
    var parts: [Part] = []
    var cursor = find(delimiter, from: 0)
    while let at = cursor {
        let start = at + delimiter.count
        if bytes.count >= start + 2 && bytes[start] == 45 && bytes[start + 1] == 45 { break }
        guard let next = find(crlf + delimiter, from: start) else { break }
        let chunk = Array(bytes[(start + 2)..<next])
        guard let split = Array(chunk).indices.first(where: { $0 + 4 <= chunk.count && Array(chunk[$0..<$0 + 4]) == crlf + crlf }) else { break }
        let head = String(decoding: chunk[..<split], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        var order: [String] = []
        for line in head {
            let colon = line.firstIndex(of: ":")!
            let key = line[line.startIndex..<colon].lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            order.append(key)
        }
        func attr(_ name: String) -> String? {
            guard let disposition = headers["content-disposition"], let range = disposition.range(of: "; \(name)=\"") ?? disposition.range(of: " \(name)=\"")
            else { return nil }
            let rest = disposition[range.upperBound...]
            return String(rest[rest.startIndex..<rest.firstIndex(of: "\"")!])
        }
        parts.append(Part(
            name: attr("name"), filename: attr("filename"), contentType: headers["content-type"], headers: order,
            bytes: Array(chunk[(split + 4)...])))
        cursor = next + 2
    }
    return parts
}

private func chatReply() -> Data {
    Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"{}"}}]}"#.utf8)
}

@Suite("Voice requests: the system prompt, chat body and transcription request match what dart_openai sends (Fixtures/voicerequest)")
struct VoiceRequestParityTests {
    /// `parse(transcript, today)`: the same method and path, Authorization,
    /// Content-Type and body bytes (model, both messages with the system
    /// prompt for that date and category vocabulary, response_format).
    @Test("chat request", arguments: voiceRequestZones)
    func chat(zone: String) async throws {
        let f = try fixture(zone)
        #expect(f["tz"].string == zone)
        let tz = TimeZone(identifier: zone)!
        let cases = f["chat"].array
        #expect(cases.count >= 16)
        var weekdays = Set<String>()
        for c in cases {
            let label = "\(zone) \(c["label"].string!)"
            #expect(c["error"].isNull, "\(label) Flutter error \(c["error"].string ?? "")")
            let today = DartDateTime(microsecondsSinceEpoch: Int64(c["today"]["us"].int!), timeZone: tz)
            #expect(today.toIso8601String() == c["today"]["iso"].string, "\(label) today")
            let (session, script) = VoiceStubProtocol.makeSession(.respond(status: 200, body: chatReply()))
            let client = OpenAIVoiceClient(apiKey: "parity-harness-dummy-key", session: session)
            _ = try? await client.draftJSON(
                transcript: c["transcript"].string!, today: today,
                expenseCategories: c["expenseCategories"].array.map { $0.string! },
                incomeCategories: c["incomeCategories"].array.map { $0.string! })
            let request = try #require(script.requests.first, "\(label) request")
            #expect(script.requests.count == 1)
            #expect(request.method == c["method"].string, "\(label) method")
            #expect(request.url?.path == c["path"].string, "\(label) path \(request.url?.path ?? "")")
            #expect(request.headers["Authorization"] == c["authorization"].string, "\(label) authorization")
            #expect(request.headers["Content-Type"] == c["contentType"].string, "\(label) content type \(request.headers["Content-Type"] ?? "") | \(c["contentType"].string ?? "")")
            same(String(data: request.body, encoding: .utf8)!, c["body"].string!, "\(label) body")
            weekdays.insert(DartDateFormat.EEEE(today))
        }
        #expect(weekdays.count >= 5, "several weekdays \(weekdays)")
    }

    /// `transcribe(file)`: Authorization, the multipart fields (model,
    /// prompt) then the file part with its name, file name and bytes, in the
    /// same order, with the file part's headers (application/octet-stream,
    /// Content-Type first) byte for byte.
    @Test("transcription request", arguments: voiceRequestZones)
    func transcription(zone: String) async throws {
        let f = try fixture(zone)
        let cases = f["transcription"].array
        #expect(cases.count == 6)
        for c in cases {
            let name = c["fileName"].string!
            let label = "\(zone) \(name)"
            #expect(c["error"].isNull, "\(label) Flutter error \(c["error"].string ?? "")")
            let directory = TestDirectory.make("voice-request")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent(name)
            let bytes = c["fileBytes"].array.map { UInt8($0.int!) }
            try Data(bytes).write(to: file)

            let body = Data(#"{"text":" coffee twelve fifty "}"#.utf8)
            let (session, script) = VoiceStubProtocol.makeSession(.respond(status: 200, body: body))
            let client = OpenAIVoiceClient(apiKey: "parity-harness-dummy-key", session: session)
            let transcript = try await client.transcribe(audioFile: file)
            same(transcript, c["transcript"].string!, "\(label) transcript")
            let request = try #require(script.requests.first, "\(label) request")
            #expect(request.method == c["method"].string, "\(label) method")
            #expect(request.url?.path == c["path"].string, "\(label) path")
            #expect(request.headers["Authorization"] == c["authorization"].string, "\(label) authorization")
            let contentType = request.headers["Content-Type"]!
            let boundary = String(contentType[contentType.range(of: "boundary=")!.upperBound...])
            #expect(String(contentType[..<contentType.range(of: "boundary=")!.lowerBound]) == c["contentTypePrefix"].string, "\(label) content type")

            let swift = parseMultipart(request.body, boundary: boundary)
            let dart = c["parts"].array
            #expect(swift.map(\.name) == dart.map { $0["name"].string }, "\(label) part order")
            // The fixture holds header bytes as latin1 code units; the name is UTF-8.
            let dartNames = dart.map { part in
                part["filename"].string.map { String(decoding: $0.unicodeScalars.map { UInt8($0.value) }, as: UTF8.self) }
            }
            #expect(swift.map(\.filename) == dartNames, "\(label) file names")
            #expect(swift.map(\.bytes) == dart.map { $0["bytes"].array.map { UInt8($0.int!) } }, "\(label) bytes")
            // The text fields are identical.
            #expect(swift.dropLast().map(\.headers) == dart.dropLast().map { $0["headers"].array.map { $0.string! } }, "\(label) field headers")
            #expect(dart.last?["contentType"].string == "application/octet-stream", "\(label) Flutter's file part type")
            // dart_openai 4.1.4 sends the file part as application/octet-stream,
            // Content-Type before Content-Disposition; Swift does the same.
            #expect(swift.last?.contentType == dart.last?["contentType"].string, "\(label) file content type")
            #expect(swift.last?.headers == dart.last?["headers"].array.map { $0.string! }, "\(label) file part header order")
            #expect(swift.last?.bytes == bytes, "\(label) audio bytes")
        }
    }
}
