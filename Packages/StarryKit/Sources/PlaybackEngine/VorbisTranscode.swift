import AVFoundation
import Foundation
import StarryCore
import UniformTypeIdentifiers

/// Decode Ogg Vorbis one packet at a time into a sparse Float32 WAV.
/// Page granules provide exact timing; decode on demand and retain decoded ranges.
/// Report unsupported input before emitting audio so the deck can fall back.
final class VorbisTranscode: NSObject, @unchecked Sendable {
    static let scheme = "starry-pcm"
    nonisolated(unsafe) static var decodeAhead: TimeInterval = 30
    /// A request this close past the decoding position waits for it instead of moving it.
    static let lookahead: TimeInterval = 3
    private static let chunkFrames = 4096

    let assetURL: URL
    private let decodeAhead: TimeInterval
    private let source: ByteSource
    private let fileURL: URL
    private let ogg: OggVorbisReader

    private let state = NSCondition()
    private enum Phase { case opening, ready(PCMFile), unsupported, failed(Error), cancelled }
    private var phase: Phase = .opening
    private var generation = 0
    private var request: Int64 = 0
    private var head: Int64 = 0
    private var playhead: Int64 = 0
    private var cancelled = false
    private var format: AudioStreamInfo?

    // The decoding thread's own.
    private var decoder: VorbisDecoder?
    private var packets: OggPacketReader?
    private var pushback: [UInt8]?
    private var outPos: Int64 = 0
    private var skipCheckFrom: Int64 = 0
    private var isUrgent = true
    private(set) var seeks = 0

    private let loaderQueue = DispatchQueue(label: "starry.vorbis-transcode")
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var serveScheduled = false

    /// Runs on the main actor when the file is not one this path plays; nothing was served.
    var onUnsupported: (@MainActor @Sendable () -> Void)?

    init(source: ByteSource, directory: URL, decodeAhead: TimeInterval = VorbisTranscode.decodeAhead) {
        self.source = source
        self.decodeAhead = decodeAhead
        let name = UUID().uuidString
        fileURL = directory.appending(path: "\(name).wav")
        assetURL = URL(string: "\(Self.scheme)://transcode/\(name).wav")!
        ogg = OggVorbisReader(source: source)
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(self, queue: loaderQueue)
        return asset
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "starry.vorbis-transcode"
        // Opening and the first seconds are waited for; `decodeLoop` lowers it once ahead.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func update(playhead seconds: TimeInterval) {
        state.withLock {
            guard case .ready(let pcm) = phase else { return }
            playhead = max(0, Int64(seconds * pcm.sampleRate))
            state.broadcast()
        }
    }

    /// Stops decoding and removes the PCM file. The item reading it must be gone.
    func cancel() {
        state.withLock {
            cancelled = true
            state.broadcast()
        }
        loaderQueue.async { [self] in serve() }
    }

    var sourceFormat: AudioStreamInfo? { state.withLock { format } }

    var decodedFrames: [Range<Int64>] {
        state.withLock {
            guard case .ready(let pcm) = phase else { return [] }
            return pcm.writtenFrames
        }
    }

    var isReady: Bool { state.withLock { if case .ready = phase { true } else { false } } }

