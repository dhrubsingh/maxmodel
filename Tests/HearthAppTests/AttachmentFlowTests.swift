import XCTest
import AppKit
import HearthCore
@testable import Hearth

/// A screenshot-like PNG written to disk, for attaching through the store.
func writeTestImage(width: CGFloat = 1600, height: CGFloat = 1000, text: String = "Invoice #4271", to url: URL) throws {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
    (text as NSString).draw(at: NSPoint(x: 60, y: height - 160), withAttributes: [.font: NSFont.systemFont(ofSize: max(40, height / 20), weight: .bold)])
    NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: width / 3, y: height / 6, width: height / 3, height: height / 3)).fill()
    image.unlockFocus()
    try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
}

@MainActor
private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw XCTSkip("Timed out waiting") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

final class AttachmentFlowTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor func testAttachingALargePhotoNeverBlocksTheInterface() async throws {
        let photo = root.appendingPathComponent("Photo.png")
        try writeTestImage(width: 6000, height: 4000, to: photo)
        let store = AppStore(storage: try LocalStorage(root: root.appendingPathComponent("data")))
        defer { store.shutdown() }
        store.attach(urls: [photo])
        XCTAssertEqual(store.currentPendingAttachments.map(\.name), ["Photo.png"], "A chip appears immediately.")
        var longestStall = 0.0
        let started = Date()
        while !store.currentPendingAttachments.isEmpty {
            let tick = Date()
            try await Task.sleep(for: .milliseconds(5))
            longestStall = max(longestStall, Date().timeIntervalSince(tick) - 0.005)
            guard Date().timeIntervalSince(started) < 30 else { return XCTFail("Processing did not finish") }
        }
        print(String(format: "24 MP photo ready in %.2f s; longest main-thread stall %.0f ms", Date().timeIntervalSince(started), longestStall * 1000))
        // Hosted CI runners are shared virtual machines; the tight limit is for real Macs.
        XCTAssertLessThan(longestStall, ProcessInfo.processInfo.environment["CI"] == nil ? 0.1 : 0.5, "Reading happens off the main thread.")
        let attachment = try XCTUnwrap(store.draftAttachments.first)
        XCTAssertEqual(attachment.pixelWidth, AttachmentProcessor.longestSide)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storage!.attachments.url(attachment.imageFile).path))
    }

    @MainActor func testDraftAttachmentsBelongToTheirConversationAndSurviveRestart() async throws {
        let image = root.appendingPathComponent("Receipt.png"); try writeTestImage(to: image)
        let storage = try LocalStorage(root: root.appendingPathComponent("data"))
        let store = AppStore(storage: storage)
        store.attach(urls: [image])
        try await waitUntil { !store.draftAttachments.isEmpty }
        let attached = store.draftAttachments
        let other = Conversation(modelID: nil)
        store.data.conversations.insert(other, at: 0)
        store.openChat(other)
        XCTAssertTrue(store.draftAttachments.isEmpty, "Another conversation has its own draft.")
        store.newChat()
        XCTAssertEqual(store.draftAttachments, attached)
        store.shutdown()
        let reopened = AppStore(storage: storage)
        defer { reopened.shutdown() }
        XCTAssertEqual(reopened.draftAttachments, attached, "Unsent attachments survive a restart, like draft text.")
    }

    @MainActor func testRemovingDeletingAndEditingKeepAttachmentFilesTidy() async throws {
        let first = root.appendingPathComponent("One.png"), second = root.appendingPathComponent("Two.png")
        try writeTestImage(to: first); try writeTestImage(to: second)
        let store = AppStore(storage: try LocalStorage(root: root.appendingPathComponent("data")))
        defer { store.shutdown() }
        let library = try XCTUnwrap(store.storage?.attachments)
        store.attach(urls: [first, second])
        try await waitUntil { store.draftAttachments.count == 2 }
        let removed = store.draftAttachments[0], sent = store.draftAttachments[1]
        store.removeAttachment(removed.id)
        try await waitUntil { !FileManager.default.fileExists(atPath: library.url(removed.imageFile).path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(sent.imageFile).path))

        var chat = Conversation(modelID: "qwen35-4")
        chat.messages = [ChatMessage(role: "user", content: "What is this?", attachments: [sent]), ChatMessage(role: "assistant", content: "An invoice.")]
        store.data.conversations.insert(chat, at: 0)
        store.draftAttachments = []
        store.openChat(chat)
        store.editLastQuestion()
        XCTAssertEqual(store.draftAttachments, [sent], "Editing a question keeps what it was asking about.")
        let revised = try XCTUnwrap(store.conversationID)
        store.draftAttachments = []
        store.deleteChat(revised)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(sent.imageFile).path), "Still used by the original conversation.")
        store.deleteChat(chat.id)
        try await waitUntil { !FileManager.default.fileExists(atPath: library.url(sent.imageFile).path) }
    }

    @MainActor func testImageSupportStatesAndAlternatives() throws {
        let store = AppStore(storage: try LocalStorage(root: root.appendingPathComponent("data")))
        defer { store.shutdown() }
        store.hardware = Hardware(chip: "Apple M4", cores: 10, memory: 16 << 30, gpu: "Apple M4", gpuWorkingSet: 12 << 30, freeDisk: 200 << 30, architecture: "Apple Silicon")
        let seeing = try XCTUnwrap(store.catalog.first { $0.id == "qwen35-4" }), reading = try XCTUnwrap(store.catalog.first { $0.id == "qwen3-4b" })
        store.installed = [seeing.id, reading.id]; store.data.selectedModelID = reading.id
        XCTAssertEqual(store.imageSupport(for: reading), .unavailable)
        XCTAssertEqual(store.imageCapableAlternative?.id, seeing.id)
        XCTAssertEqual(store.imageSupport(for: seeing), .needsDownload(bytes: seeing.vision!.bytes))
        store.visionDownloads[seeing.id] = 0.4
        XCTAssertEqual(store.imageSupport(for: seeing), .downloading(fraction: 0.4))
        store.visionDownloads = [:]; store.visionInstalled = [seeing.id]
        XCTAssertEqual(store.imageSupport(for: seeing), .ready)
        store.data.offlineOnly = true
        store.downloadVision(reading)
        XCTAssertTrue(store.visionDownloads.isEmpty, "A model without an encoder never downloads one.")
    }

    /// The whole app path with a real model: attach, send, load with image support, look, answer.
    /// Opt-in: HEARTH_VISION_FIXTURES names a data folder whose Models/ has qwen35-4 and its encoder.
    @MainActor func testRealAppLooksAtAnAttachedImage() async throws {
        guard let fixtures = ProcessInfo.processInfo.environment["HEARTH_VISION_FIXTURES"] else { throw XCTSkip("Set HEARTH_VISION_FIXTURES for the real app flow.") }
        let source = URL(fileURLWithPath: fixtures).appendingPathComponent("Models")
        let data = root.appendingPathComponent("data"), models = data.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        for file in ["qwen35-4.gguf", "qwen35-4.mmproj.gguf"] {
            try FileManager.default.linkItem(at: source.appendingPathComponent(file), to: models.appendingPathComponent(file))
        }
        for file in ["qwen35-4.verified", "qwen35-4.mmproj.verified"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: models.appendingPathComponent(file))
        }
        let image = root.appendingPathComponent("Invoice.png"); try writeTestImage(text: "Invoice #4271 · Total due $318.40", to: image)
        let store = AppStore(storage: try LocalStorage(root: data))
        defer { store.shutdown() }
        try await waitUntil { store.installed.contains("qwen35-4") && store.visionInstalled.contains("qwen35-4") }
        let model = try XCTUnwrap(store.catalog.first { $0.id == "qwen35-4" })
        store.data.selectedModelID = model.id
        XCTAssertEqual(store.imageSupport(for: model), .ready)
        store.newChat()
        store.attach(urls: [image])
        try await waitUntil { !store.draftAttachments.isEmpty }
        store.draft = "What is the total due, and what color is the circle?"
        let started = Date()
        store.send()
        var phases = Set<String>()
        while store.busy {
            if let phase = store.streamingReply?.phase { phases.insert(phase) }
            try await Task.sleep(for: .milliseconds(50))
            guard Date().timeIntervalSince(started) < 240 else { return XCTFail("No reply within four minutes") }
        }
        let reply = try XCTUnwrap(store.conversation?.messages.last)
        XCTAssertNil(reply.failure)
        XCTAssertTrue(reply.content.contains("318.40") && reply.content.lowercased().contains("red"), reply.content)
        XCTAssertTrue(store.engine?.visionEnabled == true, "The app loaded image support for a conversation with an image.")
        XCTAssertTrue(phases.contains("Looking at your image…"), "\(phases)")
        print(String(format: "App flow: reply in %.1f s (thinking %d tokens)", Date().timeIntervalSince(started), store.profile(for: model).thinkingTokens), reply.content)
    }

    @MainActor func testImageOnlyMessagesSendWithTheirAttachments() async throws {
        let image = root.appendingPathComponent("Invoice.png"); try writeTestImage(to: image)
        let store = AppStore(storage: try LocalStorage(root: root.appendingPathComponent("data")))
        defer { store.shutdown() }
        let model = try XCTUnwrap(store.catalog.first { $0.id == "qwen35-4" })
        store.newChat()
        store.attach(urls: [image])
        try await waitUntil { !store.draftAttachments.isEmpty }
        let attachment = store.draftAttachments[0]
        // Set after the startup storage refresh, which would otherwise report nothing installed.
        store.installed = [model.id]; store.data.selectedModelID = model.id
        store.send()
        let chat = try XCTUnwrap(store.conversation)
        XCTAssertEqual(chat.title, "Invoice.png")
        XCTAssertEqual(chat.messages.first?.attachments, [attachment])
        XCTAssertEqual(chat.messages.first?.content, "")
        XCTAssertTrue(store.draftAttachments.isEmpty)
        try await waitUntil(60) { !store.busy }
    }
}
