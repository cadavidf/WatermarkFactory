import AppKit
import AutomalityUI
import SwiftUI

/// Backs BrandScrollBar's up/down buttons and thumb with the real NSScrollView
/// underneath -- SwiftUI's own ScrollView has no public offset control on
/// macOS 13 (our deployment target), so paging and a live thumb both need the
/// AppKit clip view directly.
@MainActor
final class BrandScrollController: ObservableObject {
    @Published fileprivate(set) var offset: CGFloat = 0
    @Published fileprivate(set) var contentHeight: CGFloat = 0
    @Published fileprivate(set) var visibleHeight: CGFloat = 0
    fileprivate weak var clipView: NSClipView?
    fileprivate weak var scrollView: NSScrollView?

    private var maxOffset: CGFloat { max(0, contentHeight - visibleHeight) }
    var canScrollUp: Bool { offset > 0.5 }
    var canScrollDown: Bool { offset < maxOffset - 0.5 }
    /// Fraction of the track the thumb should cover, and where along the
    /// track its top edge sits -- both 0 when there's nothing to scroll.
    var thumbFraction: CGFloat { contentHeight > 0 ? min(1, visibleHeight / contentHeight) : 1 }
    var thumbPosition: CGFloat { maxOffset > 0 ? offset / maxOffset : 0 }

    func page(by delta: CGFloat) {
        guard let clipView, let scrollView else { return }
        let target = min(max(0, offset + delta), maxOffset)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            clipView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        }
        scrollView.reflectScrolledClipView(clipView)
    }
}

/// NSScrollView wrapper that hosts arbitrary SwiftUI content and reports
/// scroll position/content size to a BrandScrollController -- the piece
/// BrandScrollBar layers its own chrome around. Trackpad/mouse-wheel
/// scrolling still works normally; the controller only adds programmatic
/// paging on top.
private struct BrandScrollHost<Content: View>: NSViewRepresentable {
    @ObservedObject var controller: BrandScrollController
    let content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hosting.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        context.coordinator.attach(scrollView: scrollView, hosting: hosting, controller: controller)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.hosting?.rootView = content
        DispatchQueue.main.async { context.coordinator.refresh() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        weak var hosting: NSHostingView<Content>?
        weak var scrollView: NSScrollView?
        weak var controller: BrandScrollController?

        func attach(scrollView: NSScrollView, hosting: NSHostingView<Content>, controller: BrandScrollController) {
            self.scrollView = scrollView
            self.hosting = hosting
            self.controller = controller
            controller.clipView = scrollView.contentView
            controller.scrollView = scrollView
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: hosting)
            refresh()
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func boundsChanged() { refresh() }
        @objc func frameChanged() { refresh() }

        func refresh() {
            guard let scrollView, let hosting, let controller else { return }
            controller.offset = scrollView.contentView.bounds.origin.y
            controller.contentHeight = hosting.fittingSize.height
            controller.visibleHeight = scrollView.contentView.bounds.height
        }
    }
}

/// Brand-aware stand-in for macOS's auto-hiding scrollbar: a docked edge
/// rail with big up/down paging buttons and a teal thumb, always visible
/// rather than a thin bar that fades away. Compact mode's two long panes
/// (image list, controls) both use this instead of a bare ScrollView so
/// there's an obvious, on-brand way to move through them.
struct BrandScrollBar<Content: View>: View {
    @StateObject private var controller = BrandScrollController()
    private let content: Content
    private let pageStep: CGFloat = 220
    static var railWidth: CGFloat { 28 }
    // Fixed-width callers need to budget this in addition to their content width.
    private let railWidth = Self.railWidth

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            BrandScrollHost(controller: controller, content: content)
            VStack(spacing: 6) {
                railButton(systemName: "chevron.up", enabled: controller.canScrollUp) {
                    controller.page(by: -pageStep)
                }
                GeometryReader { geo in
                    let thumbHeight = max(24, geo.size.height * controller.thumbFraction)
                    ZStack(alignment: .top) {
                        Capsule().fill(AutomalityColor.gray300.opacity(0.4))
                        if controller.contentHeight > controller.visibleHeight {
                            Capsule()
                                .fill(AutomalityColor.teal)
                                .frame(height: thumbHeight)
                                .offset(y: (geo.size.height - thumbHeight) * controller.thumbPosition)
                        }
                    }
                }
                .frame(width: 6)
                .padding(.vertical, 2)
                railButton(systemName: "chevron.down", enabled: controller.canScrollDown) {
                    controller.page(by: pageStep)
                }
            }
            .padding(.vertical, 6)
            .frame(width: railWidth)
            .background(AutomalityColor.offWhite)
            .overlay(Rectangle().fill(AutomalityColor.gray300.opacity(0.5)).frame(width: 1), alignment: .leading)
        }
    }

    private func railButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .frame(width: railWidth - 6, height: railWidth - 6)
        }
        .buttonStyle(.plain)
        .background(enabled ? AutomalityColor.tealPale : Color.clear)
        .foregroundStyle(enabled ? AutomalityColor.tealDeep : AutomalityColor.gray300)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .disabled(!enabled)
    }
}
