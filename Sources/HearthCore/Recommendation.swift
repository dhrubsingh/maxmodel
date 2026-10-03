import Foundation
import Darwin

public enum RecommendationGoal: String, Codable, CaseIterable, Sendable {
    case capability, balanced, light
    public var title: String {
        switch self { case .capability: return "Best answers"; case .balanced: return "Balanced"; case .light: return "Light & quick" }
    }
    public var explanation: String {
        switch self {
        case .capability: return "Prioritize published capability while leaving room for your Mac. Thinking can take longer."
        case .balanced: return "Keep near the strongest published capability, with more room for other apps."
        case .light: return "Choose a smaller assistant for short questions and quicker starts."
        }
    }
    public var minimumSpeed: Double { self == .capability ? 5 : self == .balanced ? 10 : 15 }
    public var maximumFirstAnswer: Double { self == .capability ? 45 : self == .balanced ? 20 : 10 }
}

/// Facts are tied to the exact downloadable weights. Published scores remain evidence
/// about the upstream model, never a claim that this quantization reproduced them.
public struct ModelEvidence: Codable, Equatable, Sendable {
    public let modelID: String
    public let modelSHA256: String
    public let maximumContext: Int
    public let supportsThinking: Bool
    public let activeParameters: Double?
    public let quantizedCacheCompatible: Bool?
    public let cacheGeometry: CacheGeometry?
    public let metrics: [CapabilityMetric]
    public let note: String
    public var capability: Double? { score(on: rankedMetricNames) }
    /// Names of the weighted benchmarks this model has published results for.
    public var rankedMetricNames: Set<String> { Set(metrics.filter { $0.weight > 0 }.map(\.name)) }
    /// Weighted score over only the named benchmarks. At least two distinct dimensions are
    /// required; a single cherry-picked score cannot win.
    public func score(on names: Set<String>) -> Double? {
        let usable = metrics.filter { $0.weight > 0 && names.contains($0.name) }
        guard Set(usable.map(\.dimension)).count >= 2 else { return nil }
        return usable.reduce(0) { $0 + $1.value * $1.weight } / usable.reduce(0) { $0 + $1.weight }
    }
    public var usesThinkingEvidence: Bool { metrics.contains { $0.thinking } }
}

public struct CapabilityMetric: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let value: Double
    public let sourceURL: URL
    public let sourceSHA256: String
    public let setting: String
    public let thinking: Bool
    public var id: String { name }
    public var dimension: String {
        if name == "IFEval" { return "Instructions" }
        if name == "MMLU-Pro" { return "Knowledge & reasoning" }
        return "Science reasoning"
    }
    // A disclosed product policy, not an IQ scale. Distinct GPQA variants are not mixed.
    public var weight: Double {
        switch name { case "MMLU-Pro": return 0.5; case "IFEval": return 0.3; case "GPQA Diamond": return 0.2; default: return 0 }
    }
}

/// Published scores describe full-precision upstream weights. Hearth downloads compressed
/// GGUF files, so each configuration is planned with a disclosed allowance for the expected
/// loss. This is a product policy informed by llama.cpp perplexity/KL-divergence comparisons,
/// not a measurement of any specific file. It mainly decides between precisions of the same
/// model and keeps a heavily compressed large model from outranking a lightly compressed one
/// by a margin the evidence cannot support.
public enum QuantizationPolicy {
    public static func penalty(_ quantization: String) -> Double {
        let q = quantization.uppercased()
        if q == "MXFP4" { return 0 } // gpt-oss is published natively in MXFP4.
        if q.contains("IQ1") { return 15 }
        if q.contains("IQ2") || q.contains("Q2") { return 8 }
        if q.contains("IQ3") { return 3 }
        if q.contains("Q3") { return 2.5 }
        if q.contains("IQ4") { return 1.5 }
        if q.contains("Q4") || q.contains("MXFP4") { return 1 }
        if q.contains("Q5") { return 0.5 }
        if q.contains("Q6") { return 0.25 }
        if q.contains("Q8") || q.contains("F16") { return 0 }
        return 1
    }
    /// What ranking deducts. Q4_K_M and finer differ by less than benchmark noise and Q4 runs
    /// fastest, so they rank equally; only compression beyond Q4 costs points.
    public static func rankingPenalty(_ quantization: String) -> Double {
        max(0, penalty(quantization) - penalty("Q4_K_M"))
    }
    public static func label(_ quantization: String) -> String {
        switch penalty(quantization) {
        case 0: return "Near full precision"
        case ..<0.75: return "High precision"
        case ..<2: return "Standard compression"
        case ..<5: return "Compact · small quality tradeoff"
        default: return "Heavily compressed · noticeable quality tradeoff"
        }
    }
}

