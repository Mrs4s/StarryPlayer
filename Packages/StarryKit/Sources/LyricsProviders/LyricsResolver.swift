import Foundation
import LyricsCore
import MusicSources
import os
import StarryCore

public struct LyricsResolverOptions: Sendable, Equatable {
    /// The song's own platform is asked first (for a song from a self-hosted server or a local
    /// file, its own source); off, `providerOrder` alone decides and the song's own source, when
    /// it is no platform, comes last.
    public var preferTrackPlatform = true
    public var providerOrder: [LyricsProviderID] = [.qqmusic, .kugou, .netease]
    /// Ask every platform at once instead of one after another: faster, more requests, the same
    /// choice.
    public var raceProviders = false
    /// AMLL TTML DB URL template; nil turns it off. What it has for a song wins over every platform.
    public var ttmlDatabase: String? = AMLLDatabase.defaultTemplate
    /// Folder of TTML files that wins over everything; nil turns it off.
    public var localRepository: URL?
    public var stripCredits = true

    public init() {}
}

public enum LyricsOrigin: Sendable, Hashable {
    case provider(LyricsProviderID)
    case trackSource(String)
    case ttmlDatabase
    case localRepository
    case pickedSong(LyricsProviderID)
    case file(String)

    public var displayName: String {
        switch self {
        case .provider(let id), .pickedSong(let id): id.displayName
        case .trackSource(let name): name
        case .ttmlDatabase: "AMLL TTML DB"
        case .localRepository: "本地 TTML 歌词库"
        case .file: "歌词文件"
        }
    }
}

public struct ResolvedLyrics: Sendable {
    public var document: LyricsDocument
    public var origin: LyricsOrigin

    public init(document: LyricsDocument, origin: LyricsOrigin) {
        self.document = document
        self.origin = origin
    }
}

public final class LyricsResolver: Sendable {
    private let providers: [LyricsProviderID: any LyricsProvider]
    public let providerIDs: [LyricsProviderID]
    private let trackSource: TrackSourceLyricsProvider?
    private let database: AMLLDatabase
    private let repository: LocalTTMLRepository
    private let cache: LyricsCache
    private let logger = Logger(subsystem: "moe.mrs4s.starry-player", category: "lyrics")

    public init(providers: [any LyricsProvider], trackSource: TrackSourceLyricsProvider?, database: AMLLDatabase, repository: LocalTTMLRepository = LocalTTMLRepository(), cache: LyricsCache) {
        self.providers = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        providerIDs = providers.map(\.id).uniqued()
        self.trackSource = trackSource
        self.database = database
        self.repository = repository
        self.cache = cache
    }

    public func detail(of id: LyricsProviderID) -> String? {
        providers[id]?.detail
    }

    /// `providers` (the plugins'), the AMLL TTML DB
    /// and the local TTML folder; `lookup` finds a track's own source for `trackSource`.
    public static func standard(cache: LyricsCache = LyricsCache(), providers: [any LyricsProvider] = [], lookup: @escaping @Sendable (SourceID) async -> (any MusicSource)?) -> LyricsResolver {
        LyricsResolver(
            providers: providers,
            trackSource: TrackSourceLyricsProvider(lookup: lookup),
            database: AMLLDatabase(cache: cache),
            cache: cache
        )
    }

