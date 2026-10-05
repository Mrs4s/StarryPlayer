import Foundation

/// A file read while it may still be arriving: a `ProgressiveDownload`, or a file on disk.
/// Reads block, so they are made off the main thread (the transcoder's own thread).
protocol ByteSource: AnyObject, Sendable {
    /// The file's length, waiting for it if needed; nil once the source failed or `isCancelled`.
    func length(isCancelled: () -> Bool) -> Int64?
    /// `count` bytes from `offset` (fewer at the end of the file), waiting until they are here;
    /// nil once the source failed or `isCancelled` turned true first.
    func read(_ offset: Int64, _ count: Int, isCancelled: () -> Bool) -> [UInt8]?
    func prefetch(_ range: Range<Int64>)
}

extension ByteSource {
    func prefetch(_ range: Range<Int64>) {}
}

final class LocalFileSource: ByteSource, @unchecked Sendable {
    private let handle: FileHandle?
    private let size: Int64
    private let lock = NSLock()

    init(url: URL) {
        handle = try? FileHandle(forReadingFrom: url)
        size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    deinit { try? handle?.close() }

    func length(isCancelled: () -> Bool) -> Int64? { handle == nil ? nil : size }

    func read(_ offset: Int64, _ count: Int, isCancelled: () -> Bool) -> [UInt8]? {
        guard let handle, offset >= 0 else { return nil }
        let end = min(offset + Int64(count), size)
        guard offset < end else { return [] }
        return lock.withLock {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.read(upToCount: Int(end - offset)) else { return nil }
            return [UInt8](data)
        }
    }
}