/// Speed expected before anything is downloaded. Generating a token reads the active weights
/// once, so generation follows memory bandwidth. Reading the prompt is compute-bound, and Apple
/// GPU compute grows with bandwidth across the chip range. A matching local measurement wins.
public enum SpeedEstimate {
    /// Share of rated bandwidth the pinned runtime sustained for 2–3 GB models on an M4:
    /// 0.51–0.68 (`.test-data/recommendation/`). The lower middle keeps estimates cautious.
    public static let bandwidthEfficiency = 0.55
    /// Prompt tokens per second for each GB/s of bandwidth per billion active parameters.
    static let promptRate = 12.5
    /// System instructions, chat template, and a typical first question.
    static let promptTokens = 512.0
    public static func activeWeightBytes(_ model: LocalModel, evidence: ModelEvidence?) -> Double {
        Double(model.bytes) * min(1, (evidence?.activeParameters ?? model.parameters) / max(0.1, model.parameters))
    }
    public static func tokensPerSecond(_ model: LocalModel, evidence: ModelEvidence?, hardware: Hardware) -> Double {
        bandwidthEfficiency * hardware.memoryBandwidth.gigabytesPerSecond * 1e9 / max(1, activeWeightBytes(model, evidence: evidence))
    }
    public static func promptSeconds(_ model: LocalModel, evidence: ModelEvidence?, hardware: Hardware) -> Double {
        let active = min(model.parameters, evidence?.activeParameters ?? model.parameters)
        return promptTokens * max(0.1, active) / (promptRate * hardware.memoryBandwidth.gigabytesPerSecond)
    }
}

public struct RecommendationEvidence: Codable, Sendable {
    public let checkedAt: String
    public let models: [ModelEvidence]
    public static func load(catalog: [LocalModel]) throws -> Self {
        guard let url = LocalModel.resourceBundle.url(forResource: "recommendation-evidence", withExtension: "json") else {
            throw HearthError.message("The recommendation evidence is missing.")
        }
        let archive = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard Set(archive.models.map(\.modelID)).count == archive.models.count else { throw HearthError.message("Duplicate recommendation evidence.") }
        for item in archive.models {
            guard let model = catalog.first(where: { $0.id == item.modelID }), model.sha256 == item.modelSHA256,
                  item.maximumContext >= model.contextTokens,
                  item.cacheGeometry?.isValid ?? true,
                  Set(item.metrics.map(\.name)).count == item.metrics.count,
                  item.metrics.allSatisfy({ $0.value.isFinite && (0...100).contains($0.value) && $0.sourceURL.scheme == "https" && $0.sourceSHA256.count == 64 && (!$0.thinking || item.supportsThinking) }) else {
                throw HearthError.message("Recommendation evidence does not match \(item.modelID).")
            }
        }
        return archive
    }
}

