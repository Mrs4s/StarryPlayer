import Foundation
import Testing
@testable import LocalLibrary

enum TestFiles {
    /// `frames`: frame id → text. `gbk`: the text as GBK bytes in ISO-8859-1 frames.
    static func mp3(_ frames: [(String, String)], gbk: Bool = false, padding: Int = 0) throws -> Data {
        let audio = try Data(contentsOf: corpusFile("05 林俊杰 - 江南.mp3"))
        var body = Data()
        for (id, text) in frames {
            var content = Data()
            if gbk {
                content.append(0)
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                content.append(text.data(using: encoding)!)
            } else {
                content.append(1)
                content.append(contentsOf: [0xFF, 0xFE])
                content.append(text.data(using: .utf16LittleEndian)!)
            }
            body.append(Data(id.utf8))
            body.append(contentsOf: withUnsafeBytes(of: UInt32(content.count).bigEndian) { Array($0) })
            body.append(contentsOf: [0, 0])
            body.append(content)
        }
        body.append(Data(count: padding))
        let size = body.count
        let syncsafe = [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)]
        return Data("ID3".utf8) + Data([3, 0, 0]) + Data(syncsafe) + body + audio
    }

    static func song(_ title: String, artist: String, album: String? = nil, albumArtist: String? = nil, track: Int? = nil, gbk: Bool = false) throws -> Data {
        var frames = [("TIT2", title), ("TPE1", artist)]
        if let album { frames.append(("TALB", album)) }
        if let albumArtist { frames.append(("TPE2", albumArtist)) }
        if let track { frames.append(("TRCK", String(track))) }
        return try mp3(frames, gbk: gbk)
    }
}

final class TestLibrary {
    let folder = FileManager.default.temporaryDirectory.appending(path: "local-library-\(UUID().uuidString)", directoryHint: .isDirectory)
    var root: URL { folder.appending(path: "Music", directoryHint: .isDirectory) }
    let store: LibraryStore
    let scanner: LibraryScanner

    init(rules: LibraryRules = LibraryRules()) throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "Music"), withIntermediateDirectories: true)
        store = try LibraryStore(url: nil)
        scanner = LibraryScanner(store: store, artworkDirectory: folder.appending(path: "artwork"), rules: rules) { _ in }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func write(_ data: Data, to path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func addRoot() async throws -> LibraryStore.RootAccess {
        _ = try await store.addRoot(path: root.path, bookmark: try? root.bookmarkData(options: .minimalBookmark), volumeUUID: nil)
        return try #require(await store.rootAccess().first)
    }

    @discardableResult
    func scan(_ scope: LibraryScanner.Scope = .whole) async throws -> ScanSummary {
        let access = try #require(await store.rootAccess().first)
        return try await scanner.scan(access, scope: scope)
    }

    func titles() async throws -> [String] {
        try await store.tracks(order: .shelf, offset: 0, limit: 1000).map(\.title).sorted()
    }
}

struct LibraryScannerTests {
    @Test func albumsArtistsAndDiscs() async throws {
        let library = try TestLibrary()
        try library.write(TestFiles.song("晴天", artist: "周杰伦", album: "叶惠美", track: 1), to: "周杰伦/叶惠美/01.mp3")
        try library.write(TestFiles.song("以父之名", artist: "周杰伦", album: "叶惠美", track: 2), to: "周杰伦/叶惠美/02.mp3")
        try library.write(TestFiles.song("A", artist: "Band", album: "Double", track: 1), to: "Band/Double/CD1/01.mp3")
        try library.write(TestFiles.song("B", artist: "Band", album: "Double", track: 1), to: "Band/Double/CD2/01.mp3")
        try library.write(TestFiles.song("X", artist: "甲", album: "合辑"), to: "合辑/1.mp3")
        try library.write(TestFiles.song("Y", artist: "乙", album: "合辑"), to: "合辑/2.mp3")
        try library.write(TestFiles.song("Z", artist: "丙", album: "合辑"), to: "合辑/3.mp3")
        _ = try await library.addRoot()
        let summary = try await library.scan()
        #expect(summary.added == 7)

        let albums = try await library.store.albums(order: .title, offset: 0, limit: 10)
        #expect(albums.map(\.title).sorted() == ["Double", "叶惠美", "合辑"])
        let double = try #require(albums.first { $0.title == "Double" })
        #expect(double.trackCount == 2)
        let discs = try await library.store.albumTracks(double.id).map(\.disc)
        #expect(discs == [1, 2])
        let compilation = try #require(albums.first { $0.title == "合辑" })
        #expect(compilation.isCompilation)
        #expect(compilation.artistNames == ["群星"])
        let artists = try await library.store.artists(order: .trackCount, offset: 0, limit: 10)
        let jay = try #require(artists.first { $0.name == "周杰伦" })
        #expect(jay.trackCount == 2)
        #expect(jay.albumCount == 1)
        // The compilation's album artist is not listed as a singer.
        #expect(!artists.contains { $0.name == "群星" })
        let found = try await library.store.searchTracks("zjl", offset: 0, limit: 10)
        #expect(found.total == 2)
    }

