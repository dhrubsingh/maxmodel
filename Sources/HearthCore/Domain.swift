import Foundation
import Metal
import Darwin
import CryptoKit

public let gib = Double(1 << 30)

public enum HearthError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

public struct LocalModel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let family: String
    public let parameters: Double
    public let quantization: String
    public let tagline: String
    public let strengths: String
    public let limitations: String
    public let preference: Int
    public let bytes: Int64
    public let filename: String
    public let sha256: String
    public let url: URL
    public let sourceURL: URL
    public let distributorURL: URL
    public let license: String
    public let contextTokens: Int
    public let kvBytesPerToken: Int
    public let series: String?
    public let category: String?
    public let licenseID: String?
    public let licenseURL: URL?
    public let licenseSHA256: String?
    public let requiresLicenseAcceptance: Bool?
    public let noticeFiles: [ModelNotice]?
    public let architecture: String?
    public let reasoning: Bool?
    public let supportsSystemRole: Bool?
    public let validation: String?
    public let attribution: String?
    public let metadataCheckedAt: String?
    public let knowledge: ModelKnowledge?
    /// Present when the publisher's GGUF release includes the projector that lets the engine see images.
    public let vision: VisionEncoder?

    public var knowledgeCutoffLabel: String { knowledge?.cutoff ?? "Not documented" }
    public var canSeeImages: Bool { vision != nil }

    public var groupID: String { series ?? name }
    /// Precision variants of one model share this, and its published results.
    public var baseModelID: String { "\(groupID)|\(parameters)" }
    public var taskCategory: String { category ?? "Everyday" }
    public var needsLicenseReview: Bool { requiresLicenseAcceptance == true }
    public var isReasoning: Bool { reasoning == true }
    public var noticeDirectory: URL { Self.resourceBundle.resourceURL!.appendingPathComponent("model-notices/\(id)") }
    public var licenseText: String { (try? String(contentsOf: noticeDirectory.appendingPathComponent("TERMS-READABLE.txt"), encoding: .utf8)) ?? "Open the original license to review its terms." }
    static var resourceBundle: Bundle {
        Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("Hearth_HearthCore.bundle")) } ?? Bundle.module
    }

    /// Budget estimate, not measured consumption. Includes FP16 KV cache and runtime headroom.
    public var estimatedMemory: Double {
        Double(bytes) * 1.15 + Double(contextTokens * kvBytesPerToken) + 768 * 1024 * 1024
    }
    public var diskLabel: String { Self.size(Double(bytes)) }
    public var memoryLabel: String { "≈ " + Self.size(estimatedMemory) }
    public static func size(_ bytes: Double) -> String {
        bytes >= gib ? String(format: "%.1f GB", bytes / gib) : String(format: "%.0f MB", bytes / (1024 * 1024))
    }
    public static func catalog() throws -> [LocalModel] {
        guard let url = resourceBundle.url(forResource: "catalog", withExtension: "json") else {
            throw HearthError.message("The bundled model catalog is missing. Rebuild Hearth.")
        }
        let models = try JSONDecoder().decode([LocalModel].self, from: Data(contentsOf: url))
        guard Set(models.map(\.id)).count == models.count else { throw HearthError.message("Duplicate catalog entries.") }
        for model in models {
            guard !model.id.contains("/"), !model.id.contains(".."),
                  model.filename == URL(fileURLWithPath: model.filename).lastPathComponent,
                  model.url.scheme == "https", model.url.host == "huggingface.co",
                  model.sha256.count == 64, model.sha256.allSatisfy({ $0.isHexDigit }),
                  model.bytes > 0, model.contextTokens > 0,
                  model.licenseURL?.scheme == "https", model.licenseSHA256?.count == 64,
                  model.noticeFiles?.isEmpty == false else {
                throw HearthError.message("Invalid model catalog entry: \(model.id)")
            }
            // The encoder comes from the same pinned repository revision as the weights.
            if let vision = model.vision {
                let revision = model.url.deletingLastPathComponent()
                guard vision.filename == URL(fileURLWithPath: vision.filename).lastPathComponent,
                      vision.url.scheme == "https", vision.url.host == "huggingface.co",
                      vision.url.deletingLastPathComponent() == revision,
                      vision.sha256.count == 64, vision.sha256.allSatisfy({ $0.isHexDigit }), vision.bytes > 0 else {
                    throw HearthError.message("Invalid image support entry: \(model.id)")
                }
            }
            // License text is part of the release, checked just like the model manifest.
            if let knowledge = model.knowledge {
                guard knowledge.sourceURL.scheme == "https", !knowledge.checkedAt.isEmpty,
                      knowledge.cutoff.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else {
                    throw HearthError.message("Invalid knowledge-cutoff metadata for \(model.name).")
                }
            }
            for notice in model.noticeFiles ?? [] {
                guard notice.filename == URL(fileURLWithPath: notice.filename).lastPathComponent,
                      !notice.filename.contains(".."), notice.sourceURL.scheme == "https" else {
                    throw HearthError.message("Invalid license notice for \(model.name).")
                }
                let contents = try Data(contentsOf: model.noticeDirectory.appendingPathComponent(notice.filename))
                let hash = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
                guard hash == notice.sha256 else { throw HearthError.message("The bundled license for \(model.name) failed verification.") }
            }
        }
        return models
    }
}