    public func resolve(_ track: Track, options: LyricsResolverOptions) -> AsyncStream<ResolvedLyrics> {
        AsyncStream { continuation in
            let task = Task {
                var run = Run(resolver: self, track: track, options: options) { continuation.yield($0) }
                await run.start()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The best result `resolve` would end with (prefetching, tests).
    public func bestLyrics(for track: Track, options: LyricsResolverOptions) async -> ResolvedLyrics? {
        var last: ResolvedLyrics?
        for await result in resolve(track, options: options) { last = result }
        return last
    }

    enum Step: Sendable, Hashable {
        case provider(LyricsProviderID)
        case trackSource

        var candidateSource: LyricsCandidateSource {
            switch self {
            case .provider(let id): .provider(id)
            case .trackSource: .trackSource
            }
        }
    }

    struct Found: Sendable {
        var document: LyricsDocument
        var origin: LyricsOrigin
        var raw: RawLyrics
        var provider: LyricsProviderID?
        var song: LyricsSongRef?

        var isWordTimed: Bool { document.hasSyllables }
    }

    /// AMLL TTML DB ids by folder, in the order they are to be tried.
    struct TTMLIDs: Sendable {
        private(set) var folders: [(folder: String, ids: [String])] = []

        var isEmpty: Bool { folders.isEmpty }

        mutating func add(_ ids: [String], in folder: String) {
            let ids = ids.filter { !$0.isEmpty }
            guard !ids.isEmpty else { return }
            if let index = folders.firstIndex(where: { $0.folder == folder }) {
                folders[index].ids = (folders[index].ids + ids).uniqued()
            } else {
                folders.append((folder, ids.uniqued()))
            }
        }
    }

    func steps(for track: Track, options: LyricsResolverOptions) -> [Step] {
        var steps: [Step] = options.providerOrder.filter { providerAvailable($0) }.uniqued().map { .provider($0) }
        if let own = ownProvider(of: track) {
            if options.preferTrackPlatform, let index = steps.firstIndex(of: .provider(own)) {
                steps.insert(steps.remove(at: index), at: 0)
            }
        } else if trackSourceAvailable {
            if options.preferTrackPlatform { steps.insert(.trackSource, at: 0) } else { steps.append(.trackSource) }
        }
        return steps
    }

    fileprivate func fetch(_ step: Step, track: Track, options: LyricsResolverOptions) async -> Found? {
        do {
            switch step {
            case .provider(let id):
                guard let provider = providers[id], let result = try await provider.lyrics(for: track),
                      let document = document(from: result.raw, track: track, options: options) else { return nil }
                return Found(document: document, origin: .provider(id), raw: result.raw, provider: id, song: result.song)
            case .trackSource:
                guard let trackSource, let raw = try await trackSource.lyrics(for: track),
                      let document = document(from: raw, track: track, options: options) else { return nil }
                return Found(document: document, origin: .trackSource(raw.providerName), raw: raw)
            }
        } catch {
            logger.info("lyrics \(String(describing: step), privacy: .public) failed for \(track.id.description, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Parsed, credit-stripped and non-empty, or nil. A body whose declared format does not
    /// parse is retried with the detected one.
    func document(from raw: RawLyrics, track: Track, options: LyricsResolverOptions) -> LyricsDocument? {
        let declared = LyricsDocument.Format(rawValue: raw.format.rawValue) ?? .lrc
        var document = try? LyricsParsing.parse(raw.body, format: declared, translation: raw.translation, romanization: raw.romanization)
        if document?.isEmpty ?? true {
            let detected = LyricsFormatDetector.detect(raw.body)
            if detected != declared {
                document = try? LyricsParsing.parse(raw.body, format: detected, translation: raw.translation, romanization: raw.romanization)
            }
        }
        guard var document, !document.isEmpty else { return nil }
        if options.stripCredits {
            document = LyricsCreditStripper.strip(document, title: track.title, artists: track.artists.map(\.name))
        }
        return document.isEmpty ? nil : document
    }

    fileprivate func localTTML(for track: Track, in directory: URL) async -> LyricsDocument? {
        let folder = LyricsProviderID(source: track.id.source).flatMap { providers[$0]?.ttmlFolder }
        guard let text = await repository.ttml(for: track, folder: folder, in: directory),
              let document = try? TTMLParser.parse(text), !document.isEmpty else { return nil }
        return document
    }

    fileprivate func ttmlIDs(for track: Track, found: Found?) async -> TTMLIDs {
        var ids = TTMLIDs()
        for key in track.ttml ?? [] { ids.add([key.id], in: key.folder) }
        if let own = LyricsProviderID(source: track.id.source), let folder = providers[own]?.ttmlFolder {
            ids.add([track.id.id], in: folder)
        }
        if let found, let song = found.song, let provider = found.provider, let folder = providers[provider]?.ttmlFolder {
            ids.add([song.mid, song.id].compactMap { $0 }, in: folder)
        }
        let fingerprint = LyricCandidateMatcher.fingerprint(for: LyricQuery(track: track))
        for id in providerIDs {
            guard let folder = providers[id]?.ttmlFolder, let match = await cache.storedMatch(provider: id, fingerprint: fingerprint) else { continue }
            ids.add([match.mid, match.id].compactMap { $0 }, in: folder)
        }
        return ids
    }

    fileprivate func ttml(template: String, ids: TTMLIDs) async -> String? {
        for (folder, list) in ids.folders {
            if let text = await database.ttml(template: template, folder: folder, ids: list) { return text }
        }
        return nil
    }

    fileprivate func storedTTML(template: String, ids: TTMLIDs) async -> String? {
        for (folder, list) in ids.folders {
            if let text = await database.storedTTML(template: template, folder: folder, ids: list) { return text }
        }
        return nil
    }

    fileprivate func ttmlDocument(_ text: String, borrowing found: Found?) -> LyricsDocument? {
        guard var document = try? TTMLParser.parse(text), !document.isEmpty else { return nil }
        if let raw = found?.raw {
            let translation = document.hasTranslation ? nil : raw.translation
            let romanization = document.hasRomanization ? nil : raw.romanization
            LyricsParsing.attach(translation: translation, romanization: romanization, to: &document)
            if let parsed = found?.document, translation == nil, !document.hasTranslation, parsed.hasTranslation {
                LyricsParsing.attach(translation: Self.lrc(parsed, \.translation), romanization: nil, to: &document)
            }
        }
        return document
    }

    private static func lrc(_ document: LyricsDocument, _ field: KeyPath<LyricLine, String?>) -> String {
        document.lines.compactMap { line in
            line[keyPath: field].map { text in
                let centiseconds = Int((line.start * 100).rounded())
                return String(format: "[%02d:%02d.%02d]%@", centiseconds / 6000, centiseconds / 100 % 60, centiseconds % 100, text)
            }
        }.joined(separator: "\n")
    }
}

public enum LyricsCandidateSource: Sendable, Hashable, Identifiable {
    case localRepository
    case ttmlDatabase
    /// The track's own source, when it is not one of the providers.
    case trackSource
    case provider(LyricsProviderID)

    /// nil for lyrics picked by hand, which come from no source in the list.
    public init?(origin: LyricsOrigin) {
        switch origin {
        case .provider(let id): self = .provider(id)
        case .trackSource: self = .trackSource
        case .ttmlDatabase: self = .ttmlDatabase
        case .localRepository: self = .localRepository
        case .pickedSong, .file: return nil
        }
    }

    public var key: String {
        switch self {
        case .localRepository: "local"
        case .ttmlDatabase: "ttml"
        case .trackSource: "track"
        case .provider(let id): "provider:\(id.rawValue)"
        }
    }

    public init?(key: String) {
        switch key {
        case "local": self = .localRepository
        case "ttml": self = .ttmlDatabase
        case "track": self = .trackSource
        default:
            guard key.hasPrefix("provider:"), let id = LyricsProviderID(rawValue: String(key.dropFirst("provider:".count))) else { return nil }
            self = .provider(id)
        }
    }

    public var id: String { key }

    public var displayName: String {
        switch self {
        case .localRepository: LyricsOrigin.localRepository.displayName
        case .ttmlDatabase: LyricsOrigin.ttmlDatabase.displayName
        case .trackSource: "歌曲来源"
        case .provider(let id): id.displayName
        }
    }
}

/// One source's answer for a track: its lyrics, or nil when it has none.
public struct LyricsCandidate: Sendable {
    public var source: LyricsCandidateSource
    public var lyrics: ResolvedLyrics?

    public init(source: LyricsCandidateSource, lyrics: ResolvedLyrics?) {
        self.source = source
        self.lyrics = lyrics
    }
}

public extension LyricsResolver {
    /// Where the picker looks for `track`, in the order it lists them: the local TTML folder and
    /// the AMLL TTML DB when they are on, then the platforms in priority order, the song's own
    /// platform among them even when it is off in the order.
    func candidateSources(for track: Track, options: LyricsResolverOptions) -> [LyricsCandidateSource] {
        var sources: [LyricsCandidateSource] = []
        if options.localRepository != nil { sources.append(.localRepository) }
        if options.ttmlDatabase != nil { sources.append(.ttmlDatabase) }
        var steps = steps(for: track, options: options)
        if let own = ownProvider(of: track), !steps.contains(.provider(own)) { steps.insert(.provider(own), at: 0) }
        return sources + steps.map(\.candidateSource)
    }

    /// Every source's lyrics for `track`, each as soon as it answers — none skipped and nothing
    /// ranked, so the picker can show them all. The TTML DB answers last: it is asked with the
    /// ids every provider matched, and a TTML without translation borrows the best provider's.
    func candidates(for track: Track, options: LyricsResolverOptions) -> AsyncStream<LyricsCandidate> {
        AsyncStream { continuation in
            let task = Task {
                let sources = candidateSources(for: track, options: options)
                let found: [Found] = await withTaskGroup(of: (LyricsCandidateSource, ResolvedLyrics?, Found?).self) { group in
                    for source in sources {
                        switch source {
                        case .localRepository:
                            guard let directory = options.localRepository else { continue }
                            group.addTask {
                                let document = await self.localTTML(for: track, in: directory)
                                return (source, document.map { ResolvedLyrics(document: $0, origin: .localRepository) }, nil)
                            }
                        case .ttmlDatabase:
                            continue
                        case .trackSource:
                            group.addTask {
                                let found = await self.fetch(.trackSource, track: track, options: options)
                                return (source, found.map { ResolvedLyrics(document: $0.document, origin: $0.origin) }, found)
                            }
                        case .provider(let id):
                            group.addTask {
                                let found = await self.fetch(.provider(id), track: track, options: options)
                                return (source, found.map { ResolvedLyrics(document: $0.document, origin: $0.origin) }, found)
                            }
                        }
                    }
                    var all: [(LyricsCandidateSource, Found)] = []
                    for await (source, lyrics, found) in group {
                        continuation.yield(LyricsCandidate(source: source, lyrics: lyrics))
                        if let found { all.append((source, found)) }
                    }
                    return all.sorted { (sources.firstIndex(of: $0.0) ?? 0) < (sources.firstIndex(of: $1.0) ?? 0) }.map(\.1)
                }
                if sources.contains(.ttmlDatabase), let template = options.ttmlDatabase, !Task.isCancelled {
                    let lyrics = await ttmlLyrics(for: track, template: template, found: found)
                    continuation.yield(LyricsCandidate(source: .ttmlDatabase, lyrics: lyrics))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Lyrics from `source` alone (a song pinned to it), or nil when it has none.
    func lyrics(for track: Track, from source: LyricsCandidateSource, options: LyricsResolverOptions) async -> ResolvedLyrics? {
        switch source {
        case .localRepository:
            guard let directory = options.localRepository else { return nil }
            return await localTTML(for: track, in: directory).map { ResolvedLyrics(document: $0, origin: .localRepository) }
        case .trackSource:
            return await fetch(.trackSource, track: track, options: options).map { ResolvedLyrics(document: $0.document, origin: $0.origin) }
        case .provider(let id):
            return await fetch(.provider(id), track: track, options: options).map { ResolvedLyrics(document: $0.document, origin: $0.origin) }
        case .ttmlDatabase:
            guard let template = options.ttmlDatabase else { return nil }
            var found: [Found] = []
            for step in steps(for: track, options: options) {
                if let hit = await fetch(step, track: track, options: options) {
                    found.append(hit)
                    break
                }
            }
            return await ttmlLyrics(for: track, template: template, found: found)
        }
    }
}

public extension LyricsResolver {
    func searchProviders(options: LyricsResolverOptions) -> [LyricsProviderID] {
        (options.providerOrder + LyricsResolverOptions().providerOrder + providerIDs).uniqued().filter { providerAvailable($0) }
    }

    func searchSongs(_ keyword: String, options: LyricsResolverOptions) -> AsyncStream<LyricsSearchAnswer> {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let providers = keyword.isEmpty ? [] : searchProviders(options: options).compactMap { self.providers[$0] }
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: LyricsSearchAnswer.self) { group in
                    for provider in providers {
                        group.addTask {
                            do {
                                return LyricsSearchAnswer(provider: provider.id, results: try await provider.searchSongs(keyword))
                            } catch {
                                self.logger.info("lyrics search on \(provider.id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                                return LyricsSearchAnswer(provider: provider.id, results: nil)
                            }
                        }
                    }
                    for await answer in group { continuation.yield(answer) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The lyrics of a song picked from a search, prepared like any other, or nil when it has
    /// none. Throws when the provider cannot be reached.
    func lyrics(of result: LyricsSearchResult, for track: Track, options: LyricsResolverOptions) async throws -> ResolvedLyrics? {
        guard let provider = providers[result.provider], let raw = try await provider.lyrics(of: result.song),
              let document = document(from: raw, track: track, options: options) else { return nil }
        return ResolvedLyrics(document: document, origin: .pickedSong(result.provider))
    }

    /// A lyric file read as its extension says, or as it looks when that does not parse; nil
    /// when it holds no timed lyrics.
    func lyrics(from file: LyricsFile, for track: Track, options: LyricsResolverOptions) -> ResolvedLyrics? {
        let format = file.declaredFormat ?? LyricsFormatDetector.detect(file.text)
        let raw = RawLyrics(format: RawLyrics.Format(rawValue: format.rawValue) ?? .lrc, body: file.text, providerName: file.name)
        return document(from: raw, track: track, options: options).map { ResolvedLyrics(document: $0, origin: .file(file.name)) }
    }

    /// Lyrics for a song pinned in the picker, or nil when the pin gives none.
    func lyrics(for track: Track, pinnedTo pin: LyricsPin, options: LyricsResolverOptions) async -> ResolvedLyrics? {
        switch pin {
        case .source(let source):
            return await lyrics(for: track, from: source, options: options)
        case .song(let result):
            do {
                return try await lyrics(of: result, for: track, options: options)
            } catch {
                logger.info("pinned lyrics \(result.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        case .file(let file):
            return lyrics(from: file, for: track, options: options)
        }
    }
}

extension LyricsResolver {
    fileprivate var trackSourceAvailable: Bool { trackSource != nil }

    fileprivate func providerAvailable(_ id: LyricsProviderID) -> Bool { providers[id] != nil }

    fileprivate func ownProvider(of track: Track) -> LyricsProviderID? {
        LyricsProviderID(source: track.id.source).flatMap { providerAvailable($0) ? $0 : nil }
    }

    fileprivate func ttmlLyrics(for track: Track, template: String, found: [Found]) async -> ResolvedLyrics? {
        var ids = TTMLIDs()
        for more in [await ttmlIDs(for: track, found: nil)] + (await found.asyncMap { await self.ttmlIDs(for: track, found: $0) }) {
            for (folder, list) in more.folders { ids.add(list, in: folder) }
        }
        guard !ids.isEmpty, let text = await ttml(template: template, ids: ids) else { return nil }
        let lender = found.first { $0.document.hasTranslation } ?? found.first
        return ttmlDocument(text, borrowing: lender).map { ResolvedLyrics(document: $0, origin: .ttmlDatabase) }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self { result.append(await transform(element)) }
        return result
    }
}

private struct Run {
    enum Tier: Int, Comparable {
        case ttml, wordTimed, lineTimed

        init(_ found: LyricsResolver.Found) {
            self = found.isWordTimed ? .wordTimed : .lineTimed
        }

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    let resolver: LyricsResolver
    let track: Track
    let options: LyricsResolverOptions
    let emit: @Sendable (ResolvedLyrics) -> Void

    private var shown: Tier?
    private var ownTTMLIDs = LyricsResolver.TTMLIDs()
    private var early: Task<String?, Never>?
    private let earlyAnswer = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(resolver: LyricsResolver, track: Track, options: LyricsResolverOptions, emit: @escaping @Sendable (ResolvedLyrics) -> Void) {
        self.resolver = resolver
        self.track = track
        self.options = options
        self.emit = emit
    }

    private var ttmlShown: Bool { shown == .ttml }

    @discardableResult
    private mutating func offer(_ document: LyricsDocument, _ origin: LyricsOrigin, _ tier: Tier) -> Bool {
        guard shown.map({ tier < $0 }) ?? true, !Task.isCancelled else { return false }
        shown = tier
        emit(ResolvedLyrics(document: document, origin: origin))
        return true
    }

    mutating func start() async {
        if let directory = options.localRepository, let document = await resolver.localTTML(for: track, in: directory) {
            offer(document, .localRepository, .ttml)
            return
        }
        guard !Task.isCancelled else { return }

        if let template = options.ttmlDatabase {
            let ownIDs = await resolver.ttmlIDs(for: track, found: nil)
            ownTTMLIDs = ownIDs
            if !ownIDs.isEmpty {
                early = Task { [resolver, earlyAnswer] in
                    let text = await resolver.ttml(template: template, ids: ownIDs)
                    earlyAnswer.withLock { $0 = text }
                    return text
                }
            }
        }

        let chosen = await walk()

        if let template = options.ttmlDatabase, !ttmlShown, !Task.isCancelled {
            var text = await early?.value
            if text == nil {
                text = await resolver.ttml(template: template, ids: await resolver.ttmlIDs(for: track, found: chosen))
            }
            if let text, let document = resolver.ttmlDocument(text, borrowing: chosen) {
                offer(document, .ttmlDatabase, .ttml)
            }
        }
        early?.cancel()
    }

    private mutating func walk() async -> LyricsResolver.Found? {
        let (resolver, track, options) = (resolver, track, options)
        let steps = resolver.steps(for: track, options: options)
        let prefetched = options.raceProviders ? steps.map { step in Task { await resolver.fetch(step, track: track, options: options) } } : []
        defer { prefetched.forEach { $0.cancel() } }
        var chosen: LyricsResolver.Found?
        for (index, step) in steps.enumerated() {
            guard !Task.isCancelled else { break }
            let answer: LyricsResolver.Found?
            if prefetched.isEmpty {
                answer = await resolver.fetch(step, track: track, options: options)
            } else {
                let task = prefetched[index]
                answer = await withTaskCancellationHandler { await task.value } onCancel: { prefetched.forEach { $0.cancel() } }
            }
            guard let found = answer else { continue }
            if chosen.map({ found.isWordTimed && !$0.isWordTimed }) ?? true {
                chosen = found
                await show(found)
            }
            if ttmlShown || found.isWordTimed { break }
        }
        return chosen
    }

    /// Shows a platform's lyrics, unless the AMLL TTML for the song is at hand already (stored on
    /// disk, or the early lookup has answered): then that is shown instead, borrowing the
    /// platform's translation, rather than flashing the platform's lyrics first.
    private mutating func show(_ found: LyricsResolver.Found) async {
        if !ttmlShown, let template = options.ttmlDatabase {
            var text = earlyAnswer.withLock { $0 }
            if text == nil, shown == nil { text = await resolver.storedTTML(template: template, ids: ownTTMLIDs) }
            if let text, let document = resolver.ttmlDocument(text, borrowing: found), offer(document, .ttmlDatabase, .ttml) { return }
        }
        offer(found.document, found.origin, Tier(found))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
