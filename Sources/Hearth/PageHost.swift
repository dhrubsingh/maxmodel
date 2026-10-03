import AppKit
import SwiftUI
import HearthCore

/// Keep each visited screen alive. A SwiftUI conditional destroys its scroll views,
/// text layout and controls on every sidebar switch, even when their data is unchanged.
struct PageHost: NSViewRepresentable {
    let store: AppStore
    let page: AppPage

    func makeNSView(context: Context) -> PageContainer { PageContainer() }
    func updateNSView(_ view: PageContainer, context: Context) {
        view.show(page, store: store)
    }
}

@MainActor
final class PageContainer: NSView {
    private(set) var pages: [AppPage: NSHostingView<AnyView>] = [:]
    private(set) var selectedPage: AppPage?
    private var pressureSource: DispatchSourceMemoryPressure?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.discardInactivePages()
                ChatMarkdown.releaseCachedContent()
            }
        }
        source.resume(); pressureSource = source
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { pressureSource?.cancel() }

    /// Keep navigation warm normally; yield cached screens when macOS needs their memory.
    func discardInactivePages() {
        for page in Array(pages.keys) where page != selectedPage {
            pages.removeValue(forKey: page)?.removeFromSuperview()
        }
    }

    func show(_ page: AppPage, store: AppStore) {
        guard selectedPage != page else { return }
        if let previous = selectedPage, let host = pages[previous] {
            // A hidden page must not retain keyboard focus or intercept clicks.
            if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: host) {
                window?.makeFirstResponder(nil)
            }
            host.isHidden = true
        }
        let host: NSHostingView<AnyView>
        if let existing = pages[page] {
            host = existing
        } else {
            let content: AnyView
            switch page {
            case .chat: content = AnyView(ChatView())
            case .models: content = AnyView(ModelsView())
            case .device: content = AnyView(DeviceView())
            }
            host = NSHostingView(rootView: AnyView(content.environment(store)
                .foregroundStyle(Theme.ink).tint(Theme.ember)))
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            host.frame = bounds
            pages[page] = host
            addSubview(host)
        }
        host.frame = bounds
        host.isHidden = false
        selectedPage = page
    }
}