/// Publisher-reported knowledge coverage, not release, download, or training-run dates.
/// A missing cutoff means the reviewed source does not establish a date.
public struct ModelKnowledge: Codable, Hashable, Sendable {
    public let cutoff: String?
    public let sourceURL: URL
    public let checkedAt: String
    public let note: String
}

public struct ModelNotice: Codable, Hashable, Sendable {
    public let filename: String
    public let sha256: String
    public let sourceURL: URL
}

/// The publisher's F16 multimodal projector. Optional: chat works without it.
public struct VisionEncoder: Codable, Hashable, Sendable {
    public let filename: String
    public let bytes: Int64
    public let sha256: String
    public let url: URL
    /// Encoder weights plus image-encoding buffers at the engine's image cap.
    public var estimatedMemory: Double { Double(bytes) * 1.1 + 320 * 1024 * 1024 }
}

public struct ModelGroup: Identifiable, Sendable {
    public let id: String
    public let models: [LocalModel]
    public static func aggregate(_ models: [LocalModel]) -> [ModelGroup] {
        var order: [String] = [], buckets: [String: [LocalModel]] = [:]
        for model in models {
            if buckets[model.groupID] == nil { order.append(model.groupID) }
            buckets[model.groupID, default: []].append(model)
        }
        return order.map { ModelGroup(id: $0, models: buckets[$0]!.sorted { $0.bytes < $1.bytes }) }
    }
}

public struct Hardware: Codable, Sendable, Equatable {
    public let chip: String
    public let cores: Int
    public let memory: UInt64
    public let gpu: String
    public let gpuWorkingSet: UInt64
    public let freeDisk: Int64
    public let architecture: String
    public let performanceCores: Int?