    /// Interleaved samples of decoded `frames` (tests); nil unless all of them are decoded.
    func samples(_ frames: Range<Int64>) -> [Float]? {
        guard case .ready(let pcm) = state.withLock({ phase }), frames.lowerBound >= 0, frames.upperBound <= pcm.frames,
              pcm.availableEnd(from: pcm.byteOffset(frame: frames.lowerBound)) >= pcm.byteOffset(frame: frames.upperBound) else { return nil }
        let data = pcm.read(pcm.byteOffset(frame: frames.lowerBound), Int(frames.count) * pcm.channels * 4)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func need(frame: Int64) {
        state.withLock {
            guard case .ready(let pcm) = phase, !pcm.isWritten(frame: frame) else { return }
            let ahead = Int64(Self.lookahead * pcm.sampleRate)
            if frame >= head && frame <= head + ahead { return }
            if request == frame { return }
            request = frame
            head = frame
            generation += 1
            state.broadcast()
        }
    }

    private var isStopped: Bool { state.withLock { cancelled } }

    private func run() {
        ogg.isCancelled = { [unowned self] in isStopped }
        let pcm: PCMFile
        do {
            try ogg.open()
            let decoder = try VorbisDecoder(headers: ogg.headers)
            pcm = try PCMFile(url: fileURL, channels: ogg.headers.channels, sampleRate: ogg.headers.sampleRate, frames: ogg.totalFrames)
            self.decoder = decoder
        } catch let error as OggVorbisError where error != .unreadable {
            NSLog("[vorbis] not transcoding: %@", String(describing: error))
            finish(.unsupported)
            return
        } catch {
            finish(isStopped ? .cancelled : .failed(error))
            return
        }
        let seconds = Double(ogg.totalFrames) / ogg.headers.sampleRate
        let bitrate = ogg.headers.nominalBitrate ?? (seconds > 0 ? Int(Double(ogg.fileLength - ogg.dataStart) * 8 / seconds) : nil)
        state.withLock {
            if cancelled { return }
            format = AudioStreamInfo(bitrate: bitrate, sampleRate: Int(ogg.headers.sampleRate.rounded()), channels: ogg.headers.channels, fileSize: ogg.fileLength)
            phase = .ready(pcm)
        }
        pcm.onWrite = { [weak self] in self?.scheduleServe() }
        scheduleServe()
        defer { pcm.close() }

        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunkFrames * ogg.headers.channels)
        defer { buffer.deallocate() }
        prefillTail(pcm, buffer)
        decodeLoop(pcm, buffer)
    }

    private func finish(_ end: Phase) {
        state.withLock { phase = end }
        if case .unsupported = end, let onUnsupported {
            Task { @MainActor in onUnsupported() }
        }
        scheduleServe()
    }

    /// Decodes from the first page of the tail fetched with the length (its bytes are here
    /// already, so this never holds up the start).
    private func prefillTail(_ pcm: PCMFile, _ buffer: UnsafeMutablePointer<Float>) {
        guard let tailPage = ogg.tailPageGranule else { return }
        let margin: Int64 = 4096
        let target = max(pcm.frames - Int64(0.5 * pcm.sampleRate), tailPage - ogg.base + margin)
        guard target < pcm.frames, seek(to: target, generation: 0, pcm: pcm, margin: margin) else { return }
        while outPos < pcm.frames, !isStopped {
            let result = decodeChunk(buffer, generation: nil)
            guard result.frames > 0, result.status == noErr else { break }
            pcm.write(buffer, frames: result.frames, at: outPos)
            outPos += Int64(result.frames)
        }
        packets = nil
    }

