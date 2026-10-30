import Testing
@testable import PlaybackEngine

@Suite struct ByteRangesTests {
    @Test func mergesTouchingAndOverlappingRanges() {
        var ranges = ByteRanges()
        ranges.insert(10..<20)
        ranges.insert(30..<40)
        ranges.insert(20..<25)
        #expect(ranges.ranges == [10..<25, 30..<40])
        ranges.insert(22..<35)
        #expect(ranges.ranges == [10..<40])
        ranges.insert(0..<5)
        #expect(ranges.ranges == [0..<5, 10..<40])
    }

    @Test func runsGapsAndCoverage() {
        var ranges = ByteRanges()
        ranges.insert(0..<100)
        ranges.insert(300..<400)
        #expect(ranges.end(ofRunAt: 50) == 100)
        #expect(ranges.end(ofRunAt: 150) == 150)
        #expect(ranges.start(after: 150) == 300)
        #expect(ranges.start(after: 350) == nil)
        #expect(ranges.firstGap(below: 500) == 100..<300)
        #expect(ranges.covers(10..<90))
        #expect(!ranges.covers(90..<310))
        ranges.insert(100..<300)
        #expect(ranges.firstGap(below: 500) == 400..<500)
        #expect(ranges.firstGap(below: 400) == nil)
    }
}
