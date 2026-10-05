import AVFoundation
import Foundation
import StarryCore
import UniformTypeIdentifiers

final class ProgressiveDownload: NSObject, @unchecked Sendable {
    static let scheme = "starry-stream"
    /// A request this close ahead of the running connection waits for it instead of moving it.
    static let lookahead: Int64 = 512 * 1024
    private static let chunk = 512 * 1024
    private static let maxRetries = 3

    let remoteURL: URL
    let fileURL: URL
    /// What the item is created with: AVFoundation hands its requests for it to this object.
    let assetURL: URL
    private let headers: [String: String]
    private let contentType: String
    private let decryptor: (any StreamDecryptor)?

    private let queue = DispatchQueue(label: "starry.progressive-download")
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var taskOffset: Int64 = 0
    private var taskEnd: Int64?
    private var retries = 0
    private var length: Int64?
    private var have = ByteRanges()
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var failure: Error?
    private var isComplete = false
    private var isCancelled = false
    private var isStarted = false
    private var onComplete: (@MainActor @Sendable (URL) -> Void)?
    private var sideFetches: [Int: (offset: Int64, end: Int64)] = [:]
    private let arrival = NSCondition()

    static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "starry-stream", directoryHint: .isDirectory)
    }

    private static let sweepLeftovers: Void = {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff else { continue }
            try? fileManager.removeItem(at: file)
        }
    }()

    init(url: URL, headers: [String: String], fileExtension: String, decryptor: (any StreamDecryptor)? = nil, configuration: URLSessionConfiguration = .default) {
        _ = Self.sweepLeftovers
        remoteURL = url
        self.headers = headers
        self.decryptor = decryptor
        contentType = UTType(filenameExtension: fileExtension)?.identifier ?? UTType.audio.identifier
        let directory = Self.directory
        let name = "\(UUID().uuidString).\(fileExtension)"
        fileURL = directory.appending(path: name)
        assetURL = URL(string: "\(Self.scheme)://download/\(name)")!
        super.init()
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The asset to play: AVFoundation's reads go through this object.
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Runs `handler` on the main actor once every byte is on disk (at once if they are). It
    /// replaces the previous handler: a download handed to another deck reports there.
    func whenComplete(_ handler: @escaping @MainActor @Sendable (URL) -> Void) {
        queue.async { [self] in
            onComplete = handler
            if isComplete {
                let file = fileURL
                Task { @MainActor in handler(file) }
            }
        }
    }

    func start() {
        queue.async { [self] in
            guard !isCancelled, !isStarted else { return }
            isStarted = true
            do {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                writer = try FileHandle(forWritingTo: fileURL)
                reader = try FileHandle(forReadingFrom: fileURL)
            } catch {
                fail(error)
                return
            }
            fetch(from: 0)
        }
    }

    /// Stops the download and removes the file. The local item made from it must be gone.
    func cancel() {
        queue.async { [self] in
            isCancelled = true
            session?.invalidateAndCancel()
            session = nil
            task = nil
            // Finished, not dropped: while a request waits, the asset stays busy (the tap waits
            // for its tracks) and the player never starts its next item.
            for request in pending { request.finishLoading(with: CocoaError(.userCancelled)) }
            pending.removeAll()
            try? writer?.close()
            try? reader?.close()
            writer = nil
            reader = nil
            sideFetches.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
            signalArrival()
        }
    }

    private func signalArrival() {
        arrival.lock()
        arrival.broadcast()
        arrival.unlock()
    }

    private func waitForArrival() {
        arrival.lock()
        arrival.wait(until: Date().addingTimeInterval(0.05))
        arrival.unlock()
    }

    private func isSideFetching(_ offset: Int64) -> Bool {
        sideFetches.values.contains { $0.offset <= offset && offset < $0.end }
    }

    private func fetch(from offset: Int64) {
        guard let session, !isCancelled else { return }
        task?.cancel()
        let nextSide = sideFetches.values.map(\.offset).filter { $0 > offset }.min()
        let end = [have.start(after: offset), nextSide].compactMap { $0 }.min() ?? length
        var request = URLRequest(url: remoteURL)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("bytes=\(offset)-\(end.map { String($0 - 1) } ?? "")", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        self.task = task
        taskOffset = offset
        taskEnd = end
        task.resume()
    }

    /// The first byte `request` still waits for, nil when it has everything it can get now.
    private func missingByte(of request: AVAssetResourceLoadingRequest) -> Int64? {
        guard let data = request.dataRequest else { return nil }
        let offset = data.currentOffset
        let run = have.end(ofRunAt: offset)
        if let end = requestEnd(data), run >= end { return nil }
        if let length, run >= length { return nil }
        return run
    }

    private func requestEnd(_ data: AVAssetResourceLoadingDataRequest) -> Int64? {
        data.requestsAllDataToEndOfResource ? length : data.requestedOffset + Int64(data.requestedLength)
    }

    private func prioritize(_ offset: Int64) {
        if task != nil, offset >= taskOffset, offset - taskOffset <= Self.lookahead, taskEnd.map({ offset < $0 }) ?? true { return }
        fetch(from: offset)
    }

    private func scheduleNext() {
        task = nil
        if let length, have.covers(0..<length) {
            complete()
            return
        }
        for request in pending.reversed() {
            if let byte = missingByte(of: request) {
                fetch(from: byte)
                return
            }
        }
        if let gap = have.firstGap(below: length ?? .max), !isSideFetching(gap.lowerBound) { fetch(from: gap.lowerBound) }
    }

    private func complete() {
        guard !isComplete else { return }
        isComplete = true
        try? writer?.close()
        writer = nil
        serve()
        signalArrival()
        let file = fileURL
        let onComplete = onComplete
        Task { @MainActor in onComplete?(file) }
    }

    private func fail(_ error: Error) {
        failure = error
        task = nil
        for request in pending { request.finishLoading(with: error) }
        pending.removeAll()
        signalArrival()
    }

    /// Answers every waiting request as far as the bytes on disk go, a few megabytes per turn of
    /// the queue so a cancel or a new request gets in between.
    private func serve() {
        guard let length else { return }
        var budget = Self.chunk * 16
        var more = false
        pending.removeAll { request in
            if let info = request.contentInformationRequest, info.contentLength == 0 {
                info.contentType = contentType
                info.contentLength = length
                info.isByteRangeAccessSupported = true
                // Any range can be had (from disk, or by moving the connection): AVFoundation then
                // asks for 64 KB at a time instead of keeping the whole file it was handed in
                // memory.
                info.isEntireLengthAvailableOnDemand = true
            }
            guard let data = request.dataRequest else {
                request.finishLoading()
                return true
            }
            let end = min(requestEnd(data) ?? length, length)
            while data.currentOffset < end {
                let offset = data.currentOffset
                let available = min(have.end(ofRunAt: offset), end)
                guard available > offset else { break }
                guard budget > 0 else {
                    more = true
                    break
                }
                let count = Int(min(available - offset, Int64(Self.chunk)))
                guard let reader, (try? reader.seek(toOffset: UInt64(offset))) != nil,
                      let bytes = try? reader.read(upToCount: count), !bytes.isEmpty else { break }
                data.respond(with: bytes)
                budget -= bytes.count
            }
            guard data.currentOffset >= end else { return false }
            request.finishLoading()
            return true
        }
        if more { queue.async { [self] in serve() } }
    }
}

extension ProgressiveDownload: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url == assetURL, !isCancelled else { return false }
        if let failure {
            loadingRequest.finishLoading(with: failure)
            return true
        }
        pending.append(loadingRequest)
        serve()
        if pending.contains(loadingRequest), let byte = missingByte(of: loadingRequest), !isComplete {
            prioritize(byte)
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
    }
}

