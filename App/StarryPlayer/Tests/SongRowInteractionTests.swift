import AppKit
import StarryCore
import Testing
@testable import StarryPlayer

@Suite(.serialized)
@MainActor
struct SongRowInteractionTests {
    @Test(arguments: [false, true])
    func artistAndAlbumClicksReachTheirActions(whileHighlighted: Bool) throws {
        let artist = ArtistRef(id: "artist", name: "Artist")
        let track = Track(id: TrackRef(source: .local, id: "song"), title: "Song", artists: [artist], album: AlbumRef(id: "album", name: "Album"), duration: 180)
        let cell = SongCellView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        let root = try #require(window.contentView)
        cell.frame = NSRect(x: 0, y: 0, width: 900, height: Metrics.songRowHeight)
        root.addSubview(cell)
        var selectedArtist: ArtistRef?
        var albumClicks = 0
        cell.show(track, index: 1, tags: [], state: .init(), actions: .init(
            showArtist: { selectedArtist = $0 },
            showAlbum: { albumClicks += 1 }
        ))
        cell.layoutSubtreeIfNeeded()
        let content = try #require(cell.subviews.compactMap { $0 as? SongContentView }.first)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        if whileHighlighted { cell.glowOnce() }

        let geometry = SongRowGeometry(width: cell.bounds.width, height: cell.bounds.height)
        let lines = SongContentView.lines(cell.bounds.height)
        let artistPoint = NSPoint(x: geometry.textRect.minX + 5, y: lines.second + lines.lineHeight / 2)
        let albumPoint = NSPoint(x: geometry.albumRect.minX + 5, y: cell.bounds.midY)
        for point in [artistPoint, albumPoint] {
            let target = try #require(root.hitTest(root.convert(point, from: cell)))
            #expect(target === content)
            // Dispatch to the actual hit view so decorative overlays cannot hide a regression.
            guard target === content else { continue }
            let location = cell.convert(point, to: nil)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            target.mouseDown(with: down)
            target.mouseUp(with: up)
        }
        #expect(selectedArtist == artist)
        #expect(albumClicks == 1)
    }
}