    private func decodeLoop(_ pcm: PCMFile, _ buffer: UnsafeMutablePointer<Float>) {
        var active = -1
        var failures = 0
        while true {
            state.lock()
            if cancelled { state.unlock(); return }
            let gen = generation, target = request, playheadFrame = playhead
            let limit = max(playhead + Int64(decodeAhead * pcm.sampleRate), request + Int64(2 * pcm.sampleRate))
            state.unlock()

            if gen != active || packets == nil {
                active = gen
                if !seek(to: target, generation: gen, pcm: pcm) {
                    if ogg.sourceFailed { fail(OggVorbisError.unreadable); return }
                    if !isStopped, currentGeneration == gen { waitForChange(gen, timeout: 0.05) }
                    continue
                }
            }
            if outPos >= pcm.frames || (outPos >= skipCheckFrom && pcm.isWritten(frame: outPos)) {
                let runEnd = outPos >= pcm.frames ? pcm.frames : pcm.writtenRunEnd(frame: outPos)
                if runEnd < pcm.frames, runEnd < limit {
                    move(to: runEnd)
                } else {
                    waitForChange(gen, timeout: 0.25)
                }
                continue
            }
            if outPos >= limit {
                waitForChange(gen, timeout: 0.5)
                continue
            }
            let urgent = outPos < target + Int64(2 * pcm.sampleRate) || outPos < playheadFrame + Int64(5 * pcm.sampleRate)
            if urgent != isUrgent {
                isUrgent = urgent
                pthread_set_qos_class_self_np(urgent ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY, 0)
            }
            let result = decodeChunk(buffer, generation: gen)
            if result.cancelled {
                if ogg.sourceFailed { fail(OggVorbisError.unreadable); return }
                continue
            }
            if result.status != noErr {
                // A packet the decoder rejects: silence up to the next page that decodes.
                failures += 1
                NSLog("[vorbis] decode error %d at frame %lld", result.status, outPos)
                if failures > 50 { fail(OggVorbisError.malformed("decoder errors")); return }
                let from = outPos
                if seek(to: outPos + Int64(0.1 * pcm.sampleRate), generation: gen, pcm: pcm, margin: 0), outPos > from {
                    pcm.writeSilence(from: from, to: outPos)
                }
                continue
            }
            if result.frames == 0 {
                pcm.writeSilence(from: outPos, to: pcm.frames)
                outPos = pcm.frames
                continue
            }
            pcm.write(buffer, frames: result.frames, at: outPos)
            outPos += Int64(result.frames)
            state.withLock { if generation == gen { head = outPos } }
        }
    }

    private var currentGeneration: Int { state.withLock { generation } }

    private func waitForChange(_ gen: Int, timeout: TimeInterval) {
        state.lock()
        if generation == gen, !cancelled { _ = state.wait(until: Date().addingTimeInterval(timeout)) }
        state.unlock()
    }

    private func move(to frame: Int64) {
        state.withLock {
            request = frame
            head = frame
            generation += 1
        }
    }

    private func fail(_ error: Error) {
        NSLog("[vorbis] transcode failed: %@", String(describing: error))
        state.withLock { if !cancelled { phase = .failed(error) } }
        scheduleServe()
    }

    private func decodeChunk(_ buffer: UnsafeMutablePointer<Float>, generation gen: Int?) -> (frames: Int, status: OSStatus, cancelled: Bool) {
        guard let decoder, let packets else { return (0, noErr, true) }
        decoder.input = { [unowned self] in
            if let first = pushback {
                pushback = nil
                return .packet(first)
            }
            if isStopped || (gen != nil && currentGeneration != gen) { return .cancelled }
            return packets.next()
        }
        return decoder.decode(into: buffer, frames: Self.chunkFrames)
    }

    private func seek(to target: Int64, generation gen: Int, pcm: PCMFile, margin: Int64 = 4096) -> Bool {
        guard let decoder else { return false }
        let previousCancel = ogg.isCancelled
        ogg.isCancelled = { [unowned self] in isStopped || currentGeneration != gen }
        defer { ogg.isCancelled = previousCancel }
        decoder.reset()
        pushback = nil
        packets = nil
        skipCheckFrom = target
        let granule = max(0, target - margin) + ogg.base
        if granule > ogg.base, let found = ogg.locate(granule: granule) {
            let reader = OggPacketReader(after: found.page, in: ogg, previous: found.previous)
            guard case .packet(let first) = reader.next() else { return false }
            outPos = found.page.granule + Int64(ogg.headers.duration(first, previousBlocksize: reader.previousBlocksize)) - ogg.base
            pushback = first
            packets = reader
            seeks += 1
            return true
        }
        if ogg.isCancelled() { return false }
        packets = OggPacketReader(fromStartOf: ogg)
        outPos = ogg.origin - ogg.base
        return true
    }

    private func scheduleServe() {
        loaderQueue.async { [self] in
            if serveScheduled { return }
            serveScheduled = true
            loaderQueue.asyncAfter(deadline: .now() + .milliseconds(5)) { [self] in
                serveScheduled = false
                serve()
            }
        }
    }

