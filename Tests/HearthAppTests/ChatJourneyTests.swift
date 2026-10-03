import XCTest
import HearthCore
@testable import Hearth

final class ChatJourneyTests: XCTestCase {
    @MainActor func testDraftsSurviveNavigationRestartAndUnfinishedNewChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try LocalStorage(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: storage)
        let first = Conversation(modelID: "qwen3-4b"), second = Conversation(modelID: "qwen3-06b")
        store.data.conversations = [first, second]
        store.draft = "A new thought"
        store.openChat(first); store.draft = "First unfinished question"
        store.openChat(second); store.draft = "Second unfinished question"
        store.openChat(first)
        XCTAssertEqual(store.draft, "First unfinished question")
        store.shutdown()
        let restored = AppStore(storage: storage)
        XCTAssertEqual(restored.conversationID, first.id)
        XCTAssertEqual(restored.draft, "First unfinished question")
        restored.openChat(second)
        XCTAssertEqual(restored.draft, "Second unfinished question")
        restored.newChat()
        XCTAssertEqual(restored.draft, "A new thought")
        restored.shutdown()
        let newChatRestored = AppStore(storage: storage)
        XCTAssertNil(newChatRestored.conversationID)
        XCTAssertEqual(newChatRestored.draft, "A new thought")
        newChatRestored.deleteChat(first.id)
        XCTAssertNil(newChatRestored.stateSnapshot.drafts?[first.id.uuidString])
        newChatRestored.shutdown()
    }

    @MainActor func testNavigationDuringGenerationPreservesOwnershipAndDrafts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        var running = Conversation(modelID: "qwen3-4b")
        let reply = ChatMessage(role: "assistant", content: "", modelID: "qwen3-4b", interrupted: true)
        running.messages = [ChatMessage(role: "user", content: "Explain gravity"), reply]
        let other = Conversation(modelID: "qwen3-06b")
        store.data.conversations = [running, other]
        store.installed = ["qwen3-4b", "qwen3-06b"]
        store.openChat(running); store.draft = "Follow up"
        store.streamingReply = StreamingReply(conversationID: running.id, message: reply)
        store.busy = true; store.generating = true
        store.openChat(other); store.draft = "Unrelated thought"
        XCTAssertTrue(store.generationIsElsewhere)
        store.streamingReply?.message.content = "Gravity attracts masses."
        XCTAssertTrue(store.conversation?.messages.isEmpty == true)
        XCTAssertEqual(store.stateSnapshot.conversations[0].messages.last?.content, "Gravity attracts masses.")
        store.showRunningConversation()
        XCTAssertEqual(store.draft, "Follow up")
        XCTAssertEqual(store.data.selectedModelID, "qwen3-4b")
        XCTAssertFalse(store.generationIsElsewhere)
        store.newChat(); XCTAssertNil(store.conversationID)
        XCTAssertTrue(store.generationIsElsewhere)
        store.busy = false; store.generating = false
    }

    @MainActor func testEditingAndStartersPreserveUserWorkWithoutStartingInference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        var original = Conversation(modelID: "qwen3-4b")
        original.messages = [ChatMessage(role: "user", content: "First question"), ChatMessage(role: "assistant", content: "First answer"),
                             ChatMessage(role: "user", content: "Question to revise"), ChatMessage(role: "assistant", content: "Original answer")]
        store.data.conversations = [original]; store.openChat(original); store.draft = "Unsent follow up"
        store.editLastQuestion()
        XCTAssertNotEqual(store.conversationID, original.id)
        XCTAssertEqual(store.draft, "Question to revise")
        XCTAssertEqual(store.conversation?.messages, Array(original.messages.prefix(2)))
        XCTAssertEqual(store.data.conversations.first { $0.id == original.id }, original)
        store.openChat(original); XCTAssertEqual(store.draft, "Unsent follow up")
        store.useStarter("Explain a concept: ")
        XCTAssertEqual(store.draft, "Unsent follow up", "Starters must never overwrite an existing draft.")
        store.newChat(); store.useStarter("Explain a concept: ")
        XCTAssertEqual(store.draft, "Explain a concept: ")
        XCTAssertFalse(store.busy); XCTAssertNil(store.streamingReply)
        XCTAssertFalse(store.engine?.isRunning == true)
    }

    @MainActor func testFailedRetryKeepsEarlierAnswerAndDraftWithoutDuplicatingQuestion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try LocalStorage(root: root)
        let store = AppStore(storage: storage)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        var original = Conversation(modelID: "smollm2-135m")
        var answer = ChatMessage(role: "assistant", content: "Partial answer", modelID: "smollm2-135m", interrupted: true)
        answer.reasoning = "Saved thinking"
        original.messages = [ChatMessage(role: "user", content: "A question"), answer]
        store.data.conversations = [original]; store.installed = ["smollm2-135m"]
        store.openChat(original); store.draft = "My next question"
        // Installation deliberately absent: exercise a real load failure, not a mocked success.
        store.retryLastReply()
        let deadline = Date().addingTimeInterval(5)
        while store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.conversation?.messages.count, 2)
        let failed = try XCTUnwrap(store.conversation?.messages.last)
        XCTAssertNotNil(failed.failure)
        XCTAssertEqual(failed.previousReplies?.first?.content, "Partial answer")
        XCTAssertEqual(failed.previousReplies?.first?.reasoning, "Saved thinking")
        XCTAssertEqual(store.draft, "My next question")
        XCTAssertNil(store.error, "Response failures belong to their message, not an unrelated screen.")
        store.shutdown()
        XCTAssertEqual(try storage.readState().conversations[0].messages.last?.previousReplies?.first, answer)
    }

    @MainActor func testAutomaticMemoryReleaseNeverStopsAnActiveRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.activeID = "qwen3-4b"; store.busy = true
        store.releaseMemoryIfIdle(underPressure: true)
        XCTAssertEqual(store.activeID, "qwen3-4b")
        store.busy = false
        store.releaseMemoryIfIdle(underPressure: false)
        XCTAssertEqual(store.activeID, "qwen3-4b", "Recently used models should stay warm.")
        store.releaseMemoryIfIdle(underPressure: false, now: Date().addingTimeInterval(16 * 60))
        let deadline = Date().addingTimeInterval(5)
        while store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(store.activeID)
    }
}
