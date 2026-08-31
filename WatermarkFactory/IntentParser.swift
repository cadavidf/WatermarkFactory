import Foundation

enum IntentParserError: Error {
    case malformedResponse
}

struct IntentParser {
    var endpoint = URL(string: "http://localhost:11434/api/chat")!
    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
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
        guard let data = content.data(using: .utf8) else { throw IntentParserError.malformedResponse }
        do {
            return try JSONDecoder().decode(IntentSlots.self, from: data)
        } catch {
            throw IntentParserError.malformedResponse
        }
    }

    static let slotNames = ["anchor", "sizeFraction", "opacity", "tint", "exportPlatform", "renamePrefix"]

    static var systemPrompt: String {
        """
        Map one user watermark request to JSON only. No prose outside JSON.
        JSON keys: anchor, sizeFraction, opacity, tint, exportPlatform, renamePrefix, needsClarification, assistantReply.
        anchor valid values: \(Anchor.allCases.map(\.rawValue).joined(separator: ", ")), tiled.
        sizeFraction valid range: 0.05...0.6.
        opacity valid range: 0...1.
        tint valid values: \(WatermarkTint.allCases.map(\.rawValue).joined(separator: ", ")).
        exportPlatform valid values: instagram, web, print, original.
        needsClarification is an array of slot names you could not infer.
        assistantReply is one short sentence.
        Use null for unknown optional slots.
        """
    }
}

private struct OllamaRequest: Encodable {
    let model = "gpt-oss:20b"
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
