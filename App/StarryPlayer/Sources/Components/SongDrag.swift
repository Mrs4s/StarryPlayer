import AppKit
import StarryCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let starryTracks = UTType(exportedAs: "moe.mrs4s.starry-player.tracks")
}

extension AppModel {
    func dragItem(for tracks: [Track]) -> NSItemProvider {
        draggedTracks = tracks
        let text = tracks.map { track in ([track.title] + [track.artists.map(\.name).joined(separator: " / ")].filter { !$0.isEmpty }).joined(separator: " - ") }
        let provider = NSItemProvider(object: text.joined(separator: "\n") as NSString)
        let ids = Data(tracks.map(\.id.id).joined(separator: "\n").utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.starryTracks.identifier, visibility: .ownProcess) { completion in
            completion(ids, nil)
            return nil
        }
        return provider
    }

    func draggedTracks(in info: DropInfo) -> [Track] {
        info.hasItemsConforming(to: [.starryTracks]) ? draggedTracks : []
    }
}

struct SongDragPreview: View {
    let track: Track

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(artwork: track.artwork, radius: 5, pixelSize: 80)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(track.artists.map(\.name).joined(separator: " / ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 200, alignment: .leading)
        }
        .padding(5)
        .padding(.trailing, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
