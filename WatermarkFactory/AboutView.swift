import SwiftUI

/// Custom "About WatermarkFactory" panel, replacing the system-provided one
/// (CommandGroup(replacing: .appInfo) in WatermarkFactoryApp.swift) so
/// Acknowledgements and Check for Updates can live here as real buttons
/// instead of separate menu bar items.
struct AboutView: View {
    @Environment(\.openWindow) private var openWindow
    let checkForUpdates: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("WatermarkFactory")
                .font(.title2.weight(.semibold))
            Text("Version \(version) (\(build))")
                .font(.callout)
                .foregroundStyle(Color.secondary)

            HStack(spacing: 12) {
                Button("Acknowledgements...") {
                    openWindow(id: "acknowledgements")
                }
                Button("Updates...") {
                    checkForUpdates()
                }
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(width: 320)
    }
}
