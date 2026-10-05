import Foundation

public struct VocalSeparationModel: Sendable, Equatable {
    public enum Output: Sendable, Equatable {
        case accompaniment
        case voice
    }

    public enum Source: Sendable, Equatable {
        /// `kAUSoundIsolationSoundType_HighQualityVoice`, available on every Mac since macOS 15.
        case systemVoice
        /// Private AU properties: 30000 = model plist path, 40000 = model base directory.
        case directory(URL, plist: URL)
    }

    public var source: Source
    public var output: Output
    public var name: String
    /// Channel count the network takes (directory models). The AU resamples on its own, so the
    /// sample rate is informational.
    public var channels: Int?
    public var sampleRate: Double?
    /// What the network leaves of the voice, which shapes the level curve; nil when unmeasured.
    public var residual: VocalResidual?

    public init(source: Source, output: Output, name: String, channels: Int? = nil, sampleRate: Double? = nil, residual: VocalResidual? = nil) {
        self.source = source
        self.output = output
        self.name = name
        self.channels = channels
        self.sampleRate = sampleRate
        self.residual = residual
    }

    public static let systemVoice = VocalSeparationModel(source: .systemVoice, output: .voice, name: "系统人声隔离", residual: .systemVoice)

    public var isSideLoaded: Bool {
        if case .directory = source { return true }
        return false
    }

    public var directory: URL? {
        if case .directory(let url, _) = source { return url }
        return nil
    }

    public func accepts(channelCount: Int) -> Bool {
        if let channels { return channels == channelCount }
        return (1...2).contains(channelCount)
    }
}

public enum VocalSeparationModelLocator {
    public static func defaultDirectory(in dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "Models/VocalAttenuation", directoryHint: .isDirectory)
    }

    public static func locate(in directories: [URL], bundle: Bundle = .main) -> VocalSeparationModel {
        for directory in directories {
            if let model = model(at: directory) ?? newestModel(under: directory) { return model }
        }
        return bundledModel(in: bundle) ?? .systemVoice
    }

    public static func bundledModel(in bundle: Bundle) -> VocalSeparationModel? {
        guard let folder = bundle.url(forResource: "Models", withExtension: nil),
              let directories = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        return directories.sorted { $0.lastPathComponent < $1.lastPathComponent }.lazy.compactMap(model(at:)).first
    }

    public static func model(at directory: URL) -> VocalSeparationModel? {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for plist in files.filter({ $0.pathExtension == "plist" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: plist),
                  let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let net = dict["ModelNetPath"] as? String, !net.isEmpty
            else { continue }
            // `ModelNetPath` is relative to `ModelNetPathBase`, overridden by property 40000.
            guard fileManager.fileExists(atPath: directory.appending(path: net).path) else { continue }
            let inputs = (dict["NumberOfInputChannels"] as? NSNumber)?.intValue ?? 1
            let outputs = (dict["NumberOfOutputChannels"] as? NSNumber)?.intValue ?? inputs
            guard inputs == outputs, (1...2).contains(inputs) else { continue }
            // Music models isolate the accompaniment; a voice model can say so here.
            let output: VocalSeparationModel.Output = (dict["StarryWetOutput"] as? String) == "voice" ? .voice : .accompaniment
            let taskID = (dict["TaskID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let residual = ((dict["StarryResidualDecibels"] as? NSNumber)?.doubleValue).map { decibels in
                VocalResidual(decibels: decibels, correlation: (dict["StarryResidualCorrelation"] as? NSNumber)?.doubleValue ?? pow(10, decibels / 20) / 2)
            }
            return VocalSeparationModel(
                source: .directory(directory, plist: plist),
                output: output,
                name: taskID ?? directory.lastPathComponent,
                channels: inputs,
                sampleRate: (dict["SampleRate"] as? NSNumber)?.doubleValue,
                residual: residual
            )
        }
        return nil
    }

    private static func newestModel(under folder: URL) -> VocalSeparationModel? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else { return nil }
        let directories = entries.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        for (url, _) in directories.sorted(by: { $0.1 > $1.1 }) {
            if let model = model(at: url) { return model }
        }
        return nil
    }
}
