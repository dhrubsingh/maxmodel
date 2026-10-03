import XCTest
import SwiftUI
import HearthCore
@testable import Hearth

final class NavigationTests: XCTestCase {
    @MainActor func testMemoryPressureReclaimsOnlyInactiveScreensAndPreservesDraft() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let container = PageContainer(frame: NSRect(x: 0, y: 0, width: 1000, height: 820))
        weak var oldModels: NSHostingView<AnyView>?
        let visibleChat = try autoreleasepool {
            container.show(.models, store: store)
            oldModels = container.pages[.models]
            container.show(.device, store: store)
            container.show(.chat, store: store)
            let chat = try XCTUnwrap(container.pages[.chat])
            store.draft = "Keep this unsent thought"
            container.discardInactivePages()
            return chat
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(Set(container.pages.keys), [.chat])
        XCTAssertTrue(container.pages[.chat] === visibleChat)
        XCTAssertNil(oldModels)
        XCTAssertFalse(visibleChat.isHidden)
        container.show(.models, store: store)
        XCTAssertNotNil(container.pages[.models])
        XCTAssertEqual(store.draft, "Keep this unsent thought")
        XCTAssertFalse(store.engine?.isRunning == true)
    }

    @MainActor func testSidebarReturnPreservesScrollAndHidesInactiveControls() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.filter = .all; store.fitsOnly = false; store.showsFullCatalog = true
        let container = PageContainer(frame: NSRect(x: 0, y: 0, width: 1000, height: 820))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil }
        container.show(.models, store: store)
        let models = try XCTUnwrap(container.pages[.models])
        models.layoutSubtreeIfNeeded()
        func scrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: models))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        let position = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(position.y, 0)
        store.draft = "Keep my unsent question"
        container.show(.chat, store: store)
        XCTAssertTrue(models.isHidden)
        container.show(.device, store: store)
        container.show(.models, store: store)
        models.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin, position)
        XCTAssertEqual(store.draft, "Keep my unsent question")
        XCTAssertEqual(container.pages.values.filter { !$0.isHidden }.count, 1)
        XCTAssertFalse(store.engine?.isRunning == true, "Sidebar navigation must not load or change models.")
    }

    /// Opt-in native layout benchmark. Uses synthetic chat only; never opens user storage.
    @MainActor func testNavigationLayoutProbe() throws {
        guard let report = ProcessInfo.processInfo.environment["HEARTH_NAV_REPORT"] else {
            throw XCTSkip("Set HEARTH_NAV_REPORT to run the native navigation layout probe.")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        var chat = Conversation(modelID: "qwen3-4b")
        for index in 0..<8 {
            chat.messages.append(ChatMessage(role: "user", content: "Explain example \(index)."))
            chat.messages.append(ChatMessage(role: "assistant", content: "Here is **an example**.\n\n- First point\n- Second point\n\n```python\ndef example(value):\n    return value * 2\n```\n\nCheck the result before using it.", modelID: "qwen3-4b"))
        }
        store.data.conversations = [chat]; store.conversationID = chat.id
        store.installed = ["qwen3-4b"]; store.data.selectedModelID = "qwen3-4b"
        store.filter = .all; store.showsFullCatalog = true
        let host = NSHostingView(rootView: ContentView().environment(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        var samples: [[String: Any]] = []
        for cycle in 0..<6 {
            for page in [AppPage.chat, .device, .models] {
                let start = CFAbsoluteTimeGetCurrent()
                store.page = page
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
                host.layoutSubtreeIfNeeded()
                samples.append(["cycle": cycle, "page": page.rawValue, "milliseconds": (CFAbsoluteTimeGetCurrent() - start) * 1000])
            }
        }
        let catalogStart = CFAbsoluteTimeGetCurrent()
        var resultCount = 0
        for _ in 0..<2_000 {
            resultCount += store.filteredGroups.count + store.discoveryPicks.count
            _ = store.recommended
        }
        let lookupReport: [String: Any] = ["iterations": 2_000, "resultCount": resultCount,
                                          "milliseconds": (CFAbsoluteTimeGetCurrent() - catalogStart) * 1000]
        try JSONSerialization.data(withJSONObject: lookupReport, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: report + ".catalog.json"))
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report))
        XCTAssertEqual(store.conversation?.messages.count, 16)
    }

    /// Opt-in visual check: renders the home screen and recommendation details for this Mac's
    /// real hardware into PNGs. Uses empty temporary storage; never opens user data.
    @MainActor func testHomeScreenSnapshotProbe() throws {
        guard let directory = ProcessInfo.processInfo.environment["HEARTH_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set HEARTH_SNAPSHOT_DIR to render home screen snapshots.")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        func render<V: View>(_ view: V, size: NSSize, name: String) throws {
            let host = NSHostingView(rootView: view.environment(store))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            // The home screen reveals its hardware scan over about 1.6 seconds.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.5))
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        store.page = .models
        try render(ContentView(), size: NSSize(width: 1220, height: 820), name: "home.png")
        try render(RecommendationView(), size: NSSize(width: 710, height: 760), name: "how-we-choose.png")
        XCTAssertNotNil(store.recommended)

        // Chat with attachments: a sent screenshot and its answer, and a draft with an image and a PDF
        // for a text-only model, so the image-support notice shows.
        let library = try XCTUnwrap(store.storage?.attachments)
        let screenshot = try AttachmentProcessor.process(fileAt: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../site/assets/screenshot.png").standardized, into: library)
        let invoiceURL = root.appendingPathComponent("Invoice.png"); try writeTestImage(text: "Invoice #4271 · Total due $318.40", to: invoiceURL)
        let invoice = try AttachmentProcessor.process(fileAt: invoiceURL, into: library)
        let leaseURL = root.appendingPathComponent("Lease agreement.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(leaseURL as CFURL, mediaBox: &box, nil)!
        for page in 1...9 {
            pdf.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            ("Lease page \(page). " + String(repeating: "The tenant agrees to the terms in this section. ", count: 60) as NSString)
                .draw(in: NSRect(x: 54, y: 54, width: 504, height: 684), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            NSGraphicsContext.restoreGraphicsState(); pdf.endPDFPage()
        }
        pdf.closePDF()
        let lease = try AttachmentProcessor.process(fileAt: leaseURL, into: library)
        var chat = Conversation(modelID: "qwen35-4")
        chat.title = "Which model does this recommend?"
        chat.messages = [ChatMessage(role: "user", content: "Which model does this recommend, and how big is the download?", attachments: [screenshot]),
                         ChatMessage(role: "assistant", content: "It recommends **Qwen3.5 · 4B**, a **2.6 GB** download. The screen estimates about 18 words a second and up to about 35 seconds of thinking on hard questions.", modelID: "qwen35-4")]
        store.data.conversations = [chat]
        store.installed = ["qwen3-4b", "qwen35-4"]; store.visionInstalled = ["qwen35-4"]
        store.data.selectedModelID = "qwen3-4b"
        store.openChat(chat)
        store.draftAttachments = [invoice, lease]; store.draft = "What's the total due, and when does the lease start?"
        try render(ContentView(), size: NSSize(width: 1220, height: 820), name: "chat-attachments.png")
        store.data.selectedModelID = "qwen3-4b"
        try render(ContentView(), size: NSSize(width: 1220, height: 820), name: "chat-text-only-model.png")
        store.data.selectedModelID = "qwen35-4"; store.visionInstalled = []; store.visionDownloads = ["qwen35-4": 0.42]
        try render(ContentView(), size: NSSize(width: 1220, height: 820), name: "chat-adding-image-support.png")
        try render(DropOverlay(), size: NSSize(width: 820, height: 420), name: "drop-overlay.png")
    }
}
