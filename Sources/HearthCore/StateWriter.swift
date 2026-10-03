import Foundation

/// Serial snapshots keep filesystem work off the UI thread and preserve write order.
public final class StateWriter: @unchecked Sendable {
    private let storage: LocalStorage
    private let queue = DispatchQueue(label: "local.hearth.state-writer", qos: .utility)

    public init(storage: LocalStorage) { self.storage = storage }

    public func save(_ state: AppData, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [storage] in
            do { try storage.save(state); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }

    /// Used only at app termination, after any earlier queued snapshots.
    public func flush(_ state: AppData) throws { try queue.sync { try storage.save(state) } }
}
