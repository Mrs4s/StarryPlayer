import Foundation
import Testing
@testable import AudioProcessing

@Suite struct VocalDuetSeparatorTests {
    @Test func cancellationStopsBeforeOpeningAudioOrCompilingTheModel() async {
        let stopped = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await VocalDuetSeparator().separate(file: URL(fileURLWithPath: "/missing.caf"),
                    first: URL(fileURLWithPath: "/missing-a.caf"), second: URL(fileURLWithPath: "/missing-b.caf"),
                    model: URL(fileURLWithPath: "/missing.mlpackage"))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(stopped)
    }
}
