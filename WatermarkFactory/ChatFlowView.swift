import AutomalityUI
import SwiftUI

struct ChatFlowView: View {
    @ObservedObject var state: AppState
    let sizeOpacitySection: () -> AnyView
    let positionPaddingSection: () -> AnyView
    let exportSection: () -> AnyView
    @State private var input = ""
    @State private var isThinking = false
    @State private var offlineMode = false
    @State private var questionIndex = 0
    @State private var expandedQuestionID: String?
    private let parser = IntentParser()

    private let questions: [ChatQuestion] = [
        ChatQuestion(id: "style", text: "Pick a starting style.", chips: ["Subtle corner", "Centered bold", "Tiled brand"]),
        ChatQuestion(id: "additionalAnchors", text: "Add it to another corner too?", chips: ["No", "Top-left", "Top-right", "Bottom-left", "Bottom-right"]),
        ChatQuestion(id: "padding", text: "How much padding from the edge?", chips: ["Tight (8px)", "Default (16px)", "Generous (32px)"]),
        ChatQuestion(id: "contentType", text: "What kind of images are these?", chips: ["Camera photos", "Logos or screenshots", "Geo or technical data", "GIFs", "Not sure"]),
        ChatQuestion(id: "reorder", text: "Number these in the order shown, or skip numbering?", chips: ["Number them", "Skip"]),
        ChatQuestion(id: "maxFileSizeKB", text: "Cap the file size per image?", chips: ["No limit", "500 KB", "200 KB"]),
        ChatQuestion(id: "platform", text: "Where are these going?", chips: ["Instagram", "Web", "Print", "Original"]),
        ChatQuestion(id: "renamePrefix", text: "Add a filename prefix?", chips: ["No prefix", "wm_", "Skip remaining, use defaults"])
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: AutomalitySpacing.sm) {
                        ForEach(state.chatTranscript) { message in
                            bubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(AutomalitySpacing.sm)
                }
                .onChange(of: state.chatTranscript.count) { _ in
                    if let id = state.chatTranscript.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(spacing: AutomalitySpacing.xs) {
                TextField("Describe the watermark...", text: $input)
                    .textFieldStyle(.automality)
                    .onSubmit { send(input) }
                Button(isThinking ? "thinking..." : "Send") { send(input) }
                    .buttonStyle(.automalityAccent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
            }
            .padding(AutomalitySpacing.sm)
        }
        .onAppear(perform: ensureQuestion)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            Text(message.text)
                .foregroundStyle(message.role == .user ? AutomalityColor.offWhite : AutomalityColor.ink)
                .padding(10)
                .background(message.role == .user ? AutomalityColor.teal : AutomalityColor.offWhite)
                .overlay(Rectangle().stroke(AutomalityColor.gray300, lineWidth: message.role == .user ? 0 : 1))
            if message.role == .assistant, state.chatTranscript.last?.id == message.id {
                if let chips = message.chips {
                    FlowLayout {
                        ForEach(chips, id: \.self) { chip in
                            Button(chip) { send(chip) }
                                .buttonStyle(.automalityChip(isSelected: false))
                                .disabled(isThinking)
                        }
                    }
                }
                DisclosureGroup("Customize...", isExpanded: Binding(
                    get: { expandedQuestionID == message.id.uuidString },
                    set: { expandedQuestionID = $0 ? message.id.uuidString : nil }
                )) {
                if questionIndex <= 1 {
                    positionPaddingSection()
                } else if questionIndex <= 3 {
                    sizeOpacitySection()
                    positionPaddingSection()
                } else {
                        exportSection()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        input = ""
        state.chatTranscript.append(ChatMessage(role: .user, text: text))
        if offlineMode {
            applyScripted(text)
            return
        }
        isThinking = true
        Task {
            do {
                let slots = try await parser.parse(message: text, unansweredSlots: IntentParser.slotNames)
                await MainActor.run {
                    state.applyIntentSlots(slots, message: text)
                    let followUp = question(for: slots.needsClarification)
                    state.chatTranscript.append(ChatMessage(role: .assistant, text: followUp?.text ?? slots.assistantReply, chips: followUp?.chips ?? ["Skip remaining, use defaults"]))
                    isThinking = false
                    if followUp == nil || text.localizedCaseInsensitiveContains("export") {
                        state.advance(to: .export)
                    }
                }
            } catch {
                await MainActor.run {
                    offlineMode = true
                    isThinking = false
                    state.chatTranscript.append(ChatMessage(role: .assistant, text: "Working offline — I'll ask a few quick questions instead."))
                    applyScripted(text)
                }
            }
        }
    }

    private func ensureQuestion() {
        guard state.chatTranscript.count == 1 else { return }
        askCurrentQuestion()
    }

    private func askCurrentQuestion() {
        guard questionIndex < questions.count else {
            state.advance(to: .export)
            return
        }
        let question = questions[questionIndex]
        state.chatTranscript.append(ChatMessage(role: .assistant, text: question.text, chips: question.chips))
    }

    private func question(for slots: [String]) -> ChatQuestion? {
        if slots.contains("anchor") || slots.contains("sizeFraction") || slots.contains("opacity") || slots.contains("tint") {
            return questions[0]
        }
        if slots.contains("padding") {
            return questions[2]
        }
        if slots.contains("additionalAnchors") {
            return questions[1]
        }
        if slots.contains("contentType") {
            return questions[3]
        }
        if slots.contains("reorder") {
            return questions[4]
        }
        if slots.contains("maxFileSizeKB"), state.exportFormat != .png, state.exportFormat != .tiff {
            return questions[5]
        }
        if slots.contains("exportPlatform") {
            return questions[6]
        }
        if slots.contains("renamePrefix") {
            return questions[7]
        }
        return nil
    }

    private func applyScripted(_ text: String) {
        let lower = text.lowercased()
        if lower.contains("skip") || lower.contains("export") {
            state.advance(to: .export)
            return
        }

        switch questions[questionIndex].id {
        case "style":
            let anchor = lower.contains("tile") ? "tiled" : (lower.contains("center") ? Anchor.center.rawValue : Anchor.bottomRight.rawValue)
            let slots = IntentSlots(anchor: anchor, additionalAnchors: nil, sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: nil, contentType: nil, renamePrefix: nil, reorder: nil, maxFileSizeKB: nil, needsClarification: [], assistantReply: "Watermark style set.")
            state.applyIntentSlots(slots, message: text)
        case "padding":
            let value = Double(lower.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? (lower.contains("tight") ? 8 : (lower.contains("generous") ? 32 : 16))
            state.padding = min(max(value, 0), 100)
            state.status = "Padding set."
        case "additionalAnchors":
            let anchors = additionalAnchors(from: lower)
            let slots = IntentSlots(anchor: nil, additionalAnchors: anchors.map(\.rawValue), sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: nil, contentType: nil, renamePrefix: nil, reorder: nil, maxFileSizeKB: nil, needsClarification: [], assistantReply: anchors.isEmpty ? "Single placement kept." : "Extra placement added.")
            state.applyIntentSlots(slots, message: text)
        case "contentType":
            let contentType: String
            if lower.contains("camera") || lower.contains("photo") { contentType = "camera" }
            else if lower.contains("logo") || lower.contains("screenshot") || lower.contains("graphic") { contentType = "graphic" }
            else if lower.contains("geo") || lower.contains("technical") { contentType = "geoData" }
            else if lower.contains("gif") { contentType = "gif" }
            else { contentType = "other" }
            let slots = IntentSlots(anchor: nil, additionalAnchors: nil, sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: nil, contentType: contentType, renamePrefix: nil, reorder: nil, maxFileSizeKB: nil, needsClarification: [], assistantReply: "Format set.")
            state.applyIntentSlots(slots, message: text)
        case "reorder":
            let reorder = lower.contains("number") ? "byCurrentOrder" : "skip"
            let slots = IntentSlots(anchor: nil, additionalAnchors: nil, sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: nil, contentType: nil, renamePrefix: nil, reorder: reorder, maxFileSizeKB: nil, needsClarification: [], assistantReply: "Order set.")
            state.applyIntentSlots(slots, message: text)
        case "maxFileSizeKB":
            let value = lower.contains("no") ? 0 : (Double(lower.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0)
            let slots = IntentSlots(anchor: nil, additionalAnchors: nil, sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: nil, contentType: nil, renamePrefix: nil, reorder: nil, maxFileSizeKB: value, needsClarification: [], assistantReply: value > 0 ? "File size cap set." : "No file size cap set.")
            state.applyIntentSlots(slots, message: text)
        case "platform":
            let platform = ["instagram", "web", "print", "original"].first { lower.contains($0) } ?? "original"
            let slots = IntentSlots(anchor: nil, additionalAnchors: nil, sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: platform, contentType: nil, renamePrefix: nil, reorder: nil, maxFileSizeKB: nil, needsClarification: [], assistantReply: "Export target set.")
            state.applyIntentSlots(slots, message: text)
        default:
            let prefix = lower.contains("no prefix") ? "" : text
            let slots = IntentSlots(anchor: nil, additionalAnchors: nil, sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: nil, contentType: nil, renamePrefix: prefix, reorder: nil, maxFileSizeKB: nil, needsClarification: [], assistantReply: "Ready to export.")
            state.applyIntentSlots(slots, message: text)
        }
        questionIndex = nextQuestionIndex(after: questionIndex)
        askCurrentQuestion()
    }

    private func nextQuestionIndex(after index: Int) -> Int {
        var next = index + 1
        while next < questions.count, questions[next].id == "maxFileSizeKB", (state.exportFormat == .png || state.exportFormat == .tiff) {
            next += 1
        }
        return next
    }

    private func additionalAnchors(from text: String) -> [Anchor] {
        guard !text.contains("no") && !text.contains("skip") else { return [] }
        return Anchor.allCases.filter { text.contains($0.displayName) || text.contains($0.rawValue.lowercased()) }
    }
}
