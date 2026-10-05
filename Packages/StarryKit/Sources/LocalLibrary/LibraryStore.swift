import Foundation

public struct LibraryFolder: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var path: String
    public var addedAt: Date
    public var excluded: [String]
    /// The encoding picked for its old tags (nil: decided by vote).
    public var encoding: LegacyEncoding?
    /// Its volume is not mounted or the folder is gone: its songs show as unavailable.
    public var isOffline: Bool
    public var lastScan: Date?
    public var trackCount: Int
    /// Audio files the system cannot play (APE, WavPack, DSD…).
    public var unsupportedCount: Int
    public var missingCount: Int

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct StoredFile: Sendable {
    var id: String
    var rootID: Int64?
    var folderID: Int64?
    var relativePath: String
    var fileID: UInt64?
    var size: Int64
    var modified: Double
    var missingSince: Date?
    var reader: String
    var tags: RawTags
    var audio: AudioProperties
    var isPlayable: Bool
    var hasLyrics: Bool
    var coverID: String?
    var metadataHash: String
}

struct TrackRow: Sendable {
    var id: String
    var path: String
    var title: String
    var artistIDs: [String]
    var artistNames: [String]
    var albumID: String?
    var albumTitle: String?
    var coverID: String?
    var albumCoverID: String?
    var duration: TimeInterval
    var disc: Int?
    var track: Int?
    var codec: String
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?
    var bitrate: Int?
    var size: Int64
    var isPlayable: Bool
    var isAvailable: Bool
    var trackGain: Double?
    var trackPeak: Double?
    var albumGain: Double?
    var albumPeak: Double?
    var playCount: Int
    var addedAt: Date
}

struct AlbumRow: Sendable {
    var id: String
    var title: String
    var artistIDs: [String]
    var artistNames: [String]
    var year: Int?
    var coverID: String?
    var isCompilation: Bool
    var trackCount: Int
    var duration: TimeInterval
    var addedAt: Date
    var genres: [String]
}

struct ArtistRow: Sendable {
    var id: String
    var name: String
    var trackCount: Int
    var albumCount: Int
    var coverID: String?
}

struct PlaylistRow: Sendable {
    var id: String
    var name: String
    var description: String?
    var createdAt: Date
    var updatedAt: Date
    var trackCount: Int
    var coverID: String?
}

struct FolderRecord: Sendable {
    var id: Int64
    var rootID: Int64
    var relativePath: String
    var signature: String
    var encoding: LegacyEncoding?
    var encodingOverride: LegacyEncoding?
    var coverFile: String?
}

