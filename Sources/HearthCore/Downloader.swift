import Foundation

public struct DownloadProgress: Sendable {
    public let received: Int64
    public let total: Int64
    public let bytesPerSecond: Double
    public var fraction: Double { min(1, Double(received) / Double(max(1, total))) }
    public var secondsRemaining: Double? { bytesPerSecond > 0 ? Double(max(0, total - received)) / bytesPerSecond : nil }
}

/// Streams into a .part file, so pause and app restarts do not discard received bytes.
/// A serial delegate queue owns the handle and response state; only task cancellation crosses queues.
public final class ModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: URL
    private let expectedBytes: Int64
    private let destination: URL
    private let progress: @Sendable (DownloadProgress) -> Void
    private var handle: FileHandle?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var received: Int64 = 0
    private var startingBytes: Int64 = 0
    private var started = Date()
    private var lastUpdate = Date.distantPast
    private var failure: Error?
    private let lock = NSLock()
    private var cancelled = false

    public convenience init(model: LocalModel, destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.init(source: model.url, bytes: model.bytes, destination: destination, progress: progress)
    }
    /// Any pinned catalog file: model weights or an image encoder.
    public init(source: URL, bytes: Int64, destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.source = source; self.expectedBytes = bytes; self.destination = destination; self.progress = progress
    }
    public func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
    public func run() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    let fm = FileManager.default
                    if !fm.fileExists(atPath: destination.path) {
                        fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    }
                    handle = try FileHandle(forWritingTo: destination)
                    received = Int64(try handle!.seekToEnd())
                    guard received <= expectedBytes else { throw HearthError.message("This partial download is invalid. Delete it and try again.") }
                    if received == expectedBytes {
                        try handle?.close(); handle = nil
                        self.continuation = nil; continuation.resume(); return
                    }
                    startingBytes = received; started = Date()
                    var request = URLRequest(url: source)
                    request.setValue("Hearth/0.1", forHTTPHeaderField: "User-Agent")
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.httpCookieStorage = nil; configuration.urlCache = nil
                    configuration.timeoutIntervalForRequest = 60
                    configuration.timeoutIntervalForResource = 24 * 60 * 60
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    let newTask = session!.dataTask(with: request)
                    lock.lock(); task = newTask; let wasCancelled = cancelled; lock.unlock()
                    if wasCancelled { newTask.cancel() }
                    newTask.resume()
                } catch {
                    try? handle?.close(); handle = nil
                    self.continuation = nil; continuation.resume(throwing: error)
                }
            }
        }, onCancel: { self.cancel() })
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Hugging Face redirects large files to its CDN. Never follow redirects to HTTP or unrelated hosts.
        let host = request.url?.host?.lowercased() ?? ""
        let allowed = request.url?.scheme == "https" &&
            (host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co") || host.hasSuffix(".xethub.hf.co"))
        if !allowed { failure = HearthError.message("The model host redirected to an unrecognized download server.") }
        completionHandler(allowed ? request : nil)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            if response.statusCode == 200 {
                // Server ignored Range: restart the file, never append a full response to partial data.
                try handle?.truncate(atOffset: 0); try handle?.seek(toOffset: 0)
                received = 0; startingBytes = 0
            } else if response.statusCode == 206 {
                let expected = "bytes \(received)-"
                guard (response.value(forHTTPHeaderField: "Content-Range") ?? "").hasPrefix(expected) else {
                    throw HearthError.message("The download server returned an invalid resume position.")
                }
            } else { throw HearthError.message("Download failed (HTTP \(response.statusCode)). Your partial download has been kept.") }
            if response.expectedContentLength > 0 && response.expectedContentLength != expectedBytes - received {
                throw HearthError.message("The download size does not match the trusted model catalog.")
            }
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard received + Int64(data.count) <= expectedBytes else { throw HearthError.message("The model exceeds its expected download size.") }
            try handle?.write(contentsOf: data); received += Int64(data.count)
            if Date().timeIntervalSince(lastUpdate) >= 0.15 || received == expectedBytes {
                lastUpdate = Date()
                progress(DownloadProgress(received: received, total: expectedBytes,
                                          bytesPerSecond: Double(received - startingBytes) / max(0.01, Date().timeIntervalSince(started))))
            }
        } catch { failure = error; dataTask.cancel() }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize(); try? handle?.close(); handle = nil
        let completion = continuation; continuation = nil
        if let failure = failure ?? error { completion?.resume(throwing: failure) }
        else if received != expectedBytes { completion?.resume(throwing: HearthError.message("The download was incomplete. Resume to continue.")) }
        else { completion?.resume() }
        session.finishTasksAndInvalidate(); self.session = nil
    }
}
