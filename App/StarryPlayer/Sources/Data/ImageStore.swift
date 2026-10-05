import AppKit
import ImageIO

/// Shared image cache: decode and downsample off the main thread, bounded by decoded size.
/// `URLCache` stores compressed responses on disk.
@MainActor
final class ImageStore {
    static let shared = ImageStore()

    static let memoryBudget = 96 << 20

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.name = "moe.mrs4s.starry-player.images"
        cache.totalCostLimit = memoryBudget
        return cache
    }()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 512 << 20)
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = urlCache
        return URLSession(configuration: config)
    }()

    /// Decode into the window's colour space to avoid Core Animation retaining converted copies.
    /// Changing the space clears the memory cache.
    var colorSpace: CGColorSpace? {
        didSet {
            if colorSpace != oldValue { cache.removeAllObjects() }
        }
    }

    var diskUsage: Int { urlCache.currentDiskUsage }

    func clearDiskCache() {
        urlCache.removeAllCachedResponses()
    }

    func image(for url: URL, maxPixelSize: Int? = nil) -> NSImage? { cache.object(forKey: Self.key(url, maxPixelSize) as NSString) }

    /// Loads and decodes `url`. `maxPixelSize` bounds the longer side of the decoded bitmap
    /// (some hosts resize covers themselves; others and local files give the original).
    /// Kept per size step, so a small decode (a sidebar row) never stands in for a large one.
    @discardableResult
    func load(_ url: URL, maxPixelSize: Int? = nil) async -> NSImage? {
        let key = Self.key(url, maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let task = inflight[key] { return await task.value }
        let decodeSize = Self.step(maxPixelSize)
        let task = Task<NSImage?, Never> { [session, colorSpace] in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return await Task.detached(priority: .utility) { Self.decode(data, maxPixelSize: decodeSize, colorSpace: colorSpace) }.value
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image)) }
        return image
    }

    /// Sizes asked for, rounded up to a power of two from 64 px; nil: the original.
    nonisolated static func step(_ maxPixelSize: Int?) -> Int? {
        guard let maxPixelSize, maxPixelSize > 0 else { return nil }
        var side = 64
        while side < maxPixelSize { side *= 2 }
        return side
    }

    nonisolated private static func key(_ url: URL, _ maxPixelSize: Int?) -> String {
        "\(url.absoluteString)#\(step(maxPixelSize).map(String.init) ?? "full")"
    }

    /// ImageIO thumbnail decode: one fully decoded bitmap no larger than `maxPixelSize`, with
    /// orientation applied, in `colorSpace` when given. `NSImage(data:)` would keep the
    /// compressed data and decode the full image lazily on the main thread the first time it is
    /// drawn.
    nonisolated private static func decode(_ data: Data, maxPixelSize: Int?, colorSpace: CGColorSpace?) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize, maxPixelSize > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let cgImage = colorSpace.flatMap { convert(thumbnail, to: $0) } ?? thumbnail
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// ImageIO cannot select a decode colour space; redraw when conversion is needed.
    nonisolated private static func convert(_ image: CGImage, to space: CGColorSpace) -> CGImage? {
        guard image.colorSpace != space, space.model == .rgb else { return image }
        let alpha: CGImageAlphaInfo = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: .noneSkipFirst
        default: .premultipliedFirst
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func cost(of image: NSImage) -> Int {
        max(1, Int(image.size.width * image.size.height) * 4)
    }
}