actor LibraryStore {
    private let db: SQLiteDatabase
    static let fileName = "local-library.sqlite"

    /// `url` nil: in memory.
    init(url: URL?) throws {
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        db = try SQLiteDatabase(path: url?.path)
        try Self.migrate(db)
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        guard db.userVersion < 1 else { return }
        try db.transaction {
            try db.execute("""
            CREATE TABLE roots(
                id INTEGER PRIMARY KEY, path TEXT NOT NULL, bookmark BLOB, volume_uuid TEXT, added_at REAL NOT NULL,
                excluded TEXT NOT NULL DEFAULT '[]', encoding TEXT, last_event_id INTEGER, last_scan REAL,
                offline INTEGER NOT NULL DEFAULT 0, unsupported_count INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE folders(
                id INTEGER PRIMARY KEY, root_id INTEGER NOT NULL, rel_path TEXT NOT NULL, signature TEXT NOT NULL DEFAULT '',
                encoding TEXT, encoding_override TEXT, cover_file TEXT, scanned_at REAL, UNIQUE(root_id, rel_path));
            CREATE TABLE tracks(
                id TEXT PRIMARY KEY, root_id INTEGER, folder_id INTEGER, rel_path TEXT NOT NULL, file_id INTEGER,
                size INTEGER NOT NULL, mtime REAL NOT NULL, missing_since REAL, reader TEXT NOT NULL, raw TEXT NOT NULL,
                codec TEXT NOT NULL, sample_rate INTEGER, bit_depth INTEGER, channels INTEGER, bitrate INTEGER,
                duration REAL NOT NULL, playable INTEGER NOT NULL, has_lyrics INTEGER NOT NULL, cover_id TEXT, metadata_hash TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '', title_sort TEXT, artist_text TEXT NOT NULL DEFAULT '', album_id TEXT, album_title TEXT,
                album_artist_text TEXT, compilation INTEGER NOT NULL DEFAULT 0, disc INTEGER, disc_total INTEGER, track INTEGER,
                track_total INTEGER, year INTEGER, genres TEXT NOT NULL DEFAULT '', composer TEXT, rg_track_gain REAL,
                rg_track_peak REAL, rg_album_gain REAL, rg_album_peak REAL, mb_track_id TEXT, search_key TEXT NOT NULL DEFAULT '',
                sort_title TEXT NOT NULL DEFAULT '', sort_artist TEXT NOT NULL DEFAULT '', sort_album TEXT NOT NULL DEFAULT '',
                added_at REAL NOT NULL, play_count INTEGER NOT NULL DEFAULT 0, last_played_at REAL,
                UNIQUE(root_id, rel_path));
            CREATE INDEX tracks_folder ON tracks(folder_id);
            CREATE INDEX tracks_album ON tracks(album_id);
            CREATE INDEX tracks_metadata ON tracks(metadata_hash);
            CREATE TABLE track_artists(
                track_id TEXT NOT NULL, role INTEGER NOT NULL, position INTEGER NOT NULL, artist_id TEXT NOT NULL, name TEXT NOT NULL,
                PRIMARY KEY(track_id, role, position));
            CREATE INDEX track_artists_artist ON track_artists(artist_id);
            CREATE TABLE albums(
                id TEXT PRIMARY KEY, title TEXT NOT NULL, artist_ids TEXT NOT NULL, artist_names TEXT NOT NULL, year INTEGER,
                cover_id TEXT, compilation INTEGER NOT NULL, track_count INTEGER NOT NULL, duration REAL NOT NULL,
                added_at REAL NOT NULL, genres TEXT NOT NULL DEFAULT '', search_key TEXT NOT NULL,
                sort_title TEXT NOT NULL DEFAULT '', sort_artist TEXT NOT NULL DEFAULT '');
            CREATE TABLE artists(
                id TEXT PRIMARY KEY, name TEXT NOT NULL, track_count INTEGER NOT NULL, album_count INTEGER NOT NULL,
                cover_id TEXT, search_key TEXT NOT NULL, sort_name TEXT NOT NULL DEFAULT '');
            CREATE TABLE likes(track_id TEXT PRIMARY KEY, liked_at REAL NOT NULL);
            CREATE TABLE playlists(id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE playlist_items(
                playlist_id TEXT NOT NULL, position INTEGER NOT NULL, track_id TEXT NOT NULL, added_at REAL NOT NULL,
                PRIMARY KEY(playlist_id, position));
            """)
            db.userVersion = 1
        }
    }

    func roots() throws -> [LibraryFolder] {
        try db.query("""
        SELECT r.id, r.path, r.added_at, r.excluded, r.encoding, r.offline, r.last_scan, r.unsupported_count,
               (SELECT COUNT(*) FROM tracks t WHERE t.root_id = r.id AND t.missing_since IS NULL),
               (SELECT COUNT(*) FROM tracks t WHERE t.root_id = r.id AND t.missing_since IS NOT NULL)
        FROM roots r ORDER BY r.added_at
        """) { row in
            LibraryFolder(id: row.int64(0), path: row.string(1), addedAt: row.date(2), excluded: Self.decodeList(row.string(3)),
                          encoding: row.optionalString(4).flatMap(LegacyEncoding.init(rawValue:)), isOffline: row.bool(5),
                          lastScan: row.optionalDate(6), trackCount: row.int(8), unsupportedCount: row.int(7), missingCount: row.int(9))
        }
    }

    struct RootAccess: Sendable {
        var id: Int64
        var path: String
        var bookmark: Data?
        var excluded: [String]
        var lastEventID: UInt64?
    }

    func rootAccess() throws -> [RootAccess] {
        try db.query("SELECT id, path, bookmark, excluded, last_event_id FROM roots ORDER BY added_at") { row in
            RootAccess(id: row.int64(0), path: row.string(1), bookmark: row.optionalData(2), excluded: Self.decodeList(row.string(3)), lastEventID: row.optionalInt64(4).map { UInt64(bitPattern: $0) })
        }
    }

    func addRoot(path: String, bookmark: Data?, volumeUUID: String?) throws -> Int64 {
        try db.run("INSERT INTO roots(path, bookmark, volume_uuid, added_at) VALUES(?, ?, ?, ?)", [path, bookmark, volumeUUID, Date()])
        return try db.queryFirst("SELECT last_insert_rowid()") { $0.int64(0) } ?? 0
    }

    /// The root goes; its songs stay as missing (with likes and plays) until cleared, so adding the
    /// folder again finds them.
    func removeRoot(_ id: Int64) throws {
        try db.transaction {
            try db.run("UPDATE tracks SET root_id = NULL, folder_id = NULL, rel_path = (SELECT path FROM roots WHERE id = ?) || '/' || rel_path, missing_since = COALESCE(missing_since, ?) WHERE root_id = ?", [id, Date(), id])
            try db.run("DELETE FROM folders WHERE root_id = ?", [id])
            try db.run("DELETE FROM roots WHERE id = ?", [id])
        }
    }

    func updateRoot(_ id: Int64, path: String? = nil, bookmark: Data? = nil, offline: Bool? = nil, lastScan: Date? = nil, unsupported: Int? = nil) throws {
        if let path { try db.run("UPDATE roots SET path = ? WHERE id = ?", [path, id]) }
        if let bookmark { try db.run("UPDATE roots SET bookmark = ? WHERE id = ?", [bookmark, id]) }
        if let offline { try db.run("UPDATE roots SET offline = ? WHERE id = ?", [offline, id]) }
        if let lastScan { try db.run("UPDATE roots SET last_scan = ? WHERE id = ?", [lastScan, id]) }
        if let unsupported { try db.run("UPDATE roots SET unsupported_count = ? WHERE id = ?", [unsupported, id]) }
    }

    func setExcluded(_ paths: [String], of id: Int64) throws {
        try db.run("UPDATE roots SET excluded = ? WHERE id = ?", [Self.encodeList(paths), id])
    }

    /// The encoding picked for a root's old tags; nil goes back to voting.
    func setEncoding(_ encoding: LegacyEncoding?, of id: Int64) throws {
        try db.run("UPDATE roots SET encoding = ? WHERE id = ?", [encoding?.rawValue, id])
    }

    func rootEncoding(_ id: Int64) throws -> LegacyEncoding? {
        try db.queryFirst("SELECT encoding FROM roots WHERE id = ?", [id]) { $0.optionalString(0) }?.flatMap(LegacyEncoding.init(rawValue:))
    }

    func setLastEventID(_ eventID: UInt64, of id: Int64) throws {
        try db.run("UPDATE roots SET last_event_id = ? WHERE id = ?", [Int64(bitPattern: eventID), id])
    }

    func folders(of root: Int64) throws -> [String: FolderRecord] {
        let records = try db.query("SELECT id, root_id, rel_path, signature, encoding, encoding_override, cover_file FROM folders WHERE root_id = ?", [root]) { row in
            FolderRecord(id: row.int64(0), rootID: row.int64(1), relativePath: row.string(2), signature: row.string(3),
                         encoding: row.optionalString(4).flatMap(LegacyEncoding.init(rawValue:)),
                         encodingOverride: row.optionalString(5).flatMap(LegacyEncoding.init(rawValue:)), coverFile: row.optionalString(6))
        }
        return Dictionary(records.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func folderID(root: Int64, relativePath: String) throws -> Int64 {
        if let id = try db.queryFirst("SELECT id FROM folders WHERE root_id = ? AND rel_path = ?", [root, relativePath], { $0.int64(0) }) { return id }
        try db.run("INSERT INTO folders(root_id, rel_path) VALUES(?, ?)", [root, relativePath])
        return try db.queryFirst("SELECT last_insert_rowid()") { $0.int64(0) } ?? 0
    }

    func updateFolder(_ id: Int64, signature: String, encoding: LegacyEncoding?, coverFile: String?) throws {
        try db.run("UPDATE folders SET signature = ?, encoding = ?, cover_file = ?, scanned_at = ? WHERE id = ?", [signature, encoding?.rawValue, coverFile, Date(), id])
    }

    func deleteFolders(_ ids: [Int64]) throws {
        for id in ids { try db.run("DELETE FROM folders WHERE id = ?", [id]) }
    }

    func files(of root: Int64) throws -> [StoredFile] {
        try db.query("\(Self.fileColumns) WHERE root_id = ?", [root], Self.readFile)
    }

    func files(inFolder folder: Int64) throws -> [StoredFile] {
        try db.query("\(Self.fileColumns) WHERE folder_id = ? AND missing_since IS NULL", [folder], Self.readFile)
    }

    func missingFiles() throws -> [StoredFile] {
        try db.query("\(Self.fileColumns) WHERE missing_since IS NOT NULL", [], Self.readFile)
    }

    func file(root: Int64, relativePath: String) throws -> StoredFile? {
        try db.queryFirst("\(Self.fileColumns) WHERE root_id = ? AND rel_path = ?", [root, relativePath], Self.readFile)
    }

    func recentFiles(root: Int64, fileID: UInt64, size: Int64, since date: Date) throws -> [StoredFile] {
        try db.query("\(Self.fileColumns) WHERE root_id = ? AND file_id = ? AND size = ? AND missing_since IS NULL AND added_at >= ?", [root, Int64(bitPattern: fileID), size, date], Self.readFile)
    }

    func merge(_ duplicate: String, into song: String) throws {
        try db.transaction {
            try db.run("UPDATE OR IGNORE likes SET track_id = ? WHERE track_id = ?", [song, duplicate])
            try db.run("DELETE FROM likes WHERE track_id = ?", [duplicate])
            try db.run("UPDATE playlist_items SET track_id = ? WHERE track_id = ?", [song, duplicate])
            try db.run("UPDATE tracks SET play_count = play_count + COALESCE((SELECT play_count FROM tracks WHERE id = ?), 0) WHERE id = ?", [duplicate, song])
            try db.run("DELETE FROM tracks WHERE id = ?", [duplicate])
            try db.run("DELETE FROM track_artists WHERE track_id = ?", [duplicate])
        }
    }

    func file(id: String) throws -> StoredFile? {
        try db.queryFirst("\(Self.fileColumns) WHERE id = ?", [id], Self.readFile)
    }

    func externalFile(path: String) throws -> StoredFile? {
        try db.queryFirst("\(Self.fileColumns) WHERE root_id IS NULL AND rel_path = ?", [path], Self.readFile)
    }

    private static let fileColumns = "SELECT id, root_id, folder_id, rel_path, file_id, size, mtime, missing_since, reader, raw, codec, sample_rate, bit_depth, channels, bitrate, duration, playable, has_lyrics, cover_id, metadata_hash FROM tracks"

    private static func readFile(_ row: SQLiteDatabase.Row) -> StoredFile {
        let tags = (try? JSONDecoder().decode(RawTags.self, from: Data(row.string(9).utf8))) ?? RawTags()
        let audio = AudioProperties(codec: row.string(10), duration: row.double(15), sampleRate: row.optionalInt(11), bitDepth: row.optionalInt(12), channels: row.optionalInt(13), bitrate: row.optionalInt(14))
        return StoredFile(id: row.string(0), rootID: row.optionalInt64(1), folderID: row.optionalInt64(2), relativePath: row.string(3),
                          fileID: row.optionalInt64(4).map { UInt64(bitPattern: $0) }, size: row.int64(5), modified: row.double(6),
                          missingSince: row.optionalDate(7), reader: row.string(8), tags: tags, audio: audio, isPlayable: row.bool(16),
                          hasLyrics: row.bool(17), coverID: row.optionalString(18), metadataHash: row.string(19))
    }

    func save(_ file: StoredFile, isNew: Bool) throws {
        var tags = file.tags
        for key in TagKey.transient { tags.remove(key) }
        let raw = String(decoding: (try? JSONEncoder().encode(tags)) ?? Data("{}".utf8), as: UTF8.self)
        let values: [any SQLBindable] = [
            file.rootID, file.folderID, file.relativePath, file.fileID.map { Int64(bitPattern: $0) }, file.size, file.modified, file.missingSince,
            file.reader, raw, file.audio.codec, file.audio.sampleRate, file.audio.bitDepth, file.audio.channels, file.audio.bitrate,
            file.audio.duration, file.isPlayable, file.hasLyrics, file.coverID, file.metadataHash, file.id,
        ]
        if isNew {
            try db.run("""
            INSERT INTO tracks(root_id, folder_id, rel_path, file_id, size, mtime, missing_since, reader, raw, codec, sample_rate,
                bit_depth, channels, bitrate, duration, playable, has_lyrics, cover_id, metadata_hash, id, added_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values + [Date()])
        } else {
            try db.run("""
            UPDATE tracks SET root_id = ?, folder_id = ?, rel_path = ?, file_id = ?, size = ?, mtime = ?, missing_since = ?, reader = ?,
                raw = ?, codec = ?, sample_rate = ?, bit_depth = ?, channels = ?, bitrate = ?, duration = ?, playable = ?,
                has_lyrics = ?, cover_id = ?, metadata_hash = ? WHERE id = ?
            """, values)
        }
    }

    func move(_ id: String, root: Int64, folder: Int64, relativePath: String) throws {
        try db.run("UPDATE tracks SET root_id = ?, folder_id = ?, rel_path = ?, missing_since = NULL WHERE id = ?", [root, folder, relativePath, id])
    }

    func markMissing(_ ids: [String]) throws {
        let now = Date()
        for id in ids { try db.run("UPDATE tracks SET missing_since = COALESCE(missing_since, ?) WHERE id = ?", [now, id]) }
    }

    func purgeMissing() throws -> Int {
        try db.transaction {
            let ids = try db.query("SELECT id FROM tracks WHERE missing_since IS NOT NULL") { $0.string(0) }
            for id in ids {
                try db.run("DELETE FROM tracks WHERE id = ?", [id])
                try db.run("DELETE FROM track_artists WHERE track_id = ?", [id])
                try db.run("DELETE FROM likes WHERE track_id = ?", [id])
                try db.run("DELETE FROM playlist_items WHERE track_id = ?", [id])
            }
            return ids.count
        }
    }

    func saveFacts(_ facts: TrackFacts, of id: String, albumID: String?) throws {
        let artistText = facts.artists.joined(separator: " / ")
        let albumArtistText = facts.albumArtists.joined(separator: " / ")
        let searchKey = SearchKey.make([facts.title, artistText, facts.album ?? ""])
        try db.run("""
        UPDATE tracks SET title = ?, title_sort = ?, artist_text = ?, album_id = ?, album_title = ?, album_artist_text = ?, compilation = ?,
            disc = ?, disc_total = ?, track = ?, track_total = ?, year = ?, genres = ?, composer = ?, rg_track_gain = ?, rg_track_peak = ?,
            rg_album_gain = ?, rg_album_peak = ?, mb_track_id = ?, search_key = ?, sort_title = ?, sort_artist = ?, sort_album = ? WHERE id = ?
        """, [facts.title, facts.titleSort, artistText, albumID, facts.album, albumArtistText, facts.isCompilation, facts.disc, facts.discTotal,
              facts.track, facts.trackTotal, facts.year, facts.genres.joined(separator: "; "), facts.composer, facts.trackGain, facts.trackPeak,
              facts.albumGain, facts.albumPeak, facts.musicBrainzTrack, searchKey, SortKey.make(facts.titleSort ?? facts.title),
              SortKey.make(albumArtistText), SortKey.make(facts.album ?? ""), id])
        try db.run("DELETE FROM track_artists WHERE track_id = ?", [id])
        for (role, names) in [(0, facts.artists), (1, facts.albumArtists)] {
            for (position, name) in names.enumerated() {
                try db.run("INSERT INTO track_artists(track_id, role, position, artist_id, name) VALUES(?, ?, ?, ?, ?)", [id, role, position, StableID.artist(name), name])
            }
        }
    }

    func transaction<T: Sendable>(_ body: () throws -> T) throws -> T {
        try db.transaction(body)
    }

    func rebuildAggregates() throws {
        try db.transaction {
            try db.execute("DELETE FROM albums; DELETE FROM artists;")
            let albums = try db.query("""
            SELECT album_id, MAX(album_title), MIN(year), MAX(compilation), COUNT(*), SUM(duration), MIN(added_at), MIN(folder_id)
            FROM tracks WHERE album_id IS NOT NULL AND missing_since IS NULL AND root_id IS NOT NULL GROUP BY album_id
            """) { row in
                (id: row.string(0), title: row.string(1), year: row.optionalInt(2), compilation: row.bool(3), count: row.int(4),
                 duration: row.double(5), added: row.double(6), folder: row.optionalInt64(7))
            }
            for album in albums {
                let artists = try db.query("SELECT artist_id, name FROM track_artists WHERE role = 1 AND track_id = (SELECT id FROM tracks WHERE album_id = ? AND missing_since IS NULL LIMIT 1) ORDER BY position", [album.id]) { ($0.string(0), $0.string(1)) }
                let folderCover = try album.folder.flatMap { folder in
                    try db.queryFirst("SELECT r.path || '/' || f.cover_file FROM folders f JOIN roots r ON r.id = f.root_id WHERE f.id = ? AND f.cover_file IS NOT NULL", [folder]) { $0.string(0) }
                }
                let embedded = try db.queryFirst("SELECT cover_id FROM tracks WHERE album_id = ? AND cover_id IS NOT NULL AND missing_since IS NULL ORDER BY disc, track LIMIT 1", [album.id]) { $0.string(0) }
                let cover = folderCover.map(ArtworkStore.folderCoverID) ?? embedded
                let genreLists = try db.query("SELECT genres FROM tracks WHERE album_id = ? AND genres != ''", [album.id]) { $0.string(0) }
                let genres = Array(Set(genreLists.flatMap { $0.components(separatedBy: "; ") }.filter { !$0.isEmpty })).sorted().joined(separator: "; ")
                try db.run("""
                INSERT INTO albums(id, title, artist_ids, artist_names, year, cover_id, compilation, track_count, duration, added_at, genres, search_key, sort_title, sort_artist)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [album.id, album.title, Self.encodeList(artists.map(\.0)), Self.encodeList(artists.map(\.1)), album.year, cover, album.compilation,
                      album.count, album.duration, album.added, genres, SearchKey.make([album.title] + artists.map(\.1)), SortKey.make(album.title),
                      SortKey.make(artists.map(\.1).joined(separator: " / "))])
            }
            try db.run("""
            INSERT INTO artists(id, name, track_count, album_count, cover_id, search_key)
            SELECT a.artist_id, MIN(a.name), COUNT(DISTINCT CASE WHEN a.role = 0 THEN a.track_id END), COUNT(DISTINCT t.album_id), NULL, ''
            FROM track_artists a JOIN tracks t ON t.id = a.track_id WHERE t.missing_since IS NULL AND t.root_id IS NOT NULL GROUP BY a.artist_id
            """)
            try db.run("""
            UPDATE artists SET cover_id = (SELECT al.cover_id FROM albums al JOIN track_artists a ON a.artist_id = artists.id
                JOIN tracks t ON t.id = a.track_id AND t.album_id = al.id WHERE al.cover_id IS NOT NULL ORDER BY al.year DESC LIMIT 1)
            """)
            let artists = try db.query("SELECT id, name FROM artists") { ($0.string(0), $0.string(1)) }
            for (id, name) in artists { try db.run("UPDATE artists SET search_key = ?, sort_name = ? WHERE id = ?", [SearchKey.make([name]), SortKey.make(name), id]) }
        }
    }

    private static let trackColumns = """
    SELECT t.id, COALESCE(r.path || '/' || t.rel_path, t.rel_path), t.title, t.album_id, t.album_title, t.cover_id,
           (SELECT al.cover_id FROM albums al WHERE al.id = t.album_id), t.duration, t.disc, t.track, t.codec, t.sample_rate,
           t.bit_depth, t.channels, t.bitrate, t.size, t.playable, t.missing_since IS NULL AND COALESCE(r.offline, 0) = 0,
           t.rg_track_gain, t.rg_track_peak, t.rg_album_gain, t.rg_album_peak, t.play_count, t.added_at,
           (SELECT GROUP_CONCAT(a.artist_id, char(1)) FROM (SELECT artist_id FROM track_artists WHERE track_id = t.id AND role = 0 ORDER BY position) a),
           (SELECT GROUP_CONCAT(a.name, char(1)) FROM (SELECT name FROM track_artists WHERE track_id = t.id AND role = 0 ORDER BY position) a)
    FROM tracks t LEFT JOIN roots r ON r.id = t.root_id
    """

    private static func readTrack(_ row: SQLiteDatabase.Row) -> TrackRow {
        TrackRow(id: row.string(0), path: row.string(1), title: row.string(2), artistIDs: splitList(row.optionalString(24)), artistNames: splitList(row.optionalString(25)),
                 albumID: row.optionalString(3), albumTitle: row.optionalString(4), coverID: row.optionalString(5), albumCoverID: row.optionalString(6),
                 duration: row.double(7), disc: row.optionalInt(8), track: row.optionalInt(9), codec: row.string(10), sampleRate: row.optionalInt(11),
                 bitDepth: row.optionalInt(12), channels: row.optionalInt(13), bitrate: row.optionalInt(14), size: row.int64(15), isPlayable: row.bool(16),
                 isAvailable: row.bool(17), trackGain: row.optionalDouble(18), trackPeak: row.optionalDouble(19), albumGain: row.optionalDouble(20),
                 albumPeak: row.optionalDouble(21), playCount: row.int(22), addedAt: row.date(23))
    }

    private static let present = "t.missing_since IS NULL AND t.playable = 1 AND t.root_id IS NOT NULL"

    func tracks(ids: [String]) throws -> [TrackRow] {
        var rows: [String: TrackRow] = [:]
        for id in ids where rows[id] == nil {
            if let row = try db.queryFirst("\(Self.trackColumns) WHERE t.id = ?", [id], Self.readTrack) { rows[id] = row }
        }
        return ids.compactMap { rows[$0] }
    }

    enum TrackOrder: Sendable {
        case shelf
        case recentlyAdded
        case mostPlayed
        case random
    }

    func tracks(order: TrackOrder, offset: Int, limit: Int) throws -> [TrackRow] {
        let orderBy = switch order {
        case .shelf: "ORDER BY t.sort_artist, t.sort_album, t.disc, t.track, t.sort_title"
        case .recentlyAdded: "ORDER BY t.added_at DESC"
        case .mostPlayed: "AND t.play_count > 0 ORDER BY t.play_count DESC, t.last_played_at DESC"
        case .random: "ORDER BY RANDOM()"
        }
        return try db.query("\(Self.trackColumns) WHERE \(Self.present) \(orderBy) LIMIT ? OFFSET ?", [limit, offset], Self.readTrack)
    }

    func trackCount() throws -> Int {
        try db.queryFirst("SELECT COUNT(*) FROM tracks t WHERE \(Self.present)") { $0.int(0) } ?? 0
    }

    func searchTracks(_ query: String, offset: Int, limit: Int) throws -> (rows: [TrackRow], total: Int) {
        let needle = SearchKey.fold(query)
        let rows = try db.query("\(Self.trackColumns) WHERE \(Self.present) AND instr(t.search_key, ?) > 0 ORDER BY (instr(t.search_key, ?) = 1) DESC, t.play_count DESC, t.title COLLATE NOCASE LIMIT ? OFFSET ?", [needle, needle, limit, offset], Self.readTrack)
        let total = try db.queryFirst("SELECT COUNT(*) FROM tracks t WHERE \(Self.present) AND instr(t.search_key, ?) > 0", [needle]) { $0.int(0) } ?? 0
        return (rows, total)
    }

    func albumTracks(_ id: String) throws -> [TrackRow] {
        try db.query("\(Self.trackColumns) WHERE t.album_id = ? AND \(Self.present) ORDER BY t.disc, t.track, t.sort_title", [id], Self.readTrack)
    }

    func artistTracks(_ id: String, byPlays: Bool, offset: Int, limit: Int) throws -> [TrackRow] {
        let orderBy = byPlays ? "t.play_count DESC, t.year DESC, t.album_title, t.disc, t.track" : "t.year DESC, t.album_title, t.disc, t.track"
        return try db.query("\(Self.trackColumns) WHERE t.id IN (SELECT track_id FROM track_artists WHERE artist_id = ?) AND \(Self.present) ORDER BY \(orderBy) LIMIT ? OFFSET ?", [id, limit, offset], Self.readTrack)
    }

    func folderTracks(root: Int64, relativePath: String, below: Bool) throws -> [TrackRow] {
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        let rows = try db.query("\(Self.trackColumns) WHERE t.root_id = ? AND (? = '' OR substr(t.rel_path, 1, ?) = ?) AND \(Self.present)", [root, prefix, prefix.unicodeScalars.count, prefix], Self.readTrack)
        let rootPath = try db.queryFirst("SELECT path FROM roots WHERE id = ?", [root]) { $0.string(0) } ?? ""
        let start = rootPath.count + 1 + prefix.count
        let kept = below ? rows : rows.filter { !$0.path.dropFirst(start).contains("/") }
        return kept.map { (SortKey.make(String($0.path.dropFirst(start))), $0) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }.map(\.1)
    }

    func subfolders(root: Int64, relativePath: String) throws -> [(name: String, count: Int)] {
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        let paths = try db.query("SELECT rel_path FROM tracks t WHERE t.root_id = ? AND (? = '' OR substr(t.rel_path, 1, ?) = ?) AND \(Self.present)", [root, prefix, prefix.unicodeScalars.count, prefix]) { $0.string(0) }
        var counts: [String: Int] = [:]
        for path in paths {
            let rest = path.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { continue }
            counts[String(rest[..<slash]), default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { SortKey.make($0.name).localizedStandardCompare(SortKey.make($1.name)) == .orderedAscending }
    }

    private static let albumColumns = "SELECT id, title, artist_ids, artist_names, year, cover_id, compilation, track_count, duration, added_at, genres FROM albums"

    private static func readAlbum(_ row: SQLiteDatabase.Row) -> AlbumRow {
        AlbumRow(id: row.string(0), title: row.string(1), artistIDs: decodeList(row.string(2)), artistNames: decodeList(row.string(3)), year: row.optionalInt(4),
                 coverID: row.optionalString(5), isCompilation: row.bool(6), trackCount: row.int(7), duration: row.double(8), addedAt: row.date(9),
                 genres: row.string(10).components(separatedBy: "; ").filter { !$0.isEmpty })
    }

    func album(_ id: String) throws -> AlbumRow? {
        try db.queryFirst("\(Self.albumColumns) WHERE id = ?", [id], Self.readAlbum)
    }

    enum AlbumOrder: String, Sendable {
        case title, artist, year, recentlyAdded
    }

    func albums(order: AlbumOrder, genre: String? = nil, offset: Int, limit: Int) throws -> [AlbumRow] {
        let orderBy = switch order {
        case .title: "sort_title"
        case .artist: "sort_artist, year, sort_title"
        case .year: "year DESC, sort_title"
        case .recentlyAdded: "added_at DESC"
        }
        if let genre {
            return try db.query("\(Self.albumColumns) WHERE ('; ' || genres || '; ') LIKE ? ORDER BY \(orderBy) LIMIT ? OFFSET ?", ["%; \(genre); %", limit, offset], Self.readAlbum)
        }
        return try db.query("\(Self.albumColumns) ORDER BY \(orderBy) LIMIT ? OFFSET ?", [limit, offset], Self.readAlbum)
    }

    func albumCount() throws -> Int {
        try db.queryFirst("SELECT COUNT(*) FROM albums") { $0.int(0) } ?? 0
    }

    func searchAlbums(_ query: String, offset: Int, limit: Int) throws -> [AlbumRow] {
        let needle = SearchKey.fold(query)
        return try db.query("\(Self.albumColumns) WHERE instr(search_key, ?) > 0 ORDER BY title COLLATE NOCASE LIMIT ? OFFSET ?", [needle, limit, offset], Self.readAlbum)
    }

    func artistAlbums(_ id: String, offset: Int, limit: Int) throws -> [AlbumRow] {
        try db.query("\(Self.albumColumns) WHERE id IN (SELECT t.album_id FROM tracks t JOIN track_artists a ON a.track_id = t.id WHERE a.artist_id = ?) ORDER BY (artist_ids LIKE ?) DESC, year DESC LIMIT ? OFFSET ?", [id, "%\"\(id)\"%", limit, offset], Self.readAlbum)
    }

    private static let artistColumns = "SELECT id, name, track_count, album_count, cover_id FROM artists"

    private static func readArtist(_ row: SQLiteDatabase.Row) -> ArtistRow {
        ArtistRow(id: row.string(0), name: row.string(1), trackCount: row.int(2), albumCount: row.int(3), coverID: row.optionalString(4))
    }

    func artist(_ id: String) throws -> ArtistRow? {
        try db.queryFirst("\(Self.artistColumns) WHERE id = ?", [id], Self.readArtist)
    }

    enum ArtistOrder: String, Sendable {
        case name, trackCount
    }

    func artists(order: ArtistOrder, offset: Int, limit: Int) throws -> [ArtistRow] {
        let orderBy = order == .name ? "sort_name" : "track_count DESC, sort_name"
        return try db.query("\(Self.artistColumns) WHERE track_count > 0 ORDER BY \(orderBy) LIMIT ? OFFSET ?", [limit, offset], Self.readArtist)
    }

    func artistCount() throws -> Int {
        try db.queryFirst("SELECT COUNT(*) FROM artists WHERE track_count > 0") { $0.int(0) } ?? 0
    }

    func searchArtists(_ query: String, offset: Int, limit: Int) throws -> [ArtistRow] {
        let needle = SearchKey.fold(query)
        return try db.query("\(Self.artistColumns) WHERE instr(search_key, ?) > 0 ORDER BY track_count DESC LIMIT ? OFFSET ?", [needle, limit, offset], Self.readArtist)
    }

    func genres() throws -> [(name: String, count: Int)] {
        let lists = try db.query("SELECT genres FROM albums WHERE genres != ''") { $0.string(0) }
        var counts: [String: Int] = [:]
        for list in lists {
            for genre in Set(list.components(separatedBy: "; ").filter { !$0.isEmpty }) { counts[genre, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    func suggestions(_ prefix: String, limit: Int) throws -> [String] {
        let pattern = prefix.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        let titles = try db.query("SELECT DISTINCT title FROM tracks WHERE title LIKE ? ESCAPE '\\' AND missing_since IS NULL LIMIT ?", [pattern, limit]) { $0.string(0) }
        let artists = try db.query("SELECT name FROM artists WHERE name LIKE ? ESCAPE '\\' ORDER BY track_count DESC LIMIT ?", [pattern, limit]) { $0.string(0) }
        let albums = try db.query("SELECT title FROM albums WHERE title LIKE ? ESCAPE '\\' LIMIT ?", [pattern, limit]) { $0.string(0) }
        var seen = Set<String>()
        return (artists + titles + albums).filter { seen.insert($0.lowercased()).inserted }.prefix(limit).map { $0 }
    }

    func likedIDs() throws -> [String] {
        try db.query("SELECT track_id FROM likes ORDER BY liked_at DESC") { $0.string(0) }
    }

    func setLiked(_ id: String, _ liked: Bool) throws {
        if liked {
            try db.run("INSERT OR IGNORE INTO likes(track_id, liked_at) VALUES(?, ?)", [id, Date()])
        } else {
            try db.run("DELETE FROM likes WHERE track_id = ?", [id])
        }
    }

    func recordPlay(_ id: String, at date: Date) throws {
        try db.run("UPDATE tracks SET play_count = play_count + 1, last_played_at = ? WHERE id = ?", [date, id])
    }

    func playlists() throws -> [PlaylistRow] {
        try db.query("""
        SELECT p.id, p.name, p.description, p.created_at, p.updated_at, (SELECT COUNT(*) FROM playlist_items i WHERE i.playlist_id = p.id),
               (SELECT COALESCE(t.cover_id, al.cover_id) FROM playlist_items i JOIN tracks t ON t.id = i.track_id LEFT JOIN albums al ON al.id = t.album_id
                WHERE i.playlist_id = p.id ORDER BY i.position LIMIT 1)
        FROM playlists p ORDER BY p.created_at DESC
        """) { row in
            PlaylistRow(id: row.string(0), name: row.string(1), description: row.optionalString(2), createdAt: row.date(3), updatedAt: row.date(4), trackCount: row.int(5), coverID: row.optionalString(6))
        }
    }

    func playlistTrackIDs(_ id: String) throws -> [String] {
        try db.query("SELECT track_id FROM playlist_items WHERE playlist_id = ? ORDER BY position", [id]) { $0.string(0) }
    }

    func createPlaylist(name: String, description: String?) throws -> String {
        let id = "pl" + StableID.newTrack()
        let now = Date()
        try db.run("INSERT INTO playlists(id, name, description, created_at, updated_at) VALUES(?, ?, ?, ?, ?)", [id, name, description, now, now])
        return id
    }

    func editPlaylist(_ id: String, name: String?, description: String?) throws {
        if let name { try db.run("UPDATE playlists SET name = ?, updated_at = ? WHERE id = ?", [name, Date(), id]) }
        if let description { try db.run("UPDATE playlists SET description = ?, updated_at = ? WHERE id = ?", [description.isEmpty ? nil : description, Date(), id]) }
    }

    func deletePlaylist(_ id: String) throws {
        try db.transaction {
            try db.run("DELETE FROM playlist_items WHERE playlist_id = ?", [id])
            try db.run("DELETE FROM playlists WHERE id = ?", [id])
        }
    }

    /// Songs not in the playlist yet go to its end: how many did.
    func addToPlaylist(_ id: String, trackIDs: [String]) throws -> Int {
        try db.transaction {
            var existing = Set(try playlistTrackIDs(id))
            var position = try db.queryFirst("SELECT COALESCE(MAX(position), -1) FROM playlist_items WHERE playlist_id = ?", [id]) { $0.int(0) } ?? -1
            var added = 0
            for trackID in trackIDs where existing.insert(trackID).inserted {
                position += 1
                added += 1
                try db.run("INSERT INTO playlist_items(playlist_id, position, track_id, added_at) VALUES(?, ?, ?, ?)", [id, position, trackID, Date()])
            }
            if added > 0 { try db.run("UPDATE playlists SET updated_at = ? WHERE id = ?", [Date(), id]) }
            return added
        }
    }

    func removeFromPlaylist(_ id: String, trackIDs: [String]) throws {
        let remaining = try playlistTrackIDs(id).filter { !trackIDs.contains($0) }
        try writeOrder(id, remaining)
    }

    /// The playlist in `trackIDs`' order; songs not named keep theirs, after these.
    func reorderPlaylist(_ id: String, trackIDs: [String]) throws {
        let current = try playlistTrackIDs(id)
        let named = trackIDs.filter(current.contains)
        try writeOrder(id, named + current.filter { !named.contains($0) })
    }

    private func writeOrder(_ id: String, _ trackIDs: [String]) throws {
        try db.transaction {
            let added = Dictionary(try db.query("SELECT track_id, added_at FROM playlist_items WHERE playlist_id = ?", [id]) { ($0.string(0), $0.double(1)) }, uniquingKeysWith: { first, _ in first })
            try db.run("DELETE FROM playlist_items WHERE playlist_id = ?", [id])
            for (position, trackID) in trackIDs.enumerated() {
                try db.run("INSERT INTO playlist_items(playlist_id, position, track_id, added_at) VALUES(?, ?, ?, ?)", [id, position, trackID, added[trackID] ?? Date().timeIntervalSince1970])
            }
            try db.run("UPDATE playlists SET updated_at = ? WHERE id = ?", [Date(), id])
        }
    }

    static func encodeList(_ values: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(values)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func decodeList(_ text: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }

    static func splitList(_ text: String?) -> [String] {
        text.map { $0.components(separatedBy: "\u{1}").filter { !$0.isEmpty } } ?? []
    }
}

enum SortKey {
    static func make(_ text: String) -> String {
        var key = text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) ? SearchKey.pinyin(text).joined(separator: " ") : SearchKey.fold(text)
        if key.hasPrefix("the ") { key.removeFirst(4) }
        return key
    }
}

enum SearchKey {
    static func make(_ fields: [String]) -> String {
        var parts = fields.filter { !$0.isEmpty }.map(fold)
        for field in fields where field.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            let syllables = pinyin(field)
            guard !syllables.isEmpty else { continue }
            parts.append(syllables.joined())
            parts.append(String(syllables.compactMap(\.first)))
        }
        return parts.joined(separator: "\u{1}")
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pinyin(_ text: String) -> [String] {
        let mutable = NSMutableString(string: text) as CFMutableString
        guard CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false),
              CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false) else { return [] }
        return (mutable as String).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
