import AutomalityUI
import DesignSystemKit
import SwiftUI

@main
struct WatermarkFactoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(state: .shared)
                .frame(minWidth: 1180, minHeight: 720)
                // Automality is a fixed light brand palette, not a dark-adaptive
                // one (see AutomalityColor). Pinning colorScheme here isn't just
                // for our own SwiftUI Text/Color calls — it also forces native
                // AppKit-backed controls (List, segmented Picker, etc.) to render
                // their light chrome instead of following the system's actual
                // Dark Mode setting, which is what was producing a solid dark
                // List background and washed-out Picker labels regardless of any
                // SwiftUI-level .background()/.foregroundStyle() override.
                .environment(\.colorScheme, .light)
                // Required setup for every AutomalityUI/DesignSystemKit consumer:
                // Themed*Style components read this via @Environment(\.brandTheme).
                // Without it set at the true app root, every themed control
                // silently falls back to DesignSystemKit's default theme instead
                // of Automality's — this line is what makes buttons, chips,
                // toggles, and text fields actually render on-brand.
                .environment(\.brandTheme, AutomalityTheme())
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didFinishLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppState.shared.openFromFinder(urls, autoQuitWhenDone: !didFinishLaunching)
    }
}
