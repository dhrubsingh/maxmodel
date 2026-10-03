import XCTest
@testable import HearthCore

final class RecommendationTests: XCTestCase {
    private func mac(_ memory: UInt64, disk: Int64 = 200 << 30, chip: String = "Test Mac", cores: Int = 10) -> Hardware {
        Hardware(chip: chip, cores: cores, memory: memory << 30, gpu: "Metal GPU", gpuWorkingSet: memory * 3 / 4 << 30, freeDisk: disk, architecture: "Apple Silicon")
    }
    /// Shipping chip and memory pairings, slowest to fastest within each memory size.
    private let lineup: [(chip: String, cores: Int, memory: UInt64)] = [
        ("Apple M1", 8, 8), ("Apple M4", 10, 16), ("Apple M4", 10, 24), ("Apple M4 Pro", 14, 24), ("Apple M3 Pro", 12, 36),
        ("Apple M4 Pro", 14, 48), ("Apple M2 Max", 12, 64), ("Apple M4 Max", 16, 128), ("Apple M3 Ultra", 32, 256),
    ]
    private func fixtures() throws -> ([LocalModel], RecommendationEvidence) {
        let catalog = try LocalModel.catalog()
        return (catalog, try RecommendationEvidence.load(catalog: catalog))
    }
    func testEvidenceCoversExactWeightsAndNeverFabricatesMissingScores() throws {
        let (models, evidence) = try fixtures()
        XCTAssertEqual(Set(models.map(\.id)), Set(evidence.models.map(\.modelID)))
        XCTAssertGreaterThanOrEqual(evidence.models.filter { $0.capability != nil }.count, 20)
        XCTAssertGreaterThanOrEqual(Set(evidence.models.filter { $0.capability != nil }.compactMap { item in models.first { $0.id == item.modelID }?.family }).count, 5)
        let unknown = try XCTUnwrap(evidence.models.first { $0.modelID == "smollm2-135m" })
        XCTAssertNil(unknown.capability)
        XCTAssertTrue(unknown.metrics.isEmpty)
        for item in evidence.models {
            XCTAssertEqual(item.modelSHA256, models.first { $0.id == item.modelID }?.sha256)
            XCTAssertTrue(item.metrics.allSatisfy { $0.sourceSHA256.count == 64 && $0.sourceURL.scheme == "https" })
        }
    }
    func testMoreMemoryUnlocksCapabilityWithoutAParameterCeiling() throws {
        let (models, evidence) = try fixtures()
        var previous = 0.0
        for ram: UInt64 in [8, 16, 24, 32, 64, 128] {
            // Same chip throughout, so only memory changes.
            let hw = mac(ram, chip: "Apple M4 Max", cores: 16)
            let choice = try XCTUnwrap(RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hw).recommended)
            XCTAssertGreaterThanOrEqual(choice.capability ?? 0, previous - RecommendationPlanner.capabilityTieBand)
            XCTAssertLessThanOrEqual(choice.estimatedMemory, hw.modelBudget)
            XCTAssertLessThanOrEqual(choice.profile.contextTokens, choice.evidence!.maximumContext)
            previous = max(previous, choice.capability ?? 0)
        }
        let roomy = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(64, chip: "Apple M2 Max", cores: 12))
        XCTAssertGreaterThan(try XCTUnwrap(roomy.recommended).model.parameters, 8)
    }
    func testEveryPickFitsAndAnswersWithinItsGoalOnShippingMacs() throws {
        let (models, evidence) = try fixtures()
        var rows: [[String: Any]] = []
        for mac in lineup {
            let hw = self.mac(mac.memory, chip: mac.chip, cores: mac.cores)
            XCTAssertTrue(hw.memoryBandwidth.published, "\(mac.chip) should use Apple's published bandwidth.")
            for goal in RecommendationGoal.allCases {
                let choice = try XCTUnwrap(RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hw, goal: goal).recommended, "\(mac.chip) \(mac.memory) GB \(goal)")
                XCTAssertLessThanOrEqual(choice.estimatedMemory, hw.modelBudget)
                XCTAssertGreaterThanOrEqual(choice.expectedTokensPerSecond, goal.minimumSpeed)
                XCTAssertLessThanOrEqual(choice.expectedFirstAnswer, goal.maximumFirstAnswer)
                if choice.evidence?.usesThinkingEvidence == true {
                    XCTAssertGreaterThanOrEqual(choice.profile.thinkingTokens, RecommendationPlanner.minimumThinkingTokens)
                }
                rows.append(["mac": "\(mac.chip) \(mac.memory) GB", "goal": goal.rawValue, "model": choice.id, "planningScore": choice.capability ?? 0,
                             "tokensPerSecond": choice.expectedTokensPerSecond.rounded(), "firstAnswerSeconds": choice.expectedFirstAnswer.rounded(),
                             "thinkingTokens": choice.profile.thinkingTokens, "context": choice.profile.contextTokens, "memoryGB": choice.estimatedMemory / gib])
            }
        }
        if let path = ProcessInfo.processInfo.environment["HEARTH_RECOMMENDATION_REPORT"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
    func testModelsAreComparedOnlyOnBenchmarksBothPublished() throws {
        let (models, evidence) = try fixtures()
        let report = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(128))
        let qwen = try XCTUnwrap(report.assessment("qwen35-27-q8")), gemma = try XCTUnwrap(report.assessment("gemma4-31b"))
        let shared: Set<String> = ["MMLU-Pro", "GPQA Diamond"]
        XCTAssertEqual(gemma.evidence?.rankedMetricNames, shared, "Fixture assumption: Gemma 4 has no published IFEval.")
        let expected = (qwen.evidence!.score(on: shared)! - QuantizationPolicy.rankingPenalty(qwen.model.quantization))
            - (gemma.evidence!.score(on: shared)! - QuantizationPolicy.rankingPenalty(gemma.model.quantization))
        XCTAssertEqual(try XCTUnwrap(qwen.lead(over: gemma)), expected, accuracy: 1e-9)
        // One shared dimension is not a comparison.
        let instruct = try XCTUnwrap(report.assessment("qwen3-instruct-30b-a3")), sparse = try XCTUnwrap(report.assessment("gemma4-26b-a4b"))
        XCTAssertNil(instruct.lead(over: sparse))
    }
    func testBandwidthComesFromTheChipNotItsMemorySize() {
        XCTAssertEqual(mac(16, chip: "Apple M4").memoryBandwidth.gigabytesPerSecond, 120)
        XCTAssertEqual(mac(36, chip: "Apple M3 Max", cores: 14).memoryBandwidth.gigabytesPerSecond, 300)
        XCTAssertEqual(mac(48, chip: "Apple M3 Max", cores: 16).memoryBandwidth.gigabytesPerSecond, 400)
        XCTAssertEqual(mac(36, chip: "Apple M4 Max", cores: 14).memoryBandwidth.gigabytesPerSecond, 410)
        XCTAssertEqual(mac(128, chip: "Apple M4 Max", cores: 16).memoryBandwidth.gigabytesPerSecond, 546)
        let unknown = mac(64, chip: "Apple M9 Pro").memoryBandwidth
        XCTAssertFalse(unknown.published)
        XCTAssertEqual(unknown.gigabytesPerSecond, 200, "An unlisted chip falls back to a cautious value for its tier.")
        let intel = Hardware(chip: "Intel(R) Core(TM) i9", cores: 16, memory: 32 << 30, gpu: "AMD", gpuWorkingSet: 8 << 30, freeDisk: 1 << 40, architecture: "Intel")
        XCTAssertFalse(intel.memoryBandwidth.published)
    }
    func testSpeedEstimatesTrackSpeedsMeasuredOnAnM4() throws {
        let (models, evidence) = try fixtures()
        let m4 = mac(16, chip: "Apple M4")
        // Median generation speeds recorded by local benchmarks on an M4 (.test-data/recommendation, smoke, adaptive-optimization).
        for (id, measured) in [("qwen35-4", 25.5), ("qwen3-4b", 24.5), ("smollm3-3b", 42.6), ("qwen3-06b", 157.4)] {
            let model = try XCTUnwrap(models.first { $0.id == id })
            let estimate = SpeedEstimate.tokensPerSecond(model, evidence: evidence.models.first { $0.modelID == id }, hardware: m4)
            XCTAssertEqual(estimate, measured, accuracy: measured * 0.25, id)
        }
    }
    func testNearTiesGoToTheFasterModel() throws {
        let (models, evidence) = try fixtures()
        let pro = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(24, chip: "Apple M4 Pro", cores: 14))
        let compact = try XCTUnwrap(pro.assessment("qwen35-27-iq3")), pick = try XCTUnwrap(pro.recommended)
        XCTAssertTrue(compact.eligible, "Fixture assumption: the compact 27B fits and answers in time on this Mac.")
        XCTAssertEqual(pick.id, "qwen35-9", "Within the tie band, the faster 9B wins over the slower compact 27B.")
        XCTAssertLessThan(abs(try XCTUnwrap(pick.lead(over: compact))), RecommendationPlanner.capabilityTieBand)
        XCTAssertGreaterThan(pick.expectedTokensPerSecond, compact.expectedTokensPerSecond)
        let precise = try XCTUnwrap(pro.assessment("qwen35-9-q6"))
        XCTAssertEqual(precise.capability, pick.capability, "Q6 and Q4 rank equally; the difference is within benchmark noise.")
        XCTAssertGreaterThan(pick.expectedTokensPerSecond, precise.expectedTokensPerSecond)

        // Higher-precision variants must not shift the window between different models.
        let max = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(128, chip: "Apple M4 Max", cores: 16))
        XCTAssertTrue(try XCTUnwrap(max.assessment("qwen35-27-q6")).eligible)
        XCTAssertEqual(max.recommended?.id, "qwen35-35b-a3")
        let withoutVariants = RecommendationPlanner.evaluate(catalog: models.filter { !["qwen35-27-iq3", "qwen35-27-q6", "qwen35-27-q8"].contains($0.id) },
                                                             evidence: evidence, hardware: mac(128, chip: "Apple M4 Max", cores: 16))
        XCTAssertEqual(withoutVariants.recommended?.id, max.recommended?.id)
        XCTAssertEqual(Set(max.choices.map(\.model.baseModelID)).count, max.choices.count, "The shortlist shows each model once.")
    }
    func testModelsTooSlowToThinkInTimeAreExplainedNotRecommended() throws {
        let (models, evidence) = try fixtures()
        let m4 = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(16, chip: "Apple M4"))
        let precise = try XCTUnwrap(m4.assessment("qwen35-9-q6"))
        XCTAssertLessThanOrEqual(precise.estimatedMemory, mac(16, chip: "Apple M4").modelBudget, "Fixture assumption: it fits in memory.")
        XCTAssertFalse(precise.eligible)
        XCTAssertTrue(precise.exclusion?.contains("seconds to think") == true, precise.exclusion ?? "")
        XCTAssertEqual(m4.recommended?.id, "qwen35-4")
        XCTAssertGreaterThan(m4.recommended?.profile.thinkingTokens ?? 0, RecommendationPlanner.minimumThinkingTokens,
                             "Time left within the target goes to more thinking.")
        // The same model gets more thinking on a faster chip, up to the goal's ceiling.
        let fast = try XCTUnwrap(RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(64, chip: "Apple M2 Max", cores: 12)).assessment("qwen35-4"))
        XCTAssertGreaterThan(fast.profile.thinkingTokens, try XCTUnwrap(m4.recommended).profile.thinkingTokens)
        XCTAssertLessThanOrEqual(fast.expectedFirstAnswer, RecommendationGoal.capability.maximumFirstAnswer)
        // A matching local measurement replaces the estimate.
        var measured = Benchmark(modelID: precise.id, firstTokenSeconds: 20, tokensPerSecond: 30, generatedTokens: 300, contextTokens: precise.profile.contextTokens,
                                 chip: "Apple M4", modelSHA256: precise.model.sha256, processMemoryBytes: nil, sampleCount: 3)
        measured.profileID = precise.profile.id
        measured.hardwareID = mac(16, chip: "Apple M4").optimizationID
        let checked = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(16, chip: "Apple M4"), benchmarks: [precise.id: measured])
        XCTAssertTrue(try XCTUnwrap(checked.assessment(precise.id)).eligible)
        XCTAssertEqual(try XCTUnwrap(checked.assessment(precise.id)).expectedTokensPerSecond, 30)
    }
    func testCompressionAllowancesAreOrdered() {
        XCTAssertLessThan(QuantizationPolicy.penalty("Q8_0"), QuantizationPolicy.penalty("Q6_K"))
        XCTAssertLessThan(QuantizationPolicy.penalty("Q4_K_M"), QuantizationPolicy.penalty("UD-IQ3_XXS"))
        XCTAssertEqual(QuantizationPolicy.penalty("MXFP4"), 0, "gpt-oss is published natively in MXFP4.")
    }
    func testCapabilityDoesNotFollowParameterCountOrLegacyPreferences() throws {
        let (models, evidence) = try fixtures()
        let subset = models.filter { ["qwen3-instruct-4", "qwen3-4b", "llama31-8b"].contains($0.id) }
        let report = RecommendationPlanner.evaluate(catalog: subset, evidence: evidence, hardware: mac(64))
        XCTAssertEqual(report.recommended?.id, "qwen3-instruct-4")
    }
    func testAvailableMemoryAndRunningModelAreAccountedForWithoutAddingVRAM() throws {
        let hw = mac(16)
        let conditions = MachineConditions(availableMemory: 4 << 30, currentModelMemory: 3 << 30)
        XCTAssertEqual(conditions.budget(for: hw), 6.5 * gib)
        XCTAssertEqual(MachineConditions(availableMemory: 40 << 30, currentModelMemory: 30 << 30).budget(for: hw), hw.modelBudget)
        XCTAssertEqual(MachineConditions(availableMemory: 100, pressure: 4).budget(for: hw), 0)
        XCTAssertLessThan(MachineConditions(pressure: 4).budget(for: hw), hw.modelBudget)
    }
    func testContextShrinksBeforeExcludingAnOtherwiseCapableModel() throws {
        let (models, evidence) = try fixtures()
        let model = try XCTUnwrap(models.first { $0.id == "qwen35-9" })
        let facts = try XCTUnwrap(evidence.models.first { $0.modelID == model.id })
        let large = RecommendationPlanner.plan(model: model, evidence: facts, hardware: mac(16), budget: 12 * gib, goal: .capability)
        let budget = RuntimeProfile(contextTokens: 8192, thinkingTokens: 1024, threads: 8, cacheType: .q8_0, cacheGeometry: facts.cacheGeometry).memory(for: model) / 0.95 + 1024
        let small = RecommendationPlanner.plan(model: model, evidence: facts, hardware: mac(16), budget: budget, goal: .capability)
        XCTAssertGreaterThan(large.contextTokens, small.contextTokens)
        XCTAssertLessThanOrEqual(small.memory(for: model), budget)
        XCTAssertGreaterThan(small.thinkingTokens, 0, "A thinking benchmark must not silently map to thinking disabled.")
    }
    func testStoragePartialDownloadsAndUnknownEvidenceRemainHonest() throws {
        let (models, evidence) = try fixtures()
        let model = try XCTUnwrap(models.first { $0.id == "qwen3-instruct-4" })
        let full = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(16, disk: 0))
        XCTAssertNil(full.recommended)
        let installed = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(16, disk: 0), installed: [model.id])
        XCTAssertEqual(installed.recommended?.id, model.id)
        let resumable = RecommendationPlanner.evaluate(catalog: [model], evidence: evidence, hardware: mac(16, disk: 128 << 20), partials: [model.id: model.bytes])
        XCTAssertEqual(resumable.recommended?.id, model.id)
        let unknown = RecommendationPlanner.evaluate(catalog: models.filter { $0.id == "smollm2-135m" }, evidence: evidence, hardware: mac(16))
        XCTAssertNil(unknown.recommended)
        XCTAssertEqual(unknown.assessments.count, 1, "Missing evidence must not remove the downloadable model.")
    }
    func testOnlyMatchingMeasurementsCanChangeARecommendation() throws {
        let (models, evidence) = try fixtures()
        let hw = mac(16)
        let initial = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hw)
        let choice = try XCTUnwrap(initial.recommended)
        var benchmark = Benchmark(modelID: choice.id, firstTokenSeconds: 60, tokensPerSecond: 1, generatedTokens: 80,
                                  contextTokens: choice.profile.contextTokens, chip: hw.chip, modelSHA256: choice.model.sha256, processMemoryBytes: nil, sampleCount: 3)
        let mismatch = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hw, benchmarks: [choice.id: benchmark])
        XCTAssertEqual(mismatch.recommended?.id, choice.id, "Old unversioned tests cannot influence this configuration.")
        benchmark.profileID = choice.profile.id
        benchmark.hardwareID = hw.optimizationID
        let measured = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hw, benchmarks: [choice.id: benchmark])
        XCTAssertNotEqual(measured.recommended?.id, choice.id)
        XCTAssertNotNil(measured.assessment(choice.id)?.exclusion)
        let expired = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hw, benchmarks: [choice.id: benchmark], now: Date().addingTimeInterval(31 * 86400))
        XCTAssertEqual(expired.recommended?.id, choice.id)
        let future = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hw, benchmarks: [choice.id: benchmark], now: Date.distantPast)
        XCTAssertEqual(future.recommended?.id, choice.id)
    }
    func testBasicCheckFailuresAndLoadingFailuresAreActionable() throws {
        let (models, evidence) = try fixtures()
        let hw = mac(16)
        let initial = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hw)
        let choice = try XCTUnwrap(initial.recommended)
        var benchmark = Benchmark(modelID: choice.id, firstTokenSeconds: 1, tokensPerSecond: 50, generatedTokens: 80, contextTokens: choice.profile.contextTokens, chip: hw.chip, modelSHA256: choice.model.sha256, processMemoryBytes: nil, sampleCount: 3)
        benchmark.profileID = choice.profile.id
        benchmark.hardwareID = hw.optimizationID
        benchmark.checks = LocalCalibration.tasks.map { LocalAnswerCheck(name: $0.name, passed: false) }
        let checked = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hw, benchmarks: [choice.id: benchmark])
        XCTAssertNotEqual(checked.recommended?.id, choice.id)
        XCTAssertTrue(checked.assessment(choice.id)?.exclusion?.contains("basic answer checks") == true)
        let failed = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hw, failures: [choice.id + ":" + choice.profile.id: "Could not load"])
        XCTAssertNotEqual(failed.recommended?.id, choice.id)
        XCTAssertEqual(failed.assessment(choice.id)?.exclusion, "Could not load")
    }
    func testPreferencesStayWithinTheDisclosedCapabilityBand() throws {
        let (models, evidence) = try fixtures()
        let best = try XCTUnwrap(RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(32)).recommended)
        for (goal, band) in [(RecommendationGoal.balanced, 5.0), (.light, 15.0)] {
            let choice = try XCTUnwrap(RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: mac(32), goal: goal).recommended)
            XCTAssertGreaterThanOrEqual(choice.capability ?? 0, (best.capability ?? 0) - band)
        }
    }
    func testCalibrationChecksRejectInventedOrMalformedAnswers() {
        for task in LocalCalibration.tasks {
            XCTAssertTrue(LocalCalibration.passes(task.expected == "json" ? "{\"count\":3,\"color\":\"blue\"}" : task.expected, task: task))
            XCTAssertFalse(LocalCalibration.passes("I think the answer is probably " + task.expected, task: task))
        }
        XCTAssertFalse(LocalCalibration.passes("{\"count\":true,\"color\":\"blue\"}", task: LocalCalibration.tasks.last!))
    }
    func testThinkingBudgetAdaptsToMeasuredSpeedAndMustBeRetested() {
        let profile = RuntimeProfile(contextTokens: 16384, thinkingTokens: 4096, threads: 8)
        let slow = Benchmark(modelID: "test", firstTokenSeconds: 102, tokensPerSecond: 18.6, generatedTokens: 300,
                             contextTokens: 16384, chip: "Test Mac", modelSHA256: "hash", processMemoryBytes: nil, sampleCount: 3)
        let tuned = PerformanceTuning.nextProfile(profile, measurement: slow, goal: .capability)
        XCTAssertEqual(tuned?.thinkingTokens, 512)
        XCTAssertNotEqual(tuned?.id, profile.id, "Old measurements must not transfer to a newly tuned configuration.")
        let fast = Benchmark(modelID: "test", firstTokenSeconds: 2, tokensPerSecond: 100, generatedTokens: 300,
                             contextTokens: 16384, chip: "Test Mac", modelSHA256: "hash", processMemoryBytes: nil, sampleCount: 3)
        let expanded = PerformanceTuning.nextProfile(RuntimeProfile(contextTokens: 4096, thinkingTokens: 512, threads: 8), measurement: fast, goal: .capability)
        XCTAssertGreaterThan(expanded?.thinkingTokens ?? 0, 512)
        XCTAssertLessThanOrEqual(expanded?.thinkingTokens ?? 0, 2048)
        XCTAssertNil(PerformanceTuning.nextProfile(RuntimeProfile(contextTokens: 8192, thinkingTokens: 0, threads: 8), measurement: slow, goal: .capability))
    }
    func testOldSavedStateMigratesWithoutLosingConversations() throws {
        let old = Data("{\"conversations\":[],\"benchmarks\":{},\"offlineOnly\":true,\"selectedModelID\":\"qwen3-4b\"}".utf8)
        let data = try JSONDecoder().decode(AppData.self, from: old)
        XCTAssertNil(data.recommendationGoal)
        XCTAssertNil(data.runtimeProfiles)
        XCTAssertEqual(data.selectedModelID, "qwen3-4b")
        XCTAssertTrue(data.offlineOnly)
    }
}
