import Foundation
import Markdown

public struct MarkdownRun: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var strikethrough = false
    public var link: URL?
    public init(_ text: String) { self.text = text }
}

public struct MarkdownListItem: Equatable, Sendable {
    public let blocks: [MarkdownBlock]
    public let checked: Bool?
}

public indirect enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownRun])
    case heading(Int, [MarkdownRun])
    case code(language: String, text: String)
    case quote([MarkdownBlock])
    case list(start: Int?, items: [MarkdownListItem])
    case table(header: [[MarkdownRun]], rows: [[[MarkdownRun]]])
    case rule
}

/// Parses CommonMark/GFM into inert native content. Never fetches images or executes HTML.
public enum ChatMarkdown {
    private final class Cached: NSObject {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }
    private static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.countLimit = 100; cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    public static func parse(_ text: String) -> [MarkdownBlock] {
        if let cached = cache.object(forKey: text as NSString) { return cached.blocks }
        let document = Document(parsing: text)
        let blocks = document.children.flatMap { block($0, depth: 0) }
        cache.setObject(Cached(blocks), forKey: text as NSString, cost: text.utf8.count * 3)
        return blocks
    }
    public static func releaseCachedContent() { cache.removeAllObjects() }
    public static func safeLink(_ destination: String?) -> URL? {
        guard let destination, let url = URL(string: destination),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    private static func block(_ node: Markup, depth: Int) -> [MarkdownBlock] {
        guard depth < 24 else { return [.paragraph([MarkdownRun(node.format())])] }
        switch node {
        case let p as Paragraph: return [.paragraph(inline(p))]
        case let h as Heading: return [.heading(h.level, inline(h))]
        case let c as CodeBlock: return [.code(language: c.language ?? "", text: c.code)]
        case let q as BlockQuote: return [.quote(q.children.flatMap { block($0, depth: depth + 1) })]
        case let l as OrderedList: return [.list(start: Int(l.startIndex), items: items(l, depth: depth))]
        case let l as UnorderedList: return [.list(start: nil, items: items(l, depth: depth))]
        case let t as Table:
            let header = t.head.children.map { inline($0) }
            let rows = t.body.children.map { row in row.children.map { inline($0) } }
            return [.table(header: header, rows: rows)]
        case is ThematicBreak: return [.rule]
        case let html as HTMLBlock: return [.code(language: "HTML · displayed as text", text: html.rawHTML)]
        default: return node.children.flatMap { block($0, depth: depth + 1) }
        }
    }
    private static func items(_ node: Markup, depth: Int) -> [MarkdownListItem] {
        node.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            let checked: Bool? = item.checkbox.map { $0 == .checked }
            return MarkdownListItem(blocks: item.children.flatMap { block($0, depth: depth + 1) }, checked: checked)
        }
    }
    private static func inline(_ node: Markup, style: MarkdownRun = MarkdownRun(""), depth: Int = 0) -> [MarkdownRun] {
        var style = style
        if depth > 32 { style.text = node.format(); return [style] }
        switch node {
        case let t as Markdown.Text: style.text = t.string; return [style]
        case let c as InlineCode: style.text = c.code; style.code = true; return [style]
        case is SoftBreak: style.text = " "; return [style]
        case is LineBreak: style.text = "\n"; return [style]
        case is Strong: style.bold = true
        case is Emphasis: style.italic = true
        case is Strikethrough: style.strikethrough = true
        case let l as Markdown.Link: style.link = safeLink(l.destination)
        case let image as Markdown.Image:
            style.text = "[Image: \(image.plainText.isEmpty ? "not loaded" : image.plainText)]"; return [style]
        case let html as InlineHTML: style.text = html.rawHTML; return [style]
        default: break
        }
        return node.children.flatMap { inline($0, style: style, depth: depth + 1) }
    }
}
