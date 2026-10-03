import XCTest
@testable import HearthCore

/// Real models through the real engine. Opt-in: set HEARTH_VISION_FIXTURES to a data folder with
/// Models/qwen35-4.gguf (+ qwen35-4.mmproj.gguf) and Models/qwen3-4b.gguf, e.g. .test-data/smoke.
final class VisionIntegrationTests: XCTestCase {
    @MainActor func testRealModelsSeeImagesReadDocumentsAndFallBackToText() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["HEARTH_VISION_FIXTURES"] else { throw XCTSkip("Set HEARTH_VISION_FIXTURES to run real vision checks.") }
        let storage = try LocalStorage(root: URL(fileURLWithPath: root))
        let catalog = try LocalModel.catalog()
        let seeing = try XCTUnwrap(catalog.first { $0.id == "qwen35-4" }), reading = try XCTUnwrap(catalog.first { $0.id == "qwen3-4b" })
        guard storage.installed(seeing), storage.installed(reading) else { throw XCTSkip("Needs qwen35-4 and qwen3-4b in \(root)/Models.") }
        let encoder = try XCTUnwrap(seeing.vision)
        // The fixture encoder was hash-checked when downloaded; loading verifies it again.
        if !storage.visionInstalled(seeing), storage.fileSize(storage.visionURL(seeing)) == encoder.bytes {
            try Data(encoder.sha256.utf8).write(to: storage.visionReceiptURL(seeing))
        }
        XCTAssertTrue(storage.visionInstalled(seeing))

        let library = storage.attachments
        let invoice = try AttachmentProcessor.process(imageData: AttachmentFixtures.image(), name: "Invoice.png", into: library)
        let leaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("Lease-\(UUID().uuidString).pdf")
        try AttachmentFixtures.pdf(pages: ["Residential lease between Jordan Lee and Maple Homes.", "The monthly rent is $2,450. The lease starts on March 3, 2027."], to: leaseURL)
        let lease = try AttachmentProcessor.process(fileAt: leaseURL, into: library)
        defer { library.prune(keeping: []); try? FileManager.default.removeItem(at: leaseURL) }

        let engine = try LocalEngine()
        defer { engine.stop() }
        let threads = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        var report: [String: Any] = [:]

        var started = Date()
        try await engine.load(seeing, storage: storage, profile: RuntimeProfile(contextTokens: 16384, thinkingTokens: 0, threads: threads), vision: true)
        report["loadWithImageSupportSeconds"] = Date().timeIntervalSince(started)
        XCTAssertTrue(engine.visionEnabled)
        var history = [ChatMessage(role: "user", content: "What is the invoice number and the total due? What shape is drawn below the text, and what color is it? Answer briefly.",
                                   attachments: [invoice])]
        let seen = try await engine.complete(messages: history, attachments: library, temperature: 0, onToken: { _ in })
        let answer = seen.text.lowercased()
        XCTAssertTrue(answer.contains("4271") && answer.contains("318.40"), seen.text)
        XCTAssertTrue(answer.contains("red") && answer.contains("circle"), "The color and shape must be seen, not read: \(seen.text)")
        report["imageFirstAnswerSeconds"] = seen.firstTokenSeconds
        report["imageAnswer"] = seen.text
        report["processMemoryGB"] = Double(engine.memoryFootprint() ?? 0) / 1_073_741_824

        history += [ChatMessage(role: "assistant", content: seen.text), ChatMessage(role: "user", content: "What color was the shape? One word.")]
        let followUp = try await engine.complete(messages: history, attachments: library, temperature: 0, onToken: { _ in })
        XCTAssertTrue(followUp.text.lowercased().contains("red"), followUp.text)
        report["followUpFirstAnswerSeconds"] = followUp.firstTokenSeconds

        // A real Retina screenshot with small interface text: the app's own home screen.
        let screenshotURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../site/assets/screenshot.png").standardized
        let screenshot = try AttachmentProcessor.process(fileAt: screenshotURL, into: library)
        let screen = try await engine.complete(messages: [ChatMessage(role: "user", content: "Which model does this screen recommend, and how big is its download?",
                                                                      attachments: [screenshot])], attachments: library, temperature: 0, onToken: { _ in })
        XCTAssertTrue(screen.text.contains("Qwen3.5") && screen.text.contains("4B") && screen.text.contains("2.6"), screen.text)
        for doubt in ["mockup", "placeholder", "not been officially released", "fictional"] {
            XCTAssertFalse(screen.text.lowercased().contains(doubt), "The model should take the screenshot at face value: \(screen.text)")
        }
        report["screenshotFirstAnswerSeconds"] = screen.firstTokenSeconds
        report["screenshotAnswer"] = screen.text

        let document = try await engine.complete(messages: [ChatMessage(role: "user", content: "When does the lease start, and what is the monthly rent?", attachments: [lease])],
                                                 attachments: library, temperature: 0, onToken: { _ in })
        XCTAssertTrue((document.text.contains("2,450") || document.text.contains("2450")) && document.text.contains("March"), document.text)
        report["documentFirstAnswerSeconds"] = document.firstTokenSeconds

        // As this Mac runs it by default: thinking on.
        started = Date()
        try await engine.load(seeing, storage: storage, profile: RuntimeProfile(contextTokens: 16384, thinkingTokens: 768, threads: threads), vision: true)
        report["reloadSeconds"] = Date().timeIntervalSince(started)
        let thought = try await engine.complete(messages: [ChatMessage(role: "user", content: "What is the total due on this invoice?", attachments: [invoice])],
                                                attachments: library, onToken: { _ in })
        XCTAssertTrue(thought.text.contains("318.40"), thought.text)
        report["thinkingFirstAnswerSeconds"] = thought.firstTokenSeconds

        // A model that can't see gets the recognized text, labelled as such.
        try await engine.load(reading, storage: storage, profile: RuntimeProfile(contextTokens: 8192, thinkingTokens: 0, threads: threads), vision: true)
        XCTAssertFalse(engine.visionEnabled, "Requesting image support for a text-only model is ignored.")
        let read = try await engine.complete(messages: [ChatMessage(role: "user", content: "What is the invoice number and the total due?", attachments: [invoice])],
                                             attachments: library, temperature: 0, onToken: { _ in })
        XCTAssertTrue(read.text.contains("4271") && read.text.contains("318.40"), read.text)
        report["textOnlyFirstAnswerSeconds"] = read.firstTokenSeconds
        report["textOnlyAnswer"] = read.text

        print("Vision integration:", report)
        if let path = environment["HEARTH_VISION_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}
