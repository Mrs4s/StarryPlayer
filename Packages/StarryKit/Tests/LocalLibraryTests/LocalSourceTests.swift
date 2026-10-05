import Foundation
import MusicSources
import StarryCore
import Testing
@testable import LocalLibrary

struct LocalSourceTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "local-source-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func write(_ data: Data, to path: String) throws {
        let url = folder.appending(path: "Music/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func source() -> LocalSource {
        LocalSource(directory: nil, artworkDirectory: folder.appending(path: "artwork"), settings: SourceSettingValues(["watchFolders": .bool(false)]))
    }

    private func library() async throws -> LocalSource {
        try write(TestFiles.song("晴天", artist: "周杰伦", album: "叶惠美", track: 2), to: "周杰伦/叶惠美/02 晴天.mp3")
        try write(TestFiles.song("以父之名", artist: "周杰伦", album: "叶惠美", track: 1), to: "周杰伦/叶惠美/01 以父之名.mp3")
        try write(TestFiles.song("江南", artist: "林俊杰", album: "第二天堂", track: 1), to: "林俊杰/第二天堂/01.mp3")
        try write(Data("[00:01.00]故事的小黄花\n".utf8), to: "周杰伦/叶惠美/02 晴天.lrc")
        let source = source()
        await source.start()
        try await source.addFolder(folder.appending(path: "Music"))
        await source.idle()
        return source
    }

    @Test func browsesAndSearches() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await library()
        let status = await source.status()
        #expect(status.trackCount == 3)
        #expect(status.folders.count == 1)

        let songs = try await source.search("晴", kind: .song, page: Page(offset: 0, limit: 10)).songs
        #expect(songs.map(\.title) == ["晴天"])
        let pinyin = try await source.search("ljj", kind: .song, page: Page(offset: 0, limit: 10)).songs
        #expect(pinyin.map(\.title) == ["江南"])
        let albums = try await source.search("叶惠美", kind: .album, page: Page(offset: 0, limit: 10)).albums
        let album = try #require(albums.first)
        let detail = try await source.album(id: album.id)
        #expect(detail.tracks.map(\.title) == ["以父之名", "晴天"])
        #expect(detail.album.artists.map(\.name) == ["周杰伦"])

        let artist = try #require(try await source.search("周杰伦", kind: .artist, page: Page(offset: 0, limit: 10)).artists.first)
        #expect(artist.songCount == 2)
        #expect(try await source.artistAlbums(id: artist.id, page: Page(offset: 0, limit: 10)).map(\.name) == ["叶惠美"])

        let all = try await source.allMedia(page: Page(offset: 0, limit: 2))
        #expect(all.total == 3)
        #expect(all.hasMore)
        #expect(try await source.homeShelves().map(\.id).contains("local.recent"))
    }

    @Test func playsAndKeepsPlays() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await library()
        let song = try #require(try await source.search("晴天", kind: .song, page: Page(offset: 0, limit: 10)).songs.first)
        let asset = try await source.resolvePlayableAsset(song, tier: QualityTier(.hq))
        #expect(asset.url.isFileURL)
        #expect(asset.provider == .local)
        #expect(asset.container == .mp3)
        #expect(song.localPath == asset.url.path)

        let lyrics = try #require(try await source.lyrics(for: song.id))
        #expect(lyrics.format == .lrc)
        #expect(lyrics.body.contains("故事的小黄花"))

        await source.reportPlayback(PlaybackReport(track: song.id, context: nil, playedSeconds: 60, duration: 60, startedAt: Date(), endedAt: Date()))
        let played = try await source.homeShelves().first { $0.id == "local.played" }
        if case .songs(let tracks)? = played?.items { #expect(tracks.map(\.id) == [song.id]) } else { Issue.record("no 最常播放 shelf") }

        try FileManager.default.removeItem(atPath: try #require(song.localPath))
        await #expect(throws: LocalLibraryError.fileMissing("02 晴天.mp3")) { try await source.resolvePlayableAsset(song, tier: QualityTier(.hq)) }
    }

    @Test func likesAndPlaylists() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await library()
        let songs = try await source.allMedia(page: Page(offset: 0, limit: 10)).tracks
        try await source.setLiked(songs[0].id, liked: true)
        #expect(try await source.likedTrackIDs() == [songs[0].id.id])

        let playlist = try await source.createPlaylist(PlaylistDraft(name: "开车听"))
        #expect(try await source.addTracks(songs.map(\.id.id), toPlaylist: playlist.id) == 3)
        #expect(try await source.addTracks([songs[0].id.id], toPlaylist: playlist.id) == 0)
        try await source.reorderPlaylist(playlist.id, trackIDs: [songs[2].id.id])
        #expect(try await source.playlist(id: playlist.id).tracks.map(\.id) == [songs[2].id, songs[0].id, songs[1].id])
        try await source.removeTracks([songs[0].id.id], fromPlaylist: playlist.id)
        try await source.editPlaylist(playlist.id, changes: PlaylistChanges(name: "通勤"))
        let lists = try await source.userPlaylists()
        #expect(lists.map(\.name) == ["通勤"])
        #expect(lists.first?.trackCount == 2)
        try await source.deletePlaylist(playlist.id)
        #expect(try await source.userPlaylists().isEmpty)
    }

    @Test func foldersInsideAndAround() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(TestFiles.song("一", artist: "甲", album: "专辑"), to: "A/01.mp3")
        let source = source()
        await source.start()
        try await source.addFolder(folder.appending(path: "Music/A"))
        await source.idle()
        let id = try #require(try await source.allMedia(page: Page(offset: 0, limit: 10)).tracks.first?.id)
        await #expect(throws: LocalLibraryError.self) { try await source.addFolder(folder.appending(path: "Music/A")) }
        try await source.addFolder(folder.appending(path: "Music"))
        await source.idle()
        #expect(await source.status().folders.map(\.path) == [FolderWalk.canonicalPath(folder.appending(path: "Music").path)])
        #expect(try await source.allMedia(page: Page(offset: 0, limit: 10)).tracks.map(\.id) == [id])
    }

    @Test func folderPages() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await library()
        let top = try await source.libraryFolder(nil)
        let root = try #require(top.folders.first)
        #expect(root.songCount == 3)
        let page = try await source.libraryFolder(root.path)
        #expect(page.folders.map(\.name) == ["林俊杰", "周杰伦"])
        #expect(page.tracks.isEmpty)
        #expect(page.songCount == 3)
        #expect(try await source.libraryFolderSongs(root.path).count == 3)
        let jay = try await source.libraryFolder(try #require(page.folders.first { $0.name == "周杰伦" }).path)
        #expect(jay.folders.map(\.name) == ["叶惠美"])
        let album = try await source.libraryFolder(jay.folders[0].path)
        #expect(album.tracks.map(\.title) == ["以父之名", "晴天"])
        #expect(album.trail.map(\.name) == ["Music", "周杰伦"])
        #expect(album.location?.lastPathComponent == "叶惠美")
    }

    @Test func fileOpenedOnItsOwn() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = source()
        await source.start()
        try write(TestFiles.song("外面的歌", artist: "某人", album: "某专辑"), to: "Elsewhere/x.mp3")
        let tracks = await source.songs(forFiles: [folder.appending(path: "Music/Elsewhere/x.mp3")])
        let song = try #require(tracks.first)
        #expect(song.title == "外面的歌")
        #expect(song.album == nil)
        // Not listed in the library, but likeable and playable.
        #expect(try await source.allMedia(page: Page(offset: 0, limit: 10)).tracks.isEmpty)
        try await source.setLiked(song.id, liked: true)
        #expect(try await source.songs(ids: [song.id.id]).map(\.title) == ["外面的歌"])
        #expect(await source.songs(forFiles: [folder.appending(path: "Music/Elsewhere/x.mp3")]).first?.id == song.id)
    }
}