/// A small, local-only snapshot. No application names or personal files are examined.
public struct MachineConditions: Equatable, Sendable {
    public var availableMemory: UInt64?
    public var pressure: Int // 1 normal, 2 warning, 4 critical (Darwin)
    public var thermal: Int // ProcessInfo.ThermalState
    public var lowPower: Bool
    public var currentModelMemory: UInt64
    public init(availableMemory: UInt64? = nil, pressure: Int = 1, thermal: Int = 0, lowPower: Bool = false, currentModelMemory: UInt64 = 0) {
        self.availableMemory = availableMemory; self.pressure = pressure; self.thermal = thermal
        self.lowPower = lowPower; self.currentModelMemory = currentModelMemory
    }
    public static func inspect(currentModelMemory: UInt64 = 0) -> Self {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        // Inactive pages are reclaimable estimates. Purgeable pages overlap other
        // counters and must not be added a second time. No swap is counted as RAM.
        let available = result == KERN_SUCCESS ? (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(vm_kernel_page_size) : nil
        var pressure: Int32 = 1, size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        return Self(availableMemory: available, pressure: Int(pressure), thermal: ProcessInfo.processInfo.thermalState.rawValue,
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, currentModelMemory: currentModelMemory)
    }
    public func budget(for hardware: Hardware) -> Double {
        var budget = hardware.modelBudget
        if let availableMemory {
            // Return the current engine's allocation to the pool when considering a switch.
            budget = min(budget, max(0, Double(availableMemory) + Double(currentModelMemory) - 0.5 * gib))
        }
        if pressure >= 4 { budget *= 0.7 }
        return max(0, budget)
    }
}

public struct RuntimeProfile: Codable, Equatable, Sendable {
    public let contextTokens: Int
    public let thinkingTokens: Int
    public let threads: Int
    public let cacheType: ConversationCache
    public let cacheGeometry: CacheGeometry?
    public let execution: ExecutionSettings
    public let machineID: String?
    public let optimizedAt: Date?
    public let tuningKey: String?
    public var id: String { "v3-c\(contextTokens)-r\(thinkingTokens)-t\(threads)-p2-\(cacheType.rawValue)-\(execution.id)-s1" }
    public var isThinking: Bool { thinkingTokens > 0 }
    public static func legacy(_ model: LocalModel) -> Self {
        Self(contextTokens: model.contextTokens, thinkingTokens: model.isReasoning ? 512 : 0,
             threads: max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
    }
    public init(contextTokens: Int, thinkingTokens: Int, threads: Int, cacheType: ConversationCache = .f16, cacheGeometry: CacheGeometry? = nil, execution: ExecutionSettings = .init(), machineID: String? = nil, optimizedAt: Date? = nil, tuningKey: String? = nil) {
        self.contextTokens = max(1024, contextTokens); self.thinkingTokens = max(0, min(thinkingTokens, contextTokens / 2))
        self.threads = max(1, threads)
        self.cacheType = cacheType
        self.cacheGeometry = cacheGeometry
        self.execution = execution; self.machineID = machineID
        self.optimizedAt = optimizedAt
        self.tuningKey = tuningKey
    }
    private enum CodingKeys: String, CodingKey { case contextTokens, thinkingTokens, threads, cacheType, cacheGeometry, execution, machineID, optimizedAt, tuningKey }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(contextTokens: try values.decode(Int.self, forKey: .contextTokens),
                  thinkingTokens: try values.decode(Int.self, forKey: .thinkingTokens),
                  threads: try values.decode(Int.self, forKey: .threads),
                  cacheType: try values.decodeIfPresent(ConversationCache.self, forKey: .cacheType) ?? .f16,
                  cacheGeometry: try values.decodeIfPresent(CacheGeometry.self, forKey: .cacheGeometry),
                  execution: try values.decodeIfPresent(ExecutionSettings.self, forKey: .execution) ?? .init(),
                  machineID: try values.decodeIfPresent(String.self, forKey: .machineID),
                  optimizedAt: try values.decodeIfPresent(Date.self, forKey: .optimizedAt),
                  tuningKey: try values.decodeIfPresent(String.self, forKey: .tuningKey))
    }
    public func conversationMemory(for model: LocalModel) -> Double {
        cacheGeometry?.bytes(context: contextTokens, precision: cacheType) ??
            (Double(contextTokens) * Double(model.kvBytesPerToken) * cacheType.memoryRatio)
    }
    public func memory(for model: LocalModel) -> Double {
        Double(model.bytes) * 1.15 + conversationMemory(for: model) + 768 * 1024 * 1024
    }
}

public enum ConversationCache: String, Codable, Sendable, CaseIterable {
    case f16, q8_0
    public var title: String { self == .f16 ? "Full precision (FP16)" : "Compact (Q8)" }
    // GGML Q8_0: 32 signed bytes plus a two-byte scale, versus 64 FP16 bytes.
    // This ratio applies to attention cache only, not weights or recurrent state.
    public var memoryRatio: Double { self == .f16 ? 1 : 34.0 / 64.0 }
}

public enum ConversationMemory: String, Codable, Sendable, CaseIterable {
    case everyday, longer
    public var title: String { self == .everyday ? "Everyday" : "Longer chats" }
    public func target(for goal: RecommendationGoal) -> Int {
        self == .longer ? 65536 : goal == .light ? 4096 : goal == .balanced ? 8192 : 16384
    }
}

public struct ModelAssessment: Identifiable, Sendable {
    public let model: LocalModel
    public let evidence: ModelEvidence?
    public let profile: RuntimeProfile
    public let memoryBudget: Double
    public let benchmark: Benchmark?
    public let exclusion: String?
    public let estimatedTokensPerSecond: Double
    public let estimatedPromptSeconds: Double
    public var id: String { model.id }
    public var estimatedMemory: Double { profile.memory(for: model) }
    /// Measured here when a matching local test exists, otherwise estimated from the chip.
    public var expectedTokensPerSecond: Double { benchmark?.tokensPerSecond ?? estimatedTokensPerSecond }
    /// Seconds until the answer itself begins, with the full thinking allowance on a hard question.
    public var expectedFirstAnswer: Double {
        benchmark?.firstTokenSeconds ?? estimatedPromptSeconds + Double(profile.thinkingTokens) / max(0.1, estimatedTokensPerSecond)
    }
    public var expectedFirstAnswerLabel: String {
        expectedFirstAnswer < 1 ? "under a second" : expectedFirstAnswer < 1.5 ? "about a second" : expectedFirstAnswer < 10 ? String(format: "about %.0f seconds", expectedFirstAnswer)
            : "about \(Int((expectedFirstAnswer / 5).rounded()) * 5) seconds"
    }
    public var speedSummary: String {
        let seconds = expectedFirstAnswerLabel
        let words = max(1, Int((expectedTokensPerSecond * 0.75).rounded()))
        let start = profile.isThinking ? "Thinks for up to \(seconds) on hard questions" : "Starts answering in \(seconds)"
        return "\(start), then writes about \(words) words a second · \(benchmark == nil ? "estimated for this Mac" : "measured on this Mac")"
    }
    /// Published composite before the compression allowance.
    public var publishedCapability: Double? { evidence?.capability }
    /// Planning score: the published composite minus any allowance for compression beyond Q4.
    public var capability: Double? { publishedCapability.map { $0 - QuantizationPolicy.rankingPenalty(model.quantization) } }
    public var eligible: Bool { exclusion == nil && capability != nil }
    public var evidenceLabel: String { capability == nil ? "Not enough comparable evidence" : "Published benchmark evidence" }
    /// Positive when this configuration leads `other`, judged only on benchmarks both have
    /// published so that a missing (often harder) test never inflates either side. Nil when
    /// they share fewer than two benchmark dimensions.
    public func lead(over other: ModelAssessment) -> Double? {
        guard let mine = evidence, let theirs = other.evidence else { return nil }
        let shared = mine.rankedMetricNames.intersection(theirs.rankedMetricNames)
        guard let a = mine.score(on: shared), let b = theirs.score(on: shared) else { return nil }
        return (a - QuantizationPolicy.rankingPenalty(model.quantization)) - (b - QuantizationPolicy.rankingPenalty(other.model.quantization))
    }
    public var performanceLabel: String {
        guard let benchmark else { return String(format: "About %.0f tokens/s · first answer within about %.0f s · estimated", estimatedTokensPerSecond, expectedFirstAnswer) }
        return String(format: "%.0f tokens/s", benchmark.tokensPerSecond) + " · first answer " + benchmark.firstAnswerLabel
    }
    public var summary: String {
        if let exclusion { return exclusion }
        if capability == nil { return "You can try this model, but the available evidence is insufficient for an automatic quality recommendation." }
        return "Ranked using published reasoning and instruction benchmarks. Planned for about \(LocalModel.size(estimatedMemory)) of memory and a \(profile.contextTokens.formatted())-token conversation window."
    }
}

public struct RecommendationReport: Sendable {
    public let assessments: [ModelAssessment]
    public let choices: [ModelAssessment]
    public let goal: RecommendationGoal
    public var recommended: ModelAssessment? { choices.first }
    public var rankedCount: Int { assessments.filter { $0.capability != nil }.count }
    public var eligibleCount: Int { assessments.filter(\.eligible).count }
    public func assessment(_ id: String) -> ModelAssessment? { assessments.first { $0.id == id } }
}

public enum RecommendationPlanner {
    /// Published thinking-mode results come from far longer thinking than a Mac can afford per
    /// answer. Below this allowance they say too little about the answers to rank a model.
    public static let minimumThinkingTokens = 512
    /// Composite differences this small are within benchmark sampling error and differences
    /// between publishers' evaluation setups. Among such near-ties, the faster model wins.
    public static let capabilityTieBand = 2.0

