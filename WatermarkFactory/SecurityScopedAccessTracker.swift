import Foundation

final class SecurityScopedAccessTracker {
    private var activeURLs: Set<URL> = []
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void

    init(
        startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    var active: Set<URL> { activeURLs }

    func start(_ url: URL) {
        guard !activeURLs.contains(url), startAccess(url) else { return }
        activeURLs.insert(url)
    }

    func replace(with urls: some Sequence<URL>) {
        let next = Set(urls)
        for url in activeURLs.subtracting(next) {
            stopAccess(url)
        }
        activeURLs.formIntersection(next)
        for url in next where !activeURLs.contains(url) {
            start(url)
        }
    }

    func stop(_ url: URL) {
        guard activeURLs.remove(url) != nil else { return }
        stopAccess(url)
    }

    func stopAll() {
        replace(with: EmptyCollection<URL>())
    }
}
