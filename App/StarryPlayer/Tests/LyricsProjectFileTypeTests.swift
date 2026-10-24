import Foundation
import LyricsCore
import Testing
import UniformTypeIdentifiers
@testable import StarryPlayer

@MainActor
struct LyricsProjectFileTypeTests {
    @Test(arguments: ["starrylyrics", "STARRYLYRICS"])
    func aSavedProjectMatchesBothOpenAndImportFilters(fileExtension: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "歌词工程.\(fileExtension)")
        let project = LyricsProject(draft: LyricsDraft(lines: [.init(syllables: [.init(text: "未打点")])]))
        try project.data().write(to: url, options: .atomic)

        // Ask the filesystem, just like the panel: constructing the filter's type alone
        // would miss a dynamic JSON type that doesn't match the file's inferred data type.
        let fileType = try #require(url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        #expect(fileType.conforms(to: AppModel.lyricsProjectType))
        #expect(AppModel.lyricsImportTypes.contains { fileType.conforms(to: $0) })
    }
}