    /// Thinking that fits the goal's wait target at this speed, in 256-token steps. It never
    /// drops below the minimum; a model that cannot afford the minimum is excluded instead.
    public static func thinkingAllowance(tokensPerSecond: Double, promptSeconds: Double, goal: RecommendationGoal, context: Int) -> Int {
        let affordable = tokensPerSecond * max(0, goal.maximumFirstAnswer - promptSeconds) * 0.8
        let ceiling = min(context / 2, goal == .capability ? 4096 : 2048)
        return min(ceiling, max(minimumThinkingTokens, Int(affordable / 256) * 256))
    }

    public static func plan(model: LocalModel, evidence: ModelEvidence?, hardware: Hardware,
                            budget: Double, goal: RecommendationGoal, conversationMemory: ConversationMemory = .everyday,
                            compactCache: Bool = true) -> RuntimeProfile {
        let thinking = model.isReasoning || evidence?.usesThinkingEvidence == true
        let speed = SpeedEstimate.tokensPerSecond(model, evidence: evidence, hardware: hardware)
        let prompt = SpeedEstimate.promptSeconds(model, evidence: evidence, hardware: hardware)
        func thinkingTokens(_ context: Int) -> Int {
            thinking ? thinkingAllowance(tokensPerSecond: speed, promptSeconds: prompt, goal: goal, context: context) : 0
        }
        let target = conversationMemory.target(for: goal)
        let maximum = min(evidence?.maximumContext ?? model.contextTokens, target)
        // A genuine context cost, including the reply/thinking allocation, must fit.
        let minimum = thinking ? 4096 : 2048
        let candidates = Set([maximum, 65536, 49152, 32768, 16384, 8192, 4096, 2048])
            .filter { $0 <= maximum && $0 >= min(minimum, maximum) }.sorted(by: >)
        let threads = max(1, hardware.cores - (hardware.cores > 4 ? 2 : 1))
        // Enable only on a reviewed Metal path with block-aligned attention dimensions.
        let canCompress = compactCache && hardware.architecture == "Apple Silicon" && hardware.gpuWorkingSet > 0 && evidence?.quantizedCacheCompatible == true
        // Hybrid/recurrent and sliding-window models already economize on KV storage.
        // Keep their ordinary chats at FP16 unless compression buys a larger fitting window.
        let alreadyCompact = ["qwen35", "qwen35moe", "gemma3", "gemma4", "gpt-oss", "lfm2", "lfm2moe"].contains(model.architecture ?? "")
        for context in candidates {
            let full = RuntimeProfile(contextTokens: context, thinkingTokens: thinkingTokens(context), threads: threads, cacheGeometry: evidence?.cacheGeometry)
            let compressed = RuntimeProfile(contextTokens: context, thinkingTokens: full.thinkingTokens, threads: threads, cacheType: .q8_0, cacheGeometry: evidence?.cacheGeometry)
            let meaningfulSaving = (!alreadyCompact || full.cacheGeometry != nil) && full.memory(for: model) - compressed.memory(for: model) >= 256 * 1024 * 1024
            let profile = canCompress && (meaningfulSaving || full.memory(for: model) > budget * 0.95) ? compressed : full
            if profile.memory(for: model) <= budget * 0.95 { return profile }
        }
        return RuntimeProfile(contextTokens: min(minimum, maximum), thinkingTokens: thinkingTokens(min(minimum, maximum)), threads: threads, cacheType: canCompress ? .q8_0 : .f16, cacheGeometry: evidence?.cacheGeometry)
    }

