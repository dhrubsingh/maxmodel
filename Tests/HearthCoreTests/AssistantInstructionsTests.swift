import XCTest
@testable import HearthCore

final class AssistantInstructionsTests: XCTestCase {
    func testDateUsesLocalCalendarAndUnknownCutoffIsNotInvented() {
        let date = ISO8601DateFormatter().date(from: "2026-10-03T01:30:00Z")!
        let prompt = AssistantInstructions.make(knowledgeCutoff: nil, date: date, timeZone: TimeZone(secondsFromGMT: -4 * 3600)!)
        XCTAssertTrue(prompt.contains("2026-10-02"))
        XCTAssertTrue(prompt.contains("not documented a reliable knowledge cutoff"))
        XCTAssertTrue(prompt.contains("cannot browse the internet, open files on your own, see the screen, or perform actions"))
        XCTAssertTrue(prompt.contains("images, and documents the user shares"))
        XCTAssertTrue(prompt.hasPrefix("You are MaxModel, a helpful everyday assistant running locally on the user's computer."))
        let known = AssistantInstructions.make(knowledgeCutoff: "Approximately August 2024", modelName: "Qwen3.5 4B", date: date)
        XCTAssertTrue(known.contains("as the open model Qwen3.5 4B"), "A model that knows its own name won't call a screenshot of itself fictional.")
        XCTAssertTrue(known.contains("Approximately August 2024"))
        XCTAssertTrue(known.contains("current date does not give you current knowledge"))
    }

    func testOldSavedMessagesAndStateRemainReadable() throws {
        let message = ChatMessage(role: "assistant", content: "A saved answer")
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertNil(decoded.reachedLimit); XCTAssertNil(decoded.previousReplies); XCTAssertNil(decoded.failure)
        let state = try JSONDecoder().decode(AppData.self, from: Data("{\"conversations\":[],\"benchmarks\":{},\"offlineOnly\":false}".utf8))
        XCTAssertNil(state.drafts); XCTAssertNil(state.currentConversationKey); XCTAssertNil(state.replyObservations)
    }
}
