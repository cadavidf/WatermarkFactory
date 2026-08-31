import AutomalityUI
import DesignSystemKit
import Sparkle
import SwiftUI

@main
struct WatermarkFactoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

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
                // Pins the accent color every native, unstyled SwiftUI/AppKit
                // control falls back to (DisclosureGroup's chevron, Picker's
                // selection highlight, etc.) to Automality teal. Without this,
                // those controls inherit the user's macOS System Settings ->
                // Appearance accent color — which reads as random magenta/
                // purple/pink on any Mac where that's set to something other
                // than blue, regardless of how correctly every custom
                // Automality*Style component is themed.
                .tint(AutomalityColor.teal)
                // Required setup for every AutomalityUI/DesignSystemKit consumer:
                // Themed*Style components read this via @Environment(\.brandTheme).
                // Without it set at the true app root, every themed control
                // silently falls back to DesignSystemKit's default theme instead
                // of Automality's — this line is what makes buttons, chips,
                // toggles, and text fields actually render on-brand.
                .environment(\.brandTheme, AutomalityTheme())
        }
        .commands {
            // "About WatermarkFactory" is the standard macOS About panel --
            // provided automatically by SwiftUI/AppKit, no code needed here.
            // Acknowledgements gets its own window rather than being crammed
            // into the About panel's small credits box, since license text
            // (Sparkle's, specifically) is long enough to need real scrolling
            // and formatting.
            CommandGroup(after: .appInfo) {
                Button("Acknowledgements…") {
                    openWindow(id: "acknowledgements")
                }
                Button("Check for Updates…") {
                    appDelegate.checkForUpdates(nil)
                }
            }
        }
        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didFinishLaunching = false
    private var launchedViaFinderAutoRun = false
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        // Give any in-flight open-URL event (see application(_:open:) below)
        // a moment to arrive and flip launchedViaFinderAutoRun before we
        // decide whether to let Sparkle check automatically -- an update
        // prompt appearing mid a silent Finder Quick Action auto-run/
        // auto-quit would be surprising and could block the auto-quit.
        // Manual "Check for Updates..." still works either way since the
        // controller itself is always created, just not auto-started here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: !self.launchedViaFinderAutoRun,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !didFinishLaunching {
            launchedViaFinderAutoRun = true
        }
        AppState.shared.openFromFinder(urls, autoQuitWhenDone: !didFinishLaunching)
    }

    func checkForUpdates(_ sender: Any?) {
        if let controller = updaterController {
            controller.checkForUpdates(sender)
        } else {
            // Manual check requested before the deferred controller exists
            // yet (e.g. clicked within the first 0.3s of launch) -- create
            // it now, always starting the updater since this is an explicit
            // user action, not the ambiguous auto-run window.
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            updaterController = controller
            controller.checkForUpdates(sender)
        }
    }
}
