import AudioToolbox
import Foundation

enum OggVorbisError: Error, Equatable {
    /// The first logical stream is not Vorbis (Opus, FLAC in Ogg…).
    case notVorbis
    case unsupportedChannels(Int)
    case malformed(String)
    case noLength
    case decoderUnavailable
    case unreadable
}

struct OggPage: Sendable {
    let offset: Int64
    let headerSize: Int
    let flags: UInt8
    /// Granule of the last completed packet's final sample; −1 if no packet ends here.
    let granule: Int64
    let serial: UInt32
    let lacing: [UInt8]
    let body: [UInt8]

    var size: Int { headerSize + body.count }
    var end: Int64 { offset + Int64(size) }
    var continuesPacket: Bool { flags & 0x01 != 0 }
    var completedPackets: Int { lacing.reduce(0) { $0 + ($1 < 255 ? 1 : 0) } }

    func pieces() -> [(bytes: ArraySlice<UInt8>, complete: Bool)] {
        var out: [(ArraySlice<UInt8>, Bool)] = []
        var start = 0, run = 0
        for length in lacing {
            run += Int(length)
            if length < 255 {
                out.append((body[start..<run], true))
                start = run
            }
        }
        if start < run { out.append((body[start..<run], false)) }
        return out
    }

    /// Header and body sizes of the page starting at `bytes[i]`; nil when there is no page header
    /// there or it is cut short.
    static func sizes(_ bytes: [UInt8], at i: Int) -> (header: Int, body: Int)? {
        guard bytes.count - i >= 27, bytes[i] == 0x4F, bytes[i + 1] == 0x67, bytes[i + 2] == 0x67, bytes[i + 3] == 0x53, bytes[i + 4] == 0 else { return nil }
        let segments = Int(bytes[i + 26])
        guard bytes.count - i >= 27 + segments else { return nil }
        var body = 0
        for k in 0..<segments { body += Int(bytes[i + 27 + k]) }
        return (27 + segments, body)
    }

    /// The page at `bytes[i]`, which sits at `offset` in the file; nil unless it is whole and its
    /// checksum holds.
    static func parse(_ bytes: [UInt8], at i: Int, offset: Int64) -> OggPage? {
        guard let (header, body) = sizes(bytes, at: i), bytes.count - i >= header + body else { return nil }
        let stored = UInt32(bytes[i + 22]) | UInt32(bytes[i + 23]) << 8 | UInt32(bytes[i + 24]) << 16 | UInt32(bytes[i + 25]) << 24
        guard checksum(bytes, i..<(i + header + body), crcAt: i + 22) == stored else { return nil }
        var granule: UInt64 = 0
        for k in 0..<8 { granule |= UInt64(bytes[i + 6 + k]) << (8 * k) }
        let serial = UInt32(bytes[i + 14]) | UInt32(bytes[i + 15]) << 8 | UInt32(bytes[i + 16]) << 16 | UInt32(bytes[i + 17]) << 24
        return OggPage(offset: offset, headerSize: header, flags: bytes[i + 5], granule: Int64(bitPattern: granule), serial: serial,
                       lacing: Array(bytes[(i + 27)..<(i + header)]), body: Array(bytes[(i + header)..<(i + header + body)]))
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    private static func checksum(_ bytes: [UInt8], _ range: Range<Int>, crcAt: Int) -> UInt32 {
        bytes.withUnsafeBufferPointer { b in
            crcTable.withUnsafeBufferPointer { table in
                var crc: UInt32 = 0
                for i in range {
                    let byte = (i >= crcAt && i < crcAt + 4) ? 0 : b[i]
                    crc = (crc << 8) ^ table[Int(((crc >> 24) & 0xFF) ^ UInt32(byte))]
                }
                return crc
            }
        }
    }
}

struct VorbisHeaders: Sendable {
    let sampleRate: Double
    let channels: Int
    let nominalBitrate: Int?
    let shortBlock: Int
    let longBlock: Int
    let modeIsLong: [Bool]
    private let modeMask: UInt8
    private let previousWindowMask: UInt8
    let cookie: [UInt8]

    init(identification: [UInt8], comment: [UInt8], setup: [UInt8]) throws {
        guard identification.count >= 30, identification[0] == 1, Array(identification[1...6]) == Array("vorbis".utf8) else { throw OggVorbisError.notVorbis }
        guard setup.count > 7, setup[0] == 5, Array(setup[1...6]) == Array("vorbis".utf8) else { throw OggVorbisError.malformed("setup header") }
        channels = Int(identification[11])
        func le32(_ i: Int) -> UInt32 { UInt32(identification[i]) | UInt32(identification[i + 1]) << 8 | UInt32(identification[i + 2]) << 16 | UInt32(identification[i + 3]) << 24 }
        sampleRate = Double(le32(12))
        let nominal = Int32(bitPattern: le32(20))
        nominalBitrate = nominal > 0 ? Int(nominal) : nil
        shortBlock = 1 << Int(identification[28] & 0x0F)
        longBlock = 1 << Int(identification[28] >> 4)
        guard channels > 0, sampleRate > 0, shortBlock >= 64, longBlock >= shortBlock, longBlock <= 8192 else { throw OggVorbisError.malformed("identification header") }
        modeIsLong = Self.modeFlags(setup)
        guard !modeIsLong.isEmpty else { throw OggVorbisError.malformed("no modes") }
        if modeIsLong.count > 1 {
            var bits = 0
            var v = modeIsLong.count - 1
            while v > 0 { bits += 1; v >>= 1 }
            modeMask = UInt8(((1 << bits) - 1) << 1)
        } else {
            modeMask = 0
        }
        previousWindowMask = (modeMask | 1) &+ 1
        var c: [UInt8] = [2]
        for size in [identification.count, comment.count] {
            var s = size
            while s >= 255 { c.append(255); s -= 255 }
            c.append(UInt8(s))
        }
        cookie = c + identification + comment + setup
    }

