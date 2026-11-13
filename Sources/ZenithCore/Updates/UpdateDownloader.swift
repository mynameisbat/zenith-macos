import Foundation

/// Downloads one file. The real one is `URLSessionUpdateDownloader`; tests write fixture files.
public protocol UpdateDownloading: Sendable {
    /// Saves `url` at `destination`. Throws `UpdateInstallError.tooLarge` as soon as more than `maximumBytes` arrive.
    func download(
        _ url: URL,
        to destination: URL,
        maximumBytes: Int64,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws
}

/// An ephemeral `URLSession` download task (no cookies, no cache) that follows GitHub's redirect to its asset
/// storage only (`UpdateURLPolicy.isAllowedRedirect`) and stops past the size cap.
public struct URLSessionUpdateDownloader: UpdateDownloading {
    public init() {}

    public func download(
        _ url: URL,
        to destination: URL,
        maximumBytes: Int64,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 15 * 60

        let delegate = DownloadDelegate(destination: destination, maximumBytes: maximumBytes, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("Zenith/\(AppVersion.running.description)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(task: task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumBytes: Int64
    private let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var saved = false

    init(destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.progress = progress
    }

    func start(task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    private func recordFailure(_ error: Error) {
        lock.withLock { if failure == nil { failure = error } }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let url = request.url, UpdateURLPolicy.isAllowedRedirect(url) {
            completionHandler(request)
        } else {
            recordFailure(UpdateInstallError.download("redirected to a host that is not GitHub's"))
            task.cancel()
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            recordFailure(UpdateInstallError.tooLarge)
            downloadTask.cancel()
            return
        }
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this returns, so it is moved here.
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            recordFailure(UpdateInstallError.download("HTTP \(code)"))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { saved = true }
        } catch {
            recordFailure(UpdateInstallError.download(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure, saved) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?, Bool) in
            let pending = self.continuation
            self.continuation = nil
            return (pending, self.failure, self.saved)
        }
        guard let continuation else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else if let error {
            continuation.resume(throwing: UpdateInstallError.download(error.localizedDescription))
        } else if !saved {
            continuation.resume(throwing: UpdateInstallError.download("no file was received"))
        } else {
            continuation.resume()
        }
    }
}
