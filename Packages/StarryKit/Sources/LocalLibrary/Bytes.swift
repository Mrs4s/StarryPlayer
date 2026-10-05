import Foundation

/// Reads a file a piece at a time: tag readers look at a few kilobytes at the start or end and
/// skip what they do not need (pictures), so a scan does not read whole files.
final class FileReader {
    let handle: FileHandle
    let size: Int64

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
        size = Int64((try? handle.seekToEnd()) ?? 0)
    }

    deinit { try? handle.close() }

    /// `count` bytes from `offset`; fewer at the end of the file, nil when none.
    func read(at offset: Int64, count: Int) -> Data? {
        guard offset >= 0, offset < size, count > 0 else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }
}

extension Data {
    /// Big-endian unsigned integer of `count` bytes at `offset` (relative to `startIndex`).
    func bigEndian(at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count { value = value << 8 | UInt64(self[startIndex + offset + index]) }
        return value
    }

    /// Little-endian unsigned integer of `count` bytes at `offset`.
    func littleEndian(at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<count).reversed() { value = value << 8 | UInt64(self[startIndex + offset + index]) }
        return value
    }

    func byte(_ offset: Int) -> UInt8 { self[startIndex + offset] }

    func bytes(from offset: Int, count: Int? = nil) -> Data {
        let start = Swift.min(startIndex + offset, endIndex)
        let end = count.map { Swift.min(start + $0, endIndex) } ?? endIndex
        return self[start..<end]
    }

    func hasASCII(_ ascii: String, at offset: Int = 0) -> Bool {
        let pattern = Array(ascii.utf8)
        guard count >= offset + pattern.count else { return false }
        return pattern.enumerated().allSatisfy { self[startIndex + offset + $0.offset] == $0.element }
    }
}
