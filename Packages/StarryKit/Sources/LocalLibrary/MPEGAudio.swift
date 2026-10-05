import Foundation

/// The first MPEG audio frame of an MP3 and its Xing / Info / VBRI header, which counts the
/// frames: the exact length without reading the file. Without one a VBR file's length can only
/// be estimated — AVFoundation's estimate also cuts playback short —
/// so the caller then has it measured.
enum MPEGAudio {
    struct FirstFrame {
        var sampleRate: Int
        var channels: Int
        var bitrate: Int
        /// From the Xing / VBRI frame count; nil without one.
        var duration: TimeInterval?
        var isVBR: Bool
        var audioBytes: Int64
    }

    static func firstFrame(_ file: FileReader, from start: Int64) -> FirstFrame? {
        guard let window = file.read(at: start, count: 65536 + 4) else { return nil }
        var index = 0
        while index + 4 <= window.count {
            defer { index += 1 }
            guard window.byte(index) == 0xFF, window.byte(index + 1) & 0xE0 == 0xE0, let header = Header(window.bytes(from: index, count: 4)) else { continue }
            // A second frame where the first says it ends: not a stray 0xFF in some tag padding.
            let next = index + header.frameLength
            if next + 4 <= window.count {
                guard window.byte(next) == 0xFF, window.byte(next + 1) & 0xE0 == 0xE0, Header(window.bytes(from: next, count: 4)) != nil else { continue }
            }
            var frame = FirstFrame(sampleRate: header.sampleRate, channels: header.channels, bitrate: header.bitrate, duration: nil, isVBR: false, audioBytes: file.size - start - Int64(index))
            if let frames = vbrFrames(window.bytes(from: index, count: min(header.frameLength + 200, window.count - index)), header: header, isVBR: &frame.isVBR) {
                frame.duration = Double(frames) * Double(header.samplesPerFrame) / Double(header.sampleRate)
            }
            return frame
        }
        return nil
    }

    private static func vbrFrames(_ frame: Data, header: Header, isVBR: inout Bool) -> Int? {
        let sideInfo = header.isMPEG1 ? (header.channels == 1 ? 17 : 32) : (header.channels == 1 ? 9 : 17)
        let xing = 4 + (header.hasCRC ? 2 : 0) + sideInfo
        if frame.count >= xing + 12, frame.hasASCII("Xing", at: xing) || frame.hasASCII("Info", at: xing) {
            isVBR = frame.hasASCII("Xing", at: xing)
            let flags = frame.bigEndian(at: xing + 4, count: 4)
            guard flags & 1 != 0 else { return nil }
            return Int(frame.bigEndian(at: xing + 8, count: 4))
        }
        if frame.count >= 36 + 18, frame.hasASCII("VBRI", at: 36) {
            isVBR = true
            return Int(frame.bigEndian(at: 36 + 14, count: 4))
        }
        return nil
    }

    private struct Header {
        var isMPEG1: Bool
        var layer: Int
        var bitrate: Int
        var sampleRate: Int
        var channels: Int
        var frameLength: Int
        var samplesPerFrame: Int
        var hasCRC: Bool

        init?(_ bytes: Data) {
            let b1 = bytes.byte(1), b2 = bytes.byte(2), b3 = bytes.byte(3)
            let version = (b1 >> 3) & 3          // 0: 2.5, 2: 2, 3: 1
            let layerBits = (b1 >> 1) & 3        // 1: III, 2: II, 3: I
            let bitrateIndex = Int(b2 >> 4)
            let rateIndex = Int((b2 >> 2) & 3)
            guard version != 1, layerBits != 0, bitrateIndex != 0, bitrateIndex != 15, rateIndex != 3 else { return nil }
            isMPEG1 = version == 3
            layer = 4 - Int(layerBits)
            hasCRC = b1 & 1 == 0
            let table: [Int] = switch (isMPEG1, layer) {
            case (true, 1): [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
            case (true, 2): [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
            case (true, _): [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            case (false, 1): [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
            case (false, _): [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
            }
            bitrate = table[bitrateIndex - 1] * 1000
            let rates = [44100, 48000, 32000]
            sampleRate = rates[rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
            channels = (b3 >> 6) == 3 ? 1 : 2
            let padding = Int((b2 >> 1) & 1)
            switch layer {
            case 1:
                frameLength = (12 * bitrate / sampleRate + padding) * 4
                samplesPerFrame = 384
            case 2:
                frameLength = 144 * bitrate / sampleRate + padding
                samplesPerFrame = 1152
            default:
                frameLength = (isMPEG1 ? 144 : 72) * bitrate / sampleRate + padding
                samplesPerFrame = isMPEG1 ? 1152 : 576
            }
            guard frameLength > 4 else { return nil }
        }
    }
}
