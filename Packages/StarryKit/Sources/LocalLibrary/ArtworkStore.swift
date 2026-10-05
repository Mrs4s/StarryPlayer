import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Local artwork: `f:<path>` references folder images; `e:<hash>` identifies
/// embedded images extracted once and deduplicated by content.
public enum ArtworkStore {
    public static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "moe.mrs4s.starry-player/local-artwork", directoryHint: .isDirectory)
    }

    static func url(for coverID: String, directory: URL = defaultDirectory) -> URL? {
        if coverID.hasPrefix("f:") { return URL(fileURLWithPath: String(coverID.dropFirst(2))) }
        if coverID.hasPrefix("e:") { return directory.appending(path: String(coverID.dropFirst(2)) + ".jpg") }
        return nil
    }

    static func folderCoverID(path: String) -> String { "f:" + path }

    private static let largestSide = 1600
    private static let fingerprintLength = 65536

    /// Copies the picture out of `file` when it is not in the cache yet; its cover id, or nil when
    /// it is not an image.
    static func store(_ picture: EmbeddedPicture, of file: URL, directory: URL = defaultDirectory) -> String? {
        guard picture.length > 64 else { return nil }
        let head: Data?
        if let data = picture.data {
            head = data.prefix(fingerprintLength)
        } else if let offset = picture.offset, let reader = FileReader(url: file) {
            head = reader.read(at: offset, count: min(picture.length, fingerprintLength))
        } else {
            head = nil
        }
        guard let head, isImage(head) else { return nil }
        var hasher = SHA256()
        hasher.update(data: withUnsafeBytes(of: Int64(picture.length).bigEndian) { Data($0) })
        hasher.update(data: head)
        let hash = hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
        let id = "e:" + hash
        guard let target = url(for: id, directory: directory) else { return nil }
        if FileManager.default.fileExists(atPath: target.path) { return id }
        guard let bytes = picture.bytes(in: file), isImage(bytes) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let written = (reduced(bytes) ?? bytes)
        do {
            try written.write(to: target, options: .atomic)
            return id
        } catch {
            return nil
        }
    }

    /// The picture as a JPEG no larger than `largestSide`, when it is larger (or not a JPEG).
    private static func reduced(_ bytes: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let isJPEG = bytes.starts(with: [0xFF, 0xD8])
        guard max(width, height) > largestSide || !isJPEG else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: largestSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func isImage(_ head: Data) -> Bool {
        head.starts(with: [0xFF, 0xD8]) || head.starts(with: [0x89, 0x50, 0x4E, 0x47]) || head.starts(with: [0x47, 0x49, 0x46])
            || head.starts(with: [0x42, 0x4D]) || (head.count > 12 && head.hasASCII("RIFF") && head.hasASCII("WEBP", at: 8))
    }

    static func folderCover(among names: [String]) -> String? {
        let images = names.filter { ["jpg", "jpeg", "png", "webp", "gif", "bmp"].contains(($0 as NSString).pathExtension.lowercased()) }
        for stem in ["cover", "folder", "front", "album", "albumart", "albumartsmall"] {
            if let name = images.first(where: { ($0 as NSString).deletingPathExtension.lowercased() == stem }) { return name }
        }
        if let name = images.first(where: { ($0 as NSString).deletingPathExtension.lowercased().hasPrefix("albumart_") }) { return name }
        return images.count == 1 ? images[0] : nil
    }

    public static func clear(directory: URL = defaultDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
