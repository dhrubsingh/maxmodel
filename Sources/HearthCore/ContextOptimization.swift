import Foundation

/// Reviewed layouts from the pinned GGUF and runtime. Unknown architectures keep
/// the original conservative full-attention estimate. FP32 recurrent state is never quantized.
public struct CacheGeometry: Codable, Equatable, Sendable {
    public let fullAttentionBytesPerToken: Int
    public let slidingAttentionBytesPerToken: Int
    public let slidingWindowTokens: Int
    public let recurrentStateBytes: Int
    public let description: String
    public var isValid: Bool {
        fullAttentionBytesPerToken > 0 && fullAttentionBytesPerToken < 64 * 1024 * 1024 &&
        slidingAttentionBytesPerToken >= 0 && slidingAttentionBytesPerToken < 64 * 1024 * 1024 &&
        slidingWindowTokens >= 0 && slidingWindowTokens <= 1_048_576 &&
        recurrentStateBytes >= 0 && recurrentStateBytes < 8 * 1024 * 1024 * 1024
    }
    public func bytes(context: Int, precision: ConversationCache) -> Double {
        let paddedContext = ((context + 255) / 256) * 256
        // Pinned one-slot runtime: SWA window + 512-token microbatch, padded to 256.
        let rollingTokens = ((min(paddedContext, slidingWindowTokens + 512) + 255) / 256) * 256
        let full = Double(fullAttentionBytesPerToken) * Double(paddedContext)
        let rolling = Double(slidingAttentionBytesPerToken) * Double(rollingTokens)
        // One active state plus at most two partial-state checkpoints. Full attention
        // is not copied into those checkpoints; recurrent buffers remain FP32.
        return (full + rolling * 3) * precision.memoryRatio + Double(recurrentStateBytes) * 3
    }
}

public enum RuntimeFallback {
    public static func profile(after profile: RuntimeProfile, model: LocalModel, evidence: ModelEvidence?,
                               hardware: Hardware, budget: Double, goal: RecommendationGoal,
                               conversationMemory: ConversationMemory) -> RuntimeProfile {
        if profile.cacheType != .f16 {
            let fullPrecision = RecommendationPlanner.plan(model: model, evidence: evidence, hardware: hardware,
                budget: budget, goal: goal, conversationMemory: conversationMemory, compactCache: false)
            return RuntimeProfile(contextTokens: min(profile.contextTokens, fullPrecision.contextTokens),
                thinkingTokens: min(profile.thinkingTokens, fullPrecision.thinkingTokens), threads: profile.threads, cacheGeometry: fullPrecision.cacheGeometry)
        }
        return RuntimeProfile(contextTokens: min(4096, profile.contextTokens), thinkingTokens: min(2048, profile.thinkingTokens), threads: profile.threads, cacheGeometry: profile.cacheGeometry)
    }
}

public struct ContextCheck: Codable, Sendable, Equatable {
    public let promptTokens: Int
    public let matchedFacts: Int
    public let totalFacts: Int
    public let firstAnswerSeconds: Double
    public let totalSeconds: Double
    public let truncated: Bool
    public var response: String?
    public var passed: Bool { matchedFacts == totalFacts && !truncated }
}

public struct ContextProbe: Sendable {
    public let prompt: String
    public let expected: [String: String]
    public static func make(lines: Int, seed: Int) -> Self {
        let count = max(6, lines)
        let positions = [count / 10, count / 2, count * 9 / 10]
        let names = ["aurora", "cedar", "tulip"]
        let expected = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, "badge-\(seed + $0.offset * 137)") })
        var rows = ["Read these reference records. Each project has one badge. Use only the records to answer the final question."]
        for index in 0..<count {
            if let match = positions.firstIndex(of: index) {
                rows.append("Project \(names[match]): \(expected[names[match]]!).")
            } else {
                rows.append("Project record\(index): badge-\(1000000 + index * 17).")
            }
        }
        rows.append("Return only a JSON object with the badges for aurora, cedar, and tulip. Use those exact project names as keys and the complete badge strings as values.")
        return Self(prompt: rows.joined(separator: "\n"), expected: expected)
    }
    public func matches(_ answer: String) -> Int {
        // Permit a Markdown JSON fence, but require an actual object and exact values.
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let newline = text.firstIndex(of: "\n"), text.hasSuffix("```") {
            text = String(text[text.index(after: newline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let values = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] else { return 0 }
        return expected.filter { values[$0.key] == $0.value }.count
    }
}

public enum ContextFitting {
    /// Drop only complete turns. Logarithmic template/tokenizer requests replace one
    /// request per discarded turn. The final candidate is always measured exactly.
    public static func firstFittingTurn(count: Int, fits: (Int) async throws -> Bool) async rethrows -> Int? {
        guard count > 0 else { return nil }
        if try await fits(0) { return 0 }
        guard count > 1, try await fits(count - 1) else { return nil }
        var low = 1, high = count - 1
        while low < high {
            let middle = (low + high) / 2
            if try await fits(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