struct TextRepairTests {
    @Test func misreadTextIsReadAgain() {
        #expect(TextRepair.vote(["ÖÜ½ÜÂ×", "Ò¶»ÝÃÀ", "¹ú±ê±àÂë±êÌâ"]) == .gb18030)
        #expect(TextRepair.repaired("ÖÜ½ÜÂ×", as: .gb18030) == "周杰伦")
        #expect(TextRepair.vote(["æ­Œæ‰‹ç”²"]) == .utf8)
    }

    @Test func westernNamesAreLeftAlone() {
        #expect(TextRepair.vote(["Sigur Rós", "Motörhead", "Café del Mar", "Beyoncé"]) == nil)
        #expect(TextRepair.misreadBytes("plain ASCII") == nil)
        #expect(TextRepair.misreadBytes("周杰伦") == nil)
    }

    @Test func otherScripts() {
        let big5 = String(data: "周杰倫 七里香".data(using: LegacyEncoding.big5.foundation)!, encoding: .isoLatin1)!
        #expect(TextRepair.vote([big5, big5]) == .big5)
        let japanese = String(data: "宇多田ヒカル".data(using: LegacyEncoding.shiftJIS.foundation)!, encoding: .isoLatin1)!
        #expect(TextRepair.vote([japanese]) == .shiftJIS)
    }