    private func serve() {
        let (current, stopped) = state.withLock { (phase, cancelled) }
        if stopped {
            for request in pending { request.finishLoading(with: CocoaError(.userCancelled)) }
            pending.removeAll()
            return
        }
        switch current {
        case .opening, .unsupported:
            // Unsupported: the deck replaces the item; failing it here would report an error.
            return
        case .cancelled:
            for request in pending { request.finishLoading(with: CocoaError(.userCancelled)) }
            pending.removeAll()
            return
        case .failed(let error):
            for request in pending { request.finishLoading(with: error) }
            pending.removeAll()
            return
        case .ready(let pcm):
            var budget = 4 * 1024 * 1024
            pending.removeAll { request in
                if let info = request.contentInformationRequest, info.contentLength == 0 {
                    info.contentType = UTType.wav.identifier
                    info.contentLength = pcm.length
                    info.isByteRangeAccessSupported = true
                    info.isEntireLengthAvailableOnDemand = true
                }
                guard let data = request.dataRequest else {
                    request.finishLoading()
                    return true
                }
                let end = data.requestsAllDataToEndOfResource ? pcm.length : min(pcm.length, data.requestedOffset + Int64(data.requestedLength))
                while data.currentOffset < end, budget > 0 {
                    let available = min(pcm.availableEnd(from: data.currentOffset), end)
                    guard available > data.currentOffset else { break }
                    let count = Int(min(available - data.currentOffset, 512 * 1024))
                    data.respond(with: pcm.read(data.currentOffset, count))
                    budget -= count
                }
                guard data.currentOffset >= end else { return false }
                request.finishLoading()
                return true
            }
            if let newest = pending.last?.dataRequest {
                need(frame: pcm.frame(atByte: newest.currentOffset))
            }
            if budget <= 0 { loaderQueue.async { [self] in serve() } }
        }
    }
}

extension VorbisTranscode: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url == assetURL else { return false }
        pending.append(loadingRequest)
        serve()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
    }
}

/// The headers, length and pages of the first Vorbis stream in an Ogg file, read through a
/// `ByteSource`, and the page to start from for any position. Used on one thread.
final class OggVorbisReader {
    let source: ByteSource
    var isCancelled: () -> Bool = { false }
    private(set) var headers: VorbisHeaders!
    private(set) var serial: UInt32 = 0
    private(set) var dataStart: Int64 = 0
    private(set) var fileLength: Int64 = 0
    private(set) var origin: Int64 = 0
    private(set) var endGranule: Int64 = 0
    var base: Int64 { max(origin, 0) }
    var totalFrames: Int64 { endGranule - base }
    private(set) var sourceFailed = false
    private(set) var tailPageGranule: Int64?

    private var windowStart: Int64 = 0
    private var window: [UInt8] = []
    private var windowSize = 32 * 1024
    /// (offset, granule) of the pages seen so far that carry a granule, by offset: seeks
    /// interpolate between the nearest of them.
    private var index: [(offset: Int64, granule: Int64)] = []

    init(source: ByteSource) { self.source = source }

    func open() throws {
        guard let length = source.length(isCancelled: isCancelled) else { throw OggVorbisError.unreadable }
        fileLength = length
        var headerPackets: [[UInt8]] = []
        var partial: [UInt8] = []
        var offset: Int64 = 0
        var first = true
        while headerPackets.count < 3 {
            guard let page = page(at: offset) else { throw sourceFailed || isCancelled() ? OggVorbisError.unreadable : OggVorbisError.malformed("header pages") }
            offset = page.end
            if first {
                serial = page.serial
                first = false
                source.prefetch(max(0, length - 16 * 1024)..<length)
            }
            guard page.serial == serial else { continue }
            for piece in page.pieces() {
                partial += piece.bytes
                guard piece.complete else { continue }
                headerPackets.append(partial)
                partial = []
                if headerPackets.count == 1, !headerPackets[0].starts(with: [1] + Array("vorbis".utf8)) { throw OggVorbisError.notVorbis }
            }
        }
        dataStart = offset
        headers = try VorbisHeaders(identification: headerPackets[0], comment: headerPackets[1], setup: headerPackets[2])
        guard (1...2).contains(headers.channels) else { throw OggVorbisError.unsupportedChannels(headers.channels) }
        guard VorbisDecoder.isAvailable else { throw OggVorbisError.decoderUnavailable }
        endGranule = try lastGranule()
        origin = try firstGranule()
        guard endGranule > base else { throw OggVorbisError.noLength }
        // WAV data size is limited to 32 bits.
        guard totalFrames * Int64(headers.channels) * 4 < Int64(UInt32.max) - 64 else { throw OggVorbisError.malformed("too long for WAV") }
    }

