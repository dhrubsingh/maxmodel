import XCTest
@testable import HearthCore

final class CoreTests: XCTestCase {
    func testNoticePreservationAvoidsRewritesAndRepairsChangedDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try LocalStorage(root: directory)
        let model = try XCTUnwrap(LocalModel.catalog().first { $0.id == "llama32-1b" })
        try storage.preserveNotices(model)
        let notices = storage.modelsDirectory.appendingPathComponent(model.id + ".notices")
        let paths = try FileManager.default.contentsOfDirectory(at: notices, includingPropertiesForKeys: nil)
        let before = try paths.map { try FileManager.default.attributesOfItem(atPath: $0.path) }
        try storage.preserveNotices(model)
        for (path, attributes) in zip(paths, before) {
            let after = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(attributes[.modificationDate] as? Date, after[.modificationDate] as? Date)
            XCTAssertEqual(after[.posixPermissions] as? NSNumber, 0o600)
        }
        let notice = try XCTUnwrap(model.noticeFiles?.first)
        let changed = notices.appendingPathComponent(notice.filename)
        try Data("damaged notice".utf8).write(to: changed)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: changed.path)
        try storage.preserveNotices(model)
        XCTAssertEqual(try Data(contentsOf: changed), try Data(contentsOf: model.noticeDirectory.appendingPathComponent(notice.filename)))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: changed.path)[.posixPermissions] as? NSNumber, 0o600)
        let provenance = try JSONDecoder().decode(LocalModel.self, from: Data(contentsOf: notices.appendingPathComponent("PROVENANCE.json")))
        XCTAssertEqual(provenance.sha256, model.sha256)
    }

    func testCatalogIsPinnedAndLicensed() throws {
        let models = try LocalModel.catalog()
        XCTAssertEqual(Set(models.map(\.family)), ["Qwen", "SmolLM", "Phi", "Mistral", "Gemma", "Llama", "Granite", "OLMo", "DeepSeek", "Liquid", "Falcon", "gpt-oss"])
        XCTAssertGreaterThanOrEqual(models.count, 70)
        XCTAssertEqual(models.first { $0.family == "Phi" }?.license, "MIT")
        for model in models {
            XCTAssertEqual(model.needsLicenseReview, !["Apache-2.0", "MIT"].contains(model.license))
            XCTAssertFalse(model.url.path.contains("/main/"))
            XCTAssertGreaterThan(model.estimatedMemory, Double(model.bytes))
            XCTAssertEqual(model.contextTokens, 4096)
        }
    }
    func testGroupedCatalogPreservesEveryVariantAndCustomLicenseNotices() throws {
        let models = try LocalModel.catalog()
        let groups = ModelGroup.aggregate(models)
        XCTAssertLessThan(groups.count, models.count)
        XCTAssertEqual(Set(groups.flatMap(\.models).map(\.id)), Set(models.map(\.id)))
        let llama = try XCTUnwrap(models.first { $0.id == "llama32-1b" })
        XCTAssertTrue(llama.needsLicenseReview)
        XCTAssertEqual(llama.attribution, "Built with Llama")
        XCTAssertTrue(llama.noticeFiles!.contains { $0.filename == "NOTICE.txt" })
        XCTAssertTrue(llama.noticeFiles!.contains { $0.filename == "USE_POLICY.md" })
        XCTAssertTrue(llama.licenseText.contains("LLAMA 3.2 COMMUNITY LICENSE AGREEMENT"))
        let gemma4 = try XCTUnwrap(models.first { $0.id == "gemma4-e2b" })
        XCTAssertFalse(gemma4.needsLicenseReview) // Same family can have different licenses.
        XCTAssertTrue(try XCTUnwrap(models.first { $0.id == "gemma3-1b" }).needsLicenseReview)
    }
    func testHardwareFitDoesNotIgnoreDownloadSpace() throws {
        let model = try XCTUnwrap(LocalModel.catalog().first)
        let hw = Hardware(chip: "M4", cores: 10, memory: 16 << 30, gpu: "M4", gpuWorkingSet: 12 << 30, freeDisk: 200 << 20, architecture: "Apple Silicon")
        XCTAssertEqual(hw.fit(model), .comfortable)
        XCTAssertFalse(hw.hasStorage(for: model))
        XCTAssertTrue(hw.hasStorage(for: model, partialBytes: model.bytes))
    }
    func testUnifiedMemoryIsNotDoubleCounted() throws {
        let hw = Hardware(chip: "Apple M1 Pro", cores: 10, memory: 16 << 30, gpu: "M1 Pro", gpuWorkingSet: 12 << 30, freeDisk: 100 << 30, architecture: "Apple Silicon")
        XCTAssertEqual(hw.modelBudget, 12 * gib)
        let recommended = try XCTUnwrap(hw.recommended(in: try LocalModel.catalog()))
        XCTAssertGreaterThan(recommended.parameters, 4, "A 16 GB Mac with the bandwidth to run larger models must not be capped at the old default size.")
        let tiny = Hardware(chip: "Test", cores: 4, memory: 4 << 30, gpu: "CPU", gpuWorkingSet: 0, freeDisk: 100 << 30, architecture: "Intel")
        // With published results for very small models, even a 4 GB Mac gets a pick, and it must fit.
        let catalog = try LocalModel.catalog()
        if let pick = RecommendationPlanner.evaluate(catalog: catalog, evidence: try RecommendationEvidence.load(catalog: catalog), hardware: tiny).recommended {
            XCTAssertLessThanOrEqual(pick.estimatedMemory, tiny.modelBudget, "The planned configuration, including its conversation window, must fit.")
            XCTAssertLessThan(pick.model.parameters, 1.5)
        }
    }
    func testStateRoundTripAndCorruptionPreservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try LocalStorage(root: directory)
        var state = AppData(); var chat = Conversation()
        chat.messages = [ChatMessage(role: "user", content: "Private test text")]
        state.conversations = [chat]; state.offlineOnly = true
        try storage.save(state)
        XCTAssertEqual(try storage.readState().conversations[0].messages[0].content, "Private test text")
        XCTAssertTrue(try storage.readState().offlineOnly)
        try Data("broken-json".utf8).write(to: storage.stateURL)
        XCTAssertThrowsError(try storage.readState())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("conversations-recovery-") })
    }
    func testPartialFileIsNotAnInstalledModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try LocalStorage(root: directory)
        let model = try XCTUnwrap(LocalModel.catalog().first)
        try Data("GGUF incomplete".utf8).write(to: storage.partialURL(model))
        XCTAssertFalse(storage.installed(model))
        try storage.remove(model)
        XCTAssertEqual(storage.fileSize(storage.partialURL(model)), 0)
    }
    func testIntegrityRejectsWrongContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try LocalStorage(root: directory)
        let model = try XCTUnwrap(LocalModel.catalog().first)
        try Data("bad weights".utf8).write(to: storage.partialURL(model))
        do { try await storage.finishInstall(model); XCTFail("Accepted corrupt model") } catch { }
        XCTAssertFalse(storage.installed(model))
    }
    func testStreamParserHandlesContentUsageAndErrors() throws {
        XCTAssertNil(try StreamEvent.parse(": ping"))
        XCTAssertNil(try StreamEvent.parse("data: [DONE]"))
        XCTAssertEqual(try StreamEvent.parse("data: {\"choices\":[{\"delta\":{\"content\":\"Hello 🌱\"}}]}")?.text, "Hello 🌱")
        XCTAssertEqual(try StreamEvent.parse("data: {\"usage\":{\"completion_tokens\":42}}")?.tokens, 42)
        XCTAssertThrowsError(try StreamEvent.parse("data: {\"error\":{\"message\":\"out of memory\"}}"))
    }
}
