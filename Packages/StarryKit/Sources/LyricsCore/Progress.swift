import Foundation

public struct LyricsProgress: Sendable, Equatable {
    public var activeLine: Int?
    /// 0…1 progress inside the active line (for the gradient mask).
    public var lineProgress: Double
    public var wordProgress: [Double]

    public init(activeLine: Int?, lineProgress: Double, wordProgress: [Double]) {
        self.activeLine = activeLine
        self.lineProgress = lineProgress
        self.wordProgress = wordProgress
    }

    public static func compute(_ document: LyricsDocument, at time: TimeInterval) -> LyricsProgress {
        guard let index = document.activeLineIndex(at: time) else {
            return LyricsProgress(activeLine: nil, lineProgress: 0, wordProgress: [])
        }
        let line = document.lines[index]
        let lineProgress = line.duration > 0 ? min(1, max(0, (time - line.start) / line.duration)) : 1
        let wordProgress = line.words.map { word -> Double in
            guard word.duration > 0 else { return time >= word.start ? 1 : 0 }
            return min(1, max(0, (time - word.start) / word.duration))
        }
        return LyricsProgress(activeLine: index, lineProgress: lineProgress, wordProgress: wordProgress)
    }
}