    private func lastGranule() throws -> Int64 {
        var span: Int64 = 16 * 1024
        while true {
            let start = max(dataStart, fileLength - span)
            var last: Int64 = -1
            var first: Int64?
            var page = findPage(from: start, limit: fileLength)
            while let current = page {
                if current.serial == serial, current.granule >= 0 {
                    last = current.granule
                    if first == nil { first = current.granule }
                }
                page = current.end < fileLength ? self.page(at: current.end) : nil
            }
            if last >= 0 {
                tailPageGranule = first
                return last
            }
            if sourceFailed || isCancelled() { throw OggVorbisError.unreadable }
            guard start > dataStart, span < 4 * 1024 * 1024 else { throw OggVorbisError.noLength }
            span *= 4
        }
    }

    private func firstGranule() throws -> Int64 {
        var offset = dataStart
        var played = 0
        var previous: Int?
        var partial: [UInt8] = []
        while offset < fileLength {
            guard let page = page(at: offset) else { throw sourceFailed || isCancelled() ? OggVorbisError.unreadable : OggVorbisError.malformed("first audio page") }
            offset = page.end
            guard page.serial == serial else { continue }
            for piece in page.pieces() {
                partial += piece.bytes
                guard piece.complete else { continue }
                if !partial.isEmpty {
                    // The first Vorbis packet primes overlap and produces no audio.
                    if let previous { played += headers.duration(partial, previousBlocksize: previous) }
                    previous = headers.blocksize(partial)
                }
                partial = []
            }
            if page.granule >= 0 { return page.granule - Int64(played) }
        }
        throw OggVorbisError.noLength
    }

    private func bytes(_ offset: Int64, _ count: Int) -> [UInt8]? {
        let end = min(offset + Int64(count), fileLength)
        guard offset < end else { return [] }
        if offset >= windowStart, end <= windowStart + Int64(window.count) {
            return Array(window[Int(offset - windowStart)..<Int(end - windowStart)])
        }
        let wanted = min(fileLength, max(end, offset + Int64(windowSize)))
        guard let read = source.read(offset, Int(wanted - offset), isCancelled: isCancelled) else {
            if !isCancelled() { sourceFailed = true }
            return nil
        }
        windowStart = offset
        window = read
        return Array(window[0..<min(window.count, Int(end - offset))])
    }

    /// The valid page at `offset`, nil when there is none (or the read was cancelled / failed).
    func page(at offset: Int64) -> OggPage? {
        guard let head = bytes(offset, 27 + 255), let (header, body) = OggPage.sizes(head, at: 0), let all = bytes(offset, header + body),
              let page = OggPage.parse(all, at: 0, offset: offset) else { return nil }
        if page.granule >= 0, page.serial == serial { remember(page) }
        return page
    }

    private func remember(_ page: OggPage) {
        let i = index.firstIndex { $0.offset >= page.offset } ?? index.endIndex
        if i < index.endIndex, index[i].offset == page.offset { return }
        index.insert((page.offset, page.granule), at: i)
    }

    func findPage(from: Int64, limit: Int64) -> OggPage? {
        var position = from
        while position < min(limit, fileLength) {
            guard let chunk = bytes(position, 8192), chunk.count >= 4 else { return nil }
            for i in 0..<(chunk.count - 3) where chunk[i] == 0x4F && chunk[i + 1] == 0x67 && chunk[i + 2] == 0x67 && chunk[i + 3] == 0x53 {
                if position + Int64(i) >= limit { return nil }
                if let page = page(at: position + Int64(i)) { return page }
                if isCancelled() || sourceFailed { return nil }
            }
            position += Int64(chunk.count - 3)
        }
        return nil
    }