    @Test func textFiles() {
        let gbk = "[00:01.00]故事的小黄花".data(using: LegacyEncoding.gb18030.foundation)!
        #expect(TextRepair.decodeText(gbk) == "[00:01.00]故事的小黄花")
        #expect(TextRepair.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data("歌".utf8)) == "歌")
    }
}

struct ArtistNamesTests {
    private let names = ArtistNames()

    @Test func separators() {
        #expect(names.split("周杰伦/费玉清") == ["周杰伦", "费玉清"])
        #expect(names.split("A、B、C") == ["A", "B", "C"])
        #expect(names.split("A; B") == ["A", "B"])
        #expect(names.split("Artist feat. Guest") == ["Artist", "Guest"])
        #expect(names.split("Artist (feat. Guest)") == ["Artist", "Guest"])
        #expect(names.split("A / B") == ["A", "B"])
    }

    @Test func namesThatStayWhole() {
        #expect(names.split("AC/DC") == ["AC/DC"])
        #expect(names.split("Simon & Garfunkel") == ["Simon & Garfunkel"])
        #expect(names.split("王力宏&谭维维") == ["王力宏&谭维维"])
        #expect(ArtistNames(splitsAmpersand: true).split("王力宏&谭维维") == ["王力宏", "谭维维"])
        #expect(ArtistNames(splitsAmpersand: true).split("Simon & Garfunkel") == ["Simon & Garfunkel"])
        #expect(ArtistNames(exceptions: ["Me/You"]).split("Me/You") == ["Me/You"])
    }

    @Test func multipleValuesAreKept() {
        #expect(names.split(["A", "B", "a"]) == ["A", "B"])
    }
}

struct FolderRulesTests {
    @Test func fileNames() {
        let parsed = FileName("05 林俊杰 - 江南.mp3")
        #expect(parsed.track == 5)
        #expect(parsed.artist == "林俊杰")
        #expect(parsed.title == "江南")
        #expect(FileName("7 Rings.flac").title == "7 Rings")
        #expect(FileName("1. Intro.mp3").track == 1)
    }

    @Test func discFolders() {
        #expect(FolderRules.discNumber(folderName: "CD1") == 1)
        #expect(FolderRules.discNumber(folderName: "Disc 2") == 2)
        #expect(FolderRules.discNumber(folderName: "disk-3") == 3)
        #expect(FolderRules.discNumber(folderName: "CD") == nil)
        #expect(FolderRules.discNumber(folderName: "叶惠美") == nil)
    }

    @Test func numbersAndGains() {
        #expect(FolderRules.numberPair("3/12") == (3, 12))
        #expect(FolderRules.year("2021-05-20") == 2021)
        #expect(FolderRules.gain("-7.50 dB") == -7.5)
        #expect(FolderRules.r128("-512") == 3)
    }
}