extension ProgressiveDownload: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let side = sideFetches[dataTask.taskIdentifier] {
            guard let http = response as? HTTPURLResponse, http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let slash = range.lastIndex(of: "/"), range[..<slash].split(separator: " ").last?.split(separator: "-").first.flatMap({ Int64($0) }) == side.offset else {
                sideFetches[dataTask.taskIdentifier] = nil
                completionHandler(.cancel)
                if task == nil { scheduleNext() }
                return
            }
            if length == nil, let total = Int64(range[range.index(after: slash)...]) { length = total }
            completionHandler(.allow)
            return
        }
        guard dataTask === task, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            if let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") {
                if let total = Int64(range[range.index(after: slash)...]) { length = total }
                let bounds = range[..<slash].split(separator: " ").last?.split(separator: "-")
                if let start = bounds?.first.flatMap({ Int64($0) }) { taskOffset = start }
            }
        case 200:
            // The server ignored the range: the body is the whole file.
            taskOffset = 0
            taskEnd = nil
            if http.expectedContentLength > 0 { length = http.expectedContentLength }
        default:
            completionHandler(.cancel)
            fail(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
            return
        }
        retries = 0
        serve()
        signalArrival()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let side = sideFetches[dataTask.taskIdentifier] {
            guard let writer else { return }
            var data = data
            if let decryptor { data.withUnsafeMutableBytes { decryptor.decrypt($0, at: side.offset) } }
            do {
                try writer.seek(toOffset: UInt64(side.offset))
                try writer.write(contentsOf: data)
            } catch {
                dataTask.cancel()
                sideFetches[dataTask.taskIdentifier] = nil
                return
            }
            have.insert(side.offset..<(side.offset + Int64(data.count)))
            sideFetches[dataTask.taskIdentifier] = (side.offset + Int64(data.count), side.end)
            serve()
            signalArrival()
            return
        }
        guard dataTask === task, let writer else { return }
        var data = data
        if let decryptor {
            let offset = taskOffset
            data.withUnsafeMutableBytes { decryptor.decrypt($0, at: offset) }
        }
        do {
            try writer.seek(toOffset: UInt64(taskOffset))
            try writer.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            fail(error)
            return
        }
        let end = taskOffset + Int64(data.count)
        have.insert(taskOffset..<end)
        taskOffset = end
        serve()
        signalArrival()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if sideFetches.removeValue(forKey: task.taskIdentifier) != nil {
            // Whatever it did not bring, the main connection fetches when it gets there.
            guard !isCancelled, failure == nil else { return }
            if let length, have.covers(0..<length) { complete() } else if self.task == nil { scheduleNext() }
            signalArrival()
            return
        }
        guard task === self.task, !isCancelled else { return }
        if let error {
            guard retries < Self.maxRetries, (error as? URLError).map({ [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains($0.code) }) == true else {
                fail(error)
                return
            }
            retries += 1
            self.task = nil
            let offset = taskOffset
            queue.asyncAfter(deadline: .now() + .seconds(retries)) { [self] in
                guard !isCancelled, self.task == nil, failure == nil else { return }
                fetch(from: offset)
            }
            return
        }
        if length == nil { length = taskOffset }
        scheduleNext()
    }
}

