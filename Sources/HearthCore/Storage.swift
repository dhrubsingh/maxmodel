import Foundation
import CryptoKit

public struct LocalStorage: Sendable {
    public let root: URL
    public var modelsDirectory: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var stateURL: URL { root.appendingPathComponent("conversations.json") }
    public var attachments: AttachmentLibrary { AttachmentLibrary(directory: root.appendingPathComponent("Attachments", isDirectory: true)) }

    public init(root: URL? = nil) throws {
        let environment = ProcessInfo.processInfo.environment
        let supplied = root ?? (environment["MAXMODEL_DATA_DIR"] ?? environment["HEARTH_DATA_DIR"]).map { URL(fileURLWithPath: $0) }
        if let supplied { self.root = supplied } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("MaxModel", isDirectory: true)
            // The app was called Hearth. Move its models and chats over once, in place (no copy).
            let legacy = support.appendingPathComponent("Hearth", isDirectory: true)
            if !FileManager.default.fileExists(atPath: self.root.path), FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.moveItem(at: legacy, to: self.root)
            }
        }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: attachments.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
        var directory = self.root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }
    public func modelURL(_ model: LocalModel) -> URL { modelsDirectory.appendingPathComponent(model.id + ".gguf") }
    public func partialURL(_ model: LocalModel) -> URL { modelsDirectory.appendingPathComponent(model.id + ".part") }
    public func receiptURL(_ model: LocalModel) -> URL { modelsDirectory.appendingPathComponent(model.id + ".verified") }
    public func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
    public func installed(_ model: LocalModel) -> Bool {
        fileSize(modelURL(model)) == model.bytes && (try? String(contentsOf: receiptURL(model), encoding: .utf8)) == model.sha256
    }
    public func installedIDs(_ catalog: [LocalModel]) -> Set<String> { Set(catalog.filter(installed).map(\.id)) }

    // The image encoder is optional and installed beside its model's weights.
    public func visionURL(_ model: LocalModel) -> URL { modelsDirectory.appendingPathComponent(model.id + ".mmproj.gguf") }
    public func visionPartialURL(_ model: LocalModel) -> URL { modelsDirectory.appendingPathComponent(model.id + ".mmproj.part") }
    public func visionReceiptURL(_ model: LocalModel) -> URL { modelsDirectory.appendingPathComponent(model.id + ".mmproj.verified") }
    public func visionInstalled(_ model: LocalModel) -> Bool {
        guard let vision = model.vision else { return false }
        return fileSize(visionURL(model)) == vision.bytes && (try? String(contentsOf: visionReceiptURL(model), encoding: .utf8)) == vision.sha256
    }
    public func visionInstalledIDs(_ catalog: [LocalModel]) -> Set<String> { Set(catalog.filter(visionInstalled).map(\.id)) }
    public func verifyVision(_ model: LocalModel, at url: URL? = nil) async throws {
        guard let vision = model.vision else { throw HearthError.message("\(model.name) can't see images.") }
        try await verify(sha256: vision.sha256, bytes: vision.bytes, at: url ?? visionURL(model),
                         failure: "Image support did not pass its integrity check. Remove it and download it again.")
    }
    public func finishVisionInstall(_ model: LocalModel) async throws {
        guard let vision = model.vision else { return }
        try await verifyVision(model, at: visionPartialURL(model))
        if FileManager.default.fileExists(atPath: visionURL(model).path) { try FileManager.default.removeItem(at: visionURL(model)) }
        try FileManager.default.moveItem(at: visionPartialURL(model), to: visionURL(model))
        try Data(vision.sha256.utf8).write(to: visionReceiptURL(model), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: visionURL(model).path)
    }

    public func readState() throws -> AppData {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return AppData() }
        do { return try JSONDecoder().decode(AppData.self, from: Data(contentsOf: stateURL)) }
        catch {
            // Preserve damaged state for recovery; never silently overwrite a user's conversations.
            let backup = root.appendingPathComponent("conversations-recovery-\(Int(Date().timeIntervalSince1970)).json")
            try FileManager.default.moveItem(at: stateURL, to: backup)
            throw HearthError.message("Conversation storage could not be read. The original was preserved at \(backup.path). New conversations will use a fresh file.")
        }
    }
    public func save(_ state: AppData) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    public func remove(_ model: LocalModel) throws {
        for path in [modelURL(model), partialURL(model), receiptURL(model), modelsDirectory.appendingPathComponent(model.id + ".notices"),
                     visionURL(model), visionPartialURL(model), visionReceiptURL(model)] where FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
    public func verify(_ model: LocalModel, at url: URL) async throws {
        try await verify(sha256: model.sha256, bytes: model.bytes, at: url,
                         failure: "The model did not pass its integrity check. Delete the partial download and try again.")
    }
    func verify(sha256 expected: String, bytes expectedBytes: Int64, at url: URL, failure: String) async throws {
        try Task.checkCancellation()
        let verification = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var count: Int64 = 0
            while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                count += Int64(data.count); hasher.update(data: data)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard count == expectedBytes && digest == expected else { throw HearthError.message(failure) }
        }
        try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: { verification.cancel() }
    }
    public func finishInstall(_ model: LocalModel) async throws {
        let partial = partialURL(model)
        try await verify(model, at: partial)
        if FileManager.default.fileExists(atPath: modelURL(model).path) { try FileManager.default.removeItem(at: modelURL(model)) }
        try FileManager.default.moveItem(at: partial, to: modelURL(model))
        try Data(model.sha256.utf8).write(to: receiptURL(model), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: modelURL(model).path)
        try preserveNotices(model)
    }
    public func preserveNotices(_ model: LocalModel) throws {
        let destination = modelsDirectory.appendingPathComponent(model.id + ".notices", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for notice in model.noticeFiles ?? [] {
            let source = model.noticeDirectory.appendingPathComponent(notice.filename).resolvingSymlinksInPath()
            // Synced folders (iCloud Drive) can briefly hide a file while restoring it; try once more.
            let data: Data
            do { data = try Data(contentsOf: source) } catch {
                Thread.sleep(forTimeInterval: 0.3)
                data = try Data(contentsOf: source)
            }
            let path = destination.appendingPathComponent(notice.filename)
            try Self.writeNoticeIfChanged(data, to: path)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.writeNoticeIfChanged(encoder.encode(model), to: destination.appendingPathComponent("PROVENANCE.json"))
    }
    private static func writeNoticeIfChanged(_ data: Data, to path: URL) throws {
        if (try? Data(contentsOf: path)) != data { try data.write(to: path, options: .atomic) }
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        if permissions?.intValue != 0o600 {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
}
