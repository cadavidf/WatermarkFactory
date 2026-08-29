import SwiftUI

@main
struct WatermarkFactoryApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
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
        }
    }
}