extension ProgressiveDownload: ByteSource {
    func length(isCancelled stop: () -> Bool) -> Int64? {
        while true {
            let (known, over) = queue.sync { (length, isCancelled || failure != nil) }
            if let known { return known }
            if over || stop() { return nil }
            waitForArrival()
        }
    }

    /// Waits for the bytes like an AVFoundation request does: the connection moves to them when
    /// they are beyond its lookahead.
    func read(_ offset: Int64, _ count: Int, isCancelled stop: () -> Bool) -> [UInt8]? {
        enum Outcome { case bytes([UInt8]), wait, failed }
        while true {
            let outcome: Outcome = queue.sync {
                guard !isCancelled, failure == nil else { return .failed }
                guard let length, isStarted else { return .wait }
                let end = min(offset + Int64(count), length)
                guard offset < end else { return .bytes([]) }
                if have.covers(offset..<end) {
                    guard let reader, (try? reader.seek(toOffset: UInt64(offset))) != nil,
                          let data = try? reader.read(upToCount: Int(end - offset)), data.count == Int(end - offset) else { return .failed }
                    return .bytes([UInt8](data))
                }
                let missing = have.end(ofRunAt: offset)
                if !isComplete, !isSideFetching(missing) { prioritize(missing) }
                return .wait
            }
            switch outcome {
            case .bytes(let bytes): return bytes
            case .failed: return nil
            case .wait:
                if stop() { return nil }
                waitForArrival()
            }
        }
    }

    /// One extra ranged request beside the running one (the file's last page, read before
    /// playback can start), so the main connection keeps going from the start.
    func prefetch(_ range: Range<Int64>) {
        queue.async { [self] in
            guard let session, !isCancelled, !isComplete, failure == nil, let length else { return }
            let lower = max(0, range.lowerBound), upper = min(range.upperBound, length)
            guard lower < upper, !have.covers(lower..<upper) else { return }
            // The main connection is about to get there (its lookahead can take seconds on a
            // slow network: a much shorter reach here).
            if task != nil, lower >= taskOffset, lower - taskOffset <= 64 * 1024 { return }
            if sideFetches.values.contains(where: { $0.offset < upper && lower < $0.end }) { return }
            var request = URLRequest(url: remoteURL)
            for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
            request.setValue("bytes=\(lower)-\(upper - 1)", forHTTPHeaderField: "Range")
            let side = session.dataTask(with: request)
            sideFetches[side.taskIdentifier] = (lower, upper)
            side.resume()
        }
    }
}

struct ByteRanges: Equatable, Sendable {
    private(set) var ranges: [Range<Int64>] = []

    mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var merged = range
        var kept: [Range<Int64>] = []
        kept.reserveCapacity(ranges.count + 1)
        for existing in ranges {
            if existing.upperBound < merged.lowerBound || existing.lowerBound > merged.upperBound {
                kept.append(existing)
            } else {
                merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
            }
        }
        let index = kept.firstIndex { $0.lowerBound > merged.lowerBound } ?? kept.endIndex
        kept.insert(merged, at: index)
        ranges = kept
    }

    func end(ofRunAt offset: Int64) -> Int64 {
        ranges.first { $0.contains(offset) }?.upperBound ?? offset
    }

    func start(after offset: Int64) -> Int64? {
        ranges.first { $0.lowerBound > offset }?.lowerBound
    }

    func covers(_ range: Range<Int64>) -> Bool {
        range.isEmpty || ranges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    func firstGap(below limit: Int64) -> Range<Int64>? {
        var position: Int64 = 0
        for range in ranges {
            if range.lowerBound > position { return position..<min(range.lowerBound, limit) }
            position = max(position, range.upperBound)
            if position >= limit { return nil }
        }
        return position < limit ? position..<limit : nil
    }
}