    private func granulePage(from page: OggPage?) -> OggPage? {
        var current = page
        while let p = current, p.granule < 0 || p.serial != serial {
            current = p.end < fileLength ? self.page(at: p.end) : nil
        }
        return current
    }

    func locate(granule: Int64) -> (previous: OggPage?, page: OggPage)? {
        windowSize = 8 * 1024
        defer { windowSize = 32 * 1024 }
        var low = index.last { $0.granule <= granule } ?? (offset: dataStart, granule: base)
        var high = index.first { $0.granule > granule } ?? (offset: fileLength, granule: endGranule)
        let near = Int64(headers.sampleRate * 1.5)
        for _ in 0..<8 where granule - low.granule >= near && high.offset - low.offset >= 24 * 1024 {
            let fraction = Double(granule - low.granule) / Double(max(1, high.granule - low.granule))
            let guess = min(high.offset - 1, max(low.offset, low.offset + Int64(fraction * Double(high.offset - low.offset)) - 8 * 1024))
            guard let page = granulePage(from: findPage(from: guess, limit: high.offset)) else {
                if isCancelled() || sourceFailed { return nil }
                high = (guess, high.granule)
                continue
            }
            if page.granule > granule {
                high = (guess, page.granule)
            } else {
                low = (page.offset, page.granule)
            }
        }
        var previous: OggPage?
        var best: (previous: OggPage?, page: OggPage)?
        var current = page(at: low.offset)
        while let page = current {
            if page.serial == serial {
                if page.granule >= 0 {
                    if page.granule > granule { break }
                    if page.completedPackets > 0 { best = (previous, page) }
                }
                previous = page
            }
            current = page.end < fileLength ? self.page(at: page.end) : nil
        }
        if isCancelled() || sourceFailed { return nil }
        return best
    }
}

final class OggPacketReader {
    private let ogg: OggVorbisReader
    private var nextPage: Int64
    private var queue: [[UInt8]] = []
    private var partial: [UInt8] = []
    private var resync = false
    let previousBlocksize: Int

    init(fromStartOf ogg: OggVorbisReader) {
        self.ogg = ogg
        nextPage = ogg.dataStart
        previousBlocksize = ogg.headers.longBlock
    }

    init(after page: OggPage, in ogg: OggVorbisReader, previous: OggPage?) {
        self.ogg = ogg
        nextPage = page.end
        let pieces = page.pieces()
        let completed = pieces.filter(\.complete)
        var lastStart: UInt8?
        if completed.count >= 2 || (completed.count == 1 && !page.continuesPacket) {
            lastStart = completed.last?.bytes.first
        } else if let previous, let tail = previous.pieces().last, !tail.complete {
            lastStart = tail.bytes.first
        }
        previousBlocksize = lastStart.map { ogg.headers.blocksize([$0]) } ?? ogg.headers.longBlock
        if let last = pieces.last, !last.complete { partial = Array(last.bytes) }
    }

    func next() -> VorbisDecoder.Input {
        while queue.isEmpty {
            if nextPage >= ogg.fileLength { return .end }
            guard let page = ogg.page(at: nextPage) else {
                if ogg.isCancelled() || ogg.sourceFailed { return .cancelled }
                guard let found = ogg.findPage(from: nextPage + 1, limit: ogg.fileLength) else { return ogg.isCancelled() || ogg.sourceFailed ? .cancelled : .end }
                nextPage = found.offset
                partial = []
                resync = true
                continue
            }
            nextPage = page.end
            guard page.serial == ogg.serial else { continue }
            var pieces = page.pieces()
            if resync, page.continuesPacket, !pieces.isEmpty { pieces.removeFirst() }
            resync = false
            for piece in pieces {
                partial += piece.bytes
                guard piece.complete else { continue }
                if !partial.isEmpty { queue.append(partial) }
                partial = []
            }
        }
        return .packet(queue.removeFirst())
    }
}

