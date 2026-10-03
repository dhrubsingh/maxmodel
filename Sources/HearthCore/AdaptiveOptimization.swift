import Foundation
import CryptoKit

/// A deliberately bounded search space. No speculative draft downloads or unreviewed kernels.
public struct ExecutionSettings: Codable, Equatable, Sendable {
    public var batchTokens: Int = 512
    public var batchThreads: Int? = nil
    public var backendSampling: Bool = false
    public var speculative: Bool = false
    public var cpuOnly: Bool = false
    public init(batchTokens: Int = 512, batchThreads: Int? = nil, backendSampling: Bool = false, speculative: Bool = false, cpuOnly: Bool = false) {
        self.batchTokens = batchTokens; self.batchThreads = batchThreads
        self.backendSampling = backendSampling; self.speculative = speculative; self.cpuOnly = cpuOnly
    }
    public var id: String { "b\(batchTokens)-bt\(batchThreads ?? 0)-g\(backendSampling ? 1 : 0)-n\(speculative ? 1 : 0)-cpu\(cpuOnly ? 1 : 0)" }
    public static func supportsSpeculation(_ model: LocalModel) -> Bool {
        // Recurrent/state-space, shared-KV and sliding-window paths need separate validation.
        ["llama", "qwen2", "qwen3", "qwen3moe", "smollm3"].contains(model.architecture ?? "")
    }
    public func isCompatible(model: LocalModel, hardware: Hardware) -> Bool {
        [128, 256, 512].contains(batchTokens) && (batchThreads == nil || (1...max(1, hardware.cores)).contains(batchThreads!)) &&
        (!backendSampling || (!cpuOnly && hardware.architecture == "Apple Silicon" && hardware.gpuWorkingSet > 0)) &&
        (!speculative || Self.supportsSpeculation(model))
    }
    public var summary: String {
        var parts = ["\(batchTokens)-token batches"]
        if backendSampling { parts.append("GPU sampling") }
        if speculative { parts.append("verified n-gram drafting") }
        if cpuOnly { parts.append("CPU execution") }
        return parts.joined(separator: " · ")
    }
    public func arguments(threads: Int) -> [String] {
        var result = ["--ubatch-size", String(batchTokens), "--batch-size", "2048", "--threads-batch", String(batchThreads ?? threads),
                      "--n-gpu-layers", cpuOnly ? "0" : "auto"]
        if cpuOnly { result += ["--device", "none", "--no-op-offload"] }
        if backendSampling { result += ["--backend-sampling"] }
        if speculative {
            result += ["--spec-type", "ngram-simple", "--spec-draft-n-max", "8", "--spec-ngram-simple-size-n", "12", "--spec-ngram-simple-size-m", "8"]
        }
        return result
    }
}

public struct OptimizationSample: Codable, Equatable, Sendable {
    public let seconds: Double
    public let firstAnswerSeconds: Double
    public let tokensPerSecond: Double
    public let tokens: Int
    public let outputSHA256: String
    public let truncated: Bool
    public init(seconds: Double, firstAnswerSeconds: Double, tokensPerSecond: Double, tokens: Int, outputSHA256: String, truncated: Bool) {
        self.seconds = seconds; self.firstAnswerSeconds = firstAnswerSeconds; self.tokensPerSecond = tokensPerSecond
        self.tokens = tokens; self.outputSHA256 = outputSHA256; self.truncated = truncated
    }
    public var valid: Bool { seconds.isFinite && seconds > 0 && firstAnswerSeconds.isFinite && firstAnswerSeconds >= 0 && tokensPerSecond.isFinite && tokensPerSecond > 0 && tokens > 0 && !truncated }
}

public struct OptimizationTrial: Codable, Equatable, Sendable {
    public let name: String
    public let profile: RuntimeProfile
    public var samples: [OptimizationSample]
    public var memoryBytes: UInt64?
    public var note: String
    public var seconds: Double { samples.reduce(0) { $0 + $1.seconds } }
    public init(name: String, profile: RuntimeProfile, samples: [OptimizationSample] = [], memoryBytes: UInt64? = nil, note: String = "Measured") {
        self.name = name; self.profile = profile; self.samples = samples; self.memoryBytes = memoryBytes; self.note = note
    }
}

