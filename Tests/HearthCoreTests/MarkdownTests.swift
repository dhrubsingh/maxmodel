import XCTest
@testable import HearthCore

final class MarkdownTests: XCTestCase {
    func testNestedListsAndOrderedStart() {
        let blocks = ChatMarkdown.parse("3. First **bold** item\n   - Nested `code`\n4. Second item\n")
        guard case let .list(start, items) = blocks.first else { return XCTFail("Missing ordered list") }
        XCTAssertEqual(start, 3); XCTAssertEqual(items.count, 2)
        guard case let .paragraph(runs) = items[0].blocks[0] else { return XCTFail("Missing item text") }
        XCTAssertTrue(runs.contains { $0.text == "bold" && $0.bold })
        guard case let .list(nestedStart, nested) = items[0].blocks[1] else { return XCTFail("Lost nested list") }
        XCTAssertNil(nestedStart); XCTAssertEqual(nested.count, 1)
    }
    func testCodeIndentationAndIncompleteStreamingFence() {
        let source = "```python\ndef greet(name):\n    return f\"Hello, {name}\"\n"
        for input in [source, source + "```"] {
            guard case let .code(language, code) = ChatMarkdown.parse(input).first else { return XCTFail("Missing code block") }
            XCTAssertEqual(language, "python")
            XCTAssertEqual(code, "def greet(name):\n    return f\"Hello, {name}\"\n")
        }
    }
    func testFourBackticksCanContainTripleBackticks() {
        let blocks = ChatMarkdown.parse("````markdown\n```swift\nlet x = 1\n```\n````")
        guard case let .code(_, code) = blocks.first else { return XCTFail("Missing outer code block") }
        XCTAssertEqual(code, "```swift\nlet x = 1\n```\n")
    }
    func testTableHeadingsQuotesAndTasks() {
        let blocks = ChatMarkdown.parse("## Heading\n\n> A quote\n\n- [x] Done\n- [ ] Pending\n\n| Name | Value |\n| --- | --- |\n| One | **Two** |\n")
        guard case .heading(2, _) = blocks[0], case .quote = blocks[1], case let .list(_, items) = blocks[2],
              case let .table(header, rows) = blocks[3] else { return XCTFail("Lost block structure") }
        XCTAssertEqual(items.map(\.checked), [true, false]); XCTAssertEqual(header.count, 2)
        XCTAssertEqual(rows[0][1].first?.text, "Two"); XCTAssertTrue(rows[0][1].first?.bold == true)
    }
    func testUntrustedLinksImagesAndHTMLRemainInert() {
        XCTAssertNil(ChatMarkdown.safeLink("javascript:alert(1)"))
        XCTAssertNil(ChatMarkdown.safeLink("file:///etc/passwd"))
        XCTAssertNil(ChatMarkdown.safeLink("data:text/html,test"))
        XCTAssertNotNil(ChatMarkdown.safeLink("https://example.com/help"))
        let blocks = ChatMarkdown.parse("![private image](https://example.com/track.png) [danger](javascript:alert)\n\n<script>alert('test')</script>")
        guard case let .paragraph(runs) = blocks[0], case let .code(_, html) = blocks[1] else { return XCTFail("Unexpected parsing") }
        XCTAssertTrue(runs.contains { $0.text.contains("[Image:") }); XCTAssertTrue(runs.allSatisfy { $0.link == nil })
        XCTAssertTrue(html.contains("<script>"))
    }
    func testIncrementalReplyNeverLosesCompletedCode() {
        let prefix = "Steps:\n\n1. First\n2. Second\n\n```swift\nlet answer = 42\n```\n\n"
        for suffix in ["", "**", "**Result", "**Result:** done."] {
            XCTAssertTrue(ChatMarkdown.parse(prefix + suffix).contains { block in
                if case let .code(_, code) = block { return code == "let answer = 42\n" }; return false
            })
        }
    }
}
