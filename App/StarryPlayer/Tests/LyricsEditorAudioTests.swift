import AudioProcessing
import Testing
@testable import StarryPlayer

@MainActor
@Suite struct LyricsEditorAudioTests {
    @Test func combinedVoiceHintsKeepDistinctEventsAndUseTheStrongerCoincidentHint() {
        let result = LyricsEditorAudio.combinedHints(
            [VocalOnset(time: 1, strength: 0.6), VocalOnset(time: 2, strength: 0.8)],
            [VocalOnset(time: 1, strength: 0.9), VocalOnset(time: 1.02, strength: 0.7)])
        #expect(result == [VocalOnset(time: 1, strength: 0.9), VocalOnset(time: 1.02, strength: 0.7), VocalOnset(time: 2, strength: 0.8)])
    }
}
