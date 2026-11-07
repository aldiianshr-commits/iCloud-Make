import Foundation

/// iOS background URLSession for large downloads: the system keeps transferring while the app is
/// suspended and relaunches the app in the background when the transfer finishes.
/// Limits (documented by Apple): the system decides when transfers run; tasks are paused when the
/// user force-quits the app.
final class BackgroundTransferService: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundTransferService()

    struct Payload: Codable {
        let recordID: UUID
        let expectedSize: Int64?
    }

    /// Finished files waiting for the app to pick them up (persisted across relaunch).
    static var completedDir: URL { AppPaths.ensure(AppPaths.applicationSupport.appendingPathComponent("BackgroundDownloads", isDirectory: true)) }

    private let queue = OperationQueue()
    private var waiters: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var progress: [UUID: ProgressHandler] = [:]
    private let lock = NSLock()
    var systemCompletionHandler: (() -> Void)?

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: AppConfig.backgroundURLSessionID)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = NetworkPolicy.current
        c.httpCookieStorage = nil
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }()

    static func completedFile(for id: UUID) -> URL { completedDir.appendingPathComponent(id.uuidString) }

    /// Starts (or re-attaches to) a background download; returns the downloaded temp file.
    func download(_ request: URLRequest, recordID: UUID, expectedSize: Int64?, progress: ProgressHandler?) async throws -> URL {
        let done = Self.completedFile(for: recordID)
        if FileManager.default.fileExists(atPath: done.path) { return done } // finished while we were suspended
        let tasks = await session.allTasks
        let existing = tasks.first { ($0.taskDescription.flatMap { try? JSONDecoder().decode(Payload.self, from: Data($0.utf8)) })?.recordID == recordID }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                waiters[recordID] = cont
                if let progress { self.progress[recordID] = progress }
                lock.unlock()
                if existing == nil {
                    let task = session.downloadTask(with: request)
                    task.taskDescription = String(data: (try? JSONEncoder().encode(Payload(recordID: recordID, expectedSize: expectedSize))) ?? Data(), encoding: .utf8)
                    task.resume()
                }
            }
        } onCancel: {
            existing?.cancel()
            Task { for t in await self.session.allTasks where t.taskDescription?.contains(recordID.uuidString) == true { t.cancel() } }
        }
    }

    /// Record IDs with a transfer still owned by the system (used for launch recovery).
    func activeRecordIDs() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { $0.taskDescription.flatMap { try? JSONDecoder().decode(Payload.self, from: Data($0.utf8)) }?.recordID })
    }

    private func payload(_ task: URLSessionTask) -> Payload? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(Payload.self, from: Data($0.utf8)) }
    }

    private func finish(_ id: UUID, _ result: Result<URL, Error>) {
        lock.lock()
        let w = waiters.removeValue(forKey: id)
        progress[id] = nil
        lock.unlock()
        w?.resume(with: result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let p = payload(downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            finish(p.recordID, .failure(status == 401 ? AppError.sessionExpired : AppError.http(status: status, message: "background download")))
            return
        }
        let dest = Self.completedFile(for: p.recordID)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            if let e = p.expectedSize, e > 0, AppPaths.fileSize(dest) != e {
                finish(p.recordID, .failure(AppError.integrityCheckFailed(L("size mismatch"))))
                return
            }
            finish(p.recordID, .success(dest))
        } catch {
            finish(p.recordID, .failure(AppError.io(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let p = payload(downloadTask) else { return }
        lock.lock(); let handler = progress[p.recordID]; lock.unlock()
        handler?(totalBytesWritten, p.expectedSize ?? max(0, totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let p = payload(task) else { return }
        let u = error as? URLError
        finish(p.recordID, .failure(u?.code == .cancelled ? AppError.cancelled : AppError.network(error.localizedDescription)))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.systemCompletionHandler?()
            self.systemCompletionHandler = nil
        }
    }
}
