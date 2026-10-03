import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// An image or PDF the user attached. Its files live in the attachment library, named by `id`.
public struct ChatAttachment: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, pdf }
    public let id: UUID
    public let kind: Kind
    public let name: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let pageCount: Int?
    /// Pages whose text was read; a very long PDF stops early.
    public let pagesRead: Int?
    /// Pages read with text recognition because they had no text layer.
    public let scannedPages: Int?
    /// Characters of recognized or extracted text; zero when an image has no readable text.
    public let textCharacters: Int
    /// Characters per PDF page, so the interface can say how much fits without reading the text.
    public var pageCharacters: [Int]? = nil

    public var imageFile: String { "\(id.uuidString)-image.jpg" }
    public var thumbnailFile: String { "\(id.uuidString)-thumb.jpg" }
    public var textFile: String { "\(id.uuidString)-text.txt" }
    public var hasText: Bool { textCharacters > 0 }
}

public struct AttachmentLibrary: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func url(_ file: String) -> URL { directory.appendingPathComponent(file) }
    public func text(_ attachment: ChatAttachment) -> String {
        (try? String(contentsOf: url(attachment.textFile), encoding: .utf8)) ?? ""
    }
    /// PDF text is stored one page per form-feed-separated section.
    public func pages(_ attachment: ChatAttachment) -> [String] {
        text(attachment).components(separatedBy: "\u{0C}")
    }
    func write(_ data: Data, to file: String) throws {
        try data.write(to: url(file), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(file).path)
    }
    /// Removes files whose attachment no message, draft, or in-flight attachment refers to.
    public func prune(keeping referenced: Set<UUID>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            guard let id = UUID(uuidString: String(name.prefix(36))), !referenced.contains(id) else { continue }
            try? FileManager.default.removeItem(at: url(name))
        }
    }
}

/// Turns dropped, pasted, or chosen files into attachments. Synchronous and cancellable;
/// callers run it off the main actor. Nothing leaves the Mac: Vision and PDFKit run locally.
public enum AttachmentProcessor {
    /// Longest side sent to a vision model. At the 1,024-token image cap the engine downsamples
    /// further; this keeps screenshot text legible without storing originals.
    public static let longestSide = 1600
    public static let thumbnailSide = 360
    public static let maximumPDFCharacters = 600_000
    public static let maximumScannedPages = 40

    public static func kind(of url: URL) -> ChatAttachment.Kind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        return type.conforms(to: .image) ? .image : nil
    }

    public static func process(fileAt url: URL, id: UUID = UUID(), into library: AttachmentLibrary,
                               progress: @Sendable (String) -> Void = { _ in }) throws -> ChatAttachment {
        switch kind(of: url) {
        case .pdf: return try processPDF(at: url, id: id, library: library, progress: progress)
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw unreadable(url.lastPathComponent) }
            return try processImage(source, name: url.lastPathComponent, id: id, library: library)
        case nil: throw HearthError.message("\(url.lastPathComponent) isn't an image or PDF.")
        }
    }

    public static func process(imageData: Data, name: String, id: UUID = UUID(), into library: AttachmentLibrary) throws -> ChatAttachment {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { throw unreadable(name) }
        return try processImage(source, name: name, id: id, library: library)
    }

    private static func processImage(_ source: CGImageSource, name: String, id: UUID, library: AttachmentLibrary) throws -> ChatAttachment {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longestSide]
        guard CGImageSourceGetCount(source) > 0,
              let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let image = opaque(scaled) else { throw unreadable(name) }
        try checkCancellation()
        let sent = try jpeg(image, quality: 0.88)
        try library.write(sent, to: "\(id.uuidString)-image.jpg")
        try library.write(try thumbnail(of: sent), to: "\(id.uuidString)-thumb.jpg")
        try checkCancellation()
        let text = recognizeText(in: image)
        try library.write(Data(text.utf8), to: "\(id.uuidString)-text.txt")
        return ChatAttachment(id: id, kind: .image, name: name, pixelWidth: image.width, pixelHeight: image.height,
                              pageCount: nil, pagesRead: nil, scannedPages: nil, textCharacters: text.count)
    }

    private static func processPDF(at url: URL, id: UUID, library: AttachmentLibrary, progress: @Sendable (String) -> Void) throws -> ChatAttachment {
        let name = url.lastPathComponent
        guard let document = PDFDocument(url: url) else { throw unreadable(name) }
        if document.isLocked { throw HearthError.message("\(name) is password-protected. Unlock it in Preview, then attach it again.") }
        guard document.pageCount > 0 else { throw HearthError.message("\(name) has no pages.") }
        var pages: [String] = [], characters = 0, scanned = 0
        for index in 0..<document.pageCount {
            try checkCancellation()
            if document.pageCount > 3 { progress("Reading page \(index + 1) of \(document.pageCount)") }
            guard let page = document.page(at: index) else { pages.append(""); continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A page without a text layer is usually a scan; read it the way an image is read.
            if text.count < 20, scanned < maximumScannedPages, let image = render(page, longestSide: 2000) {
                let recognized = recognizeText(in: image)
                if recognized.count > text.count { text = recognized; scanned += 1 }
            }
            pages.append(text); characters += text.count
            if characters >= maximumPDFCharacters { break }
        }
        try library.write(Data(pages.joined(separator: "\u{0C}").utf8), to: "\(id.uuidString)-text.txt")
        if let cover = document.page(at: 0).flatMap({ render($0, longestSide: thumbnailSide * 2) }) {
            try library.write(try jpeg(cover, quality: 0.8), to: "\(id.uuidString)-thumb.jpg")
        }
        return ChatAttachment(id: id, kind: .pdf, name: name, pixelWidth: nil, pixelHeight: nil, pageCount: document.pageCount,
                              pagesRead: pages.count, scannedPages: scanned, textCharacters: characters, pageCharacters: pages.map(\.count))
    }

    /// On-device text recognition. Lines come back in Vision's reading order.
    public static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func render(_ page: PDFPage, longestSide: Int) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let width = rotated ? bounds.height : bounds.width, height = rotated ? bounds.width : bounds.height
        guard width > 0, height > 0 else { return nil }
        let scale = CGFloat(longestSide) / max(width, height)
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let image = page.thumbnail(of: size, for: .mediaBox)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil).flatMap(opaque)
    }

    /// JPEG has no transparency; flatten onto white so transparent screenshots don't turn black.
    private static func opaque(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw HearthError.message("Could not prepare the image.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HearthError.message("Could not prepare the image.") }
        return data as Data
    }

    private static func thumbnail(of jpegData: Data) throws -> Data {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: thumbnailSide * 2]
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw HearthError.message("Could not prepare the image.") }
        return try jpeg(small, quality: 0.8)
    }

    private static func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
    private static func unreadable(_ name: String) -> HearthError { .message("\(name) couldn't be opened. It may be damaged or in an unsupported format.") }
}

