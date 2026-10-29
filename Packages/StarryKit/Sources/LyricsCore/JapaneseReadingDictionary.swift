import Foundation

public struct JapaneseReadingDictionary: Sendable {
    public struct Entry: Equatable, Sendable {
        public let reading: String
        public let partOfSpeech: Int
        public let cost: Int
    }

    public static let shared: Self? = {
        guard let url = Bundle.module.url(forResource: "readings", withExtension: "bin", subdirectory: "JapaneseReadings") else { return nil }
        return Self(contentsOf: url)
    }()

    private let data: Data
    private let poolOffset: Int
    public let keyCount: Int
    public let entryCount: Int
    public let wordVersion: Int
    public let characterVersion: Int

    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard data.count >= 40, data.count <= 16 * 1_048_576 else { return nil }
        let header = data.withUnsafeBytes { bytes -> (Int, Int, Int, Int, Int)? in
            guard bytes.prefix(8).elementsEqual([83, 84, 74, 82, 69, 65, 68, 0]), Self.u32(bytes, 8) == 2,
                  Self.u32(bytes, 36) == 0 else { return nil }
            let wordVersion = Self.u32(bytes, 12), characterVersion = Self.u32(bytes, 16)
            let keys = Self.u32(bytes, 20), entries = Self.u32(bytes, 24)
            let pool = Self.u32(bytes, 28), length = Self.u32(bytes, 32)
            guard keys > 0, keys <= 100_000, entries >= keys, entries <= 1_000_000,
                  (20000101...20991231).contains(wordVersion), (20000101...20991231).contains(characterVersion),
                  pool == 40 + keys * 12 + entries * 9, pool <= length, length == bytes.count else { return nil }
            return (wordVersion, characterVersion, keys, entries, pool)
        }
        guard let (words, characters, keys, entries, pool) = header else { return nil }
        self.data = data
        wordVersion = words; characterVersion = characters
        keyCount = keys; entryCount = entries; poolOffset = pool
    }

    public func wordReadings(for surface: String) -> [Entry] {
        entries(for: surface, purpose: 1)
    }

    public func characterReadings(for character: String) -> [String] {
        entries(for: character, purpose: 2).map(\.reading).sorted()
    }

    private func entries(for surface: String, purpose: UInt8) -> [Entry] {
        let key = Array(surface.utf8)
        guard !key.isEmpty, key.count <= 128 else { return [] }
        return data.withUnsafeBytes { bytes in
            var lower = 0, upper = keyCount
            while lower < upper {
                let middle = (lower + upper) / 2, record = 40 + middle * 12
                let offset = Self.u32(bytes, record), length = Self.u16(bytes, record + 8)
                guard length > 0, length <= 128, offset <= bytes.count - poolOffset,
                      length <= bytes.count - poolOffset - offset else { return [] }
                let start = poolOffset + offset
                var comparison = 0
                for index in 0..<min(length, key.count) where bytes[start + index] != key[index] {
                    comparison = bytes[start + index] < key[index] ? -1 : 1
                    break
                }
                if comparison == 0, length != key.count { comparison = length < key.count ? -1 : 1 }
                if comparison < 0 { lower = middle + 1 }
                else if comparison > 0 { upper = middle }
                else {
                    let first = Self.u32(bytes, record + 4), count = Self.u16(bytes, record + 10)
                    guard count > 0, count <= 128, first <= entryCount, count <= entryCount - first else { return [] }
                    var result: [Entry] = []
                    for index in first..<(first + count) {
                        let record = 40 + keyCount * 12 + index * 9
                        let offset = Self.u32(bytes, record), metadata = Self.u16(bytes, record + 4)
                        let parts = metadata & 1023, flags = UInt8(metadata >> 14)
                        let cost = Int(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: record + 6, as: Int16.self)))
                        let length = Int(bytes[record + 8])
                        guard flags > 0, metadata & 0x3C00 == 0,
                              flags & 1 == 0 ? parts == 0 && cost == 0 : parts > 0,
                              length > 0, length <= 64, offset <= bytes.count - poolOffset,
                              length <= bytes.count - poolOffset - offset else { return [] }
                        var scalars = String.UnicodeScalarView()
                        for position in (poolOffset + offset)..<(poolOffset + offset + length) {
                            let value = bytes[position]
                            guard value <= 85 || value == 255 else { return [] }
                            scalars.append(UnicodeScalar(value == 255 ? 0x30FC : 0x3041 + UInt32(value))!)
                        }
                        if flags & purpose != 0 {
                            result.append(.init(reading: String(scalars), partOfSpeech: parts, cost: cost))
                        }
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
