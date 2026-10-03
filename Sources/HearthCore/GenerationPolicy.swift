import Foundation

/// Reviewed publisher defaults. Unknown models retain the conservative app default.
/// These affect sampling, not model weights, context capacity, or training.
public struct GenerationPolicy: Equatable, Sendable {
    public let temperature: Double
    public let topP: Double
    public let topK: Int
    public let minP: Double
    public let presencePenalty: Double
    public let sourceURL: URL?
    public var title: String { sourceURL == nil ? "Hearth generation defaults" : "Publisher generation defaults" }
    public static func forModel(_ model: LocalModel, thinking: Bool) -> Self {
        if model.series == "Qwen3" {
            return Self(temperature: thinking ? 0.6 : 0.7, topP: thinking ? 0.95 : 0.8, topK: 20, minP: 0, presencePenalty: 0,
                        sourceURL: URL(string: "https://huggingface.co/Qwen/Qwen3-4B#best-practices"))
        }
        if model.series == "Qwen3.5" {
            return Self(temperature: thinking ? 1 : 0.7, topP: thinking ? 0.95 : 0.8, topK: 20, minP: 0, presencePenalty: 1.5,
                        sourceURL: URL(string: "https://huggingface.co/Qwen/Qwen3.5-4B#best-practices"))
        }
        if ["gemma4-e2b", "gemma4-e4b", "gemma4-31b"].contains(model.id) {
            return Self(temperature: 1, topP: 0.95, topK: 64, minP: 0, presencePenalty: 0,
                        sourceURL: URL(string: model.sourceURL.absoluteString + "/blob/main/generation_config.json"))
        }
        if model.id == "smollm3-3b" || ["deepseek-r1-15b", "deepseek-r1-7b", "deepseek-r1-14b", "deepseek-r1-32b"].contains(model.id) {
            return Self(temperature: 0.6, topP: 0.95, topK: 0, minP: 0, presencePenalty: 0,
                        sourceURL: URL(string: model.id == "smollm3-3b" ? "https://huggingface.co/HuggingFaceTB/SmolLM3-3B#how-to-use" : "https://huggingface.co/deepseek-ai/DeepSeek-R1#6-usage-recommendations"))
        }
        return Self(temperature: 0.6, topP: 0.9, topK: 40, minP: 0.05, presencePenalty: 0, sourceURL: nil)
    }
    public func parameters(temperature override: Double? = nil) -> [String: Any] {
        let temperature = override.map { $0.isFinite ? max(0, min(2, $0)) : self.temperature } ?? self.temperature
        // Greedy is only used for reproducible synthetic comparisons, never the chat default.
        return ["temperature": temperature, "top_p": topP, "top_k": topK, "min_p": minP,
                "presence_penalty": temperature == 0 ? 0.0 : presencePenalty, "repeat_penalty": 1.0,
                "seed": override == 0 ? 1729 : -1]
    }
}
