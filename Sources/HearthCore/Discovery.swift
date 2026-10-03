import Foundation

public struct DiscoveryPick: Identifiable, Sendable {
    public let model: LocalModel
    public let title: String
    public let reason: String
    public let tradeoff: String
    public var id: String { model.id }
    public init(model: LocalModel, title: String, reason: String, tradeoff: String) {
        self.model = model; self.title = title; self.reason = reason; self.tradeoff = tradeoff
    }
}

public enum Discovery {
    /// A small, transparent shortlist. Parameter count is never used as a quality score.
    public static func picks(catalog: [LocalModel], hardware: Hardware, installed: Set<String>) -> [DiscoveryPick] {
        let report = RecommendationPlanner.evaluate(catalog: catalog, evidence: try? RecommendationEvidence.load(catalog: catalog), hardware: hardware, installed: installed)
        return report.choices.enumerated().map { index, choice in
            DiscoveryPick(model: choice.model, title: index == 0 ? "Recommended for your Mac" : "Another option", reason: choice.summary, tradeoff: choice.performanceLabel)
        }
    }
}

public struct DiscoveryExample: Codable, Sendable {
    public let modelID: String
    public let modelSHA256: String
    public let promptID: String
    public let prompt: String
    public let answer: String
    public let firstTokenSeconds: Double
    public let tokensPerSecond: Double
    public let reachedLimit: Bool
}

public struct DiscoveryExamples: Codable, Sendable {
    public let recordedAt: String
    public let chip: String
    public let memoryBytes: UInt64
    public let engineVersion: String
    public let contextTokens: Int
    public let examples: [DiscoveryExample]

    public static func load(catalog: [LocalModel]) throws -> Self {
        guard let url = LocalModel.resourceBundle.url(forResource: "discovery-examples", withExtension: "json") else {
            throw HearthError.message("Bundled example answers are unavailable.")
        }
        let archive = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        for example in archive.examples {
            guard let model = catalog.first(where: { $0.id == example.modelID }),
                  model.sha256 == example.modelSHA256, !example.answer.isEmpty else {
                throw HearthError.message("A discovery example does not match its model revision.")
            }
        }
        return archive
    }
    public func example(modelID: String, promptID: String) -> DiscoveryExample? {
        examples.first { $0.modelID == modelID && $0.promptID == promptID }
    }
}