public struct OptimizationRecord: Codable, Equatable, Sendable {
    public let date: Date
    public let machineID: String
    public let modelSHA256: String
    public let engineVersion: String
    public let suiteVersion: String
    public let baseline: RuntimeProfile
    public let selected: RuntimeProfile
    public let trials: [OptimizationTrial]
    public let improvement: Double
    public let summary: String
    public let baselineChecks: [LocalAnswerCheck]
    public let selectedChecks: [LocalAnswerCheck]
    public func applies(model: LocalModel, hardware: Hardware, profile: RuntimeProfile, now: Date = Date()) -> Bool {
        machineID == hardware.optimizationID && modelSHA256 == model.sha256 && engineVersion == "b11146" &&
        suiteVersion == AdaptiveOptimizer.version && selected.id == profile.id && date <= now && now.timeIntervalSince(date) < 30 * 86400
    }
}

public enum AdaptiveOptimizer {
    public static let version = "execution-v1"
    public static func key(model: LocalModel, hardware: Hardware) -> String { "\(hardware.optimizationID):\(model.sha256):b11146:\(version)" }
    // Synthetic text only. Multiple workloads; no user chat content is used.
    public static let prompts = [
        "The following archive entries are unrelated background:\n" + (1...40).map { "Archive entry \($0): the blue notebook belongs on shelf \($0 + 20) in room Cedar." }.joined(separator: "\n") + "\nIgnore the archive. Return only a JSON object with keys total and remaining. There are 14 red marbles and 9 blue marbles. Five marbles are removed. total is the original number; remaining is the final number. No markdown.",
        "Write a Python function named unique_words(text) that lowercases text, splits on whitespace, removes duplicates, and returns a sorted list. Output only the function in a Python code block, without explanation.",
        "Copy these twelve lines exactly, replacing every amber with green. No introduction or markdown:\n" + Array(repeating: "The amber lantern is beside the quiet window.", count: 12).joined(separator: "\n")
    ]
    public static func candidates(baseline: RuntimeProfile, model: LocalModel, hardware: Hardware) -> [OptimizationTrial] {
        var result: [OptimizationTrial] = []
        let cores = max(1, hardware.performanceCores ?? max(1, hardware.cores / 2))
        var lean = baseline.execution
        lean.batchTokens = hardware.gpuWorkingSet > 0 && !lean.cpuOnly ? 256 : 128
        lean.batchThreads = cores
        result.append(OptimizationTrial(name: "CPU & batch balance", profile: replacing(baseline, threads: cores, execution: lean, machineID: hardware.optimizationID, tuningKey: key(model: model, hardware: hardware))))
        if hardware.architecture == "Apple Silicon", hardware.gpuWorkingSet > 0, !baseline.execution.cpuOnly {
            var sampling = baseline.execution; sampling.backendSampling = true
            result.append(OptimizationTrial(name: "GPU sampling", profile: replacing(baseline, execution: sampling, machineID: hardware.optimizationID, tuningKey: key(model: model, hardware: hardware))))
        }
        if ExecutionSettings.supportsSpeculation(model) {
            var drafting = baseline.execution; drafting.speculative = true
            result.append(OptimizationTrial(name: "Verified token drafting", profile: replacing(baseline, execution: drafting, machineID: hardware.optimizationID, tuningKey: key(model: model, hardware: hardware))))
        }
        return result.filter { $0.profile.id != baseline.id && $0.profile.execution.isCompatible(model: model, hardware: hardware) }
    }
    public static func replacing(_ profile: RuntimeProfile, threads: Int? = nil, execution: ExecutionSettings, machineID: String? = nil, tuningKey: String? = nil) -> RuntimeProfile {
        RuntimeProfile(contextTokens: profile.contextTokens, thinkingTokens: profile.thinkingTokens, threads: threads ?? profile.threads,
                       cacheType: profile.cacheType, cacheGeometry: profile.cacheGeometry, execution: execution, machineID: machineID, optimizedAt: machineID == nil ? nil : Date(), tuningKey: tuningKey)
    }
    public static func conditionsAllow(_ conditions: MachineConditions) -> Bool {
        conditions.pressure < 4 && conditions.thermal < 2
    }
    public static func sameAnswers(_ lhs: OptimizationTrial, _ rhs: OptimizationTrial) -> Bool {
        lhs.samples.count == prompts.count && rhs.samples.count == prompts.count &&
        zip(lhs.samples, rhs.samples).allSatisfy { $0.valid && $1.valid && $0.tokens == $1.tokens && $0.outputSHA256 == $1.outputSHA256 }
    }
    public static func improves(_ candidate: OptimizationTrial, over baseline: OptimizationTrial, budget: Double) -> Bool {
        guard sameAnswers(candidate, baseline), candidate.seconds <= baseline.seconds * 0.92,
              let memory = candidate.memoryBytes, Double(memory) <= budget else { return false }
        // A repeat-heavy workload must not hide a regression on other tasks or first-answer latency.
        return zip(candidate.samples, baseline.samples).allSatisfy {
            $0.seconds <= $1.seconds * 1.15 + 0.05 && $0.firstAnswerSeconds <= $1.firstAnswerSeconds * 1.15 + 0.1
        }
    }
    public static func stable(_ first: OptimizationTrial, _ last: OptimizationTrial) -> Bool {
        sameAnswers(first, last) && zip(first.samples, last.samples).allSatisfy {
            abs($0.seconds - $1.seconds) / max($0.seconds, $1.seconds) <= 0.15
        }
    }
}