final class PCMFile: @unchecked Sendable {
    let channels: Int
    let sampleRate: Double
    let frames: Int64
    let length: Int64
    private let url: URL
    private let descriptor: Int32
    private let headerSize: Int64 = 44
    private let lock = NSLock()
    private var written = ByteRanges()
    private var isClosed = false
    private var zeros: [Float] = []
    var onWrite: (() -> Void)?

    init(url: URL, channels: Int, sampleRate: Double, frames: Int64) throws {
        self.url = url
        self.channels = channels
        self.sampleRate = sampleRate
        self.frames = frames
        let dataSize = frames * Int64(channels) * 4
        length = headerSize + dataSize
        descriptor = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard ftruncate(descriptor, off_t(length)) == 0 else {
            Darwin.close(descriptor)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        var header = [UInt8]()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header += $0 } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header += $0 } }
        header += Array("RIFF".utf8); u32(UInt32(36 + dataSize)); header += Array("WAVE".utf8)
        header += Array("fmt ".utf8); u32(16); u16(3) // IEEE float
        u16(UInt16(channels)); u32(UInt32(sampleRate.rounded())); u32(UInt32(sampleRate.rounded()) * UInt32(channels) * 4); u16(UInt16(channels * 4)); u16(32)
        header += Array("data".utf8); u32(UInt32(dataSize))
        _ = header.withUnsafeBytes { pwrite(descriptor, $0.baseAddress!, header.count, 0) }
        written.insert(0..<headerSize)
    }

    func byteOffset(frame: Int64) -> Int64 { headerSize + frame * Int64(channels) * 4 }
    func frame(atByte byte: Int64) -> Int64 { max(0, (byte - headerSize) / Int64(channels * 4)) }

    func write(_ samples: UnsafePointer<Float>, frames count: Int, at frame: Int64) {
        let start = max(frame, 0), end = min(frame + Int64(count), frames)
        guard start < end else { return }
        let skip = Int(start - frame) * channels
        let bytes = Int(end - start) * channels * 4
        let stored = lock.withLock {
            guard !isClosed, pwrite(descriptor, samples + skip, bytes, off_t(byteOffset(frame: start))) == bytes else { return false }
            written.insert(byteOffset(frame: start)..<byteOffset(frame: end))
            return true
        }
        if stored { onWrite?() }
    }

    func writeSilence(from: Int64, to: Int64) {
        var frame = max(from, 0)
        let end = min(to, frames)
        let step = 4096
        if zeros.count < step * channels { zeros = [Float](repeating: 0, count: step * channels) }
        while frame < end {
            let count = Int(min(Int64(step), end - frame))
            zeros.withUnsafeBufferPointer { write($0.baseAddress!, frames: count, at: frame) }
            frame += Int64(count)
        }
    }

    func availableEnd(from byte: Int64) -> Int64 { lock.withLock { written.end(ofRunAt: byte) } }
    func isWritten(frame: Int64) -> Bool {
        let byte = byteOffset(frame: frame)
        return lock.withLock { written.end(ofRunAt: byte) > byte }
    }
    func writtenRunEnd(frame: Int64) -> Int64 { self.frame(atByte: availableEnd(from: byteOffset(frame: frame))) }
    var writtenFrames: [Range<Int64>] {
        lock.withLock { written.ranges.compactMap { r in
            let lower = frame(atByte: max(r.lowerBound, headerSize)), upper = frame(atByte: r.upperBound)
            return lower < upper ? lower..<upper : nil
        } }
    }

    func read(_ offset: Int64, _ count: Int) -> Data {
        var data = Data(count: count)
        let got = lock.withLock { isClosed ? 0 : data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!, count, off_t(offset)) } }
        if got < count { data.count = max(0, got) }
        return data
    }

    /// Closes and removes the file (a read racing it gets nothing, never another file's bytes).
    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(descriptor)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
