import XCTest
import AppKit
import PDFKit
@testable import HearthCore

/// Synthetic test files: a screenshot-like image and PDFs with and without a text layer.
enum AttachmentFixtures {
    static func image(width: CGFloat = 1600, height: CGFloat = 1000, lines: [String] = ["Invoice #4271", "Total due: $318.40"], transparent: Bool = false) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        if !transparent { NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill() }
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 60, y: height - 140 - CGFloat(index) * 90),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: NSColor.black])
        }
        NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: 80, y: 60, width: 220, height: 220)).fill()
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
    /// Page texts become real text; `scanned` page numbers (1-based) are drawn as pictures of text.
    static func pdf(pages: [String], scanned: Set<Int> = [], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for (index, text) in pages.enumerated() {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            if scanned.contains(index + 1) {
                let picture = NSImage(data: image(width: 1224, height: 600, lines: text.components(separatedBy: "\n")))!
                picture.draw(in: NSRect(x: 0, y: 300, width: 612, height: 300))
            } else {
                (text as NSString).draw(in: NSRect(x: 54, y: 54, width: 504, height: 684), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}

final class AttachmentTests: XCTestCase {
    private var directory: URL!
    private var library: AttachmentLibrary!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = AttachmentLibrary(directory: directory)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testScreenshotIsDownscaledReadAndThumbnailedOnDevice() throws {
        let source = directory.appendingPathComponent("Screenshot.png")
        try AttachmentFixtures.image(width: 3200, height: 2000).write(to: source)
        let attachment = try AttachmentProcessor.process(fileAt: source, into: library)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.name, "Screenshot.png")
        XCTAssertEqual(max(attachment.pixelWidth ?? 0, attachment.pixelHeight ?? 0), AttachmentProcessor.longestSide)
        XCTAssertEqual(attachment.pixelWidth, 1600); XCTAssertEqual(attachment.pixelHeight, 1000, "Aspect ratio is kept.")
        let text = library.text(attachment)
        XCTAssertTrue(text.contains("4271"), text); XCTAssertTrue(text.contains("318.40"), text)
        XCTAssertEqual(attachment.textCharacters, text.count)
        for file in [attachment.imageFile, attachment.thumbnailFile, attachment.textFile] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(file).path), file)
            let permissions = try FileManager.default.attributesOfItem(atPath: library.url(file).path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600, "Attachments are private to this user.")
        }
        let thumbnail = try XCTUnwrap(NSImage(contentsOf: library.url(attachment.thumbnailFile)))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), CGFloat(AttachmentProcessor.thumbnailSide * 2))
    }

    /// A Retina screenshot should be ready to send quickly once the text recognizer is warm.
    func testScreenshotProcessingTime() throws {
        let data = AttachmentFixtures.image(width: 2880, height: 1800)
        func timed() throws -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try AttachmentProcessor.process(imageData: data, name: "Screenshot.png", into: library)
            return CFAbsoluteTimeGetCurrent() - start
        }
        let first = try timed(), second = try timed(), third = try timed()
        print(String(format: "Screenshot processing: first %.2f s, then %.2f s and %.2f s", first, second, third))
        // Hosted CI runners are shared virtual machines; the tight limit is for real Macs.
        XCTAssertLessThan(min(second, third), ProcessInfo.processInfo.environment["CI"] == nil ? 1.5 : 8)
    }

    func testTransparentImagesFlattenToWhiteNotBlack() throws {
        let attachment = try AttachmentProcessor.process(imageData: AttachmentFixtures.image(transparent: true), name: "Logo.png", into: library)
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: library.url(attachment.imageFile))))
        let corner = try XCTUnwrap(image.colorAt(x: image.pixelsWide - 4, y: 4)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(corner.brightnessComponent, 0.95)
    }

    func testPDFTextAndScannedPagesAreBothRead() throws {
        let url = directory.appendingPathComponent("Lease.pdf")
        try AttachmentFixtures.pdf(pages: ["The tenant is Jordan Lee. The lease runs for twelve months.", "Monthly rent 2450\nStarts March 3"], scanned: [2], to: url)
        let attachment = try AttachmentProcessor.process(fileAt: url, into: library)
        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertEqual(attachment.pageCount, 2); XCTAssertEqual(attachment.pagesRead, 2)
        XCTAssertEqual(attachment.scannedPages, 1, "Only the page without a text layer needs text recognition.")
        let pages = library.pages(attachment)
        XCTAssertTrue(pages[0].contains("Jordan Lee"), pages[0])
        XCTAssertTrue(pages[1].contains("2450") && pages[1].contains("March"), pages[1])
        XCTAssertEqual(attachment.pageCharacters, pages.map(\.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(attachment.thumbnailFile).path))
    }

    func testUnsupportedAndDamagedFilesExplainThemselves() throws {
        let text = directory.appendingPathComponent("notes.txt"); try Data("hello".utf8).write(to: text)
        XCTAssertNil(AttachmentProcessor.kind(of: text))
        XCTAssertThrowsError(try AttachmentProcessor.process(fileAt: text, into: library)) { XCTAssertTrue($0.localizedDescription.contains("isn't an image or PDF")) }
        let damaged = directory.appendingPathComponent("broken.png"); try Data("not an image".utf8).write(to: damaged)
        XCTAssertThrowsError(try AttachmentProcessor.process(fileAt: damaged, into: library)) { XCTAssertTrue($0.localizedDescription.contains("couldn't be opened")) }
    }

    func testImagesGoOnlyToModelsThatCanSeeAndOthersGetLabelledText() throws {
        let attachment = try AttachmentProcessor.process(imageData: AttachmentFixtures.image(), name: "Invoice.png", into: library)
        let message = ChatMessage(role: "user", content: "What's the total?", attachments: [attachment])
        let seen = ConversationRenderer.render([message], library: library, vision: true, characterBudget: 20_000)[0]
        XCTAssertEqual(seen.images, [library.url(attachment.imageFile)])
        XCTAssertTrue(seen.text.hasSuffix("What's the total?"), "The question follows the image.")
        XCTAssertTrue(seen.text.contains("Text recognized in it"))
        let read = ConversationRenderer.render([message], library: library, vision: false, characterBudget: 20_000)[0]
        XCTAssertTrue(read.images.isEmpty)
        XCTAssertTrue(read.text.contains("you can't see images") && read.text.contains("318.40"), read.text)
        let blank = try AttachmentProcessor.process(imageData: AttachmentFixtures.image(lines: []), name: "Photo.png", into: library)
        let none = ConversationRenderer.render([ChatMessage(role: "user", content: "What is this?", attachments: [blank])], library: library, vision: false, characterBudget: 20_000)[0]
        XCTAssertTrue(none.text.contains("no readable text"), "The model is told to say it can't see, not to guess.")
        XCTAssertEqual(ConversationRenderer.render([ChatMessage(role: "assistant", content: "Sure")], library: library, vision: true, characterBudget: 100)[0].text, "Sure")
    }

    func testLongDocumentsAreCutAtPageBoundariesWithANotice() throws {
        let url = directory.appendingPathComponent("Report.pdf")
        let pages = (1...10).map { "Page \($0) " + String(repeating: "words ", count: 160) }
        try AttachmentFixtures.pdf(pages: pages, to: url)
        let attachment = try AttachmentProcessor.process(fileAt: url, into: library)
        let lengths = try XCTUnwrap(attachment.pageCharacters)
        let budget = lengths.prefix(3).reduce(0, +) + 3 * 16 + 10
        XCTAssertEqual(AttachmentBudget.pagesThatFit(lengths: lengths, budget: budget), 3)
        let rendered = ConversationRenderer.render([ChatMessage(role: "user", content: "Summarize", attachments: [attachment])], library: library, vision: false, characterBudget: budget)[0]
        XCTAssertTrue(rendered.text.contains("[Page 3]")); XCTAssertFalse(rendered.text.contains("[Page 4]"))
        XCTAssertTrue(rendered.text.contains("Only pages 1–3 are included"))
        XCTAssertGreaterThan(AttachmentBudget.characters(contextTokens: 16384, thinkingTokens: 768, images: 1), 30_000, "A 16K window holds roughly 15 pages.")
        XCTAssertLessThan(AttachmentBudget.characters(contextTokens: 16384, thinkingTokens: 768, images: 1), AttachmentBudget.characters(contextTokens: 16384, thinkingTokens: 768, images: 0))
    }

    func testPayloadPutsImagesBeforeTheQuestionAndHandlesModelsWithoutASystemRole() throws {
        let attachment = try AttachmentProcessor.process(imageData: AttachmentFixtures.image(), name: "a.png", into: library)
        let turns = [RenderedTurn(role: "user", text: "Describe it", images: [library.url(attachment.imageFile)])]
        let messages = try LocalEngine.payload(turns, system: "SYSTEM", supportsSystemRole: true)
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["type"] as? String, "image_url")
        XCTAssertTrue(((parts.first?["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        XCTAssertEqual(parts.last?["text"] as? String, "Describe it")
        let merged = try LocalEngine.payload(turns, system: "SYSTEM", supportsSystemRole: false)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual((merged[0]["content"] as? [[String: Any]])?.last?["text"] as? String, "SYSTEM\n\nDescribe it")
    }

    func testAttachmentsPersistAndPruningRemovesOnlyUnreferencedFiles() throws {
        let kept = try AttachmentProcessor.process(imageData: AttachmentFixtures.image(), name: "kept.png", into: library)
        let dropped = try AttachmentProcessor.process(imageData: AttachmentFixtures.image(), name: "dropped.png", into: library)
        let unrelated = directory.appendingPathComponent("README.txt"); try Data("keep".utf8).write(to: unrelated)
        var state = AppData()
        state.conversations = [Conversation(modelID: "qwen35-4")]
        state.conversations[0].messages = [ChatMessage(role: "user", content: "", attachments: [kept])]
        state.draftAttachments = ["new": [kept]]
        let decoded = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.conversations[0].messages[0].attachments, [kept])
        XCTAssertEqual(decoded.draftAttachments?["new"], [kept])
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"id":"\#(UUID())","role":"user","content":"hi","date":0,"interrupted":false}"#.utf8)).attachments,
                     "Conversations saved before attachments still load.")
        library.prune(keeping: [kept.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(kept.imageFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(dropped.imageFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(dropped.textFile).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "Only files named for an attachment are ever removed.")
    }

    func testVisionEncodersArePinnedToTheirWeightsRevision() throws {
        let catalog = try LocalModel.catalog()
        let seeing = catalog.filter(\.canSeeImages)
        XCTAssertEqual(seeing.count, 22)
        for model in seeing {
            let vision = try XCTUnwrap(model.vision)
            XCTAssertEqual(vision.url.deletingLastPathComponent(), model.url.deletingLastPathComponent(), model.id)
            XCTAssertEqual(vision.filename, "mmproj-F16.gguf")
            XCTAssertFalse(model.limitations.contains("text chat only"), model.id)
        }
        XCTAssertTrue(catalog.first { $0.id == "qwen35-4" }?.canSeeImages == true)
        XCTAssertFalse(catalog.first { $0.id == "qwen3-4b" }?.canSeeImages == true)
        XCTAssertFalse(catalog.first { $0.id == "gpt-oss-20b" }?.canSeeImages == true)
    }

    func testRemovingAModelRemovesItsImageSupportAndReceiptsMustMatch() throws {
        let storage = try LocalStorage(root: directory.appendingPathComponent("store"))
        let model = try XCTUnwrap(LocalModel.catalog().first { $0.id == "qwen35-08" })
        let vision = try XCTUnwrap(model.vision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.attachments.directory.path))
        FileManager.default.createFile(atPath: storage.visionURL(model).path, contents: Data(count: 16))
        try Data(vision.sha256.utf8).write(to: storage.visionReceiptURL(model))
        XCTAssertFalse(storage.visionInstalled(model), "A file of the wrong size is not installed image support.")
        FileManager.default.createFile(atPath: storage.visionPartialURL(model).path, contents: Data(count: 8))
        try storage.remove(model)
        for url in [storage.visionURL(model), storage.visionPartialURL(model), storage.visionReceiptURL(model)] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
    }
}
