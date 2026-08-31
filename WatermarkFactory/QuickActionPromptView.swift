import AutomalityUI
import SwiftUI

/// Shown once, after a person's first successful export -- offers a
/// right-click "Quick Action" shortcut for next time. Instructions only:
/// this view never touches the filesystem itself. An earlier attempt to
/// have the app write a hand-authored .workflow bundle directly into
/// ~/Library/Services/ corrupted the Services database -- caught and
/// reverted immediately, but not a mistake worth repeating. Walking the
/// person through Automator.app themselves (a few minutes, one time) is
/// the safe version of the same convenience.
struct QuickActionPromptView: View {
    @Binding var isPresented: Bool

    private let steps = [
        "Open Automator (Spotlight → \u{201C}Automator\u{201D}).",
        "Choose New Document → Quick Action.",
        "Set \u{201C}Workflow receives\u{201D} to images and folders in Finder.",
        "Search the actions list for \u{201C}Open Finder Items\u{201D} and drag it into the workflow.",
        "Set \u{201C}Open with\u{201D} to WatermarkFactory.",
        "Save it, naming it something like \u{201C}Watermark with WatermarkFactory.\u{201D}"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AutomalitySpacing.md) {
            Text("Add a right-click shortcut?")
                .font(AutomalityType.display(22))
                .foregroundStyle(AutomalityColor.tealDeep)

            Text("Set this up once in Automator, and next time you can right-click a folder or a batch of images in Finder and watermark them straight from there — no need to open WatermarkFactory first.")
                .font(AutomalityType.body())
                .foregroundStyle(AutomalityColor.inkMuted)

            VStack(alignment: .leading, spacing: AutomalitySpacing.sm) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: AutomalitySpacing.xs) {
                        Text("\(index + 1).")
                            .font(AutomalityType.data(13))
                            .foregroundStyle(AutomalityColor.teal)
                            .frame(width: 20, alignment: .trailing)
                        Text(step)
                            .font(AutomalityType.body(13))
                            .foregroundStyle(AutomalityColor.ink)
                    }
                }
            }
            .padding(AutomalitySpacing.sm)
            .background(AutomalityColor.gray100)

            Text("It'll use whatever watermark and settings you had selected last, the same way opening files with WatermarkFactory already works.")
                .font(.caption)
                .foregroundStyle(AutomalityColor.inkMuted)

            HStack {
                Spacer()
                Button("Maybe later") { isPresented = false }
                    .buttonStyle(.automalitySecondary)
                Button("Open Automator") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Automator.app"))
                    isPresented = false
                }
                .buttonStyle(.automalityAccent)
            }
        }
        .padding(AutomalitySpacing.lg)
        .frame(width: 460)
        .background(AutomalityColor.offWhite)
    }
}
