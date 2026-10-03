import XCTest
import HearthCore
@testable import Hearth

final class AssistantDiscoveryTests: XCTestCase {
    @MainActor func testConversationMemoryPreferencesInvalidatePlansAndPreserveChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try LocalStorage(root: root)
        let store = AppStore(storage: storage)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.hardware = Hardware(chip: "Test Mac", cores: 10, memory: 32 << 30, gpu: "Metal", gpuWorkingSet: 24 << 30, freeDisk: 100 << 30, architecture: "Apple Silicon")
        store.conditions = MachineConditions()
        let model = try XCTUnwrap(store.catalog.first { $0.id == "qwen3-4b" })
        store.data.selectedModelID = model.id; store.draft = "Unsent question"
        let everyday = store.profile(for: model)
        XCTAssertEqual(everyday.cacheType, .q8_0)
        store.setConversationMemory(.longer)
        XCTAssertGreaterThan(store.profile(for: model).contextTokens, everyday.contextTokens)
        store.setCompactCache(false)
        XCTAssertEqual(store.profile(for: model).cacheType, .f16)
        XCTAssertEqual(store.data.selectedModelID, model.id)
        XCTAssertEqual(store.draft, "Unsent question")
        XCTAssertNil(store.activeID)
        XCTAssertNil(store.downloadID)
        store.busy = true; store.setCompactCache(true); store.setConversationMemory(.everyday)
        XCTAssertFalse(store.compactCache); XCTAssertEqual(store.conversationMemory, .longer)
        store.busy = false; store.shutdown()
        XCTAssertEqual(try storage.readState().conversationMemory, .longer)
        XCTAssertEqual(try storage.readState().compactCache, false)
    }

    @MainActor func testRecommendationPreferencesPersistWithoutChangingTheChosenAssistant() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try LocalStorage(root: root)
        let store = AppStore(storage: storage)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.installed = ["qwen3-4b"]
        store.data.selectedModelID = "qwen3-4b"
        store.draft = "Keep this unfinished question"
        store.setRecommendationGoal(.light)
        XCTAssertEqual(store.recommendationGoal, .light)
        XCTAssertEqual(store.data.selectedModelID, "qwen3-4b")
        XCTAssertNil(store.downloadID)
        XCTAssertNil(store.activeID)
        XCTAssertEqual(store.draft, "Keep this unfinished question")
        store.shutdown()
        XCTAssertEqual(try storage.readState().recommendationGoal, .light)
        XCTAssertEqual(try storage.readState().selectedModelID, "qwen3-4b")
    }

    @MainActor func testRecommendationCacheRespondsToMemoryAndFailedLocalTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.hardware = Hardware(chip: "Test Mac", cores: 10, memory: 16 << 30, gpu: "Metal", gpuWorkingSet: 12 << 30, freeDisk: 100 << 30, architecture: "Apple Silicon")
        store.conditions = MachineConditions()
        let first = try XCTUnwrap(store.recommendationReport.recommended)
        store.data.runtimeFailures = [first.id + ":" + first.profile.id: "Cannot load"]
        XCTAssertNotEqual(store.recommended?.id, first.id)
        store.data.runtimeFailures = nil
        XCTAssertEqual(store.recommended?.id, first.id)
        XCTAssertFalse(store.isShortOnFreeMemory(first.model))
        store.conditions = MachineConditions(availableMemory: 2 << 30)
        XCTAssertEqual(store.recommended?.id, first.id, "Memory other apps hold right now must not downgrade the hardware recommendation.")
        XCTAssertTrue(store.isShortOnFreeMemory(first.model), "Explain current memory pressure separately from hardware fit.")
        store.busy = true
        store.setRecommendationGoal(.light)
        XCTAssertEqual(store.recommendationGoal, .capability)
    }

    @MainActor func testSetupCompletesIntoWorkingLocalChat() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["HEARTH_SETUP_FIXTURE"] else {
            throw XCTSkip("Set HEARTH_SETUP_FIXTURE to an existing smollm2-135m GGUF for the offline setup integration check.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try LocalStorage(root: root)
        let store = AppStore(storage: storage)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let model = try XCTUnwrap(store.catalog.first { $0.id == "smollm2-135m" })
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: storage.partialURL(model))
        store.requestDownload(model, startChat: true)
        XCTAssertNil(store.requestedDownload, "Setup for a permissive model should start from one click.")
        let deadline = Date().addingTimeInterval(45)
        while (store.downloadID != nil || store.busy) && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(store.error)
        XCTAssertNil(store.downloadID)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(storage.installed(model))
        XCTAssertEqual(store.page, .chat)
        XCTAssertEqual(store.activeID, model.id)
        XCTAssertNil(store.calibrationID)
        XCTAssertTrue(store.data.benchmarks.isEmpty, "First use must not run synthetic benchmarks before chat.")
        store.send("Reply with exactly: Hello.")
        let originalID = try XCTUnwrap(store.conversationID)
        store.newChat(); store.draft = "An unsent thought in another chat"
        while store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.error)
        XCTAssertNil(store.conversationID)
        XCTAssertEqual(store.draft, "An unsent thought in another chat")
        let original = try XCTUnwrap(store.data.conversations.first { $0.id == originalID })
        XCTAssertFalse(original.messages.last?.content.isEmpty ?? true)
        XCTAssertNotNil(store.data.replyObservations?[model.id])
        XCTAssertTrue(store.data.benchmarks.isEmpty, "Passive timings must not masquerade as controlled benchmarks.")
        store.openChat(original); store.draft = "Next question, still unsent"
        store.retryLastReply()
        while store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.conversation?.messages.last?.failure)
        XCTAssertEqual(store.conversation?.messages.count, 2)
        XCTAssertEqual(store.conversation?.messages.last?.previousReplies?.first?.content, original.messages.last?.content)
        store.continueReply()
        while store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.conversation?.messages.last?.failure)
        XCTAssertEqual(store.draft, "Next question, still unsent")
        store.shutdown()
        XCTAssertEqual(try storage.readState().conversations.first?.messages.count, 4)
    }

    @MainActor func testHomePrioritizesTheUsersInstalledChoiceAndResumesSetup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(store.homeAssistant?.id, store.discoveryPicks.first?.id)
        store.partials["smollm3-3b"] = 1_024
        XCTAssertEqual(store.homeAssistant?.id, "smollm3-3b")
        store.installed = ["qwen3-17b", "gemma4-e2b"]
        store.data.selectedModelID = "gemma4-e2b"
        XCTAssertEqual(store.homeAssistant?.id, "gemma4-e2b", "A new recommendation must not replace the user's choice.")
        store.installed.remove("gemma4-e2b")
        XCTAssertEqual(store.homeAssistant?.id, "qwen3-17b")
    }

    @MainActor func testExplorationDefaultsToCompatibleModelsAndLibraryIgnoresSearchFilters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.fitsOnly = false; store.familyFilter = "Llama"; store.licenseFilter = .custom
        store.search = "incompatible query"; store.categoryFilter = "Coding"
        store.showsFullCatalog = true
        store.openCatalog()
        XCTAssertEqual(store.filter, .all)
        XCTAssertTrue(store.fitsOnly)
        XCTAssertFalse(store.showsFullCatalog)
        XCTAssertEqual(store.search, "")
        XCTAssertEqual(store.familyFilter, "")
        XCTAssertTrue(store.filteredModels.allSatisfy { store.modelFit($0) != .tight && store.hasRoom($0) })
        store.installed = ["qwen3-4b"]
        store.partials["smollm3-3b"] = 42
        store.familyFilter = "Llama"; store.categoryFilter = "Coding"
        XCTAssertEqual(Set(store.libraryModels.map(\.id)), ["qwen3-4b", "smollm3-3b"])
    }

    @MainActor func testDownloadHandoffRequiresIntentAndNeverInterruptsActiveWorkOrBypassesTerms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: try LocalStorage(root: root))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let model = try XCTUnwrap(store.catalog.first { $0.id == "qwen3-17b" })
        let licensed = try XCTUnwrap(store.catalog.first { $0.id == "llama32-1b" })
        store.page = .models; store.installed = [model.id, licensed.id]
        store.downloadDidFinish(model, openChatWhenReady: false)
        XCTAssertEqual(store.page, .models)
        store.busy = true
        store.downloadDidFinish(model, openChatWhenReady: true)
        XCTAssertEqual(store.page, .models)
        store.busy = false
        store.downloadDidFinish(licensed, openChatWhenReady: true)
        XCTAssertEqual(store.page, .models)
        XCTAssertEqual(store.requestedDownload?.id, licensed.id)
        XCTAssertNil(store.data.acceptedLicenses?[licensed.id])
        store.requestedDownload = nil
        store.downloadDidFinish(model, openChatWhenReady: true)
        XCTAssertEqual(store.page, .chat)
        XCTAssertEqual(store.data.selectedModelID, model.id)
    }
}
