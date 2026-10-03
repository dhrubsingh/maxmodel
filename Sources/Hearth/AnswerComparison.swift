import Foundation
import Observation
import HearthCore

enum ComparisonMode: String, CaseIterable { case overview = "At a glance", examples = "Example answers", live = "Try your question" }

@MainActor @Observable
final class ComparedAnswer: Identifiable {
    let id: String
    var content = ""
    var reasoning = ""
    var status = "Waiting its turn"
    var firstTokenSeconds: Double?
    var tokensPerSecond: Double?
    var finished = false
    init(modelID: String) { id = modelID }
}

@MainActor @Observable
final class AnswerComparison {
    var prompt = "Explain why the sky looks blue in three short bullet points."
    var submittedPrompt = ""
    var answers: [String: ComparedAnswer] = [:]
    var running = false
}
