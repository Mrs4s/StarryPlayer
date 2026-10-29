import AVFoundation
import Foundation
import LyricsCore
import Testing
@testable import LyricsSync

@Suite struct LyricsAITests {
    @Test func externalModelRequiresCompleteCompatibleAssetsAndPreservesItsLocation() throws {
        let folder = try modelFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try LyricsAIModelBundle.load(from: folder)
        #expect(bundle.directory == folder.resolvingSymlinksInPath())
        #expect(bundle.englishReadings.isEmpty)
        #expect(try LyricsAIModelBundle.load(from: bundle.model).vocabulary == bundle.vocabulary)
        let metadata = folder.appendingPathComponent("metadata")
        let before = try bundle.fingerprint()
        try Data(#"{"hello":"ハロー"}"#.utf8).write(to: metadata.appendingPathComponent("english-readings.json"))
        #expect(try LyricsAIModelBundle.load(from: folder).englishReadings["hello"] == "ハロー")
        #expect(try bundle.fingerprint() != before)
        try FileManager.default.removeItem(at: metadata.appendingPathComponent("hann-400.f32"))
        #expect(throws: LyricsAIError.self) { try LyricsAIModelBundle.load(from: folder) }
    }

    @Test func externalModelRejectsInvalidContractsVocabularyAndNonfiniteDSP() throws {
        let folder = try modelFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let metadata = folder.appendingPathComponent("metadata")
        let runtime = metadata.appendingPathComponent("runtime.json")
        let original = try Data(contentsOf: runtime)
        for altered in [
            String(decoding: original, as: UTF8.self).replacingOccurrences(of: "fixture.mlpackage", with: "../fixture.mlpackage"),
            String(decoding: original, as: UTF8.self).replacingOccurrences(of: "16000", with: "44100")
        ] {
            try Data(altered.utf8).write(to: runtime)
            #expect(throws: LyricsAIError.self) { try LyricsAIModelBundle.load(from: folder) }
        }
        try original.write(to: runtime)
        let vocab = metadata.appendingPathComponent("vocab.json")
        let originalVocabulary = try Data(contentsOf: vocab)
        try Data(#"{"[PAD]":121}"#.utf8).write(to: vocab)
        #expect(throws: LyricsAIError.self) { try LyricsAIModelBundle.load(from: folder) }
        try originalVocabulary.write(to: vocab)
        let invalid = [Float](repeating: .nan, count: 400).withUnsafeBytes { Data($0) }
        try invalid.write(to: metadata.appendingPathComponent("hann-400.f32"))
        #expect(throws: LyricsAIError.self) { try LyricsAIModelBundle.load(from: folder) }
    }

    private func modelFixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("starry-ai-bundle-\(UUID())", isDirectory: true)
        let metadata = folder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture.mlpackage"), withIntermediateDirectories: true)
        try Data(#"{"model":"fixture.mlpackage","inputs":{"mel":{"shape":[1,128,3000]},"valid_frames":{"shape":[1]}},"outputs":{"logits":{"shape":[1,1500,122],"blank_id":121},"sustain_logits":{"shape":[1,1500,8]}},"preprocessing":{"sample_rate":16000}}"#.utf8)
            .write(to: metadata.appendingPathComponent("runtime.json"))
        var vocabulary = Dictionary(uniqueKeysWithValues: (0..<121).map { ("token\($0)", $0) })
        vocabulary["[PAD]"] = 121
        try JSONEncoder().encode(vocabulary).write(to: metadata.appendingPathComponent("vocab.json"))
        for (name, count) in [("mel-filters.f32", 201 * 128), ("hann-400.f32", 400)] {
            let data = [Float](repeating: 1, count: count).withUnsafeBytes { Data($0) }
            try data.write(to: metadata.appendingPathComponent(name))
        }
        return folder
    }

    private func evidence(repeated: Bool = false) -> LyricsAICTC.Evidence {
        let rows: [[Float]] = (0..<10).map { frame in
            if frame == 1 || frame == 2 { return [0.08, 0.9, 0.02] }
            if frame == 5 || frame == 6 { return repeated ? [0.08, 0.9, 0.02] : [0.08, 0.02, 0.9] }
            return [0.98, 0.01, 0.01]
        }
        let sustain = (0..<10).flatMap { frame -> [Float] in
            let active = (1...4).contains(frame) ? 1 : ((5...7).contains(frame) ? (repeated ? 1 : 2) : 0)
            var row = [Float](repeating: 0.001, count: 8)
            row[active] = 0.993
            return row.map(log)
        }
        return .init(frames: 10, width: 3, blank: 0, logProbabilities: rows.flatMap { $0.map(log) },
                     sustain: sustain, silent: .init(repeating: false, count: 10), duration: 0.2)
    }

    @Test func sustainEvidenceRestoresTheHeldPartWithoutExtendingIntoSilence() throws {
        let alignment = try LyricsAICTC.decode(evidence(), tokens: [.init(label: 1, sustainClass: 1), .init(label: 2, sustainClass: 2, endsLine: true)])
        #expect(alignment.spans == [.init(start: 0.02, end: 0.10), .init(start: 0.10, end: 0.16)])
        #expect(alignment.raw == [.init(start: 0.02, end: 0.06), .init(start: 0.10, end: 0.14)])
    }

    @Test func repeatedSoundsKeepTheRequiredBlankBetweenTheirIntervals() throws {
        let spans = try LyricsAICTC.align(evidence(repeated: true), tokens: [.init(label: 1, sustainClass: 1), .init(label: 1, sustainClass: 1, endsLine: true)])
        #expect(spans.count == 2)
        #expect(spans[0].end <= spans[1].start - 0.02 + 1e-9)
        #expect(spans.allSatisfy { $0.end > $0.start })
    }

    @Test func invalidEvidenceAndMemoryBudgetsFailBeforeWritingAnyResult() {
        #expect(throws: (any Error).self) { try LyricsAICTC.align(evidence(), tokens: [.init(label: 1, sustainClass: 1)], maximumCells: 2) }
        var broken = evidence()
        broken.logProbabilities[0] = .nan
        #expect(throws: (any Error).self) { try LyricsAICTC.align(broken, tokens: [.init(label: 1, sustainClass: 1)]) }
    }

    @Test func existingReadingsAreUsedAndTimingApplicationPreservesTextAndBackground() throws {
        let original = LyricsDraft(lines: [
            .init(syllables: [.init(text: "愛", ruby: [.init(text: "あ"), .init(text: "い")]), .init(text: "！")], translation: "translation", romanization: "ai"),
            .init(syllables: [.init(text: "背景", start: 8, end: 9)], isBackground: true)
        ], metadata: ["musicName": "fixture"])
        let plan = try LyricsAIPronunciation.make(draft: original, vocabulary: ["あ": 22, "い": 24], english: [:])
        #expect(plan.tokens.map(\.label) == [22, 24])
        #expect(plan.tokens.map(\.sustainClass) == [1, 2])
        let result = try LyricsAIAligner.apply([.init(start: 1, end: 1.2), .init(start: 1.2, end: 2)], plan: plan, to: original)
        #expect(result.draft.lines[1] == original.lines[1])
        #expect(result.draft.metadata == original.metadata)
        #expect(result.draft.lines[0].text == original.lines[0].text)
        #expect(result.draft.lines[0].syllables.map(\.id) == original.lines[0].syllables.map(\.id))
        #expect(result.draft.lines[0].syllables[0].start == 1)
        #expect(result.draft.lines[0].syllables[0].end == 1.999)
        #expect(result.draft.lines[0].syllables[1].end == 2)
        #expect(result.draft.lines[0].syllables[0].ruby?.map(\.text) == ["あ", "い"])
        #expect(result.draft.lines[0].syllables[0].ruby?.allSatisfy { $0.span != nil } == true)
    }

    @Test func englishUsesTheExternalDictionaryAndUnknownOnlyLyricsDoNotGetInventedTimes() throws {
        let line = LyricsDraft(lines: [.init(syllables: [.init(text: "Hello")])])
        let plan = try LyricsAIPronunciation.make(draft: line, vocabulary: ["は": 67, "ろ": 97, "ー": 103], english: ["hello": "ハロー"])
        #expect(plan.tokens.map(\.label) == [67, 97, 103])
        #expect(plan.tokens.map(\.sustainClass) == [1, 5, 5])
        #expect(throws: (any Error).self) { try LyricsAIPronunciation.make(draft: line, vocabulary: ["あ": 22], english: [:]) }
    }

    @Test func smallKanaBelongsToTheSameVowelClassAsItsMora() throws {
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "客", ruby: [.init(text: "きゃく")])])])
        let plan = try LyricsAIPronunciation.make(draft: draft, vocabulary: ["き": 33, "ゃ": 87, "く": 35], english: [:])
        #expect(plan.tokens.map(\.sustainClass) == [1, 1, 3])
        #expect(plan.tokens.map(\.isMoraContinuation) == [false, true, false])
    }

    @Test func silenceAndAReal400PointToneUseTheExpectedMelConvention() throws {
        var filters = [Float](repeating: 0, count: 201 * 128)
        for band in 0..<128 { filters[10 * 128 + band] = 1 }
        let hann = (0..<400).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 400)) }
        let silence = try LyricsAIMel.encode([Float](repeating: 0, count: 400)[...], filters: filters, hann: hann)
        #expect(silence.count == 128 * 3000)
        #expect(silence.allSatisfy { $0 == -1.5 })
        let wave = (0..<480000).map { Float(sin(2 * Double.pi * 400 * Double($0) / 16000)) }
        let mel = try LyricsAIMel.encode(wave[...], filters: filters, hann: hann)
        // A unit sine becomes amplitude sqrt(2)*0.1; Hann's bin-10 power is 200.
        let expected = LyricsAIMel.roundedBFloat16(Float((log10(200.0) + 4) / 4))
        #expect(mel[100] == expected)
        #expect(mel[127 * 3000 + 100] == expected)
    }

    @Test func resamplingPreservesTheAudioClock() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("starry-ai-audio-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        buffer.frameLength = 4410
        let data = try #require(buffer.floatChannelData?[0])
        data.initialize(repeating: 0, count: 4410)
        data[882] = 1 // 20ms
        do { let output = try AVAudioFile(forWriting: file, settings: format.settings); try output.write(from: buffer) }
        let converted = try LyricsAIAudio.read(file)
        #expect(abs(converted.count - 1600) <= 1)
        let peak = try #require(converted.indices.max { abs(converted[$0]) < abs(converted[$1]) })
        #expect(abs(peak - 320) <= 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STARRY_AI_MODEL"] != nil))
    func externalCoreMLInferenceSmoke() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["STARRY_AI_MODEL"]))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("starry-ai-coreml-\(UUID()).wav")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("starry-ai-model-test-cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for i in 0..<48000 { buffer.floatChannelData![0][i] = Float(sin(2 * Double.pi * 220 * Double(i) / 16000)) * 0.1 }
        do { let output = try AVAudioFile(forWriting: file, settings: format.settings); try output.write(from: buffer) }
        let draft = LyricsDraft(lines: [.init(syllables: [.init(text: "あ"), .init(text: "い")])])
        let worker = LyricsAIAligner(cacheDirectory: cache)
        let result = try await worker.align(draft, vocals: file, modelDirectory: directory, backend: .neuralEngine)
        #expect(result.alignedSyllables == 2)
        #expect(result.draft.lines[0].syllables.allSatisfy { ($0.start ?? -1) >= 0 && ($0.end ?? 4) <= 3 && $0.end! > $0.start! })
        await worker.releaseWhenIdle()
    }
}
