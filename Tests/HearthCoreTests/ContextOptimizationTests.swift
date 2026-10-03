import XCTest
@testable import HearthCore

final class ContextOptimizationTests: XCTestCase {
    private func fixtures() throws -> ([LocalModel], RecommendationEvidence, Hardware) {
        let models = try LocalModel.catalog()
        let hardware = Hardware(chip: "Test Mac", cores: 10, memory: 32 << 30, gpu: "Metal", gpuWorkingSet: 24 << 30, freeDisk: 500 << 30, architecture: "Apple Silicon")
        return (models, try RecommendationEvidence.load(catalog: models), hardware)
    }
    func testCompressionOnlyChangesCacheCostAndMeasurementIdentity() throws {
        let (models, _, _) = try fixtures()
        let model = try XCTUnwrap(models.first { $0.id == "qwen3-4b" })
        let full = RuntimeProfile(contextTokens: 32768, thinkingTokens: 0, threads: 8)
        let compact = RuntimeProfile(contextTokens: 32768, thinkingTokens: 0, threads: 8, cacheType: .q8_0)
        XCTAssertEqual(compact.conversationMemory(for: model) / full.conversationMemory(for: model), 34.0 / 64.0)
        XCTAssertEqual(full.memory(for: model) - full.conversationMemory(for: model), compact.memory(for: model) - compact.conversationMemory(for: model))
        XCTAssertNotEqual(full.id, compact.id)
        let decoded = try JSONDecoder().decode(RuntimeProfile.self, from: Data("{\"contextTokens\":32768,\"thinkingTokens\":0,\"threads\":8}".utf8))
        XCTAssertEqual(decoded, full, "Old saved profiles retain their original full-precision behavior.")
        XCTAssertEqual(try JSONDecoder().decode(RuntimeProfile.self, from: JSONEncoder().encode(compact)), compact)
    }
    func testLongerMemoryRespectsEveryModelNativeLimitAndBudget() throws {
        let (models, evidence, hardware) = try fixtures()
        var expanded = 0
        for model in models {
            let facts = evidence.models.first { $0.modelID == model.id }
            let short = RecommendationPlanner.plan(model: model, evidence: facts, hardware: hardware, budget: 24 * gib, goal: .capability)
            let long = RecommendationPlanner.plan(model: model, evidence: facts, hardware: hardware, budget: 24 * gib, goal: .capability, conversationMemory: .longer)
            XCTAssertLessThanOrEqual(long.contextTokens, min(65536, facts!.maximumContext))
            if long.contextTokens > 4096 { XCTAssertLessThanOrEqual(long.memory(for: model), 24 * gib) }
            if long.contextTokens > short.contextTokens { expanded += 1 }
        }
        XCTAssertGreaterThan(expanded, 30)
    }
    func testCompressionMakesRoomAndUnsupportedPathsStayFullPrecision() throws {
        let (models, evidence, hardware) = try fixtures()
        let model = try XCTUnwrap(models.first { $0.id == "qwen3-4b" })
        let facts = evidence.models.first { $0.modelID == model.id }
        let compact = RecommendationPlanner.plan(model: model, evidence: facts, hardware: hardware, budget: 7 * gib, goal: .capability, conversationMemory: .longer)
        let full = RecommendationPlanner.plan(model: model, evidence: facts, hardware: hardware, budget: 7 * gib, goal: .capability, conversationMemory: .longer, compactCache: false)
        XCTAssertEqual(compact.cacheType, .q8_0)
        XCTAssertGreaterThan(compact.contextTokens, full.contextTokens)
        XCTAssertLessThanOrEqual(compact.memory(for: model), 7 * gib)
        let intel = Hardware(chip: "Intel", cores: 8, memory: 32 << 30, gpu: "Intel", gpuWorkingSet: 0, freeDisk: 500 << 30, architecture: "x86_64")
        XCTAssertEqual(RecommendationPlanner.plan(model: model, evidence: facts, hardware: intel, budget: 20 * gib, goal: .capability).cacheType, .f16)
        XCTAssertEqual(RecommendationPlanner.plan(model: model, evidence: nil, hardware: hardware, budget: 20 * gib, goal: .capability).cacheType, .f16)
        let unsupported = try XCTUnwrap(models.first { $0.architecture == "deepseek2" })
        XCTAssertEqual(RecommendationPlanner.plan(model: unsupported, evidence: evidence.models.first { $0.modelID == unsupported.id }, hardware: hardware, budget: 20 * gib, goal: .capability).cacheType, .f16)
    }
    func testFallbackRefitsFullPrecisionInsteadOfKeepingAnOversizedWindow() throws {
        let (models, evidence, hardware) = try fixtures()
        let model = try XCTUnwrap(models.first { $0.id == "qwen3-4b" })
        let compact = RuntimeProfile(contextTokens: 40960, thinkingTokens: 0, threads: 8, cacheType: .q8_0)
        let fallback = RuntimeFallback.profile(after: compact, model: model, evidence: evidence.models.first { $0.modelID == model.id }, hardware: hardware, budget: 7 * gib, goal: .capability, conversationMemory: .longer)
        XCTAssertEqual(fallback.cacheType, .f16)
        XCTAssertLessThan(fallback.contextTokens, compact.contextTokens)
        XCTAssertLessThanOrEqual(fallback.memory(for: model), 7 * gib)
    }
    func testProfileChangeDoesNotReuseUnrelatedSpeedOrContextChecks() throws {
        let (models, evidence, hardware) = try fixtures()
        let subset = models.filter { $0.id == "qwen3-4b" }
        let short = RecommendationPlanner.evaluate(catalog: subset, evidence: evidence, hardware: hardware)
        let choice = try XCTUnwrap(short.recommended)
        var measurement = Benchmark(modelID: choice.id, firstTokenSeconds: 0.1, tokensPerSecond: 200, generatedTokens: 100, contextTokens: choice.profile.contextTokens, chip: hardware.chip, modelSHA256: choice.model.sha256, processMemoryBytes: nil, sampleCount: 3)
        measurement.profileID = choice.profile.id
        measurement.hardwareID = hardware.optimizationID
        measurement.contextCheck = ContextCheck(promptTokens: 12000, matchedFacts: 3, totalFacts: 3, firstAnswerSeconds: 4, totalSeconds: 5, truncated: false)
        let changed = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hardware, compactCache: false, benchmarks: [choice.id: measurement])
        XCTAssertNil(changed.assessment(choice.id)?.benchmark)
        measurement.contextCheck = ContextCheck(promptTokens: 12000, matchedFacts: 1, totalFacts: 3, firstAnswerSeconds: 4, totalSeconds: 5, truncated: false)
        let failed = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hardware, benchmarks: [choice.id: measurement])
        XCTAssertNotNil(failed.assessment(choice.id)?.exclusion)
    }
    func testAlreadyCompactArchitecturesKeepPrecisionWhenEverydayMemoryFits() throws {
        let (models, evidence, hardware) = try fixtures()
        for id in ["gemma4-e2b", "qwen35-4"] {
            let model = try XCTUnwrap(models.first { $0.id == id })
            let facts = evidence.models.first { $0.modelID == id }
            let everyday = RecommendationPlanner.plan(model: model, evidence: facts, hardware: hardware, budget: 24 * gib, goal: .capability)
            XCTAssertEqual(everyday.cacheType, .f16)
            let longer = RecommendationPlanner.plan(model: model, evidence: facts, hardware: hardware, budget: 24 * gib, goal: .capability, conversationMemory: .longer)
            XCTAssertEqual(longer.cacheType, id == "gemma4-e2b" ? .f16 : .q8_0,
                           "Shared KV can make even long FP16 context cheap enough to retain precision.")
            XCTAssertGreaterThan(longer.contextTokens, everyday.contextTokens)
        }
    }
    func testReviewedGeometryCountsSharedSlidingAndRecurrentStateSeparately() throws {
        let (models, evidence, hardware) = try fixtures()
        let gemma = try XCTUnwrap(models.first { $0.id == "gemma4-e2b" })
        let gemmaFacts = try XCTUnwrap(evidence.models.first { $0.modelID == gemma.id })
        let geometry = try XCTUnwrap(gemmaFacts.cacheGeometry)
        XCTAssertEqual(geometry.fullAttentionBytesPerToken, 3 * 1 * (512 + 512) * 2)
        XCTAssertEqual(geometry.slidingAttentionBytesPerToken, 12 * 1 * (256 + 256) * 2)
        XCTAssertEqual(geometry.bytes(context: 65536, precision: .f16), 440_401_920)
        let planned = RecommendationPlanner.plan(model: gemma, evidence: gemmaFacts, hardware: hardware, budget: 4.8 * gib, goal: .capability, conversationMemory: .longer)
        XCTAssertEqual(planned.contextTokens, 65536, "Do not budget every shared/sliding layer as a full dense cache.")
        XCTAssertLessThanOrEqual(planned.memory(for: gemma), 4.8 * gib)
        let hybrid = try XCTUnwrap(evidence.models.first { $0.modelID == "qwen35-4" }?.cacheGeometry)
        XCTAssertEqual(hybrid.fullAttentionBytesPerToken, 32768)
        XCTAssertGreaterThan(hybrid.recurrentStateBytes, 0)
        let expectedSaving = Double(32768 * 32768) * (1 - ConversationCache.q8_0.memoryRatio)
        XCTAssertEqual(hybrid.bytes(context: 32768, precision: .f16) - hybrid.bytes(context: 32768, precision: .q8_0), expectedSaving,
                       "FP32 recurrent state and checkpoint copies must never receive the attention quantization factor.")
    }
    func testLongProbeRequiresExactFactsAndDoesNotLeakAnswersInQuestion() throws {
        let probe = ContextProbe.make(lines: 1000, seed: 456789)
        let answer = String(data: try JSONSerialization.data(withJSONObject: probe.expected), encoding: .utf8)!
        XCTAssertEqual(probe.matches(answer), 3)
        XCTAssertEqual(probe.matches("```json\n" + answer + "\n```"), 3)
        XCTAssertEqual(probe.matches("{\"aurora\":\"badge-456789\"}"), 1)
        XCTAssertEqual(probe.matches("The answer might be " + answer), 0)
        XCTAssertFalse(probe.prompt.components(separatedBy: "\n").last!.contains("456789"))
        XCTAssertFalse(ContextCheck(promptTokens: 100, matchedFacts: 3, totalFacts: 3, firstAnswerSeconds: 1, totalSeconds: 2, truncated: true).passed)
    }
    func testHistoryFittingUsesLogarithmicRequestsAndKeepsNewestTurn() async throws {
        for cutoff in [0, 1, 427, 998, 999] {
            var calls = 0
            let found = await ContextFitting.firstFittingTurn(count: 1000) { index in calls += 1; return index >= cutoff }
            XCTAssertEqual(found, cutoff)
            XCTAssertLessThanOrEqual(calls, 12)
        }
        let none = await ContextFitting.firstFittingTurn(count: 1000) { _ in false }
        XCTAssertNil(none, "An oversized latest turn is rejected, never discarded.")
        let single = await ContextFitting.firstFittingTurn(count: 1) { _ in true }
        XCTAssertEqual(single, 0)
    }
}
