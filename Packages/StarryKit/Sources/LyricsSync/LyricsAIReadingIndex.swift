import Foundation

struct LyricsAIReadingIndex: Sendable {
    struct Entry: Equatable, Sendable {
        var reading: String
        var partOfSpeech: Int
        var cost: Int
    }

    private let data: Data
    let wordCount: Int
    let entryCount: Int
    private let poolOffset: Int

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard data.count >= 32, data.count <= 16 * 1_048_576 else { return nil }
        let header = data.withUnsafeBytes { bytes -> (Int, Int, Int, Int)? in
            guard bytes.prefix(8).elementsEqual([83, 84, 74, 82, 69, 65, 68, 0]), Self.u32(bytes, 8) == 1 else { return nil }
            let version = Self.u32(bytes, 12), words = Self.u32(bytes, 16), entries = Self.u32(bytes, 20)
            let pool = Self.u32(bytes, 24), length = Self.u32(bytes, 28)
            guard words <= 100_000, entries <= 1_000_000, entries >= words * 2,
                  version >= 20000101, version <= 20991231,
                  pool == 32 + words * 12 + entries * 9, pool <= length, length == bytes.count else { return nil }
            return (version, words, entries, pool)
        }
        guard let (_, words, entries, pool) = header else { return nil }
        self.data = data
        wordCount = words
        entryCount = entries
        poolOffset = pool
    }

    func entries(for surface: String) -> [Entry] {
        let key = Array(surface.utf8)
        return data.withUnsafeBytes { bytes in
            var lower = 0, upper = wordCount
            while lower < upper {
                let middle = (lower + upper) / 2, record = 32 + middle * 12
                let offset = Self.u32(bytes, record), length = Self.u16(bytes, record + 8)
                guard length > 0, length <= 128, offset <= bytes.count - poolOffset,
                      length <= bytes.count - poolOffset - offset else { return [] }
                let start = poolOffset + offset
                var comparison = 0
                for i in 0..<min(length, key.count) where bytes[start + i] != key[i] {
                    comparison = bytes[start + i] < key[i] ? -1 : 1
                    break
                }
                if comparison == 0, length != key.count { comparison = length < key.count ? -1 : 1 }
                if comparison < 0 { lower = middle + 1 }
                else if comparison > 0 { upper = middle }
                else {
                    let first = Self.u32(bytes, record + 4), count = Self.u16(bytes, record + 10)
                    guard count >= 2, count <= 64, first <= entryCount, count <= entryCount - first else { return [] }
                    var result: [Entry] = []
                    result.reserveCapacity(count)
                    for index in first..<(first + count) {
                        let record = 32 + wordCount * 12 + index * 9
                        let offset = Self.u32(bytes, record), parts = Self.u16(bytes, record + 4)
                        let cost = Int(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: record + 6, as: Int16.self)))
                        let length = Int(bytes[record + 8])
                        guard length > 0, length <= 64, parts > 0, parts <= 1023,
                              offset <= bytes.count - poolOffset, length <= bytes.count - poolOffset - offset else { return [] }
                        var scalars = String.UnicodeScalarView()
                        for position in (poolOffset + offset)..<(poolOffset + offset + length) {
                            let value = bytes[position]
                            guard value <= 85 || value == 255 else { return [] }
                            scalars.append(UnicodeScalar(value == 255 ? 0x30FC : 0x3041 + UInt32(value))!)
                        }
                        result.append(.init(reading: String(scalars), partOfSpeech: parts, cost: cost))
                    }
                    return result
                }
            }
            return []
        }
    }

    private static func u32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> Int {
        Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
    }

    private static func u16(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> Int {
        Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
    }
}
