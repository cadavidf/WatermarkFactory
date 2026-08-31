import Foundation

enum IntentParserError: Error {
    case malformedResponse
}

struct IntentParser {
    var endpoint = URL(string: "http://localhost:11434/api/chat")!
    // gpt-oss:20b (this project's first choice) measured ~28-29s per turn on
    // this hardware, warm or cold -- a reasoning model that keeps burning
    // time on hidden deliberation tokens even with think:false. gemma3:4b
    // answers the same structured-extraction prompt correctly in ~5s, which
    // is what a chat UI actually needs. Timeout is set well above that
    // measured latency, not the model's best case, so a real slow turn
    // doesn't get mistaken for "Ollama is down" and silently degrade to the
    // scripted fallback.
    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    func parse(message: String, unansweredSlots: [String]) async throws -> IntentSlots {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaRequest(messages: [
            OllamaMessage(role: "system", content: Self.systemPrompt),
            OllamaMessage(role: "user", content: "Unanswered slots: \(unansweredSlots.joined(separator: ", "))\nUser message: \(message)")
        ]))
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(OllamaResponse.self, from: data)
        return try Self.decodeSlots(from: response.message.content)
    }

    static func decodeSlots(from content: String) throws -> IntentSlots {
        guard let data = Self.extractJSONObject(from: content).data(using: .utf8) else {
            throw IntentParserError.malformedResponse
        }
        do {
            return try JSONDecoder().decode(IntentSlots.self, from: data)
        } catch {
            throw IntentParserError.malformedResponse
        }
    }

    /// Small local models routinely ignore "no prose outside JSON" and wrap
    /// their answer in a ```json ... ``` fence (confirmed live with
    /// gemma3:4b this session) even when told not to -- that's normal
    /// instruction-following slack for a 4B model, not something to fight
    /// with prompt wording alone. Slice out the first top-level {...} object
    /// rather than trust the response to be bare JSON.
    private static func extractJSONObject(from content: String) -> String {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end else {
            return content
        }
        return String(content[start...end])
    }

    static let slotNames = ["anchor", "additionalAnchors", "sizeFraction", "opacity", "tint", "exportPlatform", "contentType", "renamePrefix", "reorder", "maxFileSizeKB"]

    static var systemPrompt: String {
        """
        Map one user watermark request to JSON only. No prose outside JSON.
        JSON keys: anchor, additionalAnchors, sizeFraction, opacity, tint, exportPlatform, contentType, renamePrefix, reorder, maxFileSizeKB, needsClarification, assistantReply.
        anchor valid values: \(Anchor.allCases.map(\.rawValue).joined(separator: ", ")), tiled.
        additionalAnchors is an optional array of Anchor values for extra simultaneous placements.
        sizeFraction valid range: 0.05...0.6.
        opacity valid range: 0...1.
        tint valid values: \(WatermarkTint.allCases.map(\.rawValue).joined(separator: ", ")).
        exportPlatform valid values: instagram, web, print, original.
        contentType valid values: camera, graphic, geoData, gif, other.
        reorder valid values: byCurrentOrder, skip.
        maxFileSizeKB is a positive KB number or null.
        needsClarification is an array of slot names you could not infer.
        assistantReply is one short sentence.
        Use null for unknown optional slots.
        """
    }
}

private struct OllamaRequest: Encodable {
    let model = "gemma3:4b"
    let stream = false
    let think = false
    let messages: [OllamaMessage]
}

private struct OllamaMessage: Codable {
    let role: String
    let content: String
}

private struct OllamaResponse: Decodable {
    let message: OllamaMessage
}
