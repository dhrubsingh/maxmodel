import Foundation
import Darwin

public struct CompletionResult: Sendable {
    public let text: String
    public let reasoning: String?
    public let firstTokenSeconds: Double
    public let tokensPerSecond: Double
    public let tokens: Int
    public let omittedMessages: Int
    public let reachedLimit: Bool
    public let promptTokens: Int
}

public struct StreamEvent: Sendable {
    public var text: String?
    public var reasoning: String?
    public var tokens: Int?
    public var tokensPerSecond: Double?
    public var finishReason: String?
    public static func parse(_ line: String) throws -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { throw HearthError.message(error["message"] as? String ?? "The model could not finish the response.") }
        let choice = (object["choices"] as? [[String: Any]])?.first
        let delta = choice?["delta"] as? [String: Any]
        let usage = object["usage"] as? [String: Any]
        let timings = object["timings"] as? [String: Any]
        return StreamEvent(text: delta?["content"] as? String, reasoning: delta?["reasoning_content"] as? String,
                           tokens: usage?["completion_tokens"] as? Int,
                           tokensPerSecond: timings?["predicted_per_second"] as? Double,
                           finishReason: choice?["finish_reason"] as? String)
    }
}

/// One engine process, bound only to loopback and authenticated with a fresh random key.
/// No tools, remote providers, hosted inference, or model downloads are enabled in the engine.
@MainActor
public final class LocalEngine {
    public private(set) var activeModelID: String?
    public private(set) var process: Process?
    public private(set) var port: UInt16 = 0
    private var apiKey = UUID().uuidString + UUID().uuidString
    private var contextSize = 4096
    private var thinkingEnabled = false
    public private(set) var activeProfile: RuntimeProfile?
    /// True when the running engine loaded the model's image encoder.
    public private(set) var visionEnabled = false
    /// Tokens an image may take. Image tokens cost about four times as much to read as text, and
    /// recognized text already carries the fine print, so the image needs only enough detail for
    /// layout, color, and objects. Precise object locations would need 1,024; nothing here asks for them.
    public nonisolated static let imageTokens = 512
    private var supportsSystemRole = true
    private var generationPolicy: GenerationPolicy?
    private var knowledgeCutoff: String?
    private var modelName: String?
    private var templateOptions: [String: Any] { ["enable_thinking": thinkingEnabled, "reasoning_effort": "low"] }
    private let executable: URL
    private let session: URLSession
    private var requestInFlight = false
    private var stoppingTask: Task<Void, Never>?

