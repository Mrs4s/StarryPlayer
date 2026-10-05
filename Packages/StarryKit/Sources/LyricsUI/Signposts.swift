import os

/// Points of Interest for Instruments: line changes and line snapshots, so GPU work in a Metal
/// System Trace (this process's and the render server's) can be lined up with what the page did.
/// Costs a flag check unless a trace is recording.
enum LyricsSignposts {
    static let poi = OSSignposter(subsystem: "moe.mrs4s.starry-player", category: .pointsOfInterest)
}