    /// The block flag of each mode, read backwards from the end of the setup header: the modes
    /// come last, after codebooks, floors and residues that would take a full decoder to walk.
    static func modeFlags(_ setup: [UInt8]) -> [Bool] {
        let reversed = Array(setup.reversed())
        let total = reversed.count * 8
        var position = 0
        func bits(_ count: Int) -> Int {
            var v = 0
            for _ in 0..<count {
                v = (v << 1) | Int(reversed[position >> 3] >> (7 - UInt8(position & 7))) & 1
                position += 1
            }
            return v
        }
        var framing = -1
        while total - position > 97 {
            if bits(1) == 1 { framing = position; break }
        }
        guard framing >= 0 else { return [] }
        var count = 0, found = 0
        while total - position >= 97 {
            if bits(8) > 63 || bits(16) != 0 || bits(16) != 0 { break }
            _ = bits(1)
            count += 1
            if count > 64 { break }
            if total - position > 5 {
                let saved = position
                if bits(6) == count - 1 { found = count }
                position = saved
            }
        }
        position = framing
        var flags = [Bool](repeating: false, count: found)
        for i in stride(from: found - 1, through: 0, by: -1) {
            _ = bits(40)
            flags[i] = bits(1) == 1
        }
        return flags
    }

    private func isLong(_ packet: some Collection<UInt8>) -> Bool {
        guard let first = packet.first else { return false }
        let mode = modeIsLong.count > 1 ? Int((first & modeMask) >> 1) : 0
        return mode < modeIsLong.count && modeIsLong[mode]
    }

    func blocksize(_ packet: some Collection<UInt8>) -> Int { isLong(packet) ? longBlock : shortBlock }

    func duration(_ packet: some Collection<UInt8>, previousBlocksize: Int) -> Int {
        guard let first = packet.first else { return 0 }
        var previous = previousBlocksize
        if isLong(packet) { previous = (first & previousWindowMask) != 0 ? longBlock : shortBlock }
        return (previous + blocksize(packet)) >> 2
    }
}

/// Feed the system Vorbis decoder one packet per call: large batches can hang
/// indefinitely while consuming CPU and memory.
final class VorbisDecoder {
    let channels: Int
    private var converter: AudioConverterRef?
    private var packet: UnsafeMutableRawPointer
    private var packetCapacity = 64 * 1024
    private let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private var cancelled = false

    enum Input {
        case packet([UInt8])
        case end
        case cancelled
    }

    var input: () -> Input = { .end }

    init(headers: VorbisHeaders) throws {
        channels = headers.channels
        packet = .allocate(byteCount: packetCapacity, alignment: 16)
        var source = AudioStreamBasicDescription(mSampleRate: headers.sampleRate, mFormatID: Self.formatID, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
                                                 mBytesPerFrame: 0, mChannelsPerFrame: UInt32(headers.channels), mBitsPerChannel: 0, mReserved: 0)
        var output = Self.outputFormat(sampleRate: headers.sampleRate, channels: headers.channels)
        guard AudioConverterNew(&source, &output, &converter) == noErr, let converter else {
            packet.deallocate()
            throw OggVorbisError.decoderUnavailable
        }
        let status = headers.cookie.withUnsafeBytes { AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!) }
        guard status == noErr else {
            AudioConverterDispose(converter)
            packet.deallocate()
            throw OggVorbisError.malformed("decoder refused the headers (\(status))")
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        packet.deallocate()
        description.deallocate()
    }

    static let formatID: AudioFormatID = 0x766F_7262 // 'vorb'

    static func outputFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                    mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    static let isAvailable: Bool = {
        var source = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: formatID, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
                                                 mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var output = outputFormat(sampleRate: 44_100, channels: 2)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&source, &output, &converter) == noErr, let converter else { return false }
        AudioConverterDispose(converter)
        return true
    }()

    /// Forgets the stream so far; the next packet starts a new one (its own output is dropped,
    /// it only primes the overlap).
    func reset() {
        if let converter { AudioConverterReset(converter) }
    }

    func decode(into out: UnsafeMutablePointer<Float>, frames: Int) -> (frames: Int, status: OSStatus, cancelled: Bool) {
        guard let converter else { return (0, -1, false) }
        cancelled = false
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4), mData: out))
        var count = UInt32(frames)
        let status = AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, outDescription, user in
            let decoder = Unmanaged<VorbisDecoder>.fromOpaque(user!).takeUnretainedValue()
            return decoder.supply(ioPackets, ioData, outDescription)
        }, Unmanaged.passUnretained(self).toOpaque(), &count, &list, nil)
        return (Int(count), cancelled ? noErr : status, cancelled)
    }

    private func supply(_ ioPackets: UnsafeMutablePointer<UInt32>, _ ioData: UnsafeMutablePointer<AudioBufferList>,
                        _ outDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        switch input() {
        case .end:
            ioPackets.pointee = 0
            return noErr
        case .cancelled:
            cancelled = true
            ioPackets.pointee = 0
            return -1
        case .packet(let bytes):
            if bytes.count > packetCapacity {
                packet.deallocate()
                packetCapacity = bytes.count
                packet = .allocate(byteCount: packetCapacity, alignment: 16)
            }
            bytes.withUnsafeBytes { packet.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count), mData: packet)
            outDescription?.pointee = description
            ioPackets.pointee = 1
            return noErr
        }
    }
}
