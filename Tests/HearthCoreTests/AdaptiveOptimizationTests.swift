import XCTest
@testable import HearthCore

final class AdaptiveOptimizationTests: XCTestCase {
    func mac(cores: Int = 10, memory: UInt64 = 16 << 30, metal: Bool = true, architecture: String = "Apple Silicon") -> Hardware {
        Hardware(chip: "Test chip", cores: cores, memory: memory, gpu: metal ? "Metal" : "CPU only", gpuWorkingSet: metal ? memory * 3 / 4 : 0,
                 freeDisk: 100 << 30, architecture: architecture, performanceCores: 4)
    }
    let base = RuntimeProfile(contextTokens: 4096, thinkingTokens: 512, threads: 8)
    func model(_ id: String = "qwen3-4b") throws -> LocalModel { try XCTUnwrap(LocalModel.catalog().first { $0.id == id }) }
    func trial(_ seconds: [Double], hash: String = "same", memory: UInt64 = 3 << 30, truncated: Bool = false, firstAnswer: Double = 0.3) -> OptimizationTrial {
        OptimizationTrial(name: "test", profile: base, samples: seconds.map { OptimizationSample(seconds: $0, firstAnswerSeconds: firstAnswer, tokensPerSecond: 40, tokens: 80, outputSHA256: hash, truncated: truncated) }, memoryBytes: memory)
    }
    func testLegacyProfilesDecodeToSafeSettingsAndNewIDsInvalidateOldMeasurements() throws {
        let old = Data(#"{"contextTokens":4096,"thinkingTokens":512,"threads":8}"#.utf8)
        let profile = try JSONDecoder().decode(RuntimeProfile.self, from: old)
        XCTAssertEqual(profile.execution, .init()); XCTAssertNil(profile.machineID)
        XCTAssertTrue(profile.id.hasPrefix("v3-"))
        XCTAssertEqual(try JSONDecoder().decode(RuntimeProfile.self, from: JSONEncoder().encode(profile)), profile)
    }
    func testCandidateSearchFitsDifferentMachinesAndSkipsUnreviewedArchitectures() throws {
        let dense = try model(), hybrid = try model("qwen35-4")
        let candidates = AdaptiveOptimizer.candidates(baseline: base, model: dense, hardware: mac())
        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(candidates.contains { $0.profile.execution.backendSampling })
        XCTAssertTrue(candidates.contains { $0.profile.execution.speculative })
        XCTAssertEqual(candidates.first?.profile.threads, 4)
        for item in candidates {
            XCTAssertEqual(item.profile.contextTokens, base.contextTokens)
            XCTAssertEqual(item.profile.thinkingTokens, base.thinkingTokens)
            XCTAssertEqual(item.profile.cacheType, base.cacheType)
        }
        XCTAssertFalse(AdaptiveOptimizer.candidates(baseline: base, model: hybrid, hardware: mac()).contains { $0.profile.execution.speculative })
        let intel = mac(cores: 4, memory: 8 << 30, metal: false, architecture: "Intel")
        let cpu = AdaptiveOptimizer.candidates(baseline: RuntimeProfile(contextTokens: 2048, thinkingTokens: 0, threads: 3), model: dense, hardware: intel)
        XCTAssertFalse(cpu.contains { $0.profile.execution.backendSampling })
        XCTAssertEqual(cpu.first?.profile.execution.batchTokens, 128)
        XCTAssertTrue(cpu.allSatisfy { $0.profile.threads <= intel.cores })
    }
    func testRejectsSmallGainsChangedAnswersTruncationAndMemoryOverflow() {
        let baseline = trial([10, 10, 10])
        XCTAssertTrue(AdaptiveOptimizer.improves(trial([8, 8, 8]), over: baseline, budget: 4 * gib))
        XCTAssertFalse(AdaptiveOptimizer.improves(trial([9.5, 9.5, 9.5]), over: baseline, budget: 4 * gib))
        XCTAssertFalse(AdaptiveOptimizer.improves(trial([8, 8, 8], hash: "different"), over: baseline, budget: 4 * gib))
        XCTAssertFalse(AdaptiveOptimizer.improves(trial([8, 8, 8], truncated: true), over: baseline, budget: 4 * gib))
        XCTAssertFalse(AdaptiveOptimizer.improves(trial([8, 8, 8], memory: 5 << 30), over: baseline, budget: 4 * gib))
        XCTAssertFalse(AdaptiveOptimizer.improves(trial([8, .nan, 8]), over: baseline, budget: 4 * gib))
        XCTAssertFalse(AdaptiveOptimizer.improves(trial([8, 8]), over: baseline, budget: 4 * gib))
    }
    func testOneFastRepetitiveTaskCannotHideOtherRegressions() {
        XCTAssertFalse(AdaptiveOptimizer.improves(trial([12, 5, 5]), over: trial([10, 10, 10]), budget: 4 * gib))
        XCTAssertFalse(AdaptiveOptimizer.improves(trial([8, 8, 8], firstAnswer: 1.2), over: trial([10, 10, 10]), budget: 4 * gib))
        XCTAssertFalse(AdaptiveOptimizer.stable(trial([10, 10, 10]), trial([10, 10, 15])))
        XCTAssertTrue(AdaptiveOptimizer.stable(trial([10, 10, 10]), trial([10.5, 10.3, 10.1])))
    }
    func testHardwareIdentityAndExpiryInvalidateTuning() throws {
        let models = try LocalModel.catalog(), facts = try RecommendationEvidence.load(catalog: models), hw = mac()
        let m = try model()
        let planned = RecommendationPlanner.plan(model: m, evidence: facts.models.first { $0.modelID == m.id }, hardware: hw, budget: hw.modelBudget, goal: .capability)
        let candidate = AdaptiveOptimizer.candidates(baseline: planned, model: m, hardware: hw)[1].profile
        func selected(_ hardware: Hardware, now: Date = Date()) -> RuntimeProfile {
            RecommendationPlanner.evaluate(catalog: [m], evidence: facts, hardware: hardware, profiles: [m.id: candidate], now: now).assessments[0].profile
        }
        XCTAssertEqual(selected(hw).id, candidate.id)
        XCTAssertNotEqual(selected(mac(memory: 32 << 30)).id, candidate.id)
        XCTAssertNotEqual(selected(hw, now: Date().addingTimeInterval(31 * 86400)).id, candidate.id)
        XCTAssertNotEqual(selected(hw, now: Date().addingTimeInterval(-86400)).id, candidate.id)
        XCTAssertNotEqual(mac().optimizationID, mac(metal: false).optimizationID)
        let stale = RuntimeProfile(contextTokens: candidate.contextTokens, thinkingTokens: candidate.thinkingTokens, threads: candidate.threads,
            cacheType: candidate.cacheType, cacheGeometry: candidate.cacheGeometry, execution: candidate.execution,
            machineID: hw.optimizationID, optimizedAt: Date(), tuningKey: "different-weights-or-runtime")
        let staleResult = RecommendationPlanner.evaluate(catalog: [m], evidence: facts, hardware: hw, profiles: [m.id: stale])
        XCTAssertNotEqual(staleResult.assessments[0].profile.id, candidate.id)
    }
    func testExperimentalFlagsAreBoundedAndNeverSyntheticVerification() {
        let flags = ExecutionSettings(batchTokens: 256, batchThreads: 4, backendSampling: true, speculative: true).arguments(threads: 8)
        XCTAssertTrue(flags.contains("ngram-simple")); XCTAssertTrue(flags.contains("--backend-sampling"))
        XCTAssertFalse(flags.contains { $0.contains("spec-synth") || $0.contains("hf-repo") })
        let cpu = ExecutionSettings(cpuOnly: true).arguments(threads: 2)
        XCTAssertTrue(cpu.contains("--no-op-offload")); XCTAssertTrue(cpu.contains("none"))
        XCTAssertFalse(AdaptiveOptimizer.conditionsAllow(MachineConditions(pressure: 4)))
        XCTAssertFalse(AdaptiveOptimizer.conditionsAllow(MachineConditions(thermal: 2)))
        XCTAssertTrue(AdaptiveOptimizer.conditionsAllow(MachineConditions(pressure: 2, lowPower: true)))
    }
    func testPublisherSamplingDependsOnModelAndModeAndKeepsTestsGreedy() throws {
        let qwen = try model()
        let thinking = GenerationPolicy.forModel(qwen, thinking: true)
        XCTAssertEqual(thinking.temperature, 0.6); XCTAssertEqual(thinking.topP, 0.95); XCTAssertEqual(thinking.minP, 0)
        XCTAssertEqual(GenerationPolicy.forModel(qwen, thinking: false).topP, 0.8)
        let hybrid = GenerationPolicy.forModel(try model("qwen35-4"), thinking: true)
        XCTAssertEqual(hybrid.temperature, 1); XCTAssertEqual(hybrid.presencePenalty, 1.5)
        XCTAssertEqual(hybrid.parameters(temperature: 0)["presence_penalty"] as? Double, 0)
        XCTAssertEqual(hybrid.parameters(temperature: 0)["seed"] as? Int, 1729)
        XCTAssertNil(GenerationPolicy.forModel(try model("smollm2-135m"), thinking: false).sourceURL)
    }
    @MainActor func testCancellationUnloadsExperimentalEngineAndDoesNotWriteChats() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["HEARTH_SETUP_FIXTURE"] else { throw XCTSkip("Needs the offline setup fixture.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = try LocalStorage(root: root), model = try model("smollm2-135m")
        let engine = try LocalEngine()
        defer { engine.stop(); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: storage.partialURL(model))
        try await storage.finishInstall(model)
        let hardware = Hardware.inspect(at: root)
        let task = Task {
            try await engine.optimize(model: model, storage: storage, hardware: hardware,
                baseline: RuntimeProfile(contextTokens: 2048, thinkingTokens: 0, threads: 2)) { message in
                    if message.contains("sample 1") { withUnsafeCurrentTask { $0?.cancel() } }
                }
        }
        do { _ = try await task.value; XCTFail("Cancellation should stop the optimizer") }
        catch { XCTAssertTrue(task.isCancelled); XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled) }
        XCTAssertFalse(engine.isRunning); XCTAssertNil(engine.activeProfile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.stateURL.path))
    }
}