extension LocalEngine {
    /// Never persists a candidate until the whole comparison and confirmation have passed.
    public func optimize(model: LocalModel, storage: LocalStorage, hardware: Hardware, baseline: RuntimeProfile,
                         progress: (String) -> Void = { _ in }) async throws -> OptimizationRecord {
        let started = Date()
        let machineID = hardware.optimizationID
        let initialConditions = MachineConditions.inspect(currentModelMemory: memoryFootprint() ?? 0)
        var trials: [OptimizationTrial] = []
        func checkEnvironment() throws {
            try Task.checkCancellation()
            guard hardware.optimizationID == machineID else { throw HearthError.message("Power mode changed during optimization. Previous settings are kept; run the check again in the new mode.") }
            guard Date().timeIntervalSince(started) < 20 * 60 else { throw HearthError.message("Optimization reached its time limit. Your previous settings are kept.") }
            let conditions = MachineConditions.inspect(currentModelMemory: memoryFootprint() ?? 0)
            guard AdaptiveOptimizer.conditionsAllow(conditions) else {
                let reason = conditions.thermal >= 2 ? "this Mac is warm" : "memory pressure is critical"
                throw HearthError.message("Optimization stopped because \(reason). Try again when this changes. Your previous settings are kept.")
            }
        }
        func measure(_ trial: OptimizationTrial) async throws -> OptimizationTrial {
            try checkEnvironment()
            progress("\(trial.name) · loading…")
            try await load(model, storage: storage, profile: trial.profile)
            // Warm shaders/pipelines; every timed prompt still disables prompt reuse.
            _ = try await complete(messages: [ChatMessage(role: "user", content: AdaptiveOptimizer.prompts[0])], maxTokens: trial.profile.thinkingTokens + 256, reusePrompt: false, temperature: 0, onToken: { _ in })
            var result = trial
            for (index, prompt) in AdaptiveOptimizer.prompts.enumerated() {
                try checkEnvironment()
                progress("\(trial.name) · sample \(index + 1) of \(AdaptiveOptimizer.prompts.count)")
                let clock = ContinuousClock(); let begin = clock.now
                let answer = try await complete(messages: [ChatMessage(role: "user", content: prompt)], maxTokens: trial.profile.thinkingTokens + 256, reusePrompt: false, temperature: 0, onToken: { _ in })
                let duration = begin.duration(to: clock.now).components
                let hash = SHA256.hash(data: Data((answer.text + "\n" + (answer.reasoning ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
                result.samples.append(OptimizationSample(seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                    firstAnswerSeconds: answer.firstTokenSeconds, tokensPerSecond: answer.tokensPerSecond, tokens: answer.tokens,
                    outputSHA256: hash, truncated: answer.reachedLimit || answer.omittedMessages != 0))
            }
            result.memoryBytes = memoryFootprint()
            return result
        }
        do {
            guard baseline.memory(for: model) <= initialConditions.budget(for: hardware) else {
                throw HearthError.message("There is not enough available memory for this optimization. Close other apps or choose a smaller model. Previous settings are kept.")
            }
            let initial = try await measure(OptimizationTrial(name: "Current settings", profile: baseline))
            trials.append(initial)
            let initialChecks = try await checkAnswers { progress("Baseline answer checks · \($0) of 6") }
            let budget = MachineConditions.inspect(currentModelMemory: memoryFootprint() ?? 0).budget(for: hardware)
            var winner: OptimizationTrial?
            for candidate in AdaptiveOptimizer.candidates(baseline: baseline, model: model, hardware: hardware) {
                try checkEnvironment()
                do {
                    var measured = try await measure(candidate)
                    if !AdaptiveOptimizer.sameAnswers(measured, initial) { measured.note = "Not kept: answers changed or were incomplete" }
                    else if !AdaptiveOptimizer.improves(measured, over: initial, budget: budget) { measured.note = "Not kept: no consistent improvement of at least 8% within the memory budget" }
                    else if winner == nil || measured.seconds < winner!.seconds { winner = measured }
                    trials.append(measured)
                } catch {
                    try checkEnvironment()
                    trials.append(OptimizationTrial(name: candidate.name, profile: candidate.profile, note: "Not kept: \(error.localizedDescription)"))
                }
            }
            var selected = baseline, improvement = 0.0, selectedChecks = initialChecks
            var summary = "Kept your current execution settings. No consistent speedup passed this check."
            if let winner {
                let reference = try await measure(OptimizationTrial(name: "Confirm current settings", profile: baseline))
                let confirmation = try await measure(OptimizationTrial(name: "Confirm faster settings", profile: winner.profile))
                trials += [reference, confirmation]
                let checks = try await checkAnswers { progress("Confirming answer checks · \($0) of 6") }
                try checkEnvironment()
                let qualityPreserved = zip(initialChecks, checks).allSatisfy { !$0.passed || $1.passed } && checks.filter(\.passed).count >= 4
                let currentBudget = MachineConditions.inspect(currentModelMemory: memoryFootprint() ?? 0).budget(for: hardware)
                if qualityPreserved, AdaptiveOptimizer.stable(initial, reference), AdaptiveOptimizer.stable(winner, confirmation),
                   AdaptiveOptimizer.improves(confirmation, over: reference, budget: min(budget, currentBudget)) {
                    selected = winner.profile
                    selectedChecks = checks
                    improvement = min(1 - winner.seconds / initial.seconds, 1 - confirmation.seconds / reference.seconds)
                    summary = String(format: "%.0f%% less time on the checked tasks. Answers matched, basic checks held up, and a second run confirmed the gain.", improvement * 100)
                } else { summary = "The apparent speedup did not survive the repeat and answer checks. Your previous settings are kept." }
            }
            try checkEnvironment()
            try await load(model, storage: storage, profile: selected)
            for index in trials.indices where trials[index].profile.id == selected.id && selected.id != baseline.id {
                trials[index].note = "Kept after repeat timing and answer checks"
            }
            return OptimizationRecord(date: Date(), machineID: machineID, modelSHA256: model.sha256, engineVersion: "b11146",
                suiteVersion: AdaptiveOptimizer.version, baseline: baseline, selected: selected, trials: trials, improvement: improvement, summary: summary,
                baselineChecks: initialChecks, selectedChecks: selectedChecks)
        } catch {
            // Stopping never leaves an unverified experimental engine available to chat.
            await unload()
            throw error
        }
    }
}