/// Characters of attachment text one message can carry for a given configuration.
public enum AttachmentBudget {
    /// The output allowance mirrors `LocalEngine.complete`. English averages about four
    /// characters per token; three leaves room for other languages and markup.
    public static func characters(contextTokens: Int, thinkingTokens: Int, images: Int) -> Int {
        let output = (thinkingTokens > 0 ? thinkingTokens + 1536 : 2048) + 64
        let available = contextTokens - output - 1200 - images * (LocalEngine.imageTokens + 16)
        return max(1500, available * 3)
    }
    /// How many leading pages of a document fit in `budget` characters.
    public static func pagesThatFit(_ pages: [String], budget: Int) -> Int { pagesThatFit(lengths: pages.map(\.count), budget: budget) }
    public static func pagesThatFit(lengths: [Int], budget: Int) -> Int {
        var used = 0
        for (index, length) in lengths.enumerated() {
            used += length + 16
            if used > budget { return index }
        }
        return lengths.count
    }
}

/// One conversation turn as the engine receives it: text, plus images for a model that can see.
public struct RenderedTurn: Sendable, Equatable {
    public let role: String
    public let text: String
    public let images: [URL]
}

public enum ConversationRenderer {
    /// Recognized text that accompanies an image a model can see. It carries fine print the
    /// downsampled image can't, at about a quarter of the cost of image tokens.
    static let visionTextLimit = 3000

    public static func render(_ messages: [ChatMessage], library: AttachmentLibrary?, vision: Bool, characterBudget: Int) -> [RenderedTurn] {
        messages.filter { ["user", "assistant"].contains($0.role) && (!$0.content.isEmpty || $0.attachments?.isEmpty == false) }
            .map { render($0, library: library, vision: vision, budget: characterBudget) }
    }

    static func render(_ message: ChatMessage, library: AttachmentLibrary?, vision: Bool, budget: Int) -> RenderedTurn {
        guard message.role == "user", let attachments = message.attachments, !attachments.isEmpty, let library else {
            return RenderedTurn(role: message.role, text: message.content, images: [])
        }
        var sections: [String] = [], images: [URL] = [], remaining = budget
        for attachment in attachments {
            switch attachment.kind {
            case .pdf:
                let pages = library.pages(attachment)
                let fitting = max(1, AttachmentBudget.pagesThatFit(pages, budget: remaining))
                var body = pages.prefix(fitting).enumerated().map { "[Page \($0.offset + 1)]\n\($0.element)" }.joined(separator: "\n\n")
                if body.count > remaining { body = String(body.prefix(max(0, remaining))) + "…" }
                remaining -= body.count
                let total = attachment.pageCount ?? pages.count
                var header = "[Attached document “\(attachment.name)” · \(total) page\(total == 1 ? "" : "s")]"
                if fitting < total { header += "\n[Only pages 1–\(fitting) are included; the rest did not fit in your memory. Say so if the answer may be in later pages.]" }
                sections.append("\(header)\n\(body)\n[End of “\(attachment.name)”]")
            case .image:
                let text = library.text(attachment)
                if vision {
                    images.append(library.url(attachment.imageFile))
                    var section = "[Attached image “\(attachment.name)”]"
                    if text.count >= 12 {
                        let limit = min(visionTextLimit, max(0, remaining))
                        let excerpt = text.count > limit ? String(text.prefix(limit)) + "…" : text
                        remaining -= excerpt.count
                        section += "\nText recognized in it (may contain errors):\n\(excerpt)"
                    }
                    sections.append(section)
                } else if text.isEmpty {
                    sections.append("[Attached image “\(attachment.name)”: you can't see images, and no readable text was found in it. Tell the user you can't see this image and that a model that can see images can help.]")
                } else {
                    let excerpt = text.count > remaining ? String(text.prefix(max(0, remaining))) + "…" : text
                    remaining -= excerpt.count
                    sections.append("[Attached image “\(attachment.name)”: you can't see images, so this is the text recognized in it. Layout, colors, and pictures are not available.]\n\(excerpt)\n[End of text from “\(attachment.name)”]")
                }
            }
        }
        if !message.content.isEmpty { sections.append(message.content) }
        return RenderedTurn(role: message.role, text: sections.joined(separator: "\n\n"), images: images)
    }
}
