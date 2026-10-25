import AVFoundation
import CoreML
import CryptoKit
import Foundation

public struct VocalDuetSeparation: Sendable {
    public var first: URL
    public var second: URL
    public var uncertainOverlaps: [TimeInterval]

    public init(first: URL, second: URL, uncertainOverlaps: [TimeInterval] = []) {
        self.first = first
        self.second = second
        self.uncertainOverlaps = uncertainOverlaps
    }
}

/// Offline, bounded-memory two-source separation. The actor serializes model
/// access; no inference runs on the editor's main actor or audio render thread.
public actor VocalDuetSeparator {
    public enum Failure: Error, Equatable {
        case missingModel, unsupportedAudio, invalidModel, invalidOutput
    }
    public static let modelVersion = "unmixx-coreml-explicit-resize-v2"
    public static let sampleRate: Double = 24_000
    public static let sampleCount = 480_000
    private static let overlap = 120_000
    private var loaded: (url: URL, model: MLModel)?

    public init() {}

    /// Completed hints/files can remain cached without keeping Core ML buffers alive.
    public func releaseResources() { loaded = nil }

    public nonisolated static func bundledModel(in bundle: Bundle) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let url = resources.appending(path: "Models/UNMIXX/UNMIXX.mlpackage", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Supply isolated vocals, not the full mix. A/B are anonymous voices; weak
    /// overlap matches are reported instead of being presented as known singers.
    public func separate(file: URL, first: URL, second: URL, model modelURL: URL,
                         progress: (@Sendable (Double) -> Void)? = nil) throws -> VocalDuetSeparation {
        try autoreleasepool { try process(file: file, first: first, second: second, model: modelURL, progress: progress) }
    }

    private func process(file: URL, first: URL, second: URL, model modelURL: URL,
                         progress: (@Sendable (Double) -> Void)?) throws -> VocalDuetSeparation {
        try Task.checkCancellation()
        guard first != second, file != first, file != second,
              !FileManager.default.fileExists(atPath: first.path), !FileManager.default.fileExists(atPath: second.path)
        else { throw Failure.unsupportedAudio }
        let monoURL = first.deletingPathExtension().appendingPathExtension("mono.caf")
        defer { try? FileManager.default.removeItem(at: monoURL) }
        do {
            let model = try loadModel(at: modelURL)
            try Task.checkCancellation()
            try DuetPCM.convert(file, to: monoURL, sampleRate: Self.sampleRate)
            let inputFile = try AVAudioFile(forReading: monoURL)
            let format = inputFile.processingFormat
            guard inputFile.length > 0,
                  let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536),
                  let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.sampleCount))
            else { throw Failure.unsupportedAudio }
            let writers = try [first, second].map { try AVAudioFile(forWriting: $0, settings: format.settings) }
            let spectrum = try DuetSpectrum(sampleCount: Self.sampleCount)
            let input = try MLMultiArray(shape: [1, 2, 481, 2001], dataType: .float32)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["spectrum": input])
            let total = Int(inputFile.length)
            let hop = Self.sampleCount - Self.overlap
            var tail: [[Float]]?
            var uncertain: [TimeInterval] = []
            for start in stride(from: 0, to: total, by: hop) {
                try Task.checkCancellation()
                let usable = min(Self.sampleCount, total - start)
                let isLast = start + usable == total
                inputFile.framePosition = AVAudioFramePosition(start)
                var samples = [Float](repeating: 0, count: Self.sampleCount)
                var read = 0
                while read < usable {
                    try Task.checkCancellation()
                    try inputFile.read(into: readBuffer, frameCount: AVAudioFrameCount(min(65_536, usable - read)))
                    let count = Int(readBuffer.frameLength)
                    guard count > 0 else { throw Failure.unsupportedAudio }
                    samples.withUnsafeMutableBufferPointer { ($0.baseAddress! + read).update(from: readBuffer.floatChannelData![0], count: count) }
                    read += count
                }
                let encoded = try spectrum.encode(samples)
                encoded.withUnsafeBytes { input.dataPointer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                let prediction = try model.prediction(from: provider)
                try Task.checkCancellation()
                guard let output = prediction.featureValue(for: "separated")?.multiArrayValue,
                      output.dataType == .float32, output.shape.map(\.intValue) == [1,2,2,481,2001]
                else { throw Failure.invalidOutput }
                let strides = output.strides.map(\.intValue)
                let values = output.dataPointer.assumingMemoryBound(to: Float.self)
                var voices: [[Float]] = []
                for source in 0..<2 {
                    let decoded = try spectrum.decode(values, realOffset: source * strides[1],
                        imaginaryOffset: source * strides[1] + strides[2], binStride: strides[3], frameStride: strides[4])
                    guard decoded.allSatisfy(\.isFinite) else { throw Failure.invalidOutput }
                    let mean = decoded.reduce(0.0) { $0 + Double($1) } / Double(decoded.count)
                    voices.append((0..<usable).map { decoded[$0] - Float(mean) + samples[$0] / Float(Self.sampleCount) })
                }
                if let tail {
                    let match = DuetOverlap.match(previous: tail, current: voices)
                    if match.swap { voices.swapAt(0, 1) }
                    if match.uncertain { uncertain.append(Double(start) / Self.sampleRate) }
                    DuetOverlap.blend(previous: tail, into: &voices)
                }
                let count = isLast ? usable : usable - Self.overlap
                for source in 0..<2 {
                    writeBuffer.frameLength = AVAudioFrameCount(count)
                    voices[source].withUnsafeBufferPointer { writeBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
                    try writers[source].write(from: writeBuffer)
                }
                progress?(Double(start + usable) / Double(total))
                if isLast { break }
                tail = voices.map { Array($0.suffix(Self.overlap)) }
            }
            try Task.checkCancellation()
            return VocalDuetSeparation(first: first, second: second, uncertainOverlaps: uncertain)
        } catch {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
            throw error
        }
    }

    private func loadModel(at url: URL) throws -> MLModel {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missingModel }
        if let loaded, loaded.url == url { return loaded.model }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        configuration.allowLowPrecisionAccumulationOnGPU = false
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "StarryPlayer/DuetModels/\(Self.modelVersion)-\(key)", directoryHint: .isDirectory)
        let compiled = cache.appending(path: "UNMIXX.mlmodelc", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let temporary = try MLModel.compileModel(at: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            do { try FileManager.default.moveItem(at: temporary, to: compiled) }
            catch {
                // Another editor/test process may have populated the same cache.
                guard FileManager.default.fileExists(atPath: compiled.path) else { throw error }
            }
        }
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        guard model.modelDescription.inputDescriptionsByName["spectrum"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,2,481,2001],
              model.modelDescription.outputDescriptionsByName["separated"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,2,2,481,2001]
        else { throw Failure.invalidModel }
        loaded = (url, model)
        return model
    }
}