    public init(executable: URL? = nil) throws {
        let override = ProcessInfo.processInfo.environment["HEARTH_ENGINE_PATH"].map { URL(fileURLWithPath: $0) }
        let candidates = [executable, override,
                          Bundle.main.resourceURL?.appendingPathComponent("engine/llama-server"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("vendor/llama/llama-server")].compactMap { $0 }
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw HearthError.message("Hearth's bundled engine is missing. Run scripts/build-app.sh to package the app.")
        }
        self.executable = binary
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: configuration)
    }
    public var isRunning: Bool { process?.isRunning == true && activeModelID != nil }
    public var processID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    public func load(_ model: LocalModel, storage: LocalStorage, profile: RuntimeProfile? = nil, vision: Bool = false,
                     progress: (String) -> Void = { _ in }) async throws {
        let profile = profile ?? .legacy(model)
        let vision = vision && storage.visionInstalled(model)
        if isRunning && activeModelID == model.id && activeProfile == profile && visionEnabled == vision { return }
        guard !requestInFlight else { throw HearthError.message("Stop the current response before switching models.") }
        await unload()
        try Task.checkCancellation()
        guard storage.installed(model) else { throw HearthError.message("Download this model before using it.") }
        progress("Checking model integrity…")
        try await storage.verify(model, at: storage.modelURL(model))
        if vision { try await storage.verifyVision(model) }
        try Task.checkCancellation()
        port = try Self.availablePort()
        contextSize = profile.contextTokens
        thinkingEnabled = profile.isThinking
        supportsSystemRole = model.supportsSystemRole != false
        generationPolicy = .forModel(model, thinking: profile.isThinking)
        knowledgeCutoff = model.knowledge?.cutoff
        modelName = model.name.replacingOccurrences(of: " · ", with: " ")
        // Notices were preserved at install. Refreshing them is housekeeping and must never block a chat.
        do { try await Task.detached(priority: .utility) { try storage.preserveNotices(model) }.value }
        catch { NSLog("MaxModel: could not refresh license notices for %@: %@", model.id, error.localizedDescription) }
        try Task.checkCancellation()
        apiKey = UUID().uuidString + UUID().uuidString
        let engine = Process()
        let guardian = executable.deletingLastPathComponent().appendingPathComponent("hearth-engine-guardian")
        let useGuardian = FileManager.default.isExecutableFile(atPath: guardian.path)
        engine.executableURL = useGuardian ? guardian : executable
        engine.currentDirectoryURL = executable.deletingLastPathComponent()
        engine.arguments = ["--model", storage.modelURL(model).path, "--host", "127.0.0.1", "--port", String(port),
                            "--ctx-size", String(contextSize), "--parallel", "1",
                            "--threads", String(profile.threads),
                            "--cache-type-k", profile.cacheType.rawValue, "--cache-type-v", profile.cacheType.rawValue,
                            "--flash-attn", profile.cacheType == .q8_0 ? "on" : "auto",
                            "--ctx-checkpoints", "2", "--checkpoint-min-step", "8192",
                            "--no-webui", "--no-context-shift", "--cache-ram", "0", "--jinja", "--reasoning-format", "deepseek",
                            "--reasoning-budget", String(profile.thinkingTokens),
                            "--chat-template-kwargs", String(data: try JSONSerialization.data(withJSONObject: templateOptions), encoding: .utf8)!]
        engine.arguments! += profile.execution.arguments(threads: profile.threads)
        if vision {
            engine.arguments! += ["--mmproj", storage.visionURL(model).path, "--image-max-tokens", String(Self.imageTokens)]
        }
        if useGuardian { engine.arguments?.insert(executable.path, at: 0) }
        // An allowlist prevents inherited LLAMA_ARG_*, proxy, token, and agent configuration.
        engine.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": storage.root.path,
                              "TMPDIR": NSTemporaryDirectory(), "LLAMA_API_KEY": apiKey,
                              "GGML_METAL_PATH_RESOURCES": executable.deletingLastPathComponent().path]
        engine.standardInput = FileHandle.nullDevice
        engine.standardOutput = FileHandle.nullDevice
        engine.standardError = FileHandle.nullDevice
        try engine.run()
        process = engine
        progress("Loading \(model.name)…")
        do {
            let deadline = Date().addingTimeInterval(max(120, min(600, Double(model.bytes) / (150 * 1024 * 1024))))
            while Date() < deadline {
                try Task.checkCancellation()
                guard engine.isRunning else {
                    throw HearthError.message("The local engine exited while loading (code \(engine.terminationStatus)). Try a smaller model or free some memory.")
                }
                do {
                    let (_, response) = try await session.data(for: request("/health", timeout: 2))
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        activeModelID = model.id; activeProfile = profile; visionEnabled = vision; return
                    }
                } catch is CancellationError { throw CancellationError() }
                  catch { if Task.isCancelled { throw CancellationError() } }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw HearthError.message("This model took too long to load. Try a smaller model or close other applications.")
        } catch { await unload(); throw error }
    }

    /// Interactive shutdown waits off the main actor; switching still awaits full release.
    public func unload() async {
        activeModelID = nil; activeProfile = nil; visionEnabled = false
        if let pending = stoppingTask { await pending.value; return }
        guard let engine = process else { return }
        process = nil
        let pending = Task.detached(priority: .userInitiated) { Self.terminate(engine) }
        stoppingTask = pending
        await pending.value
        stoppingTask = nil
    }

    /// Synchronous cleanup is reserved for process/app termination and CLI defers.
    public func stop() {
        activeModelID = nil; activeProfile = nil; visionEnabled = false
        guard let engine = process else { return }
        process = nil
        Self.terminate(engine)
    }

    private nonisolated static func terminate(_ engine: Process) {
        guard engine.isRunning else { return }
        engine.terminate()
        // A bounded wait ensures the previous model releases memory before another is loaded.
        let deadline = Date().addingTimeInterval(1.5)
        while engine.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if engine.isRunning { kill(engine.processIdentifier, SIGKILL) }
        engine.waitUntilExit()
    }

    public func complete(messages: [ChatMessage], attachments: AttachmentLibrary? = nil, maxTokens: Int? = nil, reusePrompt: Bool = true,
                         temperature: Double? = nil, onTrim: (Int) -> Void = { _ in }, onReasoning: (String) -> Void = { _ in },
                         onToken: (String) -> Void) async throws -> CompletionResult {
        guard isRunning else { throw HearthError.message("Choose a downloaded model first.") }
        guard !requestInFlight else { throw HearthError.message("A response is already running.") }
        requestInFlight = true
        defer { requestInFlight = false }
        let defaultOutput = thinkingEnabled ? (activeProfile?.thinkingTokens ?? 512) + 1536 : 2048
        let maxTokens = min(maxTokens ?? defaultOutput, max(256, contextSize - 1024))
        let (prepared, omitted, promptTokens) = try await fit(messages: messages, attachments: attachments, reserve: maxTokens + 64)
        onTrim(omitted)
        var payload: [String: Any] = ["model": "local", "messages": prepared, "stream": true,
                                    "stream_options": ["include_usage": true], "max_tokens": maxTokens,
                                    "chat_template_kwargs": templateOptions, "cache_prompt": reusePrompt]
        payload.merge(generationPolicy?.parameters(temperature: temperature) ?? [:]) { _, new in new }
        let started = Date()
        let (bytes, response) = try await session.bytes(for: request("/v1/chat/completions", body: payload))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HearthError.message("The local model could not start this response (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        var content = "", reasoning = "", tokens = 0, speed: Double?, firstToken: Double?, finishReason: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = try StreamEvent.parse(line) else { continue }
            if let text = event.reasoning, !text.isEmpty { reasoning += text; onReasoning(text) }
            if let text = event.text, !text.isEmpty {
                if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                content += text; onToken(text)
            }
            if let count = event.tokens { tokens = count }
            if let value = event.tokensPerSecond, value > 0 { speed = value }
            if let reason = event.finishReason { finishReason = reason }
        }
        try Task.checkCancellation()
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HearthError.message(reasoning.isEmpty ? "The model returned an empty answer. Try rephrasing your question." : "The model reached its thinking limit before answering. Its thinking is saved; try a shorter question or an everyday model.")
        }
        guard finishReason != nil else { throw HearthError.message("The response was interrupted. Your partial answer has been kept.") }
        let generationTime = max(0.001, Date().timeIntervalSince(started) - (firstToken ?? 0))
        return CompletionResult(text: content, reasoning: reasoning.isEmpty ? nil : reasoning, firstTokenSeconds: firstToken ?? 0,
                                tokensPerSecond: speed ?? Double(max(0, tokens - 1)) / generationTime,
                                tokens: tokens, omittedMessages: omitted, reachedLimit: finishReason == "length", promptTokens: promptTokens)
    }

    private func prepare(_ history: [[String: String]]) -> [[String: String]] {
        let system = ["role": "system", "content": AssistantInstructions.make(knowledgeCutoff: knowledgeCutoff, modelName: modelName)]
        var prepared = history
        if supportsSystemRole { prepared.insert(system, at: 0) }
        else if !prepared.isEmpty { prepared[0]["content"] = system["content"]! + "\n\n" + (prepared[0]["content"] ?? "") }
        return prepared
    }
    private func tokenCount(_ prepared: [[String: String]]) async throws -> Int {
        let template = try await json("/apply-template", body: ["messages": prepared, "add_generation_prompt": true,
                                                              "chat_template_kwargs": templateOptions])
        guard let prompt = template["prompt"] as? String else { throw HearthError.message("The engine could not format this conversation.") }
        let tokenized = try await json("/tokenize", body: ["content": prompt, "add_special": true])
        guard let tokens = tokenized["tokens"] as? [Any] else { throw HearthError.message("The engine could not measure the conversation length.") }
        return tokens.count
    }
    /// Text is counted exactly with the model's template and tokenizer; each image adds its capped allowance.
    private func fit(messages: [ChatMessage], attachments: AttachmentLibrary?, reserve: Int) async throws -> ([[String: Any]], Int, Int) {
        // Fixed per configuration, so earlier turns render identically and the prompt cache stays valid.
        let budget = AttachmentBudget.characters(contextTokens: contextSize, thinkingTokens: thinkingEnabled ? activeProfile?.thinkingTokens ?? 512 : 0,
                                                 images: visionEnabled ? 1 : 0)
        let vision = visionEnabled
        let turns = await Task.detached(priority: .userInitiated) {
            ConversationRenderer.render(messages, library: attachments, vision: vision, characterBudget: budget)
        }.value
        let text = turns.map { ["role": $0.role, "content": $0.text] }
        let starts = turns.indices.filter { turns[$0].role == "user" }
        guard !starts.isEmpty else {
            let prepared = prepare([])
            return (prepared.map { $0 as [String: Any] }, 0, try await tokenCount(prepared))
        }
        var counts: [Int: Int] = [:]
        let result = try await ContextFitting.firstFittingTurn(count: starts.count) { index in
            try Task.checkCancellation()
            let pictures = turns[starts[index]...].reduce(0) { $0 + $1.images.count }
            let count = try await self.tokenCount(self.prepare(Array(text[starts[index]...]))) + pictures * (Self.imageTokens + 16)
            counts[index] = count
            return count + reserve <= self.contextSize
        }
        guard let result else {
            throw HearthError.message("This message is too long for the model's \(contextSize.formatted())-token conversation window. Please shorten it, or open About this assistant for conversation memory settings.")
        }
        let kept = Array(turns[starts[result]...])
        let system = AssistantInstructions.make(knowledgeCutoff: knowledgeCutoff, modelName: modelName), systemRole = supportsSystemRole
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.payload(kept, system: system, supportsSystemRole: systemRole)
        }.value
        return (prepared, starts[result] - starts[0], counts[result]!)
    }

    /// OpenAI-style messages. Images come before the question, as the vision models were trained.
    nonisolated static func payload(_ turns: [RenderedTurn], system: String, supportsSystemRole: Bool) throws -> [[String: Any]] {
        var messages: [[String: Any]] = turns.enumerated().map { index, turn in
            let text = !supportsSystemRole && index == 0 ? system + "\n\n" + turn.text : turn.text
            return ["role": turn.role, "content": text]
        }
        for (index, turn) in turns.enumerated() where !turn.images.isEmpty {
            var parts: [[String: Any]] = try turn.images.map { url in
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + (try Data(contentsOf: url)).base64EncodedString()]]
            }
            parts.append(["type": "text", "text": messages[index]["content"] as? String ?? turn.text])
            messages[index]["content"] = parts
        }
        if supportsSystemRole { messages.insert(["role": "system", "content": system], at: 0) }
        return messages
    }

    /// Synthetic long-input retrieval, with exact tokenizer accounting. No user chats are read.
    public func checkContext(targetTokens: Int? = nil, seed: Int? = nil, progress: (String) -> Void = { _ in }) async throws -> ContextCheck {
        guard isRunning else { throw HearthError.message("Load this assistant before checking conversation memory.") }
        let output = (activeProfile?.thinkingTokens ?? 0) + 192
        let target = min(targetTokens ?? min(32768, contextSize * 3 / 4), contextSize - output - 256)
        guard target >= 512 else { throw HearthError.message("This configuration needs more room for a context check.") }
        let seed = seed ?? Int.random(in: 100000...900000)
        var lower = 6, upper = max(7, target), best = ContextProbe.make(lines: 6, seed: seed)
        // Tokenizer-only bisection: the generated test stays within the actual template budget.
        while lower <= upper {
            try Task.checkCancellation()
            let lines = (lower + upper) / 2
            let candidate = ContextProbe.make(lines: lines, seed: seed)
            let count = try await tokenCount(prepare([["role": "user", "content": candidate.prompt]]))
            if count <= target { best = candidate; lower = lines + 1 } else { upper = lines - 1 }
        }
        progress("Reading a long synthetic conversation…")
        let started = Date()
        let answer = try await complete(messages: [ChatMessage(role: "user", content: best.prompt)], maxTokens: output, reusePrompt: false, temperature: 0, onToken: { _ in })
        return ContextCheck(promptTokens: answer.promptTokens, matchedFacts: best.matches(answer.text), totalFacts: 3,
                            firstAnswerSeconds: answer.firstTokenSeconds, totalSeconds: Date().timeIntervalSince(started),
                            truncated: answer.reachedLimit || answer.omittedMessages != 0, response: answer.text)
    }

    public func benchmark(model: LocalModel, chip: String, progress: (Int) -> Void = { _ in }) async throws -> Benchmark {
        let prompts = ["Explain why the sky looks blue in five short sentences.",
                       "Give five practical tips for keeping a small kitchen organized, with one sentence per tip.",
                       "Write a friendly paragraph explaining how to begin learning a new language."]
        var results: [CompletionResult] = []
        for (index, prompt) in prompts.enumerated() {
            progress(index + 1)
            results.append(try await complete(messages: [ChatMessage(role: "user", content: prompt)], maxTokens: thinkingEnabled ? (activeProfile?.thinkingTokens ?? 512) + 256 : 192, reusePrompt: false, onToken: { _ in }))
        }
        guard results.allSatisfy({ $0.tokens > 0 && $0.tokensPerSecond > 0 }) else {
            throw HearthError.message("The model answered, but the engine did not report enough timing data for a benchmark.")
        }
        var measurement = Benchmark(modelID: model.id, firstTokenSeconds: results.map(\.firstTokenSeconds).sorted()[1],
                         tokensPerSecond: results.map(\.tokensPerSecond).sorted()[1], generatedTokens: results.reduce(0) { $0 + $1.tokens },
                         contextTokens: contextSize, chip: chip, modelSHA256: model.sha256,
                                processMemoryBytes: memoryFootprint(), sampleCount: results.count)
        measurement.profileID = activeProfile?.id
        measurement.hardwareID = Hardware.inspect(at: executable.deletingLastPathComponent()).optimizationID
        return measurement
    }

    public func checkAnswers(progress: (Int) -> Void = { _ in }) async throws -> [LocalAnswerCheck] {
        var checks: [LocalAnswerCheck] = []
        for (index, task) in LocalCalibration.tasks.enumerated() {
            try Task.checkCancellation()
            progress(index + 1)
            let result = try await complete(messages: [ChatMessage(role: "user", content: task.prompt)],
                                            maxTokens: (activeProfile?.thinkingTokens ?? 0) + 128, reusePrompt: false, temperature: 0, onToken: { _ in })
            checks.append(LocalAnswerCheck(name: task.name, passed: !result.reachedLimit && LocalCalibration.passes(result.text, task: task)))
        }
        return checks
    }

    public func memoryFootprint() -> UInt64? {
        guard let pid = processID else { return nil }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_resident_size
    }

    private func request(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 180) throws -> URLRequest {
        // The caller supplies only literal paths. There is no configurable remote API URL.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
    private func json(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request(path, body: body))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HearthError.message("The local engine could not process this conversation. Try a new chat.")
        }
        return result
    }
    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HearthError.message("Could not create the local connection.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw HearthError.message("Could not reserve a local connection.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result2 = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result2 == 0 else { throw HearthError.message("Could not find the local connection port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
