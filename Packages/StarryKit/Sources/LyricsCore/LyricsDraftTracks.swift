import Foundation

extension LyricsDraft {
    /// Editor-only lane, saved in projects. TTML still uses the line's singer and background role.
    public struct Track: Sendable, Hashable, Identifiable, Codable {
        public var id: UUID
        public var name: String

        public init(id: UUID = UUID(), name: String) {
            self.id = id
            self.name = name
        }
    }

    public enum Lane: Sendable, Hashable {
        /// The lead singer's, and both singers' together.
        case lead
        /// A second singer's, while a line not on a track is sung by one.
        case secondary
        case track(UUID)
    }

    public struct Slot: Sendable, Hashable {
        public var lane: Int
        public var background: Bool

        public init(lane: Int, background: Bool) {
            self.lane = lane
            self.background = background
        }
    }

    public var lanes: [Lane] {
        let secondary = lines.contains { !isOnTrack($0) && !$0.isBackground && $0.singer == .secondary }
        return [.lead] + (secondary ? [.secondary] : []) + tracks.map { .track($0.id) }
    }

    public func isOnTrack(_ line: Line) -> Bool {
        line.track.map { id in tracks.contains { $0.id == id } } ?? false
    }

    /// Background vocals follow their lead unless assigned a track.
    /// `line` can override the stored line for a drag preview.
    public func slot(ofLine index: Int, as line: Line? = nil, in lanes: [Lane]) -> Slot {
        let line = line ?? lines[index]
        if let track = line.track, let lane = lanes.firstIndex(of: .track(track)) { return Slot(lane: lane, background: false) }
        if line.isBackground {
            var lead = index - 1
            while lead >= 0, lines[lead].isBackground { lead -= 1 }
            if lead >= 0 { return Slot(lane: slot(ofLine: lead, in: lanes).lane, background: true) }
        }
        let lane = line.singer == .secondary ? lanes.firstIndex(of: .secondary) : nil
        return Slot(lane: lane ?? 0, background: line.isBackground)
    }

    public mutating func removeTrack(_ id: UUID) {
        tracks.removeAll { $0.id == id }
        for index in lines.indices where lines[index].track == id { lines[index].track = nil }
    }

    /// Moves overlapping lines to free tracks, creating tracks as needed.
    /// Touching lines can share a row; unassigned background vocals follow their lead.
    /// Returns the number of moved lines.
    @discardableResult
    public mutating func separateOverlaps(newTrack: ([Track]) -> Track) -> Int {
        struct Row: Hashable {
            var lane: Lane
            var background: Bool
        }
        func row(ofLine index: Int) -> Row {
            let lanes = self.lanes
            let slot = self.slot(ofLine: index, in: lanes)
            return Row(lane: lanes[slot.lane], background: slot.background)
        }
        let order = lines.indices.compactMap { index in lines[index].timedRange.map { (index, $0) } }
            .sorted { ($0.1.lowerBound, $0.0) < ($1.1.lowerBound, $1.0) }
        let tolerance = 0.001
        var ends: [Row: TimeInterval] = [:]
        var moved = 0
        for (index, range) in order {
            var row = row(ofLine: index)
            if let end = ends[row], end > range.lowerBound + tolerance {
                let free = tracks.first { (ends[Row(lane: .track($0.id), background: false)] ?? -.infinity) <= range.lowerBound + tolerance }
                let track: Track
                if let free {
                    track = free
                } else {
                    track = newTrack(tracks)
                    tracks.append(track)
                }
                lines[index].track = track.id
                row = Row(lane: .track(track.id), background: false)
                moved += 1
            }
            ends[row] = max(ends[row] ?? -.infinity, range.upperBound)
        }
        return moved
    }
}