    public init(chip: String, cores: Int, memory: UInt64, gpu: String, gpuWorkingSet: UInt64, freeDisk: Int64, architecture: String, performanceCores: Int? = nil) {
        self.chip = chip; self.cores = cores; self.memory = memory; self.gpu = gpu
        self.gpuWorkingSet = gpuWorkingSet; self.freeDisk = freeDisk; self.architecture = architecture
        self.performanceCores = performanceCores.map { max(1, min(cores, $0)) }
    }
    public static func inspect(at directory: URL) -> Hardware {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let device = MTLCreateSystemDefaultDevice()
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
        #if arch(arm64)
        let architecture = "Apple Silicon"
        #else
        let architecture = "Intel"
        #endif
        var physical: Int32 = 0, coreSize = MemoryLayout<Int32>.size
        let coreKey = architecture == "Apple Silicon" ? "hw.perflevel0.physicalcpu" : "hw.physicalcpu"
        _ = sysctlbyname(coreKey, &physical, &coreSize, nil, 0)
        return Hardware(chip: bytes[0] == 0 ? "Mac" : String(cString: bytes),
                        cores: ProcessInfo.processInfo.activeProcessorCount,
                        memory: ProcessInfo.processInfo.physicalMemory,
                        gpu: device?.name ?? "CPU only",
                        gpuWorkingSet: device?.recommendedMaxWorkingSetSize ?? 0,
                        freeDisk: (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0,
                        architecture: architecture, performanceCores: physical > 0 ? Int(physical) : nil)
    }
    /// No serial number or personal identifiers. OS changes invalidate driver-dependent tuning.
    public var optimizationID: String {
        let identity = "\(chip)|\(cores)|\(performanceCores ?? 0)|\(memory)|\(gpu)|\(gpuWorkingSet)|\(architecture)|\(ProcessInfo.processInfo.operatingSystemVersionString)|lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Apple's rated unified-memory bandwidth in GB/s. Every generated token reads the model's
    /// active weights once, so this, not memory size, bounds generation speed. Unlisted chips get
    /// a conservative value for their tier; Intel Macs run on CPU memory.
    public var memoryBandwidth: (gigabytesPerSecond: Double, published: Bool) {
        guard architecture == "Apple Silicon" else { return (35, false) }
        let words = chip.replacingOccurrences(of: "Apple ", with: "").split(separator: " ").map(String.init)
        let generation = words.first ?? ""
        let tier = words.contains("Ultra") ? "Ultra" : words.contains("Max") ? "Max" : words.contains("Pro") ? "Pro" : ""
        switch (generation, tier) {
        case ("M1", ""): return (68, true)
        case ("M2", ""), ("M3", ""): return (100, true)
        case ("M4", ""): return (120, true)
        case ("M5", ""): return (153, true)
        case ("M3", "Pro"): return (150, true)
        case ("M1", "Pro"), ("M2", "Pro"): return (200, true)
        case ("M4", "Pro"): return (273, true)
        // The 14-core CPU configurations ship with a narrower memory interface.
        case ("M3", "Max"): return (cores <= 14 ? 300 : 400, true)
        case ("M4", "Max"): return (cores <= 14 ? 410 : 546, true)
        case ("M1", "Max"), ("M2", "Max"): return (400, true)
        case ("M1", "Ultra"), ("M2", "Ultra"): return (800, true)
        case ("M3", "Ultra"): return (819, true)
        default: return (["Pro": 200, "Max": 400, "Ultra": 800][tier] ?? 100, false)
        }
    }
    public var modelBudget: Double {
        let ramBudget = max(0, Double(memory) - max(3 * gib, Double(memory) * 0.25))
        // Unified memory is shared, not added to RAM. Intel's discrete VRAM does not enlarge this budget.
        return architecture == "Apple Silicon" && gpuWorkingSet > 0 ? min(ramBudget, Double(gpuWorkingSet)) : ramBudget
    }
    public func fit(_ model: LocalModel) -> Fit {
        if model.estimatedMemory > modelBudget { return .tight }
        return model.estimatedMemory > modelBudget * 0.75 ? .heavy : .comfortable
    }
    public func hasStorage(for model: LocalModel, partialBytes: Int64 = 0) -> Bool {
        hasStorage(bytes: model.bytes, partialBytes: partialBytes)
    }
    public func hasStorage(bytes: Int64, partialBytes: Int64 = 0) -> Bool {
        freeDisk >= max(0, bytes - partialBytes) + 128 * 1024 * 1024
    }
    public func recommended(in models: [LocalModel]) -> LocalModel? {
        let fullCatalog = (try? LocalModel.catalog()) ?? models
        return RecommendationPlanner.evaluate(catalog: models, evidence: try? RecommendationEvidence.load(catalog: fullCatalog), hardware: self).recommended?.model
    }
    public enum Fit: String, Sendable {
        case comfortable = "Good fit", heavy = "Uses more memory", tight = "May struggle"
    }
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var role: String
    public var content: String
    public var modelID: String?
    public var date: Date
    public var interrupted: Bool
    public var reasoning: String?
    public var reachedLimit: Bool?
    public var failure: String?
    /// Earlier attempts are kept for the user, but never included in model context.
    public var previousReplies: [ChatMessage]?
    /// Images and documents the user attached; their files live in the attachment library.
    public var attachments: [ChatAttachment]?
    public init(role: String, content: String, modelID: String? = nil, interrupted: Bool = false, attachments: [ChatAttachment]? = nil) {
        self.id = UUID(); self.role = role; self.content = content; self.modelID = modelID
        self.date = Date(); self.interrupted = interrupted
        self.attachments = attachments?.isEmpty == false ? attachments : nil
    }
    public var hasImages: Bool { attachments?.contains { $0.kind == .image } == true }
}

public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String = "New conversation"
    public var modelID: String?
    public var messages: [ChatMessage] = []
    public var updatedAt: Date = Date()
    public init(modelID: String? = nil) { self.modelID = modelID }
}

public struct Benchmark: Codable, Sendable, Equatable {
    public let modelID: String
    public let date: Date
    public let firstTokenSeconds: Double
    public let tokensPerSecond: Double
    public let generatedTokens: Int
    public let contextTokens: Int
    public let chip: String
    public let engineVersion: String
    public let modelSHA256: String
    public let processMemoryBytes: UInt64?
    public let sampleCount: Int
    public var profileID: String?
    public var checks: [LocalAnswerCheck]?
    public var loadSeconds: Double?
    public var contextCheck: ContextCheck?
    public var hardwareID: String?
    public var firstAnswerLabel: String { firstTokenSeconds < 0.1 ? "<0.1 seconds" : String(format: "%.1f seconds", firstTokenSeconds) }
    public init(modelID: String, firstTokenSeconds: Double, tokensPerSecond: Double, generatedTokens: Int,
                contextTokens: Int, chip: String, modelSHA256: String, processMemoryBytes: UInt64?, sampleCount: Int) {
        self.modelID = modelID; self.date = Date(); self.firstTokenSeconds = firstTokenSeconds
        self.tokensPerSecond = tokensPerSecond; self.generatedTokens = generatedTokens
        self.contextTokens = contextTokens; self.chip = chip; self.engineVersion = "b11146"
        self.modelSHA256 = modelSHA256; self.processMemoryBytes = processMemoryBytes; self.sampleCount = sampleCount
    }
}

public struct AppData: Codable, Sendable {
    public var conversations: [Conversation] = []
    public var benchmarks: [String: Benchmark] = [:]
    public var selectedModelID: String?
    public var offlineOnly: Bool = false
    public var acceptedLicenses: [String: String]?
    public var recommendationGoal: RecommendationGoal?
    public var conversationMemory: ConversationMemory?
    public var compactCache: Bool?
    public var runtimeProfiles: [String: RuntimeProfile]?
    public var runtimeFailures: [String: String]?
    public var optimizations: [String: OptimizationRecord]?
    public var drafts: [String: String]?
    /// Attachments waiting in an unsent message, keyed like `drafts`.
    public var draftAttachments: [String: [ChatAttachment]]?
    /// "new" records an unfinished new conversation; nil migrates older saved state.
    public var currentConversationKey: String?
    public var replyObservations: [String: ReplyObservation]?
    public init() {}
}

/// Passive timing from a real conversation, separate from comparable synthetic benchmarks.
public struct ReplyObservation: Codable, Sendable {
    public let date: Date
    public let modelSHA256: String
    public let hardwareID: String
    public let profileID: String
    public let firstAnswerSeconds: Double
    public let tokensPerSecond: Double
    public let processMemoryBytes: UInt64?
    public init(modelSHA256: String, hardwareID: String, profileID: String, firstAnswerSeconds: Double,
                tokensPerSecond: Double, processMemoryBytes: UInt64?) {
        self.date = Date(); self.modelSHA256 = modelSHA256; self.hardwareID = hardwareID; self.profileID = profileID
        self.firstAnswerSeconds = firstAnswerSeconds; self.tokensPerSecond = tokensPerSecond
        self.processMemoryBytes = processMemoryBytes
    }
}
