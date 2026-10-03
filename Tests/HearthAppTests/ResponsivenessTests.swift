import XCTest
import Observation
import HearthCore
@testable import Hearth

private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return changed }
    func mark() { lock.lock(); changed = true; lock.unlock() }
}

final class ResponsivenessTests: XCTestCase {
    @MainActor func testCachedCatalogTracksFiltersStorageAndHardware() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.filter = .all; store.fitsOnly = false
        XCTAssertEqual(store.filteredModels.count, store.catalog.count)
        _ = store.filteredGroups // Prime the cache before registering observation.
        let changed = ChangeFlag()
        withObservationTracking { _ = store.filteredGroups } onChange: { changed.mark() }
        store.familyFilter = "Llama"
        XCTAssertTrue(changed.value, "A cache hit must still register view dependencies.")
        XCTAssertTrue(store.filteredModels.allSatisfy { $0.family == "Llama" })
        store.licenseFilter = .permissive
        XCTAssertTrue(store.filteredModels.isEmpty)
        store.resetCatalogFilters()
        store.hardware = Hardware(chip: "Test", cores: 8, memory: 16 << 30, gpu: "Test", gpuWorkingSet: 12 << 30, freeDisk: 256 << 20, architecture: "Apple Silicon")
        store.fitsOnly = true
        let model = try XCTUnwrap(store.catalog.first { $0.id == "qwen3-4b" })
        XCTAssertFalse(store.filteredModels.contains { $0.id == model.id })
        store.partials[model.id] = model.bytes
        XCTAssertTrue(store.filteredModels.contains { $0.id == model.id }, "A resumed download needs only its remaining space.")
        store.partials = [:]; store.installed = [model.id]
        XCTAssertTrue(store.filteredModels.contains { $0.id == model.id })
        _ = store.discoveryPicks; _ = store.recommended
        store.hardware = Hardware(chip: "Small Mac", cores: 4, memory: 4 << 30, gpu: "CPU", gpuWorkingSet: 0, freeDisk: 100 << 30, architecture: "Intel")
        XCTAssertNotEqual(store.recommended?.id, model.id, "A 4 GB Mac must not be recommended a model it cannot fit.")
        if let pick = store.recommended { XCTAssertLessThanOrEqual(store.profile(for: pick).memory(for: pick), store.hardware.modelBudget) }
        XCTAssertFalse(store.filteredModels.contains { $0.id == model.id }, "Installed models must still respect memory fit.")
        XCTAssertEqual(store.discoveryPicks.map(\.id), Discovery.picks(catalog: store.catalog, hardware: store.hardware, installed: store.installed).map(\.id))
        store.filter = .installed
        XCTAssertEqual(store.filteredModels.map(\.id), [model.id])
    }

    @MainActor func testSearchDebouncesToLatestQueryAndClearsImmediately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.filter = .all; store.fitsOnly = false
        store.search = "qwen"; store.search = "gemma"
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.searchQuery, "gemma")
        XCTAssertFalse(store.filteredModels.isEmpty)
        XCTAssertTrue(store.filteredModels.allSatisfy { $0.family == "Gemma" })
        store.search = "phi"; store.search = ""
        XCTAssertEqual(store.filteredModels.count, store.catalog.count)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(store.searchQuery, "")
    }
    @MainActor func testAnswerComparisonCannotBypassCustomLicenseReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let models = store.catalog.filter { ["llama32-1b", "qwen3-17b"].contains($0.id) }
        store.installed = Set(models.map(\.id))
        store.compareAnswers(models: models)
        XCTAssertFalse(store.busy)
        XCTAssertFalse(store.answerComparison.running)
        XCTAssertTrue(store.answerComparison.answers.isEmpty)
        XCTAssertFalse(store.engine?.isRunning == true)
        XCTAssertNotNil(store.error)
    }
    @MainActor func testTypingDoesNotInvalidateCatalogOrConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try LocalStorage(root: root)
        let store = AppStore(storage: storage)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let invalidated = ChangeFlag()
        withObservationTracking {
            _ = store.filteredGroups
            _ = store.conversation
            _ = store.page
        } onChange: { invalidated.mark() }
        for _ in 0..<100 { store.draft += "x" }
        XCTAssertFalse(invalidated.value, "Typing must update only the composer, not the transcript or catalog.")
    }

    @MainActor func testStreamingInvalidatesOnlyLiveReplyAndPersistsPartialAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try LocalStorage(root: root)
        let store = AppStore(storage: storage)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        var chat = Conversation(modelID: "qwen3-06b")
        let reply = ChatMessage(role: "assistant", content: "", modelID: "qwen3-06b", interrupted: true)
        chat.messages = [ChatMessage(role: "user", content: "Test"), reply]
        store.data.conversations = [chat]; store.conversationID = chat.id
        let live = StreamingReply(conversationID: chat.id, message: reply)
        store.streamingReply = live
        let catalogChanged = ChangeFlag(), transcriptChanged = ChangeFlag(), replyChanged = ChangeFlag()
        withObservationTracking { _ = store.filteredGroups } onChange: { catalogChanged.mark() }
        withObservationTracking { _ = store.conversation } onChange: { transcriptChanged.mark() }
        withObservationTracking { _ = live.message } onChange: { replyChanged.mark() }
        for _ in 0..<200 { live.message.content += "word " }
        live.message.reasoning = "Partial thinking"
        XCTAssertFalse(catalogChanged.value)
        XCTAssertFalse(transcriptChanged.value)
        XCTAssertTrue(replyChanged.value)
        XCTAssertEqual(store.conversation?.messages.last?.content, "")
        XCTAssertEqual(store.stateSnapshot.conversations[0].messages.last?.content, live.message.content)
        store.save()
        store.shutdown()
        let saved = try storage.readState().conversations[0].messages.last
        XCTAssertEqual(saved?.content, live.message.content)
        XCTAssertEqual(saved?.reasoning, "Partial thinking")
        XCTAssertTrue(saved?.interrupted == true)
    }
}
