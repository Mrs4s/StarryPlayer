import CryptoKit
import Foundation

public enum LyricsAIBackend: String, CaseIterable, Sendable, Codable {
    case neuralEngine, gpu, cpu

    public var title: String {
        switch self {
        case .neuralEngine: "Neural Engine"
        case .gpu: "GPU"
        case .cpu: "CPU"
        }
    }
}

public struct LyricsAIProgress: Sendable {
    public var fraction: Double
    public var message: String

    public init(_ fraction: Double, _ message: String) {
        self.fraction = min(max(fraction, 0), 1)
        self.message = message
    }
}

public enum LyricsAIError: Error, LocalizedError, Sendable {
    case invalidModel(String)
    case unsupportedSystem
    case noLyrics
    case unreadable(String)
    case invalidAudio
    case tooLarge
    case alignment(String)
    case busy

    public var errorDescription: String? {
        switch self {
        case .invalidModel(let reason): "模型不可用：\(reason)"
        case .unsupportedSystem: "AI 打轴需要 macOS 15 或更新版本。"
        case .noLyrics: "没有可打轴的主歌词，请先导入歌词。"
        case .unreadable(let text): "无法读取「\(text)」的发音，请为它补充假名注音后重试。"
        case .invalidAudio: "音频无法分析，请重新载入或准备人声。"
        case .tooLarge: "这份音频和歌词超出整首对齐的处理范围，请缩短音频或分段处理。"
        case .alignment(let reason): "AI 打轴未完成：\(reason)"
        case .busy: "上一项 AI 打轴任务正在结束，请稍后重试。"
        }
    }
}

public struct LyricsAIModelBundle: Sendable {
    public let directory: URL
    public let model: URL
    public let metadata: URL
    public let vocabulary: [String: Int]
    public let melFilters: [Float]
    public let hann: [Float]
    public let englishReadings: [String: String]

    public var name: String { model.deletingPathExtension().lastPathComponent }

    public static func load(from selected: URL) throws -> Self {
        let selected = selected.standardizedFileURL.resolvingSymlinksInPath()
        let isModel = ["mlpackage", "mlmodelc"].contains(selected.pathExtension.lowercased())
        let root = isModel ? selected.deletingLastPathComponent() : selected
        let metadata = root.appendingPathComponent("metadata", isDirectory: true)
        let runtime = try boundedData(metadata.appendingPathComponent("runtime.json"), limit: 1_048_576)
        let contract: Contract
        do { contract = try JSONDecoder().decode(Contract.self, from: runtime) }
        catch { throw LyricsAIError.invalidModel("metadata/runtime.json 格式不正确") }
        guard contract.inputs["mel"]?.shape == [1, 128, 3000],
              contract.inputs["valid_frames"]?.shape == [1],
              contract.outputs["logits"]?.shape == [1, 1500, 122],
              contract.outputs["logits"]?.blankID == 121,
              contract.outputs["sustain_logits"]?.shape == [1, 1500, 8],
              contract.preprocessing.sampleRate == 16000 else {
            throw LyricsAIError.invalidModel("模型接口与此版本的歌词编辑器不兼容")
        }
        guard !contract.model.isEmpty, !contract.model.contains("/"), !contract.model.contains("\\"),
              ![".", ".."].contains(contract.model) else {
            throw LyricsAIError.invalidModel("模型文件名无效")
        }
        var model = isModel ? selected : root.appendingPathComponent(contract.model, isDirectory: true)
        if !FileManager.default.fileExists(atPath: model.path), !isModel {
            model = model.deletingPathExtension().appendingPathExtension("mlmodelc")
        }
        guard ["mlpackage", "mlmodelc"].contains(model.pathExtension.lowercased()),
              (try? model.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw LyricsAIError.invalidModel("文件夹内没有对应的 .mlpackage 或 .mlmodelc 模型")
        }
        let vocabData = try boundedData(metadata.appendingPathComponent("vocab.json"), limit: 262_144)
        guard let vocabulary = try? JSONDecoder().decode([String: Int].self, from: vocabData),
              vocabulary.count == 122, Set(vocabulary.values) == Set(0..<122),
              vocabulary["[PAD]"] == 121 else {
            throw LyricsAIError.invalidModel("metadata/vocab.json 词表不兼容")
        }
        let filters = try floats(metadata.appendingPathComponent("mel-filters.f32"), count: 201 * 128)
        let hann = try floats(metadata.appendingPathComponent("hann-400.f32"), count: 400)
        guard filters.allSatisfy({ $0 >= 0 }), filters.contains(where: { $0 > 0 }),
              hann.allSatisfy({ $0 >= 0 && $0 <= 1 }), hann.contains(where: { $0 > 0 }) else {
            throw LyricsAIError.invalidModel("声谱参数无效")
        }
        let dictionary = metadata.appendingPathComponent("english-readings.json")
        let readings: [String: String]
        if FileManager.default.fileExists(atPath: dictionary.path) {
            let data = try boundedData(dictionary, limit: 16 * 1_048_576)
            guard let value = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw LyricsAIError.invalidModel("英文读音词典格式不正确")
            }
            readings = value
        } else {
            readings = [:]
        }
        return Self(directory: root, model: model, metadata: metadata, vocabulary: vocabulary,
                    melFilters: filters, hann: hann, englishReadings: readings)
    }

    /// Hash model contents only when file sizes or modification dates change.
    func stamp() throws -> String {
        let files = try resourceFiles()
        return try files.map { file in
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(file.path):\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\n")
    }

    func fingerprint() throws -> String {
        var hash = SHA256()
        for file in try resourceFiles() {
            try Task.checkCancellation()
            hash.update(data: Data(file.path.replacingOccurrences(of: directory.path, with: "").utf8))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func resourceFiles() throws -> [URL] {
        var files: [URL] = []
        for root in [model, metadata] {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                throw LyricsAIError.invalidModel("无法读取模型文件夹")
            }
            for case let file as URL in entries {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(file) }
            }
        }
        guard !files.isEmpty else { throw LyricsAIError.invalidModel("模型文件夹为空") }
        return files.sorted { $0.path < $1.path }
    }

    private static func boundedData(_ url: URL, limit: Int) throws -> Data {
        guard let length = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              length > 0, length <= limit else {
            throw LyricsAIError.invalidModel("缺少或无法读取 metadata/\(url.lastPathComponent)，请选择完整的模型文件夹")
        }
        do { return try Data(contentsOf: url) }
        catch { throw LyricsAIError.invalidModel("无法读取 metadata/\(url.lastPathComponent)") }
    }

    private static func floats(_ url: URL, count: Int) throws -> [Float] {
        let data = try boundedData(url, limit: count * 4)
        guard data.count == count * 4 else { throw LyricsAIError.invalidModel("\(url.lastPathComponent) 长度不正确") }
        let values = data.withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        guard values.allSatisfy(\.isFinite) else { throw LyricsAIError.invalidModel("\(url.lastPathComponent) 含无效数值") }
        return values
    }

    private struct Contract: Decodable {
        var model: String
        var inputs: [String: Tensor]
        var outputs: [String: Tensor]
        var preprocessing: Preprocessing
        struct Tensor: Decodable {
            var shape: [Int]
            var blankID: Int?
            enum CodingKeys: String, CodingKey { case shape; case blankID = "blank_id" }
        }
        struct Preprocessing: Decodable {
            var sampleRate: Int
            enum CodingKeys: String, CodingKey { case sampleRate = "sample_rate" }
        }
    }
}
