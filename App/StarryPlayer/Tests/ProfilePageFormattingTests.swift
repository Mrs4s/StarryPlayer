import Testing
@testable import StarryPlayer

struct ProfilePageFormattingTests {
    @Test func countsInFullThenInWan() {
        #expect(ProfileFormat.count(0) == "0")
        #expect(ProfileFormat.count(35_558) == "35,558")
        #expect(ProfileFormat.count(99_999) == "99,999")
        #expect(ProfileFormat.count(164_130) == "16.4万")
    }
}
