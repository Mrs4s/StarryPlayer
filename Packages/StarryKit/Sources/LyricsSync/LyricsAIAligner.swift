import CoreML
import Foundation
import LyricsCore

public struct LyricsAIAlignmentResult: Sendable {
    public var draft: LyricsDraft
    public var alignedLines: Int
    public var alignedSyllables: Int
    public var estimatedReadings: Int
    public var skippedBackgroundLines: Int

    public init(draft: LyricsDraft, alignedLines: Int, alignedSyllables: Int,
                estimatedReadings: Int = 0, skippedBackgroundLines: Int = 0) {
        self.draft = draft
        self.alignedLines = alignedLines
        self.alignedSyllables = alignedSyllables
        self.estimatedReadings = estimatedReadings
        self.skippedBackgroundLines = skippedBackgroundLines
    }
}

/// Keep compiled models at a stable URL so Core ML can reuse its cache.
public actor LyricsAIAligner {
    private struct Loaded {
        var stamp: String
        var identity: String
        var backend: LyricsAIBackend
        var model: MLModel
    }
    private var loaded: Loaded?
    private var cached: (key: String, evidence: LyricsAICTC.Evidence)?
    private var busy = false
    private var releasePending = false
    private let cacheDirectory: URL

    public init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StarryPlayer/LyricsAI/Compiled", isDirectory: true)
    }

    public func releaseWhenIdle() {
        if busy { releasePending = true }
        else { loaded = nil; cached = nil }
    }

    public func align(_ draft: LyricsDraft, vocals: URL, modelDirectory: URL, backend: LyricsAIBackend,
                      progress: @escaping @Sendable (LyricsAIProgress) -> Void = { _ in }) async throws -> LyricsAIAlignmentResult {
        guard #available(macOS 15, *) else { throw LyricsAIError.unsupportedSystem }
        guard !busy else { throw LyricsAIError.busy }
        busy = true
        defer {
            busy = false
            if releasePending { loaded = nil; cached = nil; releasePending = false }
        }
        let access = modelDirectory.startAccessingSecurityScopedResource()
        defer { if access { modelDirectory.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        progress(.init(0.02, "检查外置模型与歌词读音…"))
        let bundle = try LyricsAIModelBundle.load(from: modelDirectory)
        let plan = try LyricsAIPronunciation.make(draft: draft, vocabulary: bundle.vocabulary, english: bundle.englishReadings)
        let stamp = try bundle.stamp()
        let audioValues = try vocals.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let audioKey = "\(vocals.path):\(audioValues.fileSize ?? -1):\(audioValues.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let key = stamp + backend.rawValue + audioKey
        let evidence: LyricsAICTC.Evidence
        if let cached, cached.key == key {
            evidence = cached.evidence
            progress(.init(0.84, "复用人声分析结果…"))
        } else {
            progress(.init(0.05, "读取人声音频…"))
            let samples = try LyricsAIAudio.read(vocals)
            let frames = (samples.count - 400) / 320 + 1
            let (cells, overflow) = frames.multipliedReportingOverflow(by: 2 * plan.tokens.count + 1)
            guard !overflow, cells <= 160_000_000 else { throw LyricsAIError.tooLarge }
            let model = try await prepare(bundle, stamp: stamp, backend: backend, progress: progress)
            try Task.checkCancellation()
            evidence = try infer(samples, bundle: bundle, model: model, progress: progress)
            try Task.checkCancellation()
            cached = (key, evidence)
        }
        progress(.init(0.85, "定位歌词时间…"))
        let spans = try LyricsAICTC.align(evidence, tokens: plan.tokens) { fraction in
            progress(.init(0.85 + fraction * 0.14, "定位歌词时间…"))
        }
        try Task.checkCancellation()
        guard try bundle.stamp() == stamp else { throw LyricsAIError.invalidModel("模型文件在执行期间发生变化，请重试") }
        let currentAudio = try vocals.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard currentAudio.fileSize == audioValues.fileSize, currentAudio.contentModificationDate == audioValues.contentModificationDate else {
            throw LyricsAIError.alignment("人声音频在执行期间发生变化，请重试")
        }
        let result = try Self.apply(spans, plan: plan, to: draft)
        progress(.init(1, "打轴完成，请预览并试听"))
        return result
    }

    private func prepare(_ bundle: LyricsAIModelBundle, stamp: String, backend: LyricsAIBackend,
                         progress: @escaping @Sendable (LyricsAIProgress) -> Void) async throws -> MLModel {
        if let loaded, loaded.stamp == stamp, loaded.backend == backend { return loaded.model }
        progress(.init(0.09, "校验模型文件…"))
        let identity = loaded?.stamp == stamp ? loaded!.identity : try bundle.fingerprint()
        let compiled: URL
        if bundle.model.pathExtension == "mlmodelc" {
            compiled = bundle.model
        } else {
            let folder = cacheDirectory.appendingPathComponent(identity, isDirectory: true)
            compiled = folder.appendingPathComponent("Alignment.mlmodelc", isDirectory: true)
            if !FileManager.default.fileExists(atPath: compiled.path) {
                progress(.init(0.12, "首次准备模型…"))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let temporary = try await MLModel.compileModel(at: bundle.model)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                let staging = folder.appendingPathComponent(UUID().uuidString + ".mlmodelc", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: temporary, to: staging)
                if !FileManager.default.fileExists(atPath: compiled.path) { try FileManager.default.moveItem(at: staging, to: compiled) }
            }
        }
        try Task.checkCancellation()
        progress(.init(0.17, "加载本地模型…"))
        let configuration = MLModelConfiguration()
        switch backend {
        case .cpu: configuration.computeUnits = .cpuOnly
        case .gpu: configuration.computeUnits = .cpuAndGPU
        case .neuralEngine: configuration.computeUnits = .cpuAndNeuralEngine
        }
        loaded = nil
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        guard inputs["mel"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 128, 3000],
              inputs["valid_frames"]?.multiArrayConstraint?.shape.map(\.intValue) == [1],
              outputs["logits"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 1500, 122],
              outputs["sustain_logits"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 1500, 8] else {
            throw LyricsAIError.invalidModel("Core ML 的实际输入输出与模型说明不一致")
        }
        loaded = Loaded(stamp: stamp, identity: identity, backend: backend, model: model)
        return model
    }

    private func infer(_ samples: [Float], bundle: LyricsAIModelBundle, model: MLModel,
                       progress: @escaping @Sendable (LyricsAIProgress) -> Void) throws -> LyricsAICTC.Evidence {
        let frames = (samples.count - 400) / 320 + 1
        var emission = [Float](); emission.reserveCapacity(frames * 123)
        var sustain = [Float](); sustain.reserveCapacity(frames * 8)
        let windows = (frames + 999) / 1000
        for (window, start) in stride(from: 0, to: frames, by: 1000).enumerated() {
            try Task.checkCancellation()
            progress(.init(0.2 + Double(window) / Double(windows) * 0.64, "分析歌声 \(window + 1)/\(windows)…"))
            let end = min(frames, start + 1000), left = max(0, start - 250), right = min(frames, end + 250)
            let slice = samples[(left * 320)..<((right - 1) * 320 + 400)]
            let mel = try LyricsAIMel.encode(slice, filters: bundle.melFilters, hann: bundle.hann)
            let rows = (start - left)..<(end - left)
            let (wordRows, sustainRows) = try autoreleasepool {
                let input = try MLMultiArray(shape: [1, 128, 3000], dataType: .float32)
                guard input.strides.map(\.intValue) == [384000, 3000, 1] else { throw LyricsAIError.alignment("声谱缓冲区布局无效") }
                mel.withUnsafeBufferPointer { source in
                    input.dataPointer.assumingMemoryBound(to: Float.self).update(from: source.baseAddress!, count: mel.count)
                }
                let valid = try MLMultiArray(shape: [1], dataType: .float32)
                valid[0] = NSNumber(value: Float((min(slice.count, 480000) - 400) / 320 + 1))
                try Task.checkCancellation()
                let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": input, "valid_frames": valid]))
                guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
                      let held = output.featureValue(for: "sustain_logits")?.multiArrayValue else {
                    throw LyricsAIError.alignment("模型没有返回时间对齐所需的结果")
                }
                return try (Self.rows(logits, range: rows, columns: 122), Self.rows(held, range: rows, columns: 8))
            }
            for row in 0..<rows.count {
                let logp = Self.logSoftmax(Array(wordRows[(row * 122)..<((row + 1) * 122)]))
                emission += logp
                emission.append(log1p(-exp(min(logp[121], -1e-6))) - 1) // unreadable-word wildcard
                sustain += Self.logSoftmax(Array(sustainRows[(row * 8)..<((row + 1) * 8)]))
            }
        }
        var levels = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Double = 0
            for i in (frame * 320)..<((frame + 1) * 320) { sum += Double(samples[i]) * Double(samples[i]) }
            levels[frame] = Float(10 * log10(sum / 320 + 1e-12))
        }
        let sorted = levels.sorted(), percentile = Double(frames - 1) * 0.9
        let lo = Int(percentile), hi = min(frames - 1, lo + 1)
        let threshold = sorted[lo] + Float(percentile - Double(lo)) * (sorted[hi] - sorted[lo]) - 30
        return .init(frames: frames, width: 123, blank: 121, logProbabilities: emission,
                     sustain: sustain, silent: levels.map { $0 < threshold }, duration: Double(samples.count) / 16000)
    }

    private static func rows(_ array: MLMultiArray, range: Range<Int>, columns: Int) throws -> [Float] {
        guard array.shape.map(\.intValue) == [1, 1500, columns], array.dataType == .float32,
              array.strides.count == 3, range.lowerBound >= 0, range.upperBound <= 1500 else {
            throw LyricsAIError.alignment("模型输出尺寸无效")
        }
        let strides = array.strides.map(\.intValue)
        let source = array.dataPointer.assumingMemoryBound(to: Float.self)
        var result = [Float](); result.reserveCapacity(range.count * columns)
        for frame in range {
            for column in 0..<columns {
                let value = source[frame * strides[1] + column * strides[2]]
                guard value.isFinite else { throw LyricsAIError.alignment("模型输出包含无效数值，请尝试其他推理设备") }
                result.append(value)
            }
        }
        return result
    }

    private static func logSoftmax(_ values: [Float]) -> [Float] {
        let top = values.max()!
        let sum = values.reduce(Float(0)) { $0 + exp($1 - top) }
        let normalizer = top + log(sum)
        return values.map { $0 - normalizer }
    }
}