    @Test func legacyEncodingIsReadAgainByFolder() async throws {
        let library = try TestLibrary()
        try library.write(TestFiles.song("晴天", artist: "周杰伦", album: "叶惠美", gbk: true), to: "旧/01.mp3")
        try library.write(TestFiles.song("东风破", artist: "周杰伦", album: "叶惠美", gbk: true), to: "旧/02.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        #expect(try await library.titles() == ["东风破", "晴天"])
        let album = try #require(await library.store.albums(order: .title, offset: 0, limit: 10).first)
        #expect(album.title == "叶惠美")
        #expect(album.artistNames == ["周杰伦"])
    }

    @Test func renamedFileKeepsItsID() async throws {
        let library = try TestLibrary()
        try library.write(TestFiles.song("晴天", artist: "周杰伦", album: "叶惠美"), to: "A/01.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        let id = try #require(await library.store.tracks(order: .shelf, offset: 0, limit: 10).first?.id)
        try await library.store.setLiked(id, true)

        try FileManager.default.createDirectory(at: library.root.appending(path: "B"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: library.root.appending(path: "A/01.mp3"), to: library.root.appending(path: "B/晴天.mp3"))
        let summary = try await library.scan()
        #expect(summary.moved == 1)
        #expect(summary.added == 0)
        let moved = try #require(await library.store.tracks(order: .shelf, offset: 0, limit: 10).first)
        #expect(moved.id == id)
        #expect(moved.path.hasSuffix("B/晴天.mp3"))
        #expect(try await library.store.likedIDs() == [id])
    }

    @Test func moveSeenInTwoScansKeepsTheSong() async throws {
        let library = try TestLibrary()
        try library.write(TestFiles.song("晴天", artist: "周杰伦", album: "叶惠美"), to: "A/01.mp3")
        try library.write(TestFiles.song("七里香", artist: "周杰伦", album: "七里香"), to: "A/02.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        let id = try #require(await library.store.tracks(order: .shelf, offset: 0, limit: 10).first { $0.title == "晴天" }?.id)
        try await library.store.setLiked(id, true)
        try FileManager.default.createDirectory(at: library.root.appending(path: "B"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: library.root.appending(path: "A/01.mp3"), to: library.root.appending(path: "B/01.mp3"))
        let first = try await library.scan(.folders(["B"]))
        #expect(first.added == 1)
        let second = try await library.scan(.folders(["A"]))
        #expect(second.moved == 1)
        #expect(second.missing == 0)
        let rows = try await library.store.tracks(order: .shelf, offset: 0, limit: 10)
        #expect(rows.count == 2)
        let song = try #require(rows.first { $0.title == "晴天" })
        #expect(song.id == id)
        #expect(song.path.hasSuffix("B/01.mp3"))
        #expect(try await library.store.likedIDs() == [id])
    }

    @Test func purgingRemovesPlaylistEntries() async throws {
        let library = try TestLibrary()
        try library.write(TestFiles.song("一", artist: "甲", album: "专辑"), to: "A/01.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        let id = try #require(await library.store.tracks(order: .shelf, offset: 0, limit: 10).first?.id)
        let playlist = try await library.store.createPlaylist(name: "歌单", description: nil)
        _ = try await library.store.addToPlaylist(playlist, trackIDs: [id])
        try FileManager.default.removeItem(at: library.root.appending(path: "A/01.mp3"))
        try await library.scan()
        #expect(try await library.store.purgeMissing() == 1)
        #expect(try await library.store.playlists().first?.trackCount == 0)
    }

    @Test func deletedFileGoesMissingAndComesBack() async throws {
        let library = try TestLibrary()
        let song = try TestFiles.song("晴天", artist: "周杰伦", album: "叶惠美")
        try library.write(song, to: "A/01.mp3")
        try library.write(TestFiles.song("七里香", artist: "周杰伦", album: "七里香"), to: "A/02.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        let id = try #require(await library.store.tracks(order: .shelf, offset: 0, limit: 10).first { $0.title == "晴天" }?.id)

        let saved = library.folder.appending(path: "saved.mp3")
        try FileManager.default.moveItem(at: library.root.appending(path: "A/01.mp3"), to: saved)
        let gone = try await library.scan()
        #expect(gone.missing == 1)
        #expect(try await library.titles() == ["七里香"])
        #expect(try await library.store.roots().first?.missingCount == 1)

        try FileManager.default.moveItem(at: saved, to: library.root.appending(path: "A/晴天 (copy).mp3"))
        let back = try await library.scan()
        #expect(back.moved == 1)
        #expect(try await library.store.tracks(ids: [id]).first?.isAvailable == true)
    }

    @Test func editedTagsAreReadAgain() async throws {
        let library = try TestLibrary()
        try library.write(TestFiles.song("旧标题", artist: "歌手", album: "专辑"), to: "A/01.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        let id = try #require(await library.store.tracks(order: .shelf, offset: 0, limit: 10).first?.id)
        try library.write(TestFiles.song("新标题", artist: "歌手", album: "专辑"), to: "A/01.mp3")
        let summary = try await library.scan()
        #expect(summary.updated == 1)
        let row = try #require(await library.store.tracks(ids: [id]).first)
        #expect(row.title == "新标题")
        #expect(try await library.scan() == ScanSummary())
    }

    @Test func folderScopeTakesNewSubfolders() async throws {
        let library = try TestLibrary()
        try library.write(TestFiles.song("一", artist: "甲", album: "专辑"), to: "A/01.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        try library.write(TestFiles.song("二", artist: "甲", album: "专辑"), to: "A/02.mp3")
        try library.write(TestFiles.song("三", artist: "乙", album: "新专辑"), to: "A/New/01.mp3")
        let summary = try await library.scan(.folders(["A"]))
        #expect(summary.added == 2)
        try FileManager.default.removeItem(at: library.root.appending(path: "A/New"))
        let removed = try await library.scan(.folders(["A"]))
        #expect(removed.missing == 1)
        #expect(try await library.titles() == ["一", "二"])
    }

    /// A root that cannot be reached changes nothing: its songs are not missing.
    @Test func offlineRootKeepsItsSongs() async throws {
        let library = try TestLibrary()
        try library.write(TestFiles.song("一", artist: "甲", album: "专辑"), to: "A/01.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        let away = library.folder.appending(path: "Away")
        try FileManager.default.moveItem(at: library.root, to: away)
        try await library.store.updateRoot(try #require(await library.store.rootAccess().first).id, bookmark: Data([1, 2, 3]))
        let summary = try await library.scan()
        #expect(summary.offline)
        let root = try #require(await library.store.roots().first)
        #expect(root.isOffline)
        #expect(root.missingCount == 0)
        #expect(try await library.store.tracks(order: .shelf, offset: 0, limit: 10).first?.isAvailable == false)
    }

    @Test func movedRootIsFoundByItsBookmark() async throws {
        let library = try TestLibrary()
        try library.write(TestFiles.song("一", artist: "甲", album: "专辑"), to: "A/01.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        let id = try #require(await library.store.tracks(order: .shelf, offset: 0, limit: 10).first?.id)
        let moved = library.folder.appending(path: "Renamed", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: library.root, to: moved)
        let summary = try await library.scan()
        #expect(!summary.offline)
        #expect(summary == ScanSummary())
        let row = try #require(await library.store.tracks(ids: [id]).first)
        #expect(row.path.contains("/Renamed/"))
        #expect(row.isAvailable)
    }

    @Test func untaggedFilesUseTheirNames() async throws {
        let library = try TestLibrary()
        try library.write(try Data(contentsOf: corpusFile("05 林俊杰 - 江南.mp3")), to: "散/05 林俊杰 - 江南.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        let row = try #require(await library.store.tracks(order: .shelf, offset: 0, limit: 10).first)
        #expect(row.title == "江南")
        #expect(row.artistNames == ["林俊杰"])
        #expect(row.track == 5)
        #expect(row.albumID == nil)
    }

    @Test func embeddedCoverIsKeptOnce() async throws {
        let library = try TestLibrary()
        let tagged = try Data(contentsOf: corpusFile("01 v24 utf8.mp3"))
        try library.write(tagged, to: "A/01.mp3")
        try library.write(tagged, to: "A/02.mp3")
        _ = try await library.addRoot()
        try await library.scan()
        let rows = try await library.store.tracks(order: .shelf, offset: 0, limit: 10)
        #expect(rows.count == 2)
        #expect(Set(rows.compactMap(\.coverID)).count == 1)
        let cover = try #require(rows.first?.coverID)
        let url = try #require(ArtworkStore.url(for: cover, directory: library.folder.appending(path: "artwork")))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(rows.first?.albumCoverID == cover)
    }
}