    public static func evaluate(catalog: [LocalModel], evidence: RecommendationEvidence?, hardware: Hardware,
                                conditions: MachineConditions = .init(), goal: RecommendationGoal = .capability,
                                conversationMemory: ConversationMemory = .everyday, compactCache: Bool = true,
                                installed: Set<String> = [], partials: [String: Int64] = [:],
                                benchmarks: [String: Benchmark] = [:], failures: [String: String] = [:],
                                profiles: [String: RuntimeProfile] = [:],
                                now: Date = Date()) -> RecommendationReport {
        let facts = Dictionary(uniqueKeysWithValues: (evidence?.models ?? []).map { ($0.modelID, $0) })
        let budget = conditions.budget(for: hardware)
        let assessments = catalog.map { model -> ModelAssessment in
            let fact = facts[model.id]
            let saved = profiles[model.id]
            let profile = saved.flatMap { value -> RuntimeProfile? in
                guard value.contextTokens >= 2048, value.contextTokens <= min(conversationMemory.target(for: goal), fact?.maximumContext ?? model.contextTokens),
                      (value.machineID == nil ? value.execution == ExecutionSettings() : value.machineID == hardware.optimizationID && value.optimizedAt.map { $0 <= now && now.timeIntervalSince($0) < 30 * 86400 } == true),
                      value.machineID == nil || value.tuningKey == AdaptiveOptimizer.key(model: model, hardware: hardware),
                      value.execution.isCompatible(model: model, hardware: hardware),
                      value.thinkingTokens >= 0, value.thinkingTokens <= value.contextTokens / 2,
                      value.threads > 0, value.threads <= hardware.cores, value.memory(for: model) <= budget,
                      value.cacheGeometry == fact?.cacheGeometry,
                      value.cacheType == .f16 || (compactCache && hardware.architecture == "Apple Silicon" && hardware.gpuWorkingSet > 0 && fact?.quantizedCacheCompatible == true),
                      !value.isThinking || model.isReasoning || fact?.supportsThinking == true else { return nil }
                return value
            } ?? plan(model: model, evidence: fact, hardware: hardware, budget: budget, goal: goal, conversationMemory: conversationMemory, compactCache: compactCache)
            let measurement = benchmarks[model.id].flatMap { value -> Benchmark? in
                guard value.modelID == model.id, value.modelSHA256 == model.sha256, value.chip == hardware.chip, value.engineVersion == "b11146",
                      value.hardwareID == hardware.optimizationID,
                      value.profileID == profile.id, value.contextTokens == profile.contextTokens, value.sampleCount >= 3, value.generatedTokens > 0,
                      value.date <= now, now.timeIntervalSince(value.date) < 30 * 86400,
                      value.tokensPerSecond.isFinite, value.tokensPerSecond > 0,
                      value.firstTokenSeconds.isFinite, value.firstTokenSeconds >= 0 else { return nil }
                return value
            }
            let speed = SpeedEstimate.tokensPerSecond(model, evidence: fact, hardware: hardware)
            let prompt = SpeedEstimate.promptSeconds(model, evidence: fact, hardware: hardware)
            let wait = prompt + Double(profile.thinkingTokens) / max(0.1, speed)
            var reason: String?
            if profile.memory(for: model) > budget { reason = "Needs more memory than is available for an assistant right now." }
            else if !installed.contains(model.id) && !hardware.hasStorage(for: model, partialBytes: partials[model.id] ?? 0) { reason = "Needs more free storage to download." }
            else if let failure = failures[model.id + ":" + profile.id] { reason = failure }
            else if measurement == nil, speed < goal.minimumSpeed {
                reason = String(format: "Fits in memory, but would write only about %.0f tokens a second on this Mac, below the %@ target. You can still choose it.", speed, goal.title.lowercased())
            } else if measurement == nil, profile.isThinking, wait > goal.maximumFirstAnswer {
                reason = String(format: "Fits in memory, but would need about %.0f seconds to think before answering on this Mac, past the %@ target of %.0f. You can still choose it.", wait, goal.title.lowercased(), goal.maximumFirstAnswer)
            } else if let measurement {
                if measurement.tokensPerSecond < goal.minimumSpeed || measurement.firstTokenSeconds > goal.maximumFirstAnswer {
                    reason = "The local test was slower than the \(goal.title.lowercased()) target. You can still choose it."
                } else if let checks = measurement.checks, checks.count >= 4, checks.filter(\.passed).count < checks.count / 2 {
                    reason = "Several basic answer checks failed. Try another model or run the check again."
                } else if let check = measurement.contextCheck, !check.passed {
                    reason = "The long-memory check missed supplied facts. Try Everyday memory or recheck before relying on longer chats."
                } else if let footprint = measurement.processMemoryBytes, Double(footprint) > budget {
                    reason = "Measured memory use exceeds the current assistant budget."
                }
            }
            return ModelAssessment(model: model, evidence: fact, profile: profile, memoryBudget: budget, benchmark: measurement, exclusion: reason,
                                   estimatedTokensPerSecond: speed, estimatedPromptSeconds: prompt)
        }
        let eligible = rank(assessments.filter(\.eligible))
        guard let strongest = eligible.first else { return RecommendationReport(assessments: assessments, choices: [], goal: goal) }
        // Capability-first: use resource cost only within an explicit quality band.
        // This is not a parameter-count ranking; sparse models can be large but cheap to run.
        // Strict: a gap of exactly the band, such as an IQ3 file against its own Q4 copy, is not a tie.
        let band = goal == .capability ? capabilityTieBand : goal == .balanced ? 5.0 : 15.0
        let pool = eligible.filter { ($0.lead(over: strongest) ?? (($0.capability ?? 0) - (strongest.capability ?? 0))) > -band }
        let chosen = goal == .capability
            ? pool.dropFirst().reduce(strongest) { $1.expectedTokensPerSecond > $0.expectedTokensPerSecond ? $1 : $0 }
            : pool.min { cost($0) < cost($1) } ?? strongest
        var choices = [chosen]
        // Alternatives are different models, not other precisions of one already listed.
        func isNew(_ candidate: ModelAssessment) -> Bool { !choices.contains { $0.model.baseModelID == candidate.model.baseModelID } }
        if let lighter = eligible.first(where: { isNew($0) && $0.estimatedMemory < chosen.estimatedMemory * 0.8 }) { choices.append(lighter) }
        if choices.count < 3, let alternative = eligible.first(where: { isNew($0) && $0.model.family != chosen.model.family }) { choices.append(alternative) }
        if choices.count < 3, let next = eligible.first(where: isNew) { choices.append(next) }
        return RecommendationReport(assessments: assessments, choices: choices, goal: goal)
    }
    /// Head-to-head ranking on shared benchmarks only. Models with the fewest losses lead, then
    /// the most wins; the planning score and memory only break remaining ties.
    static func rank(_ candidates: [ModelAssessment]) -> [ModelAssessment] {
        var record: [String: (losses: Int, wins: Int)] = [:]
        for (i, a) in candidates.enumerated() {
            for b in candidates[(i + 1)...] {
                guard let lead = a.lead(over: b), lead != 0 else { continue }
                let (winner, loser) = lead > 0 ? (a.id, b.id) : (b.id, a.id)
                record[winner, default: (0, 0)].wins += 1
                record[loser, default: (0, 0)].losses += 1
            }
        }
        return candidates.sorted { a, b in
            let ra = record[a.id] ?? (0, 0), rb = record[b.id] ?? (0, 0)
            if ra.losses != rb.losses { return ra.losses < rb.losses }
            if ra.wins != rb.wins { return ra.wins > rb.wins }
            if a.capability != b.capability { return (a.capability ?? 0) > (b.capability ?? 0) }
            return (a.estimatedMemory, a.id) < (b.estimatedMemory, b.id)
        }
    }
    private static func cost(_ assessment: ModelAssessment) -> Double {
        let activeFraction = min(1, (assessment.evidence?.activeParameters ?? assessment.model.parameters) / max(0.1, assessment.model.parameters))
        return assessment.estimatedMemory * 0.5 + Double(assessment.model.bytes) * activeFraction * 0.5
    }
}

public enum PerformanceTuning {
    /// Convert measured local throughput into a bounded thinking-time allowance.
    /// This is a latency heuristic, not a prediction of answer quality. A second
    /// benchmark must validate the changed configuration before its results count.
    public static func nextProfile(_ profile: RuntimeProfile, measurement: Benchmark, goal: RecommendationGoal) -> RuntimeProfile? {
        guard profile.isThinking, measurement.tokensPerSecond.isFinite, measurement.tokensPerSecond > 0 else { return nil }
        var allowance = measurement.tokensPerSecond * goal.maximumFirstAnswer * 0.8
        if measurement.firstTokenSeconds > goal.maximumFirstAnswer {
            allowance = min(allowance, Double(profile.thinkingTokens) * goal.maximumFirstAnswer / measurement.firstTokenSeconds * 0.7)
        }
        let maximum = min(profile.contextTokens / 2, goal == .capability ? 4096 : 2048)
        let tokens = min(maximum, max(RecommendationPlanner.minimumThinkingTokens, Int(allowance / 256) * 256))
        guard tokens != profile.thinkingTokens else { return nil }
        return RuntimeProfile(contextTokens: profile.contextTokens, thinkingTokens: tokens, threads: profile.threads, cacheType: profile.cacheType, cacheGeometry: profile.cacheGeometry, execution: profile.execution, machineID: profile.machineID, optimizedAt: profile.optimizedAt, tuningKey: profile.tuningKey)
    }
}
