import AudioProcessing
import Foundation
import LyricsCore
import Testing
@testable import LyricsSync

@Suite struct LyricsOffsetEstimatorTests {
    static func document(wordTiming: Bool, seed: UInt64 = 7) -> LyricsDocument {
        var generator = SeededGenerator(seed: seed)
        var lines: [LyricLine] = []
        var t = 12.0
        for id in 0..<40 {
            let start = t
            var words: [LyricWord] = []
            for _ in 0..<Int.random(in: 4...7, using: &generator) {
                let length = Double.random(in: 0.2...0.5, using: &generator)
                words.append(LyricWord(start: t, end: t + length, text: "啦"))
                t += length + Double.random(in: 0...0.08, using: &generator)
            }
            lines.append(wordTiming
                ? LyricLine(id: id, start: start, end: t, words: words)
                : LyricLine.plain(id: id, start: start, end: t, text: String(repeating: "啦", count: words.count)))
            t += Double.random(in: 0.4...2.5, using: &generator)
            if id == 15 { t += 12 }                     // an interlude
        }
        if !wordTiming {
            for i in lines.indices.dropLast() { lines[i].end = lines[i + 1].start }
        }
        return LyricsDocument(format: wordTiming ? .yrc : .lrc, lines: lines)
    }

    /// Activity of someone singing `document` `shift` seconds later than it says: loud during
    /// the words, an onset at each word start, some noise.
    static func activity(singing document: LyricsDocument, wordTiming: LyricsDocument, shift: TimeInterval, duration: TimeInterval = 180, noise: Float = 3) -> VocalActivity {
        var generator = SeededGenerator(seed: 3)
        let n = Int(duration * VocalActivity.frameRate)
        var activity = VocalActivity(frameCount: n)
        for t in 0..<n {
            activity.energy[t] = Float.random(in: -noise...noise, using: &generator)
            activity.flux[t] = Float.random(in: 0...0.05, using: &generator)
            activity.valid[t] = true
        }
        for line in wordTiming.lines {
            for word in line.words {
                let a = Int(((word.start + shift) * VocalActivity.frameRate).rounded()), b = Int(((word.end + shift) * VocalActivity.frameRate).rounded())
                guard a >= 0, b < n else { continue }
                for t in a..<b { activity.energy[t] += 40 }
                activity.flux[a] += 1
            }
        }
        return activity
    }

    @Test func findsTheShiftOfWordTimedLyrics() throws {
        let lyrics = Self.document(wordTiming: true)
        for shift in [-2.3, -0.4, 0, 0.7, 3.1] {
            let activity = Self.activity(singing: lyrics, wordTiming: lyrics, shift: shift)
            let estimate = try #require(LyricsOffsetEstimator.estimate(activity, document: lyrics))
            #expect(estimate.method == .words)
            #expect(abs(estimate.offset - shift) < 0.02, "shift \(shift) → \(estimate.offset)")
            #expect(estimate.isConfident)
            #expect(abs(estimate.calibratedOffset - (estimate.offset - 0.06)) < 1e-9)
        }
    }

    @Test func findsTheShiftOfLineTimedLyrics() throws {
        let words = Self.document(wordTiming: true)
        let lines = Self.document(wordTiming: false)
        for shift in [-1.1, 0.5, 2] {
            let activity = Self.activity(singing: lines, wordTiming: words, shift: shift)
            let estimate = try #require(LyricsOffsetEstimator.estimate(activity, document: lines))
            #expect(estimate.method == .lines)
            #expect(abs(estimate.offset - shift) < 0.05, "shift \(shift) → \(estimate.offset)")
            #expect(estimate.isConfident)
        }
    }

    @Test func worksOnAFewWindowsOnly() throws {
        let lyrics = Self.document(wordTiming: true)
        let activity = Self.activity(singing: lyrics, wordTiming: lyrics, shift: 0.9)
        let calibrator = LyricsCalibrator()
        let valid = calibrator.mask([20...40, 80...100], activity)
        #expect(valid.filter { $0 }.count == 4000)
        let estimate = try #require(LyricsOffsetEstimator.estimate(activity, document: lyrics, valid: valid))
        #expect(abs(estimate.offset - 0.9) < 0.02)
    }

    @Test func noSingingIsNotConfident() {
        let lyrics = Self.document(wordTiming: true)
        var activity = Self.activity(singing: lyrics, wordTiming: lyrics, shift: 0, noise: 0)
        var generator = SeededGenerator(seed: 11)
        for t in 0..<activity.frameCount {
            activity.energy[t] = Float.random(in: -20...20, using: &generator)
            activity.flux[t] = Float.random(in: 0...1, using: &generator)
        }
        let estimate = LyricsOffsetEstimator.estimate(activity, document: lyrics)
        #expect(estimate?.isConfident == false)
    }

    @Test func tooLittleAudioOrLyricsGivesNothing() {
        let lyrics = Self.document(wordTiming: true)
        let activity = Self.activity(singing: lyrics, wordTiming: lyrics, shift: 0)
        let short = LyricsCalibrator().mask([20...23], activity)
        #expect(LyricsOffsetEstimator.estimate(activity, document: lyrics, valid: short) == nil)
        let two = LyricsDocument(format: .lrc, lines: Array(lyrics.lines.prefix(2)))
        #expect(LyricsOffsetEstimator.estimate(activity, document: two) == nil)
    }

    @Test func planSpreadsWindowsOverTheSungPart() {
        let lyrics = Self.document(wordTiming: true)
        let calibrator = LyricsCalibrator()
        let windows = calibrator.plan(lyrics, duration: 180)
        let first = lyrics.lines.first!.start, last = lyrics.lines.last!.end
        #expect(windows.count == 5)
        #expect(Set(windows.map { $0.lowerBound }).count == windows.count)
        for window in windows {
            #expect(window.upperBound - window.lowerBound == 20)
            #expect(window.lowerBound >= first - 2 && window.upperBound <= last + 2)
        }
        let span = last - first
        #expect(windows[0].lowerBound < first + span * 0.3)
        #expect(windows[2].upperBound > last - span * 0.3)
        #expect(LyricsCalibrator.visitingOrder(5) == [0, 2, 4, 1, 3])
    }

    @Test func failureSaysWhyThereIsNoOffset() {
        func calibration(_ estimate: LyricsOffsetEstimate?, offset: TimeInterval? = nil) -> LyricsCalibration {
            LyricsCalibration(estimate: estimate, offset: offset, windows: [], separatedDuration: 0, songDuration: 180, model: nil)
        }
        let clear = LyricsOffsetEstimate(method: .lines, offset: 0.9, score: 6, peakRatio: 2)
        let unclear = LyricsOffsetEstimate(method: .lines, offset: 0.9, score: 2.8, peakRatio: 1.1)
        #expect(calibration(clear, offset: 0.76).failure == nil)
        #expect(calibration(nil).failure == .tooLittle)
        #expect(calibration(unclear).failure == .noClearMatch)
        // Confident but never stable across windows.
        #expect(calibration(clear).failure == .inconsistent)
    }

    @Test func shortSongsAreAnalysedWhole() {
        let lines = (0..<6).map { LyricLine.plain(id: $0, start: 3 + Double($0) * 3, end: 5.5 + Double($0) * 3, text: "啦啦") }
        let windows = LyricsCalibrator().plan(LyricsDocument(format: .lrc, lines: lines), duration: 30)
        #expect(windows == [1.0...22.5])
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
