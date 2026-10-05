import AudioToolbox
import AVFoundation
import Foundation
import SystemConfiguration

/// What `starry.app` tells a plugin about the app and the Mac: platforms that sign requests or
/// list devices want the model and the computer's name, and a plugin offers only the formats
/// this macOS plays.
enum PluginEnvironment {
    /// `26.0.1`.
    static let osVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }()

    static let arch: String = {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1 ? "arm64" : "x86_64"
    }()

    static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let name = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? "Mac" : name
    }()

    static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    /// The containers and codecs this macOS plays: always mp3, aac, alac, flac, wav, aiff and
    /// mp4; `ogg` (Vorbis and Opus) where AVFoundation reads it (macOS 26); `eac3` where the
    /// system has an E-AC-3 decoder (Dolby Atmos).
    static let formats: [String] = {
        var formats = ["mp3", "aac", "alac", "flac", "wav", "aiff", "mp4"]
        if AVURLAsset.audiovisualTypes().contains(AVFileType("org.xiph.ogg-audio")) { formats.append("ogg") }
        var spec = kAudioFormatEnhancedAC3
        var size: UInt32 = 0
        if AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, UInt32(MemoryLayout<UInt32>.size), &spec, &size) == noErr, size > 0 { formats.append("eac3") }
        return formats
    }()

    static func app(version: String) -> [String: Any] {
        ["version": version, "platform": "macOS", "osVersion": osVersion, "arch": arch, "model": model, "deviceName": deviceName, "formats": formats]
    }
}
