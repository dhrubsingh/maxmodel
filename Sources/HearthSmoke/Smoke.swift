import Foundation
import HearthCore

final class PauseOnce: @unchecked Sendable {
    var download: ModelDownload?
    func progress(_ progress: DownloadProgress) {
        if progress.received >= 4 * 1024 * 1024 { download?.cancel() }
    }
}

@main
struct Smoke {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        let storage = try LocalStorage(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-data/smoke"))
        let hardware = Hardware.inspect(at: storage.root)
        let models = try LocalModel.catalog()
        print("HARDWARE \(hardware.chip), \(LocalModel.size(Double(hardware.memory))), \(hardware.gpu)")
        print("RECOMMENDED \(hardware.recommended(in: models)?.name ?? "none")")
        if let index = arguments.firstIndex(of: "--optimize"), index + 1 < arguments.count {
            let facts = try RecommendationEvidence.load(catalog: models)
            let engine = try LocalEngine(); defer { engine.stop() }
            let destination = URL(fileURLWithPath: ".test-data/adaptive-optimization")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for id in arguments[index + 1].split(separator: ",").map(String.init) {
                guard let model = models.first(where: { $0.id == id }), !model.needsLicenseReview, storage.installed(model) else {
                    throw HearthError.message("Optimization needs an installed permissive fixture: \(id)")
                }
                let fact = facts.models.first { $0.modelID == id }
                let plan = RecommendationPlanner.plan(model: model, evidence: fact, hardware: hardware, budget: MachineConditions.inspect().budget(for: hardware), goal: .balanced)
                let profile = RuntimeProfile(contextTokens: min(plan.contextTokens, 8192), thinkingTokens: arguments.contains("--direct") ? 0 : plan.thinkingTokens,
                    threads: plan.threads, cacheType: arguments.contains("--cpu") ? .f16 : plan.cacheType, cacheGeometry: plan.cacheGeometry,
                    execution: ExecutionSettings(cpuOnly: arguments.contains("--cpu")))
                let result = try await engine.optimize(model: model, storage: storage, hardware: hardware, baseline: profile) { print($0); fflush(stdout) }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let suffix = (arguments.contains("--cpu") ? "-cpu" : "") + (arguments.contains("--direct") ? "-direct" : "")
                try encoder.encode(result).write(to: destination.appendingPathComponent("\(id)\(suffix).json"), options: .atomic)
                print("RESULT \(id): \(result.summary)"); fflush(stdout)
                await engine.unload()
            }
            return
        }
        if let index = arguments.firstIndex(of: "--cache-probe"), index + 1 < arguments.count {
            let evidence = try RecommendationEvidence.load(catalog: models)
            let engine = try LocalEngine(); defer { engine.stop() }
            var rows: [[String: Any]] = []
            let contextIndex = arguments.firstIndex(of: "--context")
            let requestedContext = contextIndex.flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } ?? 16384
            for id in arguments[index + 1].split(separator: ",").map(String.init) {
                guard let model = models.first(where: { $0.id == id }), !model.needsLicenseReview, storage.installed(model),
                      let facts = evidence.models.first(where: { $0.modelID == id }), facts.quantizedCacheCompatible == true else {
                    throw HearthError.message("Cache probe needs an installed, permissively licensed compatible fixture: \(id)")
                }
                for cache in ConversationCache.allCases where !arguments.contains("--compact-only") || cache == .q8_0 {
                    let profile = RuntimeProfile(contextTokens: min(requestedContext, facts.maximumContext), thinkingTokens: 0,
                                                 threads: max(1, hardware.cores - 2), cacheType: cache, cacheGeometry: facts.cacheGeometry)
                    print("CACHE \(id) \(profile.id)"); fflush(stdout)
                    try await engine.load(model, storage: storage, profile: profile) { print($0); fflush(stdout) }
                    var measure = try await engine.benchmark(model: model, chip: hardware.chip) { print("SPEED \($0)/3"); fflush(stdout) }
                    measure.checks = try await engine.checkAnswers { print("BASIC \($0)/6"); fflush(stdout) }
                    measure.contextCheck = try await engine.checkContext(seed: 456789) { print($0); fflush(stdout) }
                    let longMemory = engine.memoryFootprint() ?? 0
                    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(measure))
                    rows.append(["measurement": encoded, "cache": cache.rawValue, "estimatedMemory": profile.memory(for: model),
                                 "processMemoryAfterLongInput": longMemory, "thinkingEnabled": false])
                    let destination = URL(fileURLWithPath: ".test-data/context-optimization")
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    let suffix = arguments.contains("--compact-only") ? "-compact" : ""
                    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                        .write(to: destination.appendingPathComponent("cache-probe-\(requestedContext)\(suffix).json"), options: .atomic)
                    print("RESULT \(id) \(cache.rawValue): \(measure.tokensPerSecond) tokens/s; basic \(measure.checks!.filter(\.passed).count)/6; long \(measure.contextCheck!.matchedFacts)/3 at \(measure.contextCheck!.promptTokens) tokens; RSS \(longMemory)")
                    fflush(stdout); await engine.unload()
                }
            }
            return
        }
        if let index = arguments.firstIndex(of: "--calibrate"), index + 1 < arguments.count {
            let evidence = try RecommendationEvidence.load(catalog: models)
            let engine = try LocalEngine(); defer { engine.stop() }
            var rows: [Benchmark] = []
            for id in arguments[index + 1].split(separator: ",").map(String.init) {
                guard let model = models.first(where: { $0.id == id }), !model.needsLicenseReview else {
                    throw HearthError.message("Calibration requires a known, permissively licensed fixture: \(id)")
                }
                if !storage.installed(model), arguments.contains("--download") {
                    guard hardware.hasStorage(for: model, partialBytes: storage.fileSize(storage.partialURL(model))) else { throw HearthError.message("Not enough storage for \(id)") }
                    print("DOWNLOADING \(id) \(model.diskLabel)"); fflush(stdout)
                    try await ModelDownload(model: model, destination: storage.partialURL(model), progress: { _ in }).run()
                    try await storage.finishInstall(model)
                }
                guard storage.installed(model) else { throw HearthError.message("Missing fixture \(id)") }
                let report = RecommendationPlanner.evaluate(catalog: models, evidence: evidence, hardware: hardware)
                let profile = report.assessment(id)!.profile
                print("CALIBRATE \(id) \(profile.id)"); fflush(stdout)
                let started = Date()
                try await engine.load(model, storage: storage, profile: profile) { print($0); fflush(stdout) }
                let loadSeconds = Date().timeIntervalSince(started)
                var measurement = try await engine.benchmark(model: model, chip: hardware.chip) { print("SPEED \($0)/3"); fflush(stdout) }
                if let tuned = PerformanceTuning.nextProfile(profile, measurement: measurement, goal: .capability) {
                    print("TUNING \(tuned.id)"); fflush(stdout)
                    try await engine.load(model, storage: storage, profile: tuned)
                    measurement = try await engine.benchmark(model: model, chip: hardware.chip) { print("VALIDATE \($0)/3"); fflush(stdout) }
                }
                measurement.loadSeconds = loadSeconds
                measurement.checks = try await engine.checkAnswers { print("CHECK \($0)/6"); fflush(stdout) }
                rows.append(measurement)
                let encoded = try JSONEncoder().encode(rows)
                try encoded.write(to: URL(fileURLWithPath: ".test-data/recommendation/calibration.json"), options: .atomic)
                print("PASS \(id): \(measurement.checks!.filter(\.passed).count)/6 basic checks; \(measurement.tokensPerSecond) tokens/s; \(measurement.firstTokenSeconds)s first answer")
                await engine.unload()
            }
            return
        }
        if arguments.contains("--examples") {
            let engine = try LocalEngine(); defer { engine.stop() }
            let prompts = [
                "Rewrite this as a friendly, concise email. Keep the deadline and do not invent details: 'Hi Sam. Please send the revised slides by Thursday at 3 pm. I need time to review them before Friday's meeting. Thanks, Alex.'",
                "Explain why the sky looks blue to someone with no science background, in three short bullet points.",
                "Use only these notes to answer the question. Notes: The workshop is on October 12. It starts at 10 am. Bring a notebook. Question: Where is the workshop? If the notes do not say, reply only: Not specified."
            ]
            var results: [[String: Any]] = []
            for id in ["qwen3-4b", "qwen3-17b", "gemma4-e2b"] {
                guard let model = models.first(where: { $0.id == id }), storage.installed(model), !model.needsLicenseReview else {
                    throw HearthError.message("Missing permissively licensed example fixture: \(id)")
                }
                try await engine.load(model, storage: storage)
                for (index, prompt) in prompts.enumerated() {
                    let answer = try await engine.complete(messages: [ChatMessage(role: "user", content: prompt)], maxTokens: 320, reusePrompt: false, onToken: { _ in })
                    results.append(["modelID": id, "modelSHA256": model.sha256, "promptID": ["email", "explain", "grounding"][index],
                                    "prompt": prompt, "answer": answer.text, "firstTokenSeconds": answer.firstTokenSeconds,
                                    "tokensPerSecond": answer.tokensPerSecond, "reachedLimit": answer.reachedLimit])
                    print("EXAMPLE \(id) \(index + 1)/\(prompts.count)"); fflush(stdout)
                }
            }
            let report: [String: Any] = ["recordedAt": ISO8601DateFormatter().string(from: Date()),
                                       "chip": hardware.chip, "memoryBytes": hardware.memory,
                                       "engineVersion": "b11146", "contextTokens": 4096, "examples": results]
            let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: URL(fileURLWithPath: ".test-data/performance/discovery-examples.json"), options: .atomic)
            print("PASS: recorded exact-model sample answers and timing; these are examples, not a quality leaderboard")
            return
        }
        if let index = arguments.firstIndex(of: "--models"), index + 1 < arguments.count {
            try await catalogSmoke(ids: arguments[index + 1].split(separator: ",").map(String.init), storage: storage, catalog: models, allowDownload: arguments.contains("--download"))
            return
        }
        if arguments.contains("--families") {
            try await families(storage: storage, catalog: models, hardware: hardware, allowDownload: arguments.contains("--download"))
            return
        }
        let small = models.first { $0.id == "qwen3-06b" }!
        if arguments.contains("--download") && !storage.installed(small) {
            let download = ModelDownload(model: small, destination: storage.partialURL(small)) { progress in
                if progress.fraction > 0.99 { print("DOWNLOAD finishing") }
            }
            try await download.run()
            try await storage.finishInstall(small)
        }
        guard storage.installed(small) else { throw HearthError.message("Run with --download to obtain the smoke-test model.") }
        let engine = try LocalEngine()
        defer { engine.stop() }
        try await engine.load(small, storage: storage) { print($0) }
        print("ENGINE pid=\(engine.processID ?? 0) port=\(engine.port)")
        fflush(stdout)
        if arguments.contains("--prompt-cache") {
            let notes = String(repeating: "The workshop starts at ten. Bring a notebook. The room has chairs and tables.\n", count: 90)
            let messages = [ChatMessage(role: "user", content: "Read these workshop notes, then reply only OK.\n" + notes)]
            var rows: [[String: Any]] = []
            for reuse in [false, false, true, true] {
                let began = ProcessInfo.processInfo.systemUptime
                let answer = try await engine.complete(messages: messages, maxTokens: 12, reusePrompt: reuse, onToken: { _ in })
                rows.append(["reusePrompt": reuse, "firstTokenSeconds": answer.firstTokenSeconds,
                             "totalSeconds": ProcessInfo.processInfo.systemUptime - began, "answer": answer.text])
            }
            let output = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: URL(fileURLWithPath: ".test-data/performance/prompt-cache.json"), options: .atomic)
            print(String(decoding: output, as: UTF8.self))
            return
        }
        if arguments.contains("--responsiveness") {
            var gaps: [Double] = []
            let monitor = Task { @MainActor in
                var previous = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    let now = ProcessInfo.processInfo.systemUptime
                    gaps.append(max(0, now - previous - 0.010) * 1000)
                    previous = now
                }
            }
            var durations: [Double] = []
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(50))
                let start = ProcessInfo.processInfo.systemUptime
                await engine.unload()
                durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                try await Task.sleep(for: .milliseconds(50))
                try await engine.load(small, storage: storage)
            }
            monitor.cancel(); await monitor.value
            let report: [String: Any] = ["unloadMilliseconds": durations, "maximumMainActorDelayMilliseconds": gaps.max() ?? 0,
                                       "mainActorSamples": gaps.count, "modelID": small.id]
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
            if let index = arguments.firstIndex(of: "--report"), index + 1 < arguments.count {
                try json.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
            }
            return
        }
        if arguments.contains("--hold") {
            try await Task.sleep(for: .seconds(120))
            return
        }
        let answer = try await engine.complete(messages: [ChatMessage(role: "user", content: "What is 2 + 2? Answer in one short sentence.")], onToken: { print($0, terminator: "") })
        print("\nANSWER tokens=\(answer.tokens) speed=\(answer.tokensPerSecond)")
        guard answer.text.contains("4") || answer.text.lowercased().contains("four") else { throw HearthError.message("Arithmetic smoke check failed.") }
        guard !answer.text.contains("<think>") else { throw HearthError.message("Thinking markup leaked into the chat.") }
        if arguments.contains("--extended") {
            try await extended(engine: engine, storage: storage, catalog: models, allowDownload: arguments.contains("--download"))
            try await engine.load(small, storage: storage)
        }
        let benchmark = try await engine.benchmark(model: small, chip: hardware.chip) { print("BENCHMARK \($0)/3") }
        var data = AppData(); data.benchmarks[small.id] = benchmark
        var conversation = Conversation(modelID: small.id)
        conversation.messages = [ChatMessage(role: "user", content: "What is 2 + 2?"), ChatMessage(role: "assistant", content: answer.text, modelID: small.id)]
        data.conversations = [conversation]
        try storage.save(data)
        guard try storage.readState().conversations.first?.messages.last?.content == answer.text else { throw HearthError.message("Conversation persistence failed.") }
        try JSONEncoder().encode(benchmark).write(to: storage.root.appendingPathComponent("benchmark-report.json"), options: .atomic)
        engine.stop()
        guard !engine.isRunning else { throw HearthError.message("The engine did not unload.") }
        print("PASS: download, verification, local inference, benchmark, persistence, unload")
    }

    @MainActor static func catalogSmoke(ids: [String], storage: LocalStorage, catalog: [LocalModel], allowDownload: Bool) async throws {
        let engine = try LocalEngine(); defer { engine.stop() }
        var report: [[String: Any]] = [], failed: [String] = []
        for id in ids {
            guard let model = catalog.first(where: { $0.id == id }) else { throw HearthError.message("Unknown test model \(id)") }
            // This automated suite intentionally does not accept custom licenses for a user.
            guard !model.needsLicenseReview else { throw HearthError.message("\(id) requires the user's license review; test it through the app after acceptance.") }
            print("CATALOG \(id)"); fflush(stdout)
            do {
                if !storage.installed(model) {
                    guard allowDownload else { throw HearthError.message("Missing fixture. Run with --download.") }
                    let download = ModelDownload(model: model, destination: storage.partialURL(model)) { _ in }
                    try await download.run(); try await storage.finishInstall(model)
                }
                let previous = engine.processID
                try await engine.load(model, storage: storage) { print($0); fflush(stdout) }
                if let previous, kill(previous, 0) == 0 { throw HearthError.message("Previous process was not released.") }
                let message = ChatMessage(role: "user", content: "My favorite color is green. What is 2 + 2? Answer briefly.")
                let limit = model.isReasoning ? 1024 : 256
                let first = try await engine.complete(messages: [message], maxTokens: limit, onToken: { _ in })
                let second = try await engine.complete(messages: [message, ChatMessage(role: "assistant", content: first.text),
                    ChatMessage(role: "user", content: "What color did I mention in my previous message?")], maxTokens: limit, onToken: { _ in })
                let formatted = try await engine.complete(messages: [ChatMessage(role: "user", content: "Give two Markdown bullet points about Python, then a fenced python code block that prints hello. Keep it short.")], maxTokens: limit, onToken: { _ in })
                guard first.tokens > 0, second.tokens > 0, formatted.tokens > 0 else { throw HearthError.message("No generation metrics") }
                guard ![first.text, second.text, formatted.text].contains(where: { $0.contains("<think>") || $0.contains("<|im_start|>") }) else { throw HearthError.message("Template markup leaked into the answer") }
                let entry: [String: Any] = ["id":id,"sha256":model.sha256,"architecture":model.architecture ?? "", "runtimePassed":true,
                    "arithmeticAnswer":first.text,"recallAnswer":second.text,"formattedAnswer":formatted.text,
                    "arithmeticMatched":first.text.contains("4") || first.text.lowercased().contains("four"),
                    "recallMatched":second.text.lowercased().contains("green"),
                    "thinkingSeparated":first.reasoning != nil,"tokensPerSecond":formatted.tokensPerSecond]
                report.append(entry)
                print("PASS runtime \(id) · \(Int(formatted.tokensPerSecond)) tokens/s · recall=\(second.text.lowercased().contains("green"))"); fflush(stdout)
            } catch {
                failed.append(id); report.append(["id":id,"runtimePassed":false,"error":error.localizedDescription])
                print("FAIL \(id): \(error.localizedDescription)"); fflush(stdout); engine.stop()
            }
        }
        engine.stop()
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
            .write(to: storage.root.appendingPathComponent("catalog-report.json"), options: .atomic)
        if !failed.isEmpty { throw HearthError.message("Catalog runtime failures: \(failed.joined(separator: ", "))") }
        print("PASS runtime compatibility: \(report.count) models. Quality observations are separate in catalog-report.json.")
    }

    @MainActor static func families(storage: LocalStorage, catalog: [LocalModel], hardware: Hardware, allowDownload: Bool) async throws {
        let ids = ["qwen3-06b", "smollm3-3b", "phi4-mini", "ministral3-3b"]
        let engine = try LocalEngine()
        defer { engine.stop() }
        var reports: [[String: Any]] = []
        for id in ids {
            guard let model = catalog.first(where: { $0.id == id }) else { throw HearthError.message("Missing family test model: \(id)") }
            print("FAMILY \(model.family): \(model.name)"); fflush(stdout)
            if !storage.installed(model) {
                guard allowDownload else { throw HearthError.message("Run --families --download to obtain \(model.name).") }
                let download = ModelDownload(model: model, destination: storage.partialURL(model)) { _ in }
                try await download.run()
                try await storage.finishInstall(model)
            }
            let oldPID = engine.processID
            try await engine.load(model, storage: storage) { print($0); fflush(stdout) }
            if let oldPID, kill(oldPID, 0) == 0 { throw HearthError.message("Previous model process survived switching families.") }
            let first = ChatMessage(role: "user", content: "My favorite color is green. What is 2 + 2? Answer briefly.")
            let answer = try await engine.complete(messages: [first], maxTokens: 128, onToken: { _ in })
            print("ANSWER \(answer.text)"); fflush(stdout)
            guard answer.text.contains("4") || answer.text.lowercased().contains("four") else { throw HearthError.message("\(id): arithmetic check failed: \(answer.text)") }
            let followup = try await engine.complete(messages: [first, ChatMessage(role: "assistant", content: answer.text),
                ChatMessage(role: "user", content: "What color did I say is my favorite in my previous message?")], maxTokens: 128, onToken: { _ in })
            guard followup.text.lowercased().contains("green") else { throw HearthError.message("\(id): conversation history check failed: \(followup.text)") }
            for text in [answer.text, followup.text] {
                guard !text.contains("<think>"), !text.contains("<|im_"), !text.contains("[INST]") else {
                    throw HearthError.message("\(id): template markup leaked into the conversation.")
                }
            }
            let benchmark = try await engine.benchmark(model: model, chip: hardware.chip)
            reports.append(["modelID": id, "family": model.family, "sha256": model.sha256,
                            "answer": answer.text, "followup": followup.text,
                            "medianTokensPerSecond": benchmark.tokensPerSecond,
                            "medianFirstTokenSeconds": benchmark.firstTokenSeconds,
                            "benchmarkPrompts": benchmark.sampleCount])
            print("PASS \(model.family): verified weights, chat, history, switching, three-prompt benchmark (\(Int(benchmark.tokensPerSecond)) tokens/s)"); fflush(stdout)
        }
        engine.stop()
        guard !engine.isRunning else { throw HearthError.message("Family test engine did not unload.") }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: storage.root.appendingPathComponent("family-report.json"), options: .atomic)
        print("PASS: all \(ids.count) model families")
    }

    @MainActor static func extended(engine: LocalEngine, storage: LocalStorage, catalog: [LocalModel], allowDownload: Bool) async throws {
        var unauthorized = URLRequest(url: URL(string: "http://127.0.0.1:\(engine.port)/v1/chat/completions")!)
        unauthorized.httpMethod = "POST"
        unauthorized.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unauthorized.httpBody = Data("{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}".utf8)
        let (_, response) = try await URLSession.shared.data(for: unauthorized)
        guard (response as? HTTPURLResponse)?.statusCode == 401 else { throw HearthError.message("Unauthenticated requests were not rejected.") }
        print("PASS authentication")

        let memory = try await engine.complete(messages: [
            ChatMessage(role: "user", content: "My favorite color is green. Please remember that."),
            ChatMessage(role: "assistant", content: "Your favorite color is green."),
            ChatMessage(role: "user", content: "What is my favorite color? Answer in one short sentence.")
        ], onToken: { _ in })
        guard memory.text.lowercased().contains("green") else { throw HearthError.message("Multi-turn conversation failed.") }
        print("PASS conversation context")

        var longHistory: [ChatMessage] = []
        for _ in 0..<16 {
            longHistory += [ChatMessage(role: "user", content: String(repeating: "Tell me about a tree in the garden. ", count: 60)),
                            ChatMessage(role: "assistant", content: "The tree has green leaves.")]
        }
        longHistory.append(ChatMessage(role: "user", content: "What is 2 + 2?"))
        let trimmed = try await engine.complete(messages: longHistory, onToken: { _ in })
        guard trimmed.omittedMessages > 0 else { throw HearthError.message("Oversized history was not trimmed.") }
        print("PASS context trimming (\(trimmed.omittedMessages) messages)")
        do {
            _ = try await engine.complete(messages: [ChatMessage(role: "user", content: String(repeating: "tree ", count: 7000))], onToken: { _ in })
            throw HearthError.message("Oversized single message was accepted.")
        } catch { guard error.localizedDescription.contains("too long") else { throw error } }
        print("PASS oversized input rejection")

        var generation: Task<CompletionResult, Error>?
        var pieces = 0
        generation = Task { @MainActor in
            try await engine.complete(messages: [ChatMessage(role: "user", content: "Write a long story about a forest.")], onToken: { _ in
                pieces += 1
                if pieces == 5 { generation?.cancel() }
            })
        }
        do { _ = try await generation!.value; throw HearthError.message("Generation was not cancelled.") }
        catch { guard error is CancellationError || (error as NSError).code == NSURLErrorCancelled else { throw error } }
        let resumed = try await engine.complete(messages: [ChatMessage(role: "user", content: "Say hello in one word.")], onToken: { _ in })
        guard !resumed.text.isEmpty else { throw HearthError.message("Generation did not recover after cancellation.") }
        print("PASS cancel and recover")

        let second = catalog.first { $0.id == "qwen3-17b" }!
        if !storage.installed(second) {
            guard allowDownload else { throw HearthError.message("Second test model is missing; first run --download --extended.") }
            let pauser = PauseOnce()
            let firstAttempt = ModelDownload(model: second, destination: storage.partialURL(second)) { pauser.progress($0) }
            pauser.download = firstAttempt
            do { try await firstAttempt.run() } catch { guard (error as NSError).code == NSURLErrorCancelled else { throw error } }
            pauser.download = nil
            let partialBytes = storage.fileSize(storage.partialURL(second))
            guard partialBytes > 0 && partialBytes < second.bytes else { throw HearthError.message("Download pause did not leave resumable data.") }
            print("PASS pause at \(partialBytes) bytes")
            let resume = ModelDownload(model: second, destination: storage.partialURL(second)) { _ in }
            try await resume.run()
            try await storage.finishInstall(second)
            print("PASS resume and checksum")
        }
        let oldPID = engine.processID!
        try await engine.load(second, storage: storage)
        guard engine.activeModelID == second.id, engine.processID != oldPID, kill(oldPID, 0) != 0 else {
            throw HearthError.message("Model switching did not stop the previous process.")
        }
        let secondAnswer = try await engine.complete(messages: [ChatMessage(role: "user", content: "What is 3 + 3? Answer in one sentence.")], onToken: { _ in })
        guard secondAnswer.text.contains("6") || secondAnswer.text.lowercased().contains("six") else { throw HearthError.message("Second model did not answer.") }
        print("PASS switch and second-model inference")

        // Copy-on-write clone verifies removal without deleting the reusable integration fixture.
        let scratch = try LocalStorage(root: storage.root.appendingPathComponent("deletion-check"))
        try FileManager.default.copyItem(at: storage.modelURL(second), to: scratch.modelURL(second))
        try FileManager.default.copyItem(at: storage.receiptURL(second), to: scratch.receiptURL(second))
        guard scratch.installed(second) else { throw HearthError.message("Deletion fixture is not installed.") }
        try scratch.remove(second)
        guard !scratch.installed(second), !FileManager.default.fileExists(atPath: scratch.modelURL(second).path) else {
            throw HearthError.message("Deleting a model did not remove its files.")
        }
        try FileManager.default.removeItem(at: scratch.root)
        print("PASS model deletion")
    }
}
