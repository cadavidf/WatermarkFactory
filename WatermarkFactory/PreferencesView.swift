import SwiftUI

struct PreferencesView: View {
    @AppStorage("useAutomalityBrandColors") private var useAutomalityBrandColors = false

    var body: some View {
        Form {
            Toggle("Use Automality Brand Colors", isOn: $useAutomalityBrandColors)
            Text("Off uses the standard macOS look. On uses Automality's teal and orange brand colors throughout the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360)
    }
}
