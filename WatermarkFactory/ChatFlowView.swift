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
        if slots.contains("exportPlatform") {
            return questions[1]
        }
        if slots.contains("renamePrefix") {
            return questions[2]
        }
        return nil
    }

    private func applyScripted(_ text: String) {
        let lower = text.lowercased()
        if lower.contains("skip") || lower.contains("export") {
            state.advance(to: .export)
            return
        }

        switch questionIndex {
        case 0:
            let anchor = lower.contains("tile") ? "tiled" : (lower.contains("center") ? Anchor.center.rawValue : Anchor.bottomRight.rawValue)
            let slots = IntentSlots(anchor: anchor, sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: nil, renamePrefix: nil, needsClarification: [], assistantReply: "Watermark style set.")
            state.applyIntentSlots(slots, message: text)
        case 1:
            let platform = ["instagram", "web", "print", "original"].first { lower.contains($0) } ?? "original"
            let slots = IntentSlots(anchor: nil, sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: platform, renamePrefix: nil, needsClarification: [], assistantReply: "Export target set.")
            state.applyIntentSlots(slots, message: text)
        default:
            let prefix = lower.contains("no prefix") ? "" : text
            let slots = IntentSlots(anchor: nil, sizeFraction: nil, opacity: nil, tint: nil, exportPlatform: nil, renamePrefix: prefix, needsClarification: [], assistantReply: "Ready to export.")
            state.applyIntentSlots(slots, message: text)
        }
        questionIndex += 1
        askCurrentQuestion()
    }
}
