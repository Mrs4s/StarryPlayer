import AppKit
import StarryCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let starryTracks = UTType(exportedAs: "moe.mrs4s.starry-player.tracks")
}

extension AppModel {
    func draggedTracks(in info: DropInfo) -> [Track] {
        info.hasItemsConforming(to: [.starryTracks]) ? draggedTracks : []
    }
}
