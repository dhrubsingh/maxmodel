import SwiftUI
import AppKit

/// Observes only user-initiated live scrolling, not layout changes while tokens arrive.
struct ChatScrollObserver: NSViewRepresentable {
    let onScroll: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(onScroll: onScroll) }
    func updateNSView(_ view: ObserverView, context: Context) { view.onScroll = onScroll }
    final class ObserverView: NSView {
        var onScroll: (Bool) -> Void
        private var tokens: [NSObjectProtocol] = []
        init(onScroll: @escaping (Bool) -> Void) { self.onScroll = onScroll; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver); tokens.removeAll()
            DispatchQueue.main.async { [weak self] in self?.observe() }
        }
        private func observe() {
            guard tokens.isEmpty, let scroll = enclosingScrollView else { return }
            for notification in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: notification, object: scroll, queue: .main) { [weak self, weak scroll] _ in
                    guard let self, let scroll, let document = scroll.documentView else { return }
                    let visible = scroll.documentVisibleRect
                    let nearBottom = document.isFlipped ? visible.maxY >= document.bounds.maxY - 80 : visible.minY <= document.bounds.minY + 80
                    self.onScroll(nearBottom)
                })
            }
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
